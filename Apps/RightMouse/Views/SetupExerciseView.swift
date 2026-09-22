import SwiftUI

/// A user-triggered exercise through the same host creator as Finder commands.
struct SetupExerciseView: View {
    @ObservedObject var model: AppModel
    var showTasks: () -> Void
    private var waiting: Bool { model.setupExercisePhase == .waiting }
    private var successful: Bool { model.setupExercisePhase == .succeeded }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(successful ? Color.green.opacity(0.12) : Color.blue.opacity(0.10)).frame(width: 32, height: 32)
                    if successful { Image(systemName: "checkmark").foregroundStyle(.green) }
                    else { Text("3").font(.headline).foregroundStyle(.blue) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("创建第一个 TXT 文件").font(.headline)
                    Text("由你选择目录并确认创建。演练使用应用内文件服务；Finder 扩展状态在第一步单独显示。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let target = model.setupExerciseTarget {
                VStack(alignment: .leading, spacing: 4) {
                    Text("演练目标目录").font(.caption.weight(.semibold))
                    Text(target.path).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if waiting { HStack { ProgressView().controlSize(.small); Text("正在等待实际创建结果…").font(.callout) } }
            Label(model.setupExerciseMessage, systemImage: successful ? "checkmark.circle" : (model.setupExercisePhase == .failed || model.setupExercisePhase == .needsReview ? "exclamationmark.triangle" : "info.circle"))
                .font(.caption).foregroundStyle(successful ? .green : .secondary).fixedSize(horizontal: false, vertical: true)
            if let result = model.setupExerciseResult {
                Text("已创建：\(result.path)").font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button("在 Finder 中定位演练文件") { model.revealSetupExerciseResult() }
            }
            HStack {
                Button("选择演练目录…") { model.chooseSetupExerciseDirectory() }
                    .disabled(model.isReadOnly || waiting)
                Button(model.setupExercisePhase == .failed ? "重新创建演练 TXT" : "创建演练 TXT") {
                    if let target = model.setupExerciseTarget { model.beginSetupExercise(at: target) }
                }.buttonStyle(.borderedProminent)
                    .disabled(model.isReadOnly || waiting || successful || model.setupExercisePhase == .needsReview || model.setupExerciseTarget == nil)
                if model.setupExerciseRequestID != nil { Button("查看任务") { showTasks() } }
            }
            Text("会新建“RightMouse 演练.txt”；重名自动增加序号，不覆盖现有文件。取消目录选择不会创建文件。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 8).accessibilityElement(children: .contain)
    }
}
