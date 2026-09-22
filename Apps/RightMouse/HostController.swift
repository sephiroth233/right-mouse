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
    private let followups: TaskFollowupStore
    private enum Work { case command(CommandRequest), undo(UUID) }
    private var queue: [Work] = []
    private var queuedUndos: Set<UUID> = []
    private var worker: Task<Void, Never>?
    private var cancellations: [UUID: TransferCancellation] = [:]
    private var results: [UUID: TransferResult] = [:]
    private var requests: [UUID: CommandRequest] = [:]
    private var activeIDs: Set<UUID> = []
    private var interactiveIDs: Set<UUID> = []
    private var sessionAuthorizedIDs: Set<UUID> = []
    private var followupParents: [UUID: UUID] = [:]
    private let conflictPrompt: ConflictPrompt
    private let projectDirectoryPicker: ProjectDirectoryPicker
    private let openApplication: ApplicationOpen
    private var waitingConflicts: Set<UUID> = []
    private var batchConflictDecisions: [UUID: TransferConflictDecision] = [:]
    private var conflictFailures: [UUID: CommandFailure] = [:]
    private var conflictStopNotes: [UUID: String] = [:]
    private var pending: (token: UUID, files: [FileReference], identities: [UUID: String], expires: Date)?
    private let moveType = NSPasteboard.PasteboardType("cn.rightmouse.pending-move")
    var showTasks: (() -> Void)?

    init(storagePaths: SharedPaths? = nil, conflictPrompt: @escaping ConflictPrompt = ConflictDialog.present,
         projectDirectoryPicker: @escaping ProjectDirectoryPicker = OpenWithInteraction.chooseProjectDirectory,
         openApplication: @escaping ApplicationOpen = { urls, integration in try await ApplicationLauncher.open(urls, with: integration) }) throws {
        self.conflictPrompt = conflictPrompt
        self.projectDirectoryPicker = projectDirectoryPicker; self.openApplication = openApplication
        if let storagePaths { paths = storagePaths; try paths.prepare() }
        else { paths = try SharedPaths.resolveAndPrepare() }
        model = AppModel(configurationStore: ConfigurationStore(directory: paths.configurationDirectory), templateStore: TemplateStore(directory: paths.templatesDirectory))
        ledger = try CommandLedger(directory: paths.operationsDirectory.appendingPathComponent("Commands"))
        inbox = InboxStore(directory: paths.inboxDirectory)
        engine = FileTransferEngine(journalDirectory: paths.operationsDirectory.appendingPathComponent("Transfers"))
        followups = TaskFollowupStore(directory: paths.operationsDirectory.appendingPathComponent("Followups"))
        model.isDevelopmentStorage = paths.isDevelopmentFallback
        model.storageDiagnostic = paths.developmentDiagnostic
        model.onPerformAction = { [weak self] action, files, target in self?.perform(action, files: files, destination: target) }
        model.onConfigurationChanged = { _ in DistributedNotificationCenter.default().postNotificationName(Notification.Name("cn.rightmouse.configurationChanged"), object: nil, deliverImmediately: true) }
        model.onCancelTask = { [weak self] id in self?.cancellations[id]?.cancel() }
        model.onUndoTask = { [weak self] id in self?.enqueueUndo(id) }
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
    @discardableResult func submit(_ request: CommandRequest, interactive: Bool = false) -> Bool {
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
                return true
            }
            activeIDs.insert(request.requestID)
            if interactive { interactiveIDs.insert(request.requestID); sessionAuthorizedIDs.insert(request.requestID) }
            publishBestEffort(accepted.entry.receipt)
            if request.action.changesFiles {
                cancellations[request.requestID] = TransferCancellation()
                model.updateTask(TaskPresentation(id: request.requestID, title: title(request.action), status: "等待处理", total: max(1, request.context.selection.count), canCancel: true))
                queue.append(.command(request))
                startWorker()
            } else { Task { await self.execute(request) } }
            return true
        } catch { model.reportError(error); return false }
    }
    private func startWorker() {
        guard worker == nil else { return }
        worker = Task {
            while !queue.isEmpty {
                switch queue.removeFirst() {
                case .command(let request): await execute(request)
                case .undo(let id): await undo(id)
                }
            }
            worker = nil
        }
    }
    func perform(_ text: String, files: [URL], destination: URL?) {
        let components = text.split(separator: ":", maxSplits: 1).map(String.init)
        let name = components[0], argument = components.count > 1 ? components[1] : ""
        let selection = files.map(reference)
        var target = destination.map { reference($0) }
        if destination == model.destination, let recentID = model.selectedRecentDestinationID { target?.bookmarkToken = recentID }
        let usesDestination = ["createFile", "pasteMove", "copyTo", "moveTo"].contains(name)
        let context = ActionContext(entryPoint: files.isEmpty ? .container : .items,
                                    container: usesDestination || files.isEmpty ? target : nil, selection: selection)
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
        defer { for url in scopes { url.stopAccessingSecurityScopedResource() }; cancellations[id] = nil; activeIDs.remove(id); interactiveIDs.remove(id); followupParents[id] = nil }
        do {
            if cancellations[id]?.isCancelled == true { throw CommandFailure(.cancelled, "已取消尚未开始的任务") }
            try update(id, status: .planning)
            if let parent = followupParents[id], let followup = try verifiedFollowup(parent) {
                scopes = try acquireFollowupAccess(id: parent, record: followup, urls: request.context.selection.map(\.url) + [followup.destination].compactMap { $0 })
                try validateRetryIdentities(parent: parent, record: followup)
                if sessionAuthorizedIDs.contains(parent) { sessionAuthorizedIDs.insert(id) }
            } else {
                scopes = try resolveAccess(for: request, interactive: interactiveIDs.contains(id))
            }
            var items: [ItemReceipt] = []
            switch request.action {
            case let .copyText(format):
                let urls = request.context.selection.isEmpty ? [try resolveStoredReference(request.context.container!)] : request.context.selection.map(\.url)
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
                if target.startAccessingSecurityScopedResource() { scopes.append(target) }
                try update(id, status: .running)
                let store = model.templateStore
                effectStarted = true
                let created = try await Task.detached { try store.create(template: template, in: target, filename: name, date: request.createdAt) }.value
                items = [ItemReceipt(status: "success", destinationURL: created)]
                model.rememberDestination(target)
                if model.configuration.revealCreatedFile { NSWorkspace.shared.activateFileViewerSelecting([created]) }
            case let .transfer(mode, destination, policy):
                let target = try chooseTarget(try targetURL(destination, context: request.context), context: request.context, infer: false)
                if target.startAccessingSecurityScopedResource() { scopes.append(target) }
                await transfer(request, sources: request.context.selection.map(\.url), destination: target, mode: mode, policy: policy, grantedScopes: scopes)
                return
            case let .pasteMove(token, destination, policy):
                guard let state = validPending(), state.token == token else { throw CommandFailure(.requestExpired, "剪切列表已失效，请重新选择文件并剪切") }
                for file in state.files {
                    guard try identity(file.url) == state.identities[file.refID] else { throw CommandFailure(.sourceChanged, "剪切后的来源已改变，请重新选择") }
                }
                let target = try chooseTarget(try targetURL(destination, context: request.context), context: request.context, infer: false)
                if target.startAccessingSecurityScopedResource() { scopes.append(target) }
                await transfer(request, sources: state.files.map(\.url), destination: target, mode: .move, policy: policy, grantedScopes: scopes)
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
                if mode == .directory || integration.adapterType == "terminal" { urls = [try chooseTarget(try contextDirectory(request.context), context: request.context, infer: false)] }
                else { urls = request.context.selection.map(\.url) }
                guard !urls.isEmpty else { throw CommandFailure(.contextUnavailable, "请选择要打开的文件") }
                switch try ApplicationLauncher.plan(urls, with: integration) {
                case .launch(let planned): try await openApplication(planned, integration)
                case .chooseProjectDirectory:
                    try update(id, status: .waitingForUser)
                    guard let project = projectDirectoryPicker() else { throw CommandFailure(.cancelled, "已取消选择项目目录，未启动应用。") }
                    guard project.isFileURL, try project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                        throw CommandFailure(.invalidDestination, "请选择有效的项目目录。")
                    }
                    if project.startAccessingSecurityScopedResource() { scopes.append(project) }
                    try update(id, status: .running)
                    try await openApplication([project], integration)
                }
                model.notice = "已将所选项目交给 \(integration.name)。"
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

    private func transfer(_ request: CommandRequest, sources: [URL], destination: URL, mode: CommandTransferMode, policy: ConflictPolicy, grantedScopes: [URL]) async {
        let id = request.requestID
        defer {
            waitingConflicts.remove(id); batchConflictDecisions[id] = nil
            conflictFailures[id] = nil; conflictStopNotes[id] = nil
        }
        let cancellation = cancellations[id] ?? TransferCancellation()
        cancellations[id] = cancellation
        do {
            var record = TaskFollowupRecord(requestID: id, destination: destination)
            record.destinationIdentity = try identity(destination.resolvingSymlinksInPath())
            record.accessBookmarks = (grantedScopes + sources + sources.map { $0.deletingLastPathComponent() } + [destination]).compactMap {
                try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            try followups.save(record)
            try update(id, status: .running)
        } catch {
            model.updateTask(TaskPresentation(id: id, title: title(request.action), status: "需要核对", detail: "无法保存执行计划，未开始文件操作。", canReview: true))
            model.reportError(error); return
        }
        showTasks?()
        let result = await engine.transfer(sources: sources, to: destination, mode: mode == .copy ? .copy : .move,
            conflictPolicy: TransferConflictPolicy(rawValue: policy.rawValue) ?? .ask, cancellation: cancellation,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.activeIDs.contains(id), self.results[id] == nil else { return }
                    if self.waitingConflicts.contains(id) {
                        if var waiting = self.model.tasks.first(where: { $0.id == id }) {
                            waiting.completed = max(waiting.completed, progress.completedItems)
                            waiting.total = progress.totalItems
                            self.model.updateTask(waiting)
                        }
                        return
                    }
                    self.model.updateTask(TaskPresentation(id: id, title: self.title(request.action), status: "处理中", detail: self.phaseTitle(progress.phase), completed: progress.completedItems, total: progress.totalItems, canCancel: true))
                }
            }, resolveConflict: { [weak self] source, target in
                await self?.resolveConflict(id: id, source: source, target: target) ?? .cancel
            }, operationID: id)
        results[id] = result
        if result.completedCount > 0 { model.rememberDestination(destination) }
        if let parent = followupParents[id], let old = requests[parent], case let .pasteMove(token, _, _) = old.action, pending?.token == token {
            let moved = Set(result.items.filter { $0.status == .completed }.map { $0.source.standardizedFileURL.path })
            pending?.files.removeAll { moved.contains($0.url.standardizedFileURL.path) }
            if pending?.files.isEmpty == true { invalidatePending() }
            else {
                do { try writePending() }
                catch { model.notice = "重试结果已保留，但剪切列表快照未更新；请重新剪切剩余项目。" }
            }
        }
        let itemReceipts = result.items.map { item in
            ItemReceipt(itemID: item.itemID, status: item.status == .completed ? "success" : item.status.rawValue, destinationURL: item.destination,
                        error: item.status == .failed ? CommandFailure(.ioFailed, item.message) : (item.status == .sourceRetained ? CommandFailure(.sourceRetained, item.message) : nil))
        }
        do {
            var followup = try followups.read(id) ?? TaskFollowupRecord(requestID: id, destination: destination)
            followup.result = result
            try followups.save(followup)
            let failure = conflictFailures[id]
            let note = conflictStopNotes[id]
            try update(id, status: failure == nil ? (ReceiptStatus(rawValue: result.state) ?? .needsReview) : .needsReview,
                       items: itemReceipts, error: failure ?? note.map { CommandFailure(.cancelled, $0) })
            var task = decorate(presentation(result, title: title(request.action)), followup: followup)
            if let failure {
                task.status = "需要核对"; task.detail = failure.message
                task.canUndo = false; task.canRetry = false; task.canReview = true
            } else if let note { task.detail += "；\(note)" }
            model.updateTask(task)
        } catch {
            var task = presentation(result, title: title(request.action)); task.status = "需要核对"; task.canReview = true; task.canRetry = false; task.canUndo = false
            task.detail = "文件引擎已返回结果，但主任务记录失败；请核对后再操作。"
            model.updateTask(task); model.reportError(error)
        }
    }
    private func resolveConflict(id: UUID, source: URL, target: URL) async -> TransferConflictDecision {
        guard let cancellation = cancellations[id], !cancellation.isCancelled else { return .cancel }
        if let decision = batchConflictDecisions[id] { return decision }
        do {
            try update(id, status: .waitingForUser)
            waitingConflicts.insert(id)
            var task = model.tasks.first(where: { $0.id == id }) ?? TaskPresentation(id: id, title: "文件操作", status: "等待选择")
            task.status = "等待选择"; task.detail = "目标中已有“\(target.lastPathComponent)”，请选择处理方式。"; task.canCancel = true
            model.updateTask(task)
            showTasks?()
            let response = await conflictPrompt(source, target, cancellation)
            waitingConflicts.remove(id)
            try update(id, status: .running)
            task = model.tasks.first(where: { $0.id == id }) ?? task
            task.status = "处理中"; task.detail = "正在重新核对来源和目标。"
            model.updateTask(task)
            if response.reason == .timedOut { conflictStopNotes[id] = "等待选择超过 15 分钟，已取消剩余操作。" }
            if response.reason == .unavailable { conflictStopNotes[id] = "冲突窗口不可用或已关闭，已取消剩余操作。" }
            guard !cancellation.isCancelled, response.reason == .user else { return .cancel }
            if response.applyToRemaining && response.decision != .cancel { batchConflictDecisions[id] = response.decision }
            return response.decision
        } catch {
            waitingConflicts.remove(id); cancellation.cancel()
            conflictFailures[id] = CommandFailure(.recoveryRequired, "无法保存冲突等待状态，已停止后续操作；请核对已完成项目。")
            model.reportError(error)
            return .cancel
        }
    }
    private func chooseTarget(_ explicit: URL?, context: ActionContext, infer: Bool) throws -> URL {
        if let proposed = explicit ?? (infer ? PathText.directory(for: context) : nil) {
            guard try proposed.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CommandFailure(.invalidDestination, "目标不是有效目录") }
            return proposed
        }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "请选择此操作的目标目录。"; panel.prompt = "选择目录"
        guard panel.runModal() == .OK, let url = panel.url else { throw CommandFailure(.cancelled, "已取消选择目标目录") }
        model.rememberDestination(url)
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
        if let container = request.context.container { references.append(try resolveStoredReference(container)) }
        var requestedRecent: UUID?
        switch request.action {
        case let .createFile(_, destination, _), let .pasteMove(_, destination, _), let .transfer(_, destination, _):
            if let destination {
                references.append(try resolveStoredReference(destination).resolvingSymlinksInPath())
                requestedRecent = destination.bookmarkToken
            }
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
        for location in model.configuration.recentDestinations {
            guard location.id == requestedRecent || references.contains(where: { $0.path == location.path || $0.path.hasPrefix(location.path + "/") }) else { continue }
            let resolved = try location.resolve()
            if resolved.startAccessingSecurityScopedResource() { scopes.append(resolved) }
            roots.append(resolved.resolvingSymlinksInPath().standardizedFileURL)
        }
        for location in locations {
            let isRequestedFavorite: Bool
            if case let .openFavorite(favoriteID) = request.action { isRequestedFavorite = location.id == favoriteID }
            else { isRequestedFavorite = location.id == requestedRecent }
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
        if context.selection.isEmpty {
            guard let container = context.container else { return nil }
            return try resolveStoredReference(container)
        }
        if context.selection.count == 1 {
            let url = context.selection[0].url
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true ? url : url.deletingLastPathComponent()
        }
        let parents = Set(context.selection.map { $0.url.deletingLastPathComponent().standardizedFileURL })
        return parents.count == 1 ? parents.first : nil
    }
    private func targetURL(_ reference: FileReference?, context: ActionContext) throws -> URL? {
        guard let reference else { return nil }
        if reference.bookmarkToken != nil { return try resolveStoredReference(reference) }
        if reference.kindHint == .unknown { return try contextDirectory(context) }
        return reference.url
    }
    private func resolveStoredReference(_ reference: FileReference) throws -> URL {
        guard let token = reference.bookmarkToken else { return reference.url }
        if let recent = model.configuration.recentDestinations.first(where: { $0.id == token }) { return try recent.resolve() }
        if let saved = (model.configuration.favorites + model.configuration.watchedLocations).first(where: { $0.id == token }) { return try saved.resolve() }
        throw CommandFailure(.bookmarkStale, "保存的目标已移除或不再可用，请重新选择目录。")
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
                    var task = TaskPresentation(id: entry.request.requestID, title: title(entry.request.action), status: entry.receipt.status == .needsReview ? "需要核对" : stateTitle(entry.receipt.status.rawValue), detail: entry.receipt.error?.message ?? "历史任务", total: entry.receipt.itemResults.count, items: entry.receipt.itemResults.map { TaskItemPresentation(name: $0.destinationURL?.lastPathComponent ?? "项目", status: stateTitle($0.status), detail: $0.error?.message ?? "", destination: $0.destinationURL) }, canReview: true)
                    do {
                        if entry.receipt.status != .needsReview, let followup = try verifiedFollowup(entry.request.requestID), let result = followup.result {
                            results[result.operationID] = result
                            task = decorate(presentation(result, title: title(entry.request.action)), followup: followup)
                            task.canReview = true
                        }
                    } catch {
                        task.status = "需要核对"; task.detail = error.localizedDescription
                    }
                    model.updateTask(task)
                }
            }
        } catch { model.reportError("读取操作记录失败，已保留现场：\(error.localizedDescription)") }
    }
    private func presentation(_ result: TransferResult, title: String) -> TaskPresentation {
        TaskPresentation(id: result.operationID, title: title, status: stateTitle(result.state), detail: "完成 \(result.completedCount) / \(result.items.count) 项", completed: result.completedCount, total: result.items.count, items: result.items.map { TaskItemPresentation(name: $0.source.lastPathComponent, status: stateTitle($0.status.rawValue), detail: $0.message, destination: $0.destination) }, canUndo: result.items.contains { $0.undoToken != nil }, canRetry: result.items.contains { $0.status == .failed }, canReview: result.items.contains { $0.status == .needsReview || $0.status == .sourceRetained })
    }
    private func verifiedFollowup(_ id: UUID) throws -> TaskFollowupRecord? {
        guard let followup = try followups.read(id) else { return nil }
        guard let entry = try ledger.entry(id), let result = followup.result,
              [.completed,.partial,.failed,.cancelled].contains(entry.receipt.status),
              entry.receipt.status.rawValue == result.state,
              Set(entry.receipt.itemResults.map(\.itemID)) == Set(result.items.map(\.itemID)),
              entry.receipt.itemResults.count == result.items.count else {
            throw CommandFailure(.recoveryRequired, "原任务与后续操作记录不完整或不一致，请先核对")
        }
        for item in result.items {
            guard let receipt = entry.receipt.itemResults.first(where: { $0.itemID == item.itemID }),
                  receipt.destinationURL == item.destination,
                  receipt.status == (item.status == .completed ? "success" : item.status.rawValue) else {
                throw CommandFailure(.recoveryRequired, "项目回执与后续操作记录不一致")
            }
            switch entry.request.action {
            case .transfer:
                guard entry.request.context.selection.contains(where: { canonicalItemURL($0.url) == canonicalItemURL(item.source) }) else {
                    throw CommandFailure(.recoveryRequired, "后续操作来源不属于原请求")
                }
            case .pasteMove(let token, _, _):
                let knownPending = pending?.token == token && pending?.files.contains(where: { canonicalItemURL($0.url) == canonicalItemURL(item.source) }) == true
                if !knownPending {
                    let path = paths.operationsDirectory.appendingPathComponent("Transfers").appendingPathComponent(item.itemID.uuidString + ".json")
                    let journal = try JSONDecoder().decode(TransferJournalRecord.self, from: PrivateFileIO.read(path))
                    guard journal.schemaVersion == 1, journal.operationID == id, journal.itemID == item.itemID, journal.source == item.source else {
                        throw CommandFailure(.recoveryRequired, "粘贴来源与传输记录不一致")
                    }
                }
            default: throw CommandFailure(.recoveryRequired, "原操作不支持此后续动作")
            }
        }
        return followup
    }
    private func canonicalItemURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL
    }
    private func validateRetryIdentities(parent: UUID, record: TaskFollowupRecord) throws {
        guard let destination = record.destination, let expectedTarget = record.destinationIdentity,
              try identity(destination.resolvingSymlinksInPath()) == expectedTarget else {
            throw CommandFailure(.sourceChanged, "原目标目录已变化或缺少身份记录，请重新选择目标后发起操作。")
        }
        for item in record.result?.items.filter({ $0.status == .failed }) ?? [] {
            let path = paths.operationsDirectory.appendingPathComponent("Transfers").appendingPathComponent(item.itemID.uuidString + ".json")
            guard let data = try? PrivateFileIO.read(path), let journal = try? JSONDecoder().decode(TransferJournalRecord.self, from: data),
                  journal.schemaVersion == 1, journal.operationID == parent, journal.itemID == item.itemID,
                  journal.source == item.source, let expected = journal.sourceIdentity else {
                throw CommandFailure(.sourceChanged, "无法确认原失败来源的身份，请重新选择文件后发起操作。")
            }
            var info = stat()
            // Permission repair may change ctime; the inode, file kind, size and
            // modification time must still identify the originally failed object.
            guard lstat(item.source.path, &info) == 0, UInt64(info.st_dev) == expected.device,
                  UInt64(info.st_ino) == expected.inode, UInt32(info.st_mode & S_IFMT) == expected.kind,
                  info.st_size == expected.size, Int64(info.st_mtimespec.tv_sec) == expected.modifiedSeconds,
                  Int64(info.st_mtimespec.tv_nsec) == expected.modifiedNanoseconds else {
                throw CommandFailure(.sourceChanged, "失败来源已被替换或修改，请重新选择文件后发起操作。")
            }
        }
    }
    private func acquireFollowupAccess(id: UUID, record: TaskFollowupRecord, urls: [URL]) throws -> [URL] {
        var scopes: [URL] = [], roots: [URL] = []
        var succeeded = false
        defer { if !succeeded { scopes.forEach { $0.stopAccessingSecurityScopedResource() } } }
        for bookmark in record.accessBookmarks {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope,.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), !stale, url.startAccessingSecurityScopedResource() {
                scopes.append(url); roots.append(url.resolvingSymlinksInPath().standardizedFileURL)
            }
        }
        for location in model.configuration.watchedLocations + model.configuration.favorites {
            guard urls.contains(where: { $0.path == location.path || $0.path.hasPrefix(location.path + "/") }) else { continue }
            if let url = try? location.resolve(), url.startAccessingSecurityScopedResource() {
                scopes.append(url); roots.append(url.resolvingSymlinksInPath().standardizedFileURL)
            }
        }
        for location in model.configuration.recentDestinations {
            guard urls.contains(where: { $0.path == location.path || $0.path.hasPrefix(location.path + "/") }) else { continue }
            if let url = try? location.resolve(), url.startAccessingSecurityScopedResource() {
                scopes.append(url); roots.append(url.resolvingSymlinksInPath().standardizedFileURL)
            }
        }
        if sessionAuthorizedIDs.contains(id) {
            // Only a request from this process's picker may retain its original session grant.
            // Finder and restored requests cannot enter this branch based on a persisted flag.
            for url in urls where url.startAccessingSecurityScopedResource() { scopes.append(url) }
        } else {
            for url in urls {
                let canonical = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
                guard roots.contains(where: { canonical == $0.path || canonical.hasPrefix($0.path + "/") }) else {
                    throw CommandFailure(.accessDenied, "后续操作的位置缺少有效授权，请在权限与诊断中重新选择来源和目标目录。")
                }
            }
        }
        succeeded = true
        return scopes
    }
    private func decorate(_ original: TaskPresentation, followup: TaskFollowupRecord) -> TaskPresentation {
        var task = original
        if let retryID = followup.retryRequestID {
            task.canRetry = false
            task.detail += "；重试任务：\(retryID.uuidString)"
        }
        if followup.requiresReview {
            task.status = "需要核对"; task.detail = "撤销留下了未确认的执行记录，不会自动重做。请核对来源和目标。"
            task.canUndo = false; task.canRetry = false; task.canReview = true
        } else if !followup.undoCompleted.isEmpty, let result = followup.result {
            let available = Set(result.items.filter { $0.undoToken != nil }.map(\.itemID))
            task.status = available.isSubset(of: followup.undoCompleted) ? "已撤销" : "部分撤销"
            task.detail = "已撤销 \(followup.undoCompleted.count) 项移动；原任务结果保留。"
            task.canUndo = !available.subtracting(followup.undoCompleted).isEmpty
            task.items = result.items.map { item in
                let undone = followup.undoCompleted.contains(item.itemID)
                return TaskItemPresentation(id: item.itemID, name: item.source.lastPathComponent, status: undone ? "已撤销" : stateTitle(item.status.rawValue), detail: undone ? "已移回原位置" : item.message, destination: undone ? item.source : item.destination, source: item.source)
            }
        }
        return task
    }
    private func enqueueUndo(_ id: UUID) {
        guard !queuedUndos.contains(id), let result = results[id] else { return }
        do {
            guard let followup = try verifiedFollowup(id), !followup.requiresReview,
                  result.items.contains(where: { $0.undoToken != nil && !followup.undoStarted.contains($0.itemID) }) else { return }
            queuedUndos.insert(id)
            var task = decorate(presentation(result, title: "等待撤销移动"), followup: followup)
            task.status = "等待撤销"; task.canUndo = false; task.canRetry = false
            model.updateTask(task)
            queue.append(.undo(id)); startWorker()
        } catch { model.reportError(error) }
    }
    private func undo(_ id: UUID) async {
        defer { queuedUndos.remove(id) }
        guard let result = results[id] else { return }
        do {
            guard var followup = try verifiedFollowup(id), !followup.requiresReview else { throw CommandFailure(.recoveryRequired, "撤销状态不明确，请核对任务") }
            for item in result.items where !followup.undoCompleted.contains(item.itemID) {
                guard let token = item.undoToken else { continue }
                let scopes = try acquireFollowupAccess(id: id, record: followup, urls: [token.originalURL, token.currentURL])
                defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
                let scan = try await engine.scanRecoveryRecords()
                guard let journal = scan.records.first(where: { $0.operationID == id && $0.itemID == item.itemID }),
                      journal.source == token.originalURL, journal.destination == token.currentURL,
                      journal.destinationIdentity == token.identity,
                      journal.result?.undoToken?.contentFingerprint == token.contentFingerprint else {
                    throw CommandFailure(.recoveryRequired, "撤销凭据与文件操作记录不一致，请核对任务")
                }
                // Save the intent before the engine can mutate a file. Never replay an ambiguous item.
                followup.undoStarted.insert(item.itemID); try followups.save(followup)
                try await engine.undo(token, operationID: id)
                followup.undoCompleted.insert(item.itemID); try followups.save(followup)
            }
            model.updateTask(decorate(presentation(result, title: "撤销移动"), followup: followup))
        } catch {
            var task = presentation(result, title: "撤销移动")
            if let saved = try? verifiedFollowup(id), !saved.requiresReview {
                task = decorate(task, followup: saved)
                task.detail += "；未开始下一项撤销：\(error.localizedDescription)"
                task.canReview = true
            } else {
                task.status = "需要核对"; task.detail = "撤销未完整确认：\(error.localizedDescription)"; task.canUndo = false; task.canRetry = false; task.canReview = true
            }
            model.updateTask(task); model.reportError(error)
        }
    }
    private func retry(_ id: UUID) {
        guard !queuedUndos.contains(id), let result = results[id], let old = requests[id] else { return }
        do {
            guard var followup = try verifiedFollowup(id), !followup.requiresReview, followup.retryRequestID == nil else { return }
            let mode: CommandTransferMode, policy: ConflictPolicy
            switch old.action {
            case .transfer(let value, _, let conflict): mode = value; policy = conflict
            case .pasteMove(_, _, let conflict): mode = .move; policy = conflict
            default: return
            }
            let failed = result.items.filter { $0.status == .failed }.map { reference($0.source) }
            guard !failed.isEmpty, let destination = followup.destination else { return }
            let context = ActionContext(entryPoint: .items, container: nil, selection: failed)
            let request = CommandRequest(context: context, action: .transfer(mode: mode, destination: reference(destination), conflictPolicy: policy))
            let scopes = try acquireFollowupAccess(id: id, record: followup, urls: failed.map(\.url) + [destination])
            defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
            try validateRetryIdentities(parent: id, record: followup)
            followupParents[request.requestID] = id
            guard submit(request) else { followupParents[request.requestID] = nil; return }
            // submit and this write run without suspension on MainActor. On write
            // failure, cancel the queued child before its first file side effect.
            followup.retryRequestID = request.requestID
            do { try followups.save(followup) }
            catch { cancellations[request.requestID]?.cancel(); throw error }
            model.updateTask(decorate(presentation(result, title: title(old.action)), followup: followup))
        } catch { model.reportError(error) }
    }
    private func review(_ id: UUID) {
        Task {
            do {
                guard let entry = try ledger.entry(id) else { throw CommandFailure(.recoveryRequired, "操作记录缺失") }
                let scan = try await engine.scanRecoveryRecords()
                let records = scan.records.filter { $0.operationID == id }
                if !scan.issues.isEmpty { model.notice = "有 \(scan.issues.count) 条文件记录损坏或不兼容，已保留；其余记录仍可核对。" }
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
                let followup = try followups.read(id)
                let summary = followup?.requiresReview == true ? "撤销曾开始但没有完整结果。请检查原位置与移动目标；不会自动重做撤销。" : (entry.receipt.error?.message ?? "检查来源与目标。确认仅记录人工核对，不改变原始操作结果。")
                model.showReview(TaskReviewPresentation(id: id, title: title(entry.request.action), status: followup?.requiresReview == true ? "需要核对" : stateTitle(entry.receipt.status.rawValue), summary: summary, items: items, canConfirm: !items.isEmpty, previouslyConfirmedAt: confirmation?.confirmedAt))
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
