import AppKit
import SwiftUI
import RightMouseCore
import Darwin

@MainActor final class HostController {
    let paths: SharedPaths
    let model: AppModel
    private let ledger: CommandLedger
    private let inbox: InboxStore
    private let engine: FileTransferEngine
    private var queue: [CommandRequest] = []
    private var worker: Task<Void, Never>?
    private var cancellations: [UUID: TransferCancellation] = [:]
    private var results: [UUID: TransferResult] = [:]
    private var requests: [UUID: CommandRequest] = [:]
    private var activeIDs: Set<UUID> = []
    private var interactiveIDs: Set<UUID> = []
    private var pending: (token: UUID, files: [FileReference], identities: [UUID: String], expires: Date)?
    private let moveType = NSPasteboard.PasteboardType("cn.rightmouse.pending-move")
    var showTasks: (() -> Void)?

    init() throws {
        paths = try SharedPaths.resolve(); try paths.prepare()
        model = AppModel(configurationStore: ConfigurationStore(directory: paths.configurationDirectory), templateStore: TemplateStore(directory: paths.templatesDirectory))
        ledger = try CommandLedger(directory: paths.operationsDirectory.appendingPathComponent("Commands"))
        inbox = InboxStore(directory: paths.inboxDirectory)
        engine = FileTransferEngine(journalDirectory: paths.operationsDirectory.appendingPathComponent("Transfers"))
        if paths.isDevelopmentFallback { model.notice = "开发模式：应用操作可用，Finder 共享容器与签名仍需验证。" }
        model.onPerformAction = { [weak self] action, files, target in self?.perform(action, files: files, destination: target) }
        model.onConfigurationChanged = { _ in DistributedNotificationCenter.default().postNotificationName(Notification.Name("cn.rightmouse.configurationChanged"), object: nil, deliverImmediately: true) }
        model.onCancelTask = { [weak self] id in self?.cancellations[id]?.cancel() }
        model.onUndoTask = { [weak self] id in Task { await self?.undo(id) } }
        model.onRetryTask = { [weak self] id in self?.retry(id) }
        model.onReviewTask = { [weak self] id in self?.review(id) }
        model.onConfirmReviewTask = { [weak self] id in
            guard let self else { throw CommandFailure(.recoveryRequired, "任务服务已退出") }
            let directory = self.paths.operationsDirectory.appendingPathComponent("Reviews")
            try PrivateFileIO.ensureDirectory(directory)
            try PrivateFileIO.write(WireCodec.encoder().encode(ReviewConfirmation(requestID: id, confirmedAt: Date())), to: directory.appendingPathComponent(id.uuidString + ".json"))
        }
        try? FileManager.default.removeItem(at: paths.pendingMoveURL)
        restoreHistory()
    }

