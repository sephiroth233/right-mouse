import SwiftUI
import AppKit
import RightMouseCore

struct FileToolsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("要处理的文件").font(.headline); Spacer(); if !model.selectedFiles.isEmpty { Button("清空") { model.selectedFiles = [] } }; Button("选择文件或目录…") { model.chooseFiles() } }
                        if model.selectedFiles.isEmpty { Text("尚未选择文件。新建文件只需设置目标目录。").foregroundStyle(.secondary).padding(.vertical, 8) }
                        else {
                            ForEach(Array(model.selectedFiles.prefix(8).enumerated()), id: \.offset) { _, file in Label(file.path, systemImage: "doc").lineLimit(1).truncationMode(.middle).font(.callout) }
                            if model.selectedFiles.count > 8 { Text("以及其他 \(model.selectedFiles.count - 8) 项").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(8)
                }
                GroupBox {
                    HStack { VStack(alignment: .leading, spacing: 6) { Text("目标目录").font(.headline); Text(model.destination?.path ?? "尚未选择").foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle) }; Spacer(); Button("选择目录…") { model.chooseDestination() } }.padding(8)
                }
                GroupBox("操作") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Menu("新建文件") { ForEach(model.configuration.templates) { template in Button(template.name) { model.perform("createFile:\(template.id)") } } }.disabled(model.destination == nil)
                            Menu("复制文本") {
                                Button("完整路径") { model.perform("copyText:path") }
                                Button("文件名") { model.perform("copyText:name") }.disabled(model.selectedFiles.isEmpty)
                                Button("不含扩展名") { model.perform("copyText:stem") }.disabled(model.selectedFiles.isEmpty)
                                Button("终端转义路径") { model.perform("copyText:shellPath") }
                            }.disabled(model.selectedFiles.isEmpty && model.destination == nil)
                            Menu("打开方式") { ForEach(model.configuration.integrations.filter(\.enabled)) { app in Button(app.name) { model.perform("openWith:\(app.id)") } } }.disabled(model.selectedFiles.isEmpty && model.destination == nil)
                        }
                        HStack(spacing: 12) {
                            Button("剪切所选文件") { model.perform("stageMove") }.disabled(model.selectedFiles.isEmpty)
                            Button("粘贴待移动文件") { model.perform("pasteMove") }.disabled(model.destination == nil)
                            Button("复制到目标") { model.perform("copyTo") }.disabled(model.selectedFiles.isEmpty || model.destination == nil)
                            Button("移动到目标") { model.perform("moveTo") }.disabled(model.selectedFiles.isEmpty || model.destination == nil)
                        }
                        Text("操作结果会出现在“任务记录”。处理同名文件时按“文件操作”中的策略询问、跳过或保留两份。").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if let task = model.tasks.first {
                    GroupBox("最近任务") { HStack { Image(systemName: task.canCancel ? "clock" : "checklist"); Text(task.title); Spacer(); Text(taskStatus(task.status)).foregroundStyle(.secondary) }.padding(8) }
                }
            }.padding(.horizontal, 28).padding(.bottom, 24)
        }
    }
}

struct TasksView: View {
    @ObservedObject var model: AppModel
    @ViewState private var expanded: Set<UUID> = []
    var body: some View {
        Group {
            if model.tasks.isEmpty {
                ContentUnavailableView("还没有任务", systemImage: "checklist", description: Text("从 Finder 右键菜单或文件操作台发起操作，结果会显示在这里。"))
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
        }.frame(maxWidth: .infinity, minHeight: 320)
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
                    .disabled(model.isConfirmingReview || model.onReviewTask == nil)
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
                            if review.canConfirm {
                                Toggle("我已核对这一项", isOn: Binding(get: { acknowledged.contains(item.id) }, set: { value in
                                    if value { acknowledged.insert(item.id) } else { acknowledged.remove(item.id) }
                                })).toggleStyle(.checkbox).accessibilityLabel("已核对 \(item.name)")
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
                if model.isConfirmingReview { ProgressView().controlSize(.small); Text("正在保存核对记录…").foregroundStyle(.secondary) }
                else { Text("已核对 \(acknowledged.count) / \(review.items.count) 项").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("稍后处理") { model.taskReview = nil }.keyboardShortcut(.cancelAction).disabled(model.isConfirmingReview)
                Button("标记为已人工核对") { Task { await model.confirmReview() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready || model.isConfirmingReview || model.onConfirmReviewTask == nil)
            }.padding(20)
        }.frame(width: 680, height: 620)
            .interactiveDismissDisabled(model.isConfirmingReview)
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
