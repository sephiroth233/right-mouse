import SwiftUI
import AppKit
import FinderSync
import ServiceManagement
import UniformTypeIdentifiers
import RightMouseCore

struct TaskItemPresentation: Identifiable {
    var id: UUID = UUID()
    var name: String
    var status: String
    var detail: String = ""
    var destination: URL? = nil
    var source: URL? = nil
}

struct TaskReviewItemPresentation: Identifiable {
    var id: UUID = UUID()
    var name: String
    var status: String
    var detail: String = ""
    var source: URL? = nil
    var destination: URL? = nil
    var sourceObservation: String = "未检查"
    var destinationObservation: String = "未检查"
    var staging: StagingRecoveryItem? = nil
    var sourceRecoveryURL: URL? = nil
}

/// The host supplies a fresh, read-only inspection of known operation records.
/// User acknowledgement remains distinct from a successful file operation.
struct TaskReviewPresentation: Identifiable {
    var id: UUID
    var title: String
    var status: String
    var summary: String
    var items: [TaskReviewItemPresentation]
    var checkedAt: Date = Date()
    var canConfirm: Bool = true
    var previouslyConfirmedAt: Date? = nil
}

struct TaskPresentation: Identifiable {
    var id: UUID
    var title: String
    var status: String
    var detail: String = ""
    var completed: Int = 0
    var total: Int = 0
    var items: [TaskItemPresentation] = []
    var canCancel: Bool = false
    var canUndo: Bool = false
    var canRetry: Bool = false
    var canReview: Bool = false
}

enum SetupExercisePhase: Equatable {
    case idle, ready, waiting, succeeded, failed, needsReview
}

@MainActor final class AppModel: ObservableObject {
    @Published var configuration: AppConfiguration
    @Published var tasks: [TaskPresentation] = []
    var recoveryTasks: [TaskPresentation] { tasks.filter { $0.canReview } }
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var isDevelopmentStorage = false
    @Published var isLocalFinderMode = false
    @Published var authenticatedXPCBuild = false
    @Published var localServiceReady = false
    @Published var localServiceStatus = "正在启动本机连接…"
    var onRepairLocalService: (() -> Void)?
    var onStopLocalService: (() -> Void)?
    @Published var storageDiagnostic: String?
    @Published var retentionSummary: String?
    @Published var isReadOnly = false
    @Published var extensionEnabled = false
    @Published var selectedFiles: [URL] = []
    @Published var destination: URL?
    @Published var selectedRecentDestinationID: UUID?
    @Published var recentDestinationIssues: [UUID: String] = [:]
    @Published var taskReview: TaskReviewPresentation?
    @Published var reviewError: String?
    @Published var isConfirmingReview = false
    @Published private(set) var isCleaningStaging = false
    @Published private(set) var setupExercisePhase: SetupExercisePhase = .idle
    @Published private(set) var setupExerciseTarget: URL?
    @Published private(set) var setupExerciseRequestID: UUID?
    @Published private(set) var setupExerciseResult: URL?
    @Published private(set) var setupExerciseMessage = "选择演练目录，再创建一个 TXT 文件来验证文件操作。"
    private var setupExerciseReceiptRevision = 0
    let configurationStore: ConfigurationStore
    let templateStore: TemplateStore
    var onConfigurationChanged: ((AppConfiguration) -> Void)?
    var onPerformAction: ((String, [URL], URL?) -> Void)?
    var onCancelTask: ((UUID) -> Void)?
    var onUndoTask: ((UUID) -> Void)?
    var onRetryTask: ((UUID) -> Void)?
    var onReviewTask: ((UUID) -> Void)?
    var onConfirmReviewTask: ((UUID) async throws -> Void)?
    var onCleanupStaging: ((StagingCleanupToken) -> Void)?
    var onOpenLocation: ((URL) -> Void)?
    var onExportDiagnostics: (() throws -> DiagnosticLogExport)?
    /// Request ID is installed before dispatch, so synchronous accepted receipts
    /// cannot race callback return. The host remains the sole file creator.
    var onRunSetupExercise: ((URL, UUID) -> Bool)?