    func scanInbox() {
        do { for id in try inbox.pendingIDs() { receive(id) } }
        catch { model.reportError(error) }
    }
    func receive(_ id: UUID) {
        do { submit(try inbox.request(id)) }
        catch { model.reportError(error) }
    }
    func submit(_ request: CommandRequest, interactive: Bool = false) {
        do {
            _ = try RequestValidator.decode(WireCodec.encoder().encode(request))
            let accepted = try ledger.accept(request)
            requests[request.requestID] = request
            if !accepted.isNew {
                var receipt = accepted.entry.receipt
                if !activeIDs.contains(request.requestID), [.accepted,.planning,.running,.waitingForUser,.cancelling].contains(receipt.status) {
                    try update(request.requestID, status: .needsReview, error: CommandFailure(.recoveryRequired, "操作已被接受，但没有可确认的执行结果，请先核对。"))
                    guard let saved = try ledger.entry(request.requestID) else { throw CommandFailure(.recoveryRequired, "操作记录缺失") }; receipt = saved.receipt
                    model.updateTask(TaskPresentation(id: request.requestID, title: title(request.action), status: "需要核对", detail: receipt.error?.message ?? "", canReview: true))
                }
                publishBestEffort(receipt)
                if receipt.status == .needsReview { showTasks?() }
                return
            }
            activeIDs.insert(request.requestID)
            if interactive { interactiveIDs.insert(request.requestID) }
            publishBestEffort(accepted.entry.receipt)
            if request.action.changesFiles {
                cancellations[request.requestID] = TransferCancellation()
                model.updateTask(TaskPresentation(id: request.requestID, title: title(request.action), status: "等待处理", total: max(1, request.context.selection.count), canCancel: true))
                queue.append(request)
                startWorker()
            } else { Task { await self.execute(request) } }
        } catch { model.reportError(error) }
    }
    private func startWorker() {
        guard worker == nil else { return }
        worker = Task {
            while !queue.isEmpty {
                let request = queue.removeFirst()
                await execute(request)
            }
            worker = nil
        }
    }
    func perform(_ text: String, files: [URL], destination: URL?) {
        let components = text.split(separator: ":", maxSplits: 1).map(String.init)
        let name = components[0], argument = components.count > 1 ? components[1] : ""
        let selection = files.map(reference)
        let context = ActionContext(entryPoint: files.isEmpty ? .container : .items, container: destination.map { reference($0) }, selection: selection)
        let target = destination.map { reference($0) }
        let policy = ConflictPolicy(rawValue: model.configuration.conflictPolicy) ?? .ask
        let action: CommandAction
        switch name {
        case "createFile": action = .createFile(templateID: argument.isEmpty ? "txt" : argument, destination: target, name: nil)
        case "copyText": action = .copyText(format: CopyTextFormat(rawValue: argument) ?? .path)
        case "stageMove": action = .stageMove
        case "pasteMove":
            guard let pending = validPending() else { model.reportError("没有有效的待移动文件，请先剪切。"); return }
            action = .pasteMove(pendingToken: pending.token, destination: target, conflictPolicy: policy)
        case "copyTo", "moveTo": action = .transfer(mode: name == "copyTo" ? .copy : .move, destination: target, conflictPolicy: policy)
        case "openWith": action = .openWith(integrationID: argument, mode: argument == "terminal" || files.isEmpty ? .directory : .files)
        default: model.reportError("未知操作"); return
        }
        submit(CommandRequest(context: context, action: action), interactive: true)
    }

