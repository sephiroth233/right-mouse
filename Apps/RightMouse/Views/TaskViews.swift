import SwiftUI
import AppKit
import RightMouseCore

struct TasksView: View {
    @ObservedObject var model: AppModel
    @ViewState private var expanded: Set<UUID> = []
    var body: some View {
        Group {
            if model.tasks.isEmpty {
                ContentUnavailableView("还没有任务", systemImage: "checklist", description: Text("从 Finder 右键菜单发起操作，结果会显示在这里。"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.tasks) { task in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top) {
                                    Image(systemName: statusIcon(task.status)).font(.title2).foregroundStyle(statusColor(task.status)).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 4) { Text(task.title).font(.headline); Text(taskStatus(task.status)).font(.caption).foregroundStyle(statusColor(task.status)) }
                                    Spacer()
                                    if task.canCancel { Button("取消") { model.onCancelTask?(task.id) }.disabled(model.onCancelTask == nil) }
                                    if task.canUndo { Button("撤销移动") { model.onUndoTask?(task.id) }.disabled(model.onUndoTask == nil) }
                                    if task.canRetry { Button("重试失败项") { model.onRetryTask?(task.id) }.disabled(model.onRetryTask == nil) }
                                    if task.canReview { Button("核对任务") { model.onReviewTask?(task.id) }.disabled(model.onReviewTask == nil) }
                                }
                                if !task.detail.isEmpty { Text(task.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                                if task.canCancel {
                                    if task.total > 0 { ProgressView(value: Double(min(task.completed, task.total)), total: Double(task.total)) { Text("已处理 \(task.completed) / \(task.total) 项").font(.caption) } }
                                    else { ProgressView("正在扫描或等待执行…").controlSize(.small) }
                                }
                                if !task.items.isEmpty {
                                    DisclosureGroup("逐项结果（\(task.items.count)）", isExpanded: Binding(get: { expanded.contains(task.id) }, set: { value in if value { expanded.insert(task.id) } else { expanded.remove(task.id) } })) {
                                        VStack(spacing: 10) {
                                            ForEach(task.items) { item in
                                                HStack(alignment: .top) {
                                                    VStack(alignment: .leading, spacing: 4) { Text(item.name).font(.callout).textSelection(.enabled); Text(taskStatus(item.status)).font(.caption).foregroundStyle(statusColor(item.status)); if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
                                                    Spacer()
                                                    if let url = item.destination { Button("定位") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                                                }.padding(.top, 6)
                                            }
                                        }.padding(.leading, 8)
                                    }
                                }
                                Text("任务 \(task.id.uuidString)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
                            }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 24).padding(.top, 4)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(item: $model.taskReview) { review in
                TaskReviewView(model: model, review: review)
                    .id("\(review.id)-\(review.checkedAt.timeIntervalSince1970)")
            }
    }
    private func statusIcon(_ status: String) -> String {
        switch status {
        case "completed", "succeeded", "success", "完成", "成功", "已撤销": return "checkmark.circle"
        case "failed", "rejected", "失败", "已拒绝": return "xmark.octagon"
        case "partial", "needsReview", "sourceRetained", "waitingForUser", "部分完成", "需要核对", "源文件已保留", "等待你处理": return "exclamationmark.triangle"
        case "cancelled", "已取消": return "stop.circle"
        default: return "clock"
        }
    }
}

private struct TaskReviewView: View {
    @ObservedObject var model: AppModel
    let review: TaskReviewPresentation
    @ViewState private var acknowledged: Set<UUID> = []
    private var ready: Bool {
        review.canConfirm && !review.items.isEmpty && acknowledged.isSuperset(of: review.items.map(\.id))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text("核对任务").font(.title2.weight(.semibold))
                    Text(review.title + " · " + taskStatus(review.status)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新检查") { model.refreshReview() }
                    .disabled(model.isConfirmingReview || model.isCleaningStaging || model.onReviewTask == nil)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(review.summary).textSelection(.enabled)
                    Label("请打开来源与目标，确认需要保留的文件。勾选各项后，可记录本次人工核对。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    if let confirmed = review.previouslyConfirmedAt {
                        Text("上次人工核对：\(confirmed.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if review.items.isEmpty {
                        Text("记录中没有可核对的文件项。请保留当前现场，通过权限与诊断检查任务记录。").foregroundStyle(.orange)
                    }
                    ForEach(review.items) { item in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.name).font(.headline).textSelection(.enabled)
                                Spacer()
                                Text(taskStatus(item.status)).font(.caption).foregroundStyle(statusColor(item.status))
                            }
                            if !item.detail.isEmpty { Text(item.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                            ReviewLocationRow(model: model, label: "来源", url: item.source, observation: item.sourceObservation)
                            ReviewLocationRow(model: model, label: "目标", url: item.destination, observation: item.destinationObservation)
                            if let sourceRecoveryURL = item.sourceRecoveryURL {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("待核对的来源副本").font(.callout.weight(.semibold))
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(sourceRecoveryURL.path).font(.callout).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Button("在 Finder 中定位") { model.revealReviewURL(sourceRecoveryURL) }
                                            .accessibilityLabel("在 Finder 中定位待核对的来源副本：\(sourceRecoveryURL.lastPathComponent)")
                                    }
                                    Text("此处可能保留原来源；请核对目标与该副本，不会自动删除或移回。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.accessibilityElement(children: .contain)
                            }
                            if let staging = item.staging { StagingReviewSection(model: model, staging: staging) }
                            if review.canConfirm {
                                Toggle("我已核对这一项", isOn: Binding(get: { acknowledged.contains(item.id) }, set: { value in
                                    if value { acknowledged.insert(item.id) } else { acknowledged.remove(item.id) }
                                })).toggleStyle(.checkbox).accessibilityLabel("已核对 \(item.name)")
                                    .disabled(model.isCleaningStaging || model.isConfirmingReview)
                            }
                        }.padding(16).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityElement(children: .contain)
                    }
                    Text("检查时间：\(review.checkedAt.formatted(date: .abbreviated, time: .standard))。此后文件仍可能变化，请在确认前检查最新内容。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("人工核对会保存一条确认记录，不会将失败或未知操作改为成功，也不会删除、覆盖或重新执行文件操作。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = model.reviewError {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled)
                    }
                    Text("任务 \(review.id.uuidString)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
                }.padding(24)
            }
            Divider()
            HStack {
                if model.isCleaningStaging { ProgressView().controlSize(.small); Text("正在核验并清理暂存…").foregroundStyle(.secondary) }
                else if model.isConfirmingReview { ProgressView().controlSize(.small); Text("正在保存核对记录…").foregroundStyle(.secondary) }
                else { Text("已核对 \(acknowledged.count) / \(review.items.count) 项").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("稍后处理") { model.taskReview = nil }.keyboardShortcut(.cancelAction).disabled(model.isConfirmingReview || model.isCleaningStaging)
                Button("标记为已人工核对") { Task { await model.confirmReview() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready || model.isConfirmingReview || model.isCleaningStaging || model.onConfirmReviewTask == nil)
            }.padding(20)
        }.frame(width: 680, height: 620)
            .interactiveDismissDisabled(model.isConfirmingReview || model.isCleaningStaging)
    }
}

private struct StagingReviewSection: View {
    @ObservedObject var model: AppModel
    let staging: StagingRecoveryItem
    @ViewState private var confirmsCleanup = false
    private var cleanupToken: StagingCleanupToken? {
        if case .cleanupAllowed(let token) = staging.disposition { return token }
        return nil
    }
    private var explanation: String {
        switch staging.disposition {
        case .cleanupAllowed: return "此暂存的归属证据可核验。确认后，服务会再次检查身份与权限，再清理该任务的暂存副本。"
        case .legacyEvidenceOnly(let reason), .retainedForReview(let reason): return reason
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            ReviewLocationRow(model: model, label: "暂存", url: staging.stagingURL, observation: explanation)
            Text("空间占用估算：\(ByteCountFormatter.string(fromByteCount: max(0, staging.occupiedBytes), countStyle: .file))")
                .font(.caption.weight(.semibold))
            Text("按文件系统已分配块统计；无法访问的位置可能无法完整统计，实际释放量由文件系统决定。")
                .font(.caption).foregroundStyle(.secondary)
            if cleanupToken != nil {
                Button("清理此任务暂存…", role: .destructive) { confirmsCleanup = true }
                    .disabled(model.isReadOnly || model.isCleaningStaging || model.isConfirmingReview || model.onCleanupStaging == nil)
                    .accessibilityLabel("清理当前项目的已验证暂存副本")
            } else {
                Label("当前证据不足以允许清理，暂存将保留。", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("确认清理此任务的暂存副本？", isPresented: $confirmsCleanup, titleVisibility: .visible) {
            Button("只清理此任务暂存", role: .destructive) {
                if let token = cleanupToken { model.beginStagingCleanup(token) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清理下面这个项目的暂存目录及其中副本，不删除来源文件或已提交目标。此清理无法撤销。\n\n\(staging.stagingURL?.path ?? "暂存位置未记录")")
        }
    }
}

private struct ReviewLocationRow: View {
    @ObservedObject var model: AppModel
    let label: String
    let url: URL?
    let observation: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.caption.weight(.semibold)).frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(url?.path ?? "记录中没有此位置").font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(observation).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let url {
                Button("在 Finder 中定位") { model.revealReviewURL(url) }
                    .accessibilityLabel("在 Finder 中定位\(label)：\(url.lastPathComponent)")
            }
        }.accessibilityElement(children: .contain)
    }
}

private func taskStatus(_ status: String) -> String {
    ["received": "已收到", "accepted": "等待执行", "planning": "正在准备", "running": "处理中", "waitingForUser": "等待你处理", "completed": "完成", "succeeded": "成功", "success": "成功", "partial": "部分完成", "failed": "失败", "rejected": "已拒绝", "cancelled": "已取消", "cancelling": "正在取消", "needsReview": "需要核对", "sourceRetained": "已复制，源保留", "skipped": "已跳过" ][status] ?? status
}

private func statusColor(_ status: String) -> Color {
    switch status {
    case "completed", "succeeded", "success", "完成", "成功", "已撤销": return .green
    case "failed", "rejected", "失败", "已拒绝": return .red
    case "partial", "needsReview", "sourceRetained", "waitingForUser", "部分完成", "需要核对", "源文件已保留", "等待你处理": return .orange
    default: return .secondary
    }
}