    init(configurationStore: ConfigurationStore, templateStore: TemplateStore) {
        self.configurationStore = configurationStore; self.templateStore = templateStore
        do {
            configuration = try configurationStore.load()
            notice = configurationStore.lastWarning
        } catch {
            configuration = AppConfiguration()
            errorMessage = error.localizedDescription
            isReadOnly = true
        }
        refreshDiagnostics()
    }
    func chooseSetupExerciseDirectory() {
        guard !isReadOnly, setupExercisePhase != .waiting else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.title = "选择 TXT 演练目录"
        panel.message = "选择后会先显示目标位置；点击“创建演练 TXT”才会创建文件。"
        acceptSetupExerciseSelection(panel.runModal() == .OK ? panel.url : nil)
    }
    /// Only called with an accepted system-picker selection; nil models cancel.
    func acceptSetupExerciseSelection(_ url: URL?) {
        guard !isReadOnly, setupExercisePhase != .waiting, let url else { return }
        guard url.isFileURL else { setupExerciseMessage = "请选择本地目录。"; return }
        setupExerciseTarget = url; setupExerciseResult = nil; setupExerciseRequestID = nil
        setupExercisePhase = .ready
        setupExerciseMessage = "演练目录已选择。创建权限会在实际任务中验证；现有同名文件会被保留。"
    }
    @discardableResult func beginSetupExercise(at url: URL) -> Bool {
        guard !isReadOnly, setupExercisePhase != .waiting else { return false }
        guard url.isFileURL, (url.host ?? "").isEmpty, url.query == nil, url.fragment == nil else {
            setupExercisePhase = .failed; setupExerciseMessage = "演练目标必须是本地目录。"; return false
        }
        guard let onRunSetupExercise else {
            setupExercisePhase = .failed; setupExerciseMessage = "创建服务未连接，请重新打开应用。"; return false
        }
        let id = UUID()
        setupExerciseTarget = url; setupExerciseRequestID = id; setupExerciseResult = nil
        setupExerciseReceiptRevision = 0; setupExercisePhase = .waiting
        setupExerciseMessage = "正在连接或等待创建结果。关闭设置窗口不会重新创建文件。"
        let accepted = onRunSetupExercise(url, id)
        if !accepted, setupExercisePhase == .waiting {
            setupExercisePhase = .failed
            setupExerciseMessage = "创建请求未被接受。请检查任务提示后重试；尚未确认创建成功。"
        }
        return accepted
    }
    func receiveSetupReceipt(_ receipt: CommandReceipt) {
        guard receipt.requestID == setupExerciseRequestID, receipt.schemaVersion == 1,
              setupExercisePhase == .waiting, receipt.revision > setupExerciseReceiptRevision else { return }
        setupExerciseReceiptRevision = receipt.revision
        switch receipt.status {
        case .accepted, .planning, .running, .waitingForUser, .cancelling:
            setupExerciseMessage = receipt.status == .waitingForUser ? "创建任务正在等待你处理，请查看任务窗口。" : "正在连接或等待创建结果。以实际任务回执确认完成。"
        case .completed:
            guard receipt.error == nil, receipt.itemResults.count == 1,
                  let item = receipt.itemResults.first, item.status == "success", item.error == nil,
                  let url = item.destinationURL, url.isFileURL, (url.host ?? "").isEmpty,
                  url.query == nil, url.fragment == nil else {
                setupExercisePhase = .needsReview
                setupExerciseMessage = "任务已结束，但缺少明确的新建成功记录。请在任务窗口核对，不能确认演练成功。"
                return
            }
            setupExerciseResult = url; setupExercisePhase = .succeeded
            setupExerciseMessage = "TXT 创建演练成功。下面显示任务实际创建的文件，可在 Finder 中定位。"
        case .needsReview, .partial:
            setupExercisePhase = .needsReview
            setupExerciseMessage = receipt.error?.message ?? "创建结果需要核对。请查看任务记录，确认已有结果后再重新演练。"
        case .failed, .rejected, .cancelled:
            setupExercisePhase = .failed
            setupExerciseMessage = receipt.error?.message ?? (receipt.status == .cancelled ? "演练已取消，未确认创建成功。" : "演练创建失败，请检查目录权限后重试。")
        }
    }
    func revealSetupExerciseResult() {
        guard setupExercisePhase == .succeeded, let setupExerciseResult else { return }
        NSWorkspace.shared.activateFileViewerSelecting([setupExerciseResult])
    }
    func updateTask(_ task: TaskPresentation) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task }
        else { tasks.insert(task, at: 0) }
    }
    func showReview(_ review: TaskReviewPresentation) {
        guard !isConfirmingReview, !isCleaningStaging else { return }
        reviewError = nil
        taskReview = review
    }
    func refreshReview() {
        guard let review = taskReview, !isConfirmingReview, !isCleaningStaging else { return }
        guard let onReviewTask else { reviewError = "任务核对服务未连接，请重新打开应用。"; return }
        reviewError = nil
        onReviewTask(review.id)
    }
    func confirmReview() async {
        guard let review = taskReview, review.canConfirm, !isConfirmingReview, !isCleaningStaging else { return }
        guard let onConfirmReviewTask else { reviewError = "无法保存核对记录：任务服务未连接。"; return }
        isConfirmingReview = true
        defer { isConfirmingReview = false }
        do {
            try await onConfirmReviewTask(review.id)
            if taskReview?.id == review.id { taskReview = nil }
            notice = "已保存人工核对记录。任务原有结果和文件均已保留。"
        } catch { reviewError = "核对记录未保存：\(error.localizedDescription)" }
    }
    /// Called only after explicit user confirmation; the host rechecks ownership
    /// and authorization immediately before any deletion.
    @discardableResult func beginStagingCleanup(_ token: StagingCleanupToken) -> Bool {
        guard !isCleaningStaging, !isConfirmingReview else { return false }
        guard !isReadOnly else { reviewError = "当前配置为只读，不能清理暂存。"; return false }
        guard let review = taskReview, review.id == token.operationID,
              let item = review.items.first(where: { $0.id == token.itemID }), let staging = item.staging,
              staging.operationID == token.operationID, staging.itemID == token.itemID,
              case .cleanupAllowed(let expected) = staging.disposition,
              expected.operationID == token.operationID, expected.itemID == token.itemID,
              expected.journalURL == token.journalURL, expected.stagingURL == token.stagingURL,
              expected.stagingIdentity == token.stagingIdentity, expected.parentIdentity == token.parentIdentity,
              expected.journalDigest == token.journalDigest else {
            reviewError = "当前暂存没有可用的清理凭据，请重新检查任务。"; return false
        }
        guard let onCleanupStaging else { reviewError = "暂存清理服务未连接，请重新打开应用。"; return false }
        reviewError = nil; notice = nil; isCleaningStaging = true
        onCleanupStaging(token)
        return true
    }
    /// The host calls this once its cleanup attempt has finished, then requests a
    /// fresh review. An error never changes the task's result into success.
    func stagingCleanupFinished(error: String? = nil) {
        guard isCleaningStaging else { return }
        isCleaningStaging = false
        if let error { reviewError = error; notice = nil }
        else { reviewError = nil; notice = "已清理该任务的暂存副本，来源与已提交目标均保留。" }
    }
    func revealReviewURL(_ url: URL) {
        guard url.isFileURL else { reviewError = "此记录不是本地文件路径。"; return }
        // Finder handles a stale recorded path; do not substitute another file.
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func reportError(_ error: Error) { errorMessage = error.localizedDescription }
    func reportError(_ message: String) { errorMessage = message }
    @discardableResult func save(_ change: (inout AppConfiguration) -> Void) -> Bool {
        guard !isReadOnly else { errorMessage = "当前配置为只读，请修复配置版本后重试。"; return false }
        var next = configuration; change(&next)
        do {
            configuration = try configurationStore.save(next)
            onConfigurationChanged?(configuration)
            return true
        } catch { reportError(error); return false }
    }
    func binding<Value>(_ keyPath: WritableKeyPath<AppConfiguration, Value>) -> Binding<Value> {
        Binding(get: { self.configuration[keyPath: keyPath] }, set: { value in self.save { $0[keyPath: keyPath] = value } })
    }
    func chooseLocation(watched: Bool, replacing: UUID? = nil) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = watched ? "选择需要显示 RightMouse 右键菜单的目录。" : "选择要收藏的目录。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let scoped = !isLocalFinderMode
            let bookmark = try url.bookmarkData(options: scoped ? .withSecurityScope : .withoutImplicitSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            save { value in
                var locations = watched ? value.watchedLocations : value.favorites
                if let replacing, let index = locations.firstIndex(where: { $0.id == replacing }) {
                    locations[index].path = url.path; locations[index].bookmarkData = bookmark; locations[index].securityScoped = scoped
                } else if !locations.contains(where: { $0.path == url.path }) {
                    locations.append(SavedLocation(name: url.lastPathComponent, path: url.path, bookmarkData: bookmark, order: locations.count, securityScoped: scoped))
                }
                if watched { value.watchedLocations = locations } else { value.favorites = locations }
            }
        } catch { reportError(error) }
    }
    func openLocation(_ location: SavedLocation) {
        do {
            let url = try location.resolve()
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path) else { throw ConfigurationError.invalid("目录不可用，请连接磁盘或重新选择目录。") }
            if let onOpenLocation { onOpenLocation(url) } else { NSWorkspace.shared.open(url) }
        } catch { reportError(error) }
    }
    func importTemplate() {
        guard configuration.templates.count < 100 else { reportError("模板最多 100 个，请先删除不再使用的模板。"); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.message = "导入真实模板文件。内容会复制到 RightMouse，之后不再依赖源文件。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try templateStore.importTemplate(from: url)
            if !save({ $0.templates.append(imported) }) { try? templateStore.deleteResource(for: imported) }
        } catch { reportError(error) }
    }
    func removeTemplate(_ template: FileTemplate) {
        if save({ $0.templates.removeAll { $0.id == template.id } }) {
            do { try templateStore.deleteResource(for: template) } catch { reportError(error) }
        }
    }
    func updateTemplate(_ template: FileTemplate) -> Bool {
        do { try templateStore.validateVariables(for: template) }
        catch { reportError(error); return false }
        return save { config in
            if let index = config.templates.firstIndex(where: { $0.id == template.id }) { config.templates[index] = template }
        }
    }
    func addApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.message = "选择可接收文件或文件夹的应用程序。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { reportError("此应用缺少有效 Bundle ID。"); return }
        save { value in
            if let index = value.integrations.firstIndex(where: { $0.bundleID == identifier }) {
                value.integrations[index].applicationPath = url.path; value.integrations[index].enabled = true
            } else {
                value.integrations.append(.init(id: UUID().uuidString, name: url.deletingPathExtension().lastPathComponent, bundleID: identifier, applicationPath: url.path))
            }
        }
    }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = "选择要处理的文件或文件夹。"
        if panel.runModal() == .OK { selectedFiles = panel.urls }
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "选择新建、粘贴、复制到或移动到的目标目录。"
        if panel.runModal() == .OK, let url = panel.url {
            destination = url; selectedRecentDestinationID = nil
            if rememberDestination(url) { selectedRecentDestinationID = configuration.recentDestinations.first?.id }
        }
    }
    /// The caller must already hold an explicit picker selection or validated access.
    /// A history persistence error does not change the outcome of a completed task.
    @discardableResult func rememberDestination(_ url: URL) -> Bool {
        guard !isReadOnly else { notice = "配置为只读，未保存最近目标。"; return false }
        do {
            var next = configuration
            next.recentDestinations = try RecentDestinationHistory.remember(url, in: next.recentDestinations)
            configuration = try configurationStore.save(next)
            onConfigurationChanged?(configuration)
            refreshRecentDestinations()
            return true
        } catch { notice = "未能保存最近目标：\(error.localizedDescription)"; return false }
    }
    @discardableResult func selectRecentDestination(_ id: UUID) -> Bool {
        guard let item = configuration.recentDestinations.first(where: { $0.id == id }) else { reportError("最近目标已被移除，请重新选择目录。"); return false }
        do {
            let url = try item.resolve()
            destination = url; selectedRecentDestinationID = id
            _ = rememberDestination(url)
            notice = "已将“\(item.name)”设为目标目录。"
            return true
        } catch {
            recentDestinationIssues[id] = error.localizedDescription
            reportError(error)
            return false
        }
    }
    func removeRecentDestination(_ id: UUID) {
        if save({ $0.recentDestinations.removeAll { $0.id == id } }) {
            recentDestinationIssues[id] = nil
            if selectedRecentDestinationID == id { selectedRecentDestinationID = nil; destination = nil }
        }
    }
    func clearRecentDestinations() {
        if save({ $0.recentDestinations.removeAll() }) {
            recentDestinationIssues.removeAll()
            if selectedRecentDestinationID != nil { selectedRecentDestinationID = nil; destination = nil }
        }
    }
    func repairRecentDestination(_ id: UUID) {
        guard configuration.recentDestinations.contains(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "重新选择此最近目标的目录。只有你明确选择后才会更新授权。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = repairRecentDestination(id, with: url)
    }
    /// Shares the accepted-picker path with fixture checks; never called with a path hint alone.
    @discardableResult func repairRecentDestination(_ id: UUID, with url: URL) -> Bool {
        guard configuration.recentDestinations.contains(where: { $0.id == id }) else { return false }
        do {
            let repaired = try RecentDestinationHistory.remember(url, in: configuration.recentDestinations, replacingID: id)
            if save({ $0.recentDestinations = repaired }) {
                if selectedRecentDestinationID == id { destination = try repaired.first!.resolve() }
                refreshRecentDestinations()
                return true
            }
        } catch { reportError(error) }
        return false
    }
    func refreshRecentDestinations() {
        var issues: [UUID: String] = [:]
        for item in configuration.recentDestinations {
            do { _ = try item.resolve() } catch { issues[item.id] = error.localizedDescription }
        }
        recentDestinationIssues = issues
    }
    func perform(_ action: String) {
        guard let onPerformAction else { reportError("操作服务尚未连接，请重新启动 RightMouse。"); return }
        let requiresDestination = action.hasPrefix("createFile:") || ["createFile", "pasteMove", "copyTo", "moveTo"].contains(action)
        if requiresDestination, let id = selectedRecentDestinationID {
            guard let item = configuration.recentDestinations.first(where: { $0.id == id }) else { reportError("选中的最近目标已被移除，请重新选择。"); return }
            do { destination = try item.resolve() }
            catch { recentDestinationIssues[id] = error.localizedDescription; reportError(error); return }
        }
        onPerformAction(action, selectedFiles, destination)
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isReadOnly else { reportError("当前配置为只读，无法更改登录启动设置。"); return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            save { $0.launchAtLogin = enabled }
            if SMAppService.mainApp.status == .requiresApproval { notice = "请在系统设置的登录项中允许 RightMouse。" }
        } catch { reportError(error) }
    }
    func refreshDiagnostics() { extensionEnabled = FIFinderSyncController.isExtensionEnabled }
    func showExtensionSettings() { FIFinderSyncController.showExtensionManagementInterface() }
    func copyDiagnostics() {
        let summary = "RightMouse 开发版\n系统：\(ProcessInfo.processInfo.operatingSystemVersionString)\n存储模式：\(isLocalFinderMode ? (authenticatedXPCBuild ? "本机 XPC：" + localServiceStatus : "本机 Finder 模式，操作需确认") : isDevelopmentStorage ? "独立开发目录；Finder 右键功能不可用" : "共享容器")\nFinder 扩展登记：\(extensionEnabled ? "已启用" : "未启用")\n配置版本：\(configuration.schemaVersion) / \(configuration.revision)\n监控目录：\(configuration.watchedLocations.count)\n只读配置：\(isReadOnly ? "是" : "否")\n此摘要不包含用户文件路径、内容或书签。"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary, forType: .string)
        notice = "诊断摘要已复制。"
    }
    func exportDiagnostics() {
        do {
            guard let onExportDiagnostics else { throw CommandFailure(.ioFailed, "诊断服务未连接，请重新打开应用。") }
            let export = try onExportDiagnostics()
            guard export.report.issues.ioFailures == 0 else { throw CommandFailure(.ioFailed, "无法安全读取诊断记录，请检查应用存储空间和权限后重试。") }
            let panel = NSSavePanel()
            panel.title = "导出脱敏诊断记录"
            panel.message = "仅导出组件状态、事件时间和错误码，不包含逐项操作历史。"
            panel.nameFieldStringValue = "RightMouse-diagnostics.jsonl"
            panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .plainText]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try export.data.write(to: url, options: .atomic)
            notice = "已导出 \(export.report.retainedRecords) 条脱敏诊断记录。" + (export.report.issues.total > 0 ? "已按保留期限、容量和字段规则过滤记录。" : "")
        } catch { reportError(error) }
    }
}