    private func execute(_ request: CommandRequest) async {
        let id = request.requestID
        var scopes: [URL] = []
        var effectStarted = false
        defer { for url in scopes { url.stopAccessingSecurityScopedResource() }; cancellations[id] = nil; activeIDs.remove(id); interactiveIDs.remove(id) }
        do {
            if cancellations[id]?.isCancelled == true { throw CommandFailure(.cancelled, "已取消尚未开始的任务") }
            try update(id, status: .planning)
            scopes = try resolveAccess(for: request, interactive: interactiveIDs.contains(id))
            var items: [ItemReceipt] = []
            switch request.action {
            case let .copyText(format):
                let urls = request.context.selection.isEmpty ? [request.context.container!.url] : request.context.selection.map(\.url)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(PathText.format(urls, as: format), forType: .string)
                invalidatePending(); model.notice = "已复制 \(urls.count) 项。"
            case .stageMove:
                var identities: [UUID: String] = [:]
                for file in request.context.selection { identities[file.refID] = try identity(file.url) }
                let token = UUID(), expiry = Date().addingTimeInterval(86400)
                pending = (token, request.context.selection, identities, expiry)
                try writePending()
                model.notice = "已剪切 \(request.context.selection.count) 项，请到目标目录粘贴。"
            case let .createFile(templateID, destination, name):
                guard let template = model.configuration.templates.first(where: { $0.id == templateID }) else { throw CommandFailure(.invalidRequest, "模板不存在，请刷新菜单") }
                let target = try chooseTarget(try targetURL(destination, context: request.context), context: request.context, infer: false)
                try update(id, status: .running)
                let store = model.templateStore
                effectStarted = true
                let created = try await Task.detached { try store.create(template: template, in: target, filename: name, date: request.createdAt) }.value
                items = [ItemReceipt(status: "success", destinationURL: created)]
                if model.configuration.revealCreatedFile { NSWorkspace.shared.activateFileViewerSelecting([created]) }
            case let .transfer(mode, destination, policy):
                let target = try chooseTarget(destination?.url, context: request.context, infer: false)
                await transfer(request, sources: request.context.selection.map(\.url), destination: target, mode: mode, policy: policy)
                return
            case let .pasteMove(token, destination, policy):
                guard let state = validPending(), state.token == token else { throw CommandFailure(.requestExpired, "剪切列表已失效，请重新选择文件并剪切") }
                for file in state.files {
                    guard try identity(file.url) == state.identities[file.refID] else { throw CommandFailure(.sourceChanged, "剪切后的来源已改变，请重新选择") }
                }
                let target = try chooseTarget(try targetURL(destination, context: request.context), context: request.context, infer: false)
                await transfer(request, sources: state.files.map(\.url), destination: target, mode: .move, policy: policy)
                if let result = results[id], pending?.token == token {
                    let done = Set(result.items.filter { $0.status == .completed }.map { $0.source.standardizedFileURL.path })
                    pending?.files.removeAll { done.contains($0.url.standardizedFileURL.path) }
                    if pending?.files.isEmpty == true { invalidatePending() } else { try writePending() }
                }
                return
            case let .openFavorite(favoriteID):
                guard let location = model.configuration.favorites.first(where: { $0.id == favoriteID }) else { throw CommandFailure(.invalidRequest, "收藏目录已被移除") }
                let url = try location.resolve()
                guard NSWorkspace.shared.open(url) else { throw CommandFailure(.volumeUnavailable, "无法打开此目录") }
            case let .openWith(integrationID, mode):
                guard let integration = model.configuration.integrations.first(where: { $0.id == integrationID && $0.enabled }) else { throw CommandFailure(.appUnavailable, "打开方式已停用或不存在") }
                let urls: [URL]
                if mode == .directory { urls = [try chooseTarget(try contextDirectory(request.context), context: request.context, infer: false)] }
                else { urls = request.context.selection.map(\.url) }
                guard !urls.isEmpty else { throw CommandFailure(.contextUnavailable, "请选择要打开的文件") }
                try await ApplicationLauncher.open(urls, with: integration)
            }
            try update(id, status: .completed, items: items)
            if request.action.changesFiles {
                model.updateTask(TaskPresentation(id: id, title: title(request.action), status: "完成", completed: max(1, items.count), total: max(1, items.count), items: items.map { TaskItemPresentation(name: $0.destinationURL?.lastPathComponent ?? "完成", status: "成功", destination: $0.destinationURL) }))
            }
        } catch {
            let failure = (error as? CommandFailure) ?? CommandFailure(.ioFailed, error.localizedDescription)
            var status: ReceiptStatus = effectStarted ? .needsReview : (failure.code == .cancelled ? .cancelled : .failed)
            do { try update(id, status: status, error: failure) }
            catch { status = .needsReview }
            model.updateTask(TaskPresentation(id: id, title: title(request.action), status: stateTitle(status.rawValue), detail: status == .needsReview ? "操作结果或状态记录需要核对。\(failure.message)" : failure.message, canReview: status == .needsReview))
            if failure.code != .cancelled { model.reportError(failure) }
        }
    }

