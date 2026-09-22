import AppKit
import RightMouseCore

struct ConflictResolution {
    enum Reason { case user, cancelled, timedOut, unavailable }
    let decision: TransferConflictDecision
    var applyToRemaining = false
    var reason: Reason = .user
}

typealias ConflictPrompt = @MainActor (URL, URL, TransferCancellation) async -> ConflictResolution

@MainActor enum ConflictDialog {
    static func present(source: URL, target: URL, cancellation: TransferCancellation) async -> ConflictResolution {
        guard !cancellation.isCancelled else { return .init(decision: .cancel, reason: .cancelled) }
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.isVisible, parent.attachedSheet == nil else {
            return .init(decision: .cancel, reason: .unavailable)
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "目标已存在同名项目"
        alert.informativeText = "来源：\(source.path)\n目标：\(target.path)\n保留两份将为新项目添加编号。等待超过 15 分钟会取消剩余操作。"
        alert.addButton(withTitle: "保留两份")
        alert.addButton(withTitle: "跳过")
        alert.addButton(withTitle: "取消剩余操作")
        let apply = NSButton(checkboxWithTitle: "对本批后续冲突使用同一选择", target: nil, action: nil)
        apply.state = .off
        apply.sizeToFit()
        alert.accessoryView = apply
        let deadline = ContinuousClock.now.advanced(by: .seconds(15 * 60))
        return await withCheckedContinuation { continuation in
            var stopReason: ConflictResolution.Reason?
            var monitor: Task<Void, Never>?
            alert.beginSheetModal(for: parent) { response in
                monitor?.cancel()
                alert.window.orderOut(nil)
                let effectiveReason = stopReason ?? (cancellation.isCancelled ? .cancelled : (ContinuousClock.now >= deadline ? .timedOut : nil))
                let decision: TransferConflictDecision = response == .alertFirstButtonReturn ? .keepBoth : (response == .alertSecondButtonReturn ? .skip : .cancel)
                continuation.resume(returning: ConflictResolution(decision: effectiveReason == nil ? decision : .cancel,
                    applyToRemaining: apply.state == .on && decision != .cancel && effectiveReason == nil,
                    reason: effectiveReason ?? .user))
            }
            monitor = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    if cancellation.isCancelled { stopReason = .cancelled }
                    else if ContinuousClock.now >= deadline { stopReason = .timedOut }
                    else if !parent.isVisible { stopReason = .unavailable }
                    if stopReason != nil {
                        parent.endSheet(alert.window, returnCode: .abort)
                        return
                    }
                }
            }
        }
    }
}
