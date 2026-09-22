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

@MainActor final class AppModel: ObservableObject {
    @Published var configuration: AppConfiguration
    @Published var tasks: [TaskPresentation] = []
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var isDevelopmentStorage = false
    @Published var storageDiagnostic: String?
    @Published var isReadOnly = false
    @Published var extensionEnabled = false
    @Published var selectedFiles: [URL] = []
    @Published var destination: URL?
    @Published var taskReview: TaskReviewPresentation?
    @Published var reviewError: String?
    @Published var isConfirmingReview = false
    let configurationStore: ConfigurationStore
    let templateStore: TemplateStore
    var onConfigurationChanged: ((AppConfiguration) -> Void)?
    var onPerformAction: ((String, [URL], URL?) -> Void)?
    var onCancelTask: ((UUID) -> Void)?
    var onUndoTask: ((UUID) -> Void)?
    var onRetryTask: ((UUID) -> Void)?
    var onReviewTask: ((UUID) -> Void)?
    var onConfirmReviewTask: ((UUID) async throws -> Void)?
    var onOpenLocation: ((URL) -> Void)?

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
    func updateTask(_ task: TaskPresentation) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task }
        else { tasks.insert(task, at: 0) }
    }
    func showReview(_ review: TaskReviewPresentation) {
        guard !isConfirmingReview else { return }
        reviewError = nil
        taskReview = review
    }
    func refreshReview() {
        guard let review = taskReview, !isConfirmingReview else { return }
        guard let onReviewTask else { reviewError = "任务核对服务未连接，请重新打开应用。"; return }
        reviewError = nil
        onReviewTask(review.id)
    }
    func confirmReview() async {
        guard let review = taskReview, review.canConfirm, !isConfirmingReview else { return }
        guard let onConfirmReviewTask else { reviewError = "无法保存核对记录：任务服务未连接。"; return }
        isConfirmingReview = true
        defer { isConfirmingReview = false }
        do {
            try await onConfirmReviewTask(review.id)
            if taskReview?.id == review.id { taskReview = nil }
            notice = "已保存人工核对记录。任务原有结果和文件均已保留。"
        } catch { reviewError = "核对记录未保存：\(error.localizedDescription)" }
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
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            save { value in
                var locations = watched ? value.watchedLocations : value.favorites
                if let replacing, let index = locations.firstIndex(where: { $0.id == replacing }) {
                    locations[index].path = url.path; locations[index].bookmarkData = bookmark
                } else if !locations.contains(where: { $0.path == url.path }) {
                    locations.append(SavedLocation(name: url.lastPathComponent, path: url.path, bookmarkData: bookmark, order: locations.count))
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
        if panel.runModal() == .OK { destination = panel.url }
    }
    func perform(_ action: String) {
        guard let onPerformAction else { reportError("操作服务尚未连接，请重新启动 RightMouse。"); return }
        onPerformAction(action, selectedFiles, destination)
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            save { $0.launchAtLogin = enabled }
            if SMAppService.mainApp.status == .requiresApproval { notice = "请在系统设置的登录项中允许 RightMouse。" }
        } catch { reportError(error) }
    }
    func refreshDiagnostics() { extensionEnabled = FIFinderSyncController.isExtensionEnabled }
    func showExtensionSettings() { FIFinderSyncController.showExtensionManagementInterface() }
    func copyDiagnostics() {
        let summary = "RightMouse 开发版\n系统：\(ProcessInfo.processInfo.operatingSystemVersionString)\n存储模式：\(isDevelopmentStorage ? "独立开发目录；Finder 右键功能不可用" : "共享容器")\nFinder 扩展登记：\(extensionEnabled ? "已启用" : "未启用")\n配置版本：\(configuration.schemaVersion) / \(configuration.revision)\n监控目录：\(configuration.watchedLocations.count)\n任务数量：\(tasks.count)\n只读配置：\(isReadOnly ? "是" : "否")\n此摘要不包含用户文件路径、内容或书签。"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary, forType: .string)
        notice = "诊断摘要已复制。"
    }
}