    private func transfer(_ request: CommandRequest, sources: [URL], destination: URL, mode: CommandTransferMode, policy: ConflictPolicy) async {
        let id = request.requestID
        let cancellation = cancellations[id] ?? TransferCancellation()
        cancellations[id] = cancellation
        do { try update(id, status: .running) }
        catch { model.reportError(error); return }
        showTasks?()
        let result = await engine.transfer(sources: sources, to: destination, mode: mode == .copy ? .copy : .move,
            conflictPolicy: TransferConflictPolicy(rawValue: policy.rawValue) ?? .ask, cancellation: cancellation,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.model.updateTask(TaskPresentation(id: id, title: self.title(request.action), status: "处理中", detail: self.phaseTitle(progress.phase), completed: progress.completedItems, total: progress.totalItems, canCancel: true))
                }
            }, resolveConflict: { [weak self] source, target in
                await self?.resolveConflict(source: source, target: target) ?? .cancel
            }, operationID: id)
        results[id] = result
        let itemReceipts = result.items.map { item in
            ItemReceipt(itemID: item.itemID, status: item.status == .completed ? "success" : item.status.rawValue, destinationURL: item.destination,
                        error: item.status == .failed ? CommandFailure(.ioFailed, item.message) : (item.status == .sourceRetained ? CommandFailure(.sourceRetained, item.message) : nil))
        }
        do {
            try update(id, status: ReceiptStatus(rawValue: result.state) ?? .needsReview, items: itemReceipts)
            model.updateTask(presentation(result, title: title(request.action)))
        } catch {
            var task = presentation(result, title: title(request.action)); task.status = "需要核对"; task.canReview = true; task.canRetry = false
            task.detail = "文件引擎已返回结果，但主任务记录失败；请核对后再操作。"
            model.updateTask(task); model.reportError(error)
        }
    }
    private func resolveConflict(source: URL, target: URL) -> TransferConflictDecision {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "目标已存在同名项目"
        alert.informativeText = "来源：\(source.path)\n目标：\(target.path)\n保留两份将为新项目添加编号。"
        alert.addButton(withTitle: "保留两份"); alert.addButton(withTitle: "跳过"); alert.addButton(withTitle: "取消剩余操作")
        switch alert.runModal() { case .alertFirstButtonReturn: return .keepBoth; case .alertSecondButtonReturn: return .skip; default: return .cancel }
    }
    private func chooseTarget(_ explicit: URL?, context: ActionContext, infer: Bool) throws -> URL {
        if let proposed = explicit ?? (infer ? PathText.directory(for: context) : nil) {
            var url = proposed
            if let favorite = (model.configuration.favorites + model.configuration.watchedLocations).first(where: { $0.path == proposed.path }) { url = try favorite.resolve() }
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CommandFailure(.invalidDestination, "目标不是有效目录") }
            return url
        }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "请选择此操作的目标目录。"; panel.prompt = "选择目录"
        guard panel.runModal() == .OK, let url = panel.url else { throw CommandFailure(.cancelled, "已取消选择目标目录") }
        return url
    }
    private func reference(_ url: URL) -> FileReference {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
        return FileReference(url: url, kindHint: values?.isSymbolicLink == true ? .symlink : (values?.isDirectory == true ? .directory : .file))
    }
    private func resolveAccess(for request: CommandRequest, interactive: Bool) throws -> [URL] {
        // Local UI calls originate from a system picker in this process. Finder requests
        // must stay within configured, bookmark-resolved roots; a URL is not a grant.
        var references = request.context.selection.map(\.url)
        if case .pasteMove = request.action, let pending { references.append(contentsOf: pending.files.map(\.url)) }
        if let container = request.context.container { references.append(container.url) }
        switch request.action {
        case let .createFile(_, destination, _), let .pasteMove(_, destination, _), let .transfer(_, destination, _):
            if let destination { references.append(destination.url.resolvingSymlinksInPath()) }
        default: break
        }
        let locations = model.configuration.watchedLocations + model.configuration.favorites
        var roots: [URL] = []
        var scopes: [URL] = []
        var succeeded = false
        defer { if !succeeded { for scope in scopes { scope.stopAccessingSecurityScopedResource() } } }
        if interactive {
            for url in references where url.startAccessingSecurityScopedResource() { scopes.append(url) }
            succeeded = true
            return scopes
        }
        for location in locations {
            let isRequestedFavorite: Bool
            if case let .openFavorite(favoriteID) = request.action { isRequestedFavorite = location.id == favoriteID }
            else { isRequestedFavorite = false }
            guard references.contains(where: { $0.standardizedFileURL.path == location.path || $0.standardizedFileURL.path.hasPrefix(location.path + "/") }) || isRequestedFavorite else { continue }
            let resolved = try location.resolve()
            if resolved.startAccessingSecurityScopedResource() { scopes.append(resolved) }
            roots.append(resolved.resolvingSymlinksInPath().standardizedFileURL)
        }
        if !interactive && request.action.type != "openFavorite" {
            for url in references {
                let canonical = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
                guard roots.contains(where: { canonical == $0.path || canonical.hasPrefix($0.path + "/") }) else {
                    throw CommandFailure(.accessDenied, "Finder 请求中的位置不在已授权的使用目录内，请在设置中重新选择该目录。")
                }
            }
        }
        succeeded = true
        return scopes
    }
    private func contextDirectory(_ context: ActionContext) throws -> URL? {
        if context.selection.isEmpty { return context.container?.url }
        if context.selection.count == 1 {
            let url = context.selection[0].url
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true ? url : url.deletingLastPathComponent()
        }
        let parents = Set(context.selection.map { $0.url.deletingLastPathComponent().standardizedFileURL })
        return parents.count == 1 ? parents.first : nil
    }
    private func targetURL(_ reference: FileReference?, context: ActionContext) throws -> URL? {
        guard let reference else { return nil }
        if reference.kindHint == .unknown { return try contextDirectory(context) }
        return reference.url
    }
    private func identity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CommandFailure(.sourceMissing, "来源不存在或不可访问") }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mode & S_IFMT)"
    }
    private func validPending() -> (token: UUID, files: [FileReference], identities: [UUID: String], expires: Date)? {
        guard let pending, pending.expires > Date(), NSPasteboard.general.string(forType: moveType) == pending.token.uuidString else { invalidatePending(); return nil }
        return pending
    }
    private func writePending() throws {
        guard let pending else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pending.token.uuidString, forType: moveType)
        try PrivateFileIO.write(WireCodec.encoder().encode(PendingMoveSnapshot(token: pending.token, count: pending.files.count, expiresAt: pending.expires)), to: paths.pendingMoveURL)
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("cn.rightmouse.pendingMoveChanged"), object: nil, deliverImmediately: true)
    }
    private func invalidatePending() { pending = nil; try? FileManager.default.removeItem(at: paths.pendingMoveURL) }
    private func publish(_ receipt: CommandReceipt) throws {
        try PrivateFileIO.write(WireCodec.encoder().encode(receipt), to: paths.receiptsDirectory.appendingPathComponent(receipt.requestID.uuidString + ".json"))
    }
    private func publishBestEffort(_ receipt: CommandReceipt) {
        do { try publish(receipt) }
        catch { model.notice = "任务状态已保存在本机，但共享回执暂时写入失败；请在文件任务中查看实际结果。" }
    }
    private func update(_ id: UUID, status: ReceiptStatus, items: [ItemReceipt] = [], error: CommandFailure? = nil) throws {
        guard var entry = try ledger.entry(id) else { throw CommandFailure(.recoveryRequired, "操作日志缺失") }
        entry.receipt = CommandReceipt(requestID: id, revision: entry.receipt.revision + 1, status: status, itemResults: items, error: error)
        try ledger.save(entry); publishBestEffort(entry.receipt)
        if [.completed,.partial,.failed,.cancelled,.rejected].contains(status) { try? inbox.remove(id) }
    }
    private func restoreHistory() {
        do {
            let scan = try ledger.scanEntries()
            if !scan.issues.isEmpty { model.notice = "有 \(scan.issues.count) 条操作记录损坏或版本不兼容，已保留现场；其他任务仍可核对。" }
            let entries = scan.entries.sorted(by: { $0.request.createdAt > $1.request.createdAt })
            for (index, original) in entries.enumerated() {
                var entry = original
                requests[entry.request.requestID] = entry.request
                let terminal: Set<ReceiptStatus> = [.completed,.partial,.failed,.cancelled,.rejected,.needsReview]
                if !terminal.contains(entry.receipt.status) {
                    entry.receipt.status = .needsReview; entry.receipt.revision += 1
                    entry.receipt.error = CommandFailure(.recoveryRequired, "上次操作未留下完整结果，请核对文件和任务记录。")
                    try ledger.save(entry); publishBestEffort(entry.receipt)
                }
                if entry.request.action.changesFiles && (index < 100 || entry.receipt.status == .needsReview) {
                    model.updateTask(TaskPresentation(id: entry.request.requestID, title: title(entry.request.action), status: entry.receipt.status == .needsReview ? "需要核对" : stateTitle(entry.receipt.status.rawValue), detail: entry.receipt.error?.message ?? "历史任务", total: entry.receipt.itemResults.count, items: entry.receipt.itemResults.map { TaskItemPresentation(name: $0.destinationURL?.lastPathComponent ?? "项目", status: stateTitle($0.status), detail: $0.error?.message ?? "", destination: $0.destinationURL) }, canReview: true))
                }
            }
        } catch { model.reportError("读取操作记录失败，已保留现场：\(error.localizedDescription)") }
    }
    private func presentation(_ result: TransferResult, title: String) -> TaskPresentation {
        TaskPresentation(id: result.operationID, title: title, status: stateTitle(result.state), detail: "完成 \(result.completedCount) / \(result.items.count) 项", completed: result.completedCount, total: result.items.count, items: result.items.map { TaskItemPresentation(name: $0.source.lastPathComponent, status: stateTitle($0.status.rawValue), detail: $0.message, destination: $0.destination) }, canUndo: result.items.contains { $0.undoToken != nil }, canRetry: result.items.contains { $0.status == .failed }, canReview: result.items.contains { $0.status == .needsReview || $0.status == .sourceRetained })
    }
    private func undo(_ id: UUID) async {
        guard let result = results[id] else { return }
        do {
            for token in result.items.compactMap(\.undoToken) { try await engine.undo(token) }
            var task = presentation(result, title: "已撤销移动"); task.status = "已撤销"; task.canUndo = false; model.updateTask(task)
        } catch { model.reportError(error) }
    }
    private func retry(_ id: UUID) {
        guard let result = results[id], let old = requests[id], case let .transfer(mode,destination,policy) = old.action else { model.reportError("请重新选择未完成的文件，再发起操作。"); return }
        let failed = result.items.filter { $0.status == .failed }.map { reference($0.source) }
        guard !failed.isEmpty else { return }
        let context = ActionContext(entryPoint: .items, container: old.context.container, selection: failed)
        submit(CommandRequest(context: context, action: .transfer(mode: mode, destination: destination, conflictPolicy: policy)), interactive: true)
    }
    private func review(_ id: UUID) {
        Task {
            do {
                guard let entry = try ledger.entry(id) else { throw CommandFailure(.recoveryRequired, "操作记录缺失") }
                let records = try await engine.recoveryRecords().filter { $0.operationID == id }
                var items: [TaskReviewItemPresentation] = []
                for record in records {
                    let assessment = await engine.recoveryAssessment(record)
                    items.append(TaskReviewItemPresentation(id: record.itemID, name: record.source.lastPathComponent, status: stateTitle(record.phase), detail: assessment, source: record.source, destination: record.destination, sourceObservation: observation(record.source), destinationObservation: observation(record.destination)))
                }
                if items.isEmpty {
                    items = entry.receipt.itemResults.map { item in
                        TaskReviewItemPresentation(id: item.itemID, name: item.destinationURL?.lastPathComponent ?? "操作项目", status: stateTitle(item.status), detail: item.error?.message ?? "请核对实际文件内容。", destination: item.destinationURL, destinationObservation: item.destinationURL.map(observation) ?? "没有已记录的目标")
                    }
                }
                if items.isEmpty {
                    items = entry.request.context.selection.map { source in
                        TaskReviewItemPresentation(id: source.refID, name: source.url.lastPathComponent, status: stateTitle(entry.receipt.status.rawValue), detail: "未记录确定的目标，请自行核对操作位置；本工具不会重放请求。", source: source.url, sourceObservation: observation(source.url))
                    }
                }
                let confirmationURL = paths.operationsDirectory.appendingPathComponent("Reviews").appendingPathComponent(id.uuidString + ".json")
                let confirmation = (try? PrivateFileIO.read(confirmationURL, maximumBytes: 4096)).flatMap { try? WireCodec.decoder().decode(ReviewConfirmation.self, from: $0) }
                model.showReview(TaskReviewPresentation(id: id, title: title(entry.request.action), status: stateTitle(entry.receipt.status.rawValue), summary: entry.receipt.error?.message ?? "检查来源与目标。确认仅记录人工核对，不改变原始操作结果。", items: items, canConfirm: !items.isEmpty, previouslyConfirmedAt: confirmation?.confirmedAt))
                showTasks?()
            } catch { model.reviewError = error.localizedDescription; model.reportError(error) }
        }
    }
    private struct ReviewConfirmation: Codable { var schemaVersion = 1; let requestID: UUID; let confirmedAt: Date }
    private func observation(_ url: URL) -> String {
        var info = stat()
        if lstat(url.path, &info) == 0 { return "位置存在；此检查不能证明文件内容一致" }
        return errno == ENOENT ? "位置不存在" : "无法读取此位置，请检查访问权限"
    }
    private func title(_ action: CommandAction) -> String {
        switch action { case .createFile: return "新建文件"; case .copyText: return "复制路径与名称"; case .stageMove: return "剪切文件"; case .pasteMove: return "粘贴待移动文件"; case let .transfer(mode,_,_): return mode == .copy ? "复制文件" : "移动文件"; case .openFavorite: return "打开常用目录"; case .openWith: return "在应用中打开" }
    }
    private func phaseTitle(_ value: String) -> String { ["scanning":"正在扫描文件","copying":"正在复制","verifying":"正在校验","committing":"正在提交目标","sourceCleanupPending":"正在核对来源"][value] ?? stateTitle(value) }
    private func stateTitle(_ value: String) -> String { ["completed":"完成","success":"成功","partial":"部分完成","failed":"失败","cancelled":"已取消","needsReview":"需要核对","sourceRetained":"源文件已保留","skipped":"已跳过"][value] ?? value }
}
