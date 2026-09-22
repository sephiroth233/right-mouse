import Foundation
import RightMouseCore

private struct StagingPresentationFailure: Error, CustomStringConvertible { let description: String }

/// Pure presentation/controller checks. The callback never invokes the transfer
/// engine, touches a journal, or removes any directory.
@MainActor func runStagingPresentationChecks() async throws -> Int {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("rightmouse-staging-ui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(configurationStore: ConfigurationStore(directory: root.appendingPathComponent("Configuration")), templateStore: TemplateStore(directory: root.appendingPathComponent("Templates")))
    let operationID = UUID(), itemID = UUID()
    let identity = try JSONDecoder().decode(TransferFileIdentity.self, from: Data(#"{"device":1,"inode":2,"kind":16384,"size":0,"modifiedSeconds":10,"modifiedNanoseconds":0,"changedSeconds":10,"changedNanoseconds":0}"#.utf8))
    let token = StagingCleanupToken(operationID: operationID, itemID: itemID, journalURL: root.appendingPathComponent("fixture.json"), stagingURL: root.appendingPathComponent(".rightmouse-\(itemID)"), stagingIdentity: identity, parentIdentity: identity, journalDigest: "fixture-digest")
    func review(_ disposition: StagingRecoveryDisposition) -> TaskReviewPresentation {
        let item = StagingRecoveryItem(operationID: operationID, itemID: itemID, stagingURL: token.stagingURL, occupiedBytes: 4096, disposition: disposition)
        return TaskReviewPresentation(id: operationID, title: "fixture", status: "需要核对", summary: "presentation only", items: [TaskReviewItemPresentation(id: itemID, name: "fixture", status: "需要核对", staging: item)])
    }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ title: String) throws {
        guard try condition() else { throw StagingPresentationFailure(description: title) }
        count += 1
    }
    var calls = 0
    model.onCleanupStaging = { _ in calls += 1 }
    try check(!model.beginStagingCleanup(token) && calls == 0, "cleanup accepted without a current review")
    model.showReview(review(.legacyEvidenceOnly("legacy fixture")))
    try check(!model.beginStagingCleanup(token) && calls == 0, "legacy evidence was allowed to invoke cleanup")
    model.showReview(review(.retainedForReview("unconfirmed fixture")))
    try check(!model.beginStagingCleanup(token) && calls == 0, "retained-for-review item invoked cleanup")
    model.showReview(review(.cleanupAllowed(token)))
    model.isReadOnly = true
    try check(!model.beginStagingCleanup(token) && !model.isCleaningStaging && calls == 0, "read-only model invoked cleanup")
    model.isReadOnly = false; model.isConfirmingReview = true
    try check(!model.beginStagingCleanup(token) && calls == 0, "cleanup raced review confirmation")
    model.isConfirmingReview = false
    let wrongTask = StagingCleanupToken(operationID: UUID(), itemID: itemID, journalURL: token.journalURL, stagingURL: token.stagingURL, stagingIdentity: identity, parentIdentity: identity, journalDigest: "fixture-digest")
    try check(!model.beginStagingCleanup(wrongTask) && calls == 0, "another task token invoked cleanup")
    let wrongLocation = StagingCleanupToken(operationID: operationID, itemID: itemID, journalURL: token.journalURL, stagingURL: root.appendingPathComponent("replacement"), stagingIdentity: identity, parentIdentity: identity, journalDigest: "fixture-digest")
    try check(!model.beginStagingCleanup(wrongLocation) && calls == 0, "stale or substituted staging token invoked cleanup")
    let wrongDigest = StagingCleanupToken(operationID: operationID, itemID: itemID, journalURL: token.journalURL, stagingURL: token.stagingURL, stagingIdentity: identity, parentIdentity: identity, journalDigest: "changed-digest")
    try check(!model.beginStagingCleanup(wrongDigest) && calls == 0, "outdated journal evidence invoked cleanup")
    model.onCleanupStaging = nil
    try check(!model.beginStagingCleanup(token) && !model.isCleaningStaging, "missing cleanup service left model busy")
    var wasBusyInCallback = false
    var reentrantAccepted = true
    model.onCleanupStaging = { supplied in
        calls += 1
        wasBusyInCallback = model.isCleaningStaging
        reentrantAccepted = model.beginStagingCleanup(supplied)
    }
    model.notice = "previous completion"
    try check(model.beginStagingCleanup(token) && calls == 1 && wasBusyInCallback && !reentrantAccepted && model.notice == nil, "cleanup state was not installed before callback or allowed reentry")
    try check(!model.beginStagingCleanup(token) && calls == 1, "double-click dispatched a second cleanup")
    var refreshes = 0, confirmations = 0
    model.onReviewTask = { _ in refreshes += 1 }
    model.onConfirmReviewTask = { _ in confirmations += 1 }
    model.refreshReview()
    await model.confirmReview()
    model.showReview(TaskReviewPresentation(id: UUID(), title: "other", status: "completed", summary: "", items: []))
    try check(refreshes == 0 && confirmations == 0 && model.taskReview?.id == operationID, "cleanup allowed refresh, confirmation, or replacement of its review")
    model.stagingCleanupFinished(error: "fixture cleanup failed")
    try check(!model.isCleaningStaging && model.reviewError == "fixture cleanup failed" && model.notice == nil && model.taskReview?.status == "需要核对", "cleanup error falsely reported success or rewrote task outcome")
    model.stagingCleanupFinished()
    try check(model.reviewError == "fixture cleanup failed" && model.notice == nil, "unsolicited completion overwrote prior cleanup error")
    model.onCleanupStaging = { _ in calls += 1; model.stagingCleanupFinished(error: "synchronous failure") }
    try check(model.beginStagingCleanup(token) && !model.isCleaningStaging && model.reviewError == "synchronous failure" && model.notice == nil, "synchronous cleanup failure was lost")
    model.onCleanupStaging = { _ in calls += 1 }
    _ = model.beginStagingCleanup(token)
    model.stagingCleanupFinished()
    try check(!model.isCleaningStaging && model.reviewError == nil && model.notice?.contains("已清理") == true && model.taskReview?.status == "需要核对", "host-confirmed cleanup completion lost status or changed original task result")
    model.refreshReview()
    try check(refreshes == 1, "review stayed locked after cleanup completion")
    model.onCleanupStaging = nil
    try check(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "presentation-only checks wrote journals or file payloads")
    return count
}
