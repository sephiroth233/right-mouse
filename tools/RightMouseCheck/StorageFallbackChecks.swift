import Foundation
import RightMouseCore

private struct StorageFallbackCheckFailure: Error, CustomStringConvertible { let description: String }

/// Each path is a disposable fixture. No real App Group, TCC state or bookmark is used.
func runStorageFallbackChecks() throws -> Int {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw StorageFallbackCheckFailure(description: message) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-storage-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let group = root.appendingPathComponent("group", isDirectory: true)
    let support = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
    let development = SharedPaths.ResolutionEnvironment(appGroup: "group.test.storage", isExtension: false, allowsDevelopmentFallback: true)
    let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))

    var prepared: [URL] = []; var localLookups = 0
    let shared = try SharedPaths.resolveAndPrepare(environment: development, groupContainer: { _ in group }, applicationSupport: { localLookups += 1; return support }, prepare: { prepared.append($0.root) })
    try check(!shared.isDevelopmentFallback && shared.root == group.appendingPathComponent("RightMouse", isDirectory: true), "Working group must be preferred even in a development build")
    try check(localLookups == 0 && prepared.count == 1, "Working group must not touch local development storage")

    let unavailable = try SharedPaths.resolveAndPrepare(environment: development, groupContainer: { _ in nil }, applicationSupport: { support }, prepare: { try $0.prepare() })
    try check(unavailable.developmentReason == .sharedContainerUnavailable && unavailable.root.lastPathComponent == "RightMouse-Development", "Missing group must use a distinct development directory")
    try check(FileManager.default.fileExists(atPath: unavailable.inboxDirectory.path), "Fallback must be prepared before it is returned")
    try check(unavailable.developmentDiagnostic?.contains("Finder 右键功能不可用") == true, "Fallback must disclose Finder unavailability")

    prepared = []
    let unwritable = try SharedPaths.resolveAndPrepare(environment: development, groupContainer: { _ in group }, applicationSupport: { support }, prepare: {
        prepared.append($0.root)
        if !$0.isDevelopmentFallback { throw denied }
        try $0.prepare()
    })
    try check(unwritable.developmentReason == .sharedContainerUnwritable && prepared.count == 2, "Returned-but-unwritable group must fall back after the real access failure")

    var production = development; production.allowsDevelopmentFallback = false
    localLookups = 0
    do {
        _ = try SharedPaths.resolveAndPrepare(environment: production, groupContainer: { _ in group }, applicationSupport: { localLookups += 1; return support }, prepare: { _ in throw denied })
        throw StorageFallbackCheckFailure(description: "Signed/production policy unexpectedly downgraded")
    } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EACCES) { }
    try check(localLookups == 0, "Production failure must preserve the original error without touching local storage")

    var extensionEnvironment = development; extensionEnvironment.isExtension = true
    localLookups = 0
    do {
        _ = try SharedPaths.resolveAndPrepare(environment: extensionEnvironment, groupContainer: { _ in nil }, applicationSupport: { localLookups += 1; return support }, prepare: { _ in })
        throw StorageFallbackCheckFailure(description: "Extension unexpectedly fell back despite its role")
    } catch let failure as CommandFailure { try check(failure.code == .accessDenied, "Extension refusal must be explicit") }
    try check(localLookups == 0, "Extension must never resolve local storage even if a development flag is present")

    var explicit = development; explicit.developmentDirectory = root.appendingPathComponent("explicit").path
    var groupLookups = 0
    let overridden = try SharedPaths.resolveAndPrepare(environment: explicit, groupContainer: { _ in groupLookups += 1; return group }, applicationSupport: { support }, prepare: { try $0.prepare() })
    try check(overridden.developmentReason == .explicitDirectory && groupLookups == 0, "Allowed explicit fixture directory should not probe the system container")

    for original in [production, extensionEnvironment] {
        var restricted = original; restricted.developmentDirectory = explicit.developmentDirectory
        do {
            _ = try SharedPaths.resolveAndPrepare(environment: restricted, groupContainer: { _ in groupLookups += 1; return group }, applicationSupport: { support }, prepare: { _ in })
            throw StorageFallbackCheckFailure(description: "Production or extension accepted a development environment override")
        } catch let failure as CommandFailure { try check(failure.code == .accessDenied, "Forbidden override must return accessDenied") }
    }
    try check(groupLookups == 0, "Forbidden overrides must be rejected before any storage access")

    do {
        _ = try SharedPaths.resolveAndPrepare(environment: development, groupContainer: { _ in nil }, applicationSupport: { support }, prepare: { _ in throw denied })
        throw StorageFallbackCheckFailure(description: "Unwritable local fallback was silently accepted")
    } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EACCES) { }

    var invalid = development; invalid.developmentDirectory = "relative/path"
    do {
        _ = try SharedPaths.resolveAndPrepare(environment: invalid, groupContainer: { _ in group }, applicationSupport: { support }, prepare: { _ in })
        throw StorageFallbackCheckFailure(description: "Relative override silently used the working directory")
    } catch let failure as CommandFailure { try check(failure.code == .invalidRequest, "Invalid override must be rejected") }

    // A real filesystem error after a successful URL lookup reproduces the startup
    // failure class without making any protected directory writable.
    let obstructedGroup = root.appendingPathComponent("group-is-a-file")
    let sentinel = Data("leave this fixture untouched".utf8); try sentinel.write(to: obstructedGroup)
    let actual = try SharedPaths.resolveAndPrepare(environment: development, groupContainer: { _ in obstructedGroup }, applicationSupport: { support }, prepare: { try $0.prepare() })
    try check(actual.isDevelopmentFallback && actual.developmentReason == .sharedContainerUnwritable, "Actual prepare failure did not select the permitted fallback")
    let remaining = try Data(contentsOf: obstructedGroup)
    try check(remaining == sentinel, "Fallback changed the inaccessible group fixture")
    return 10
}
