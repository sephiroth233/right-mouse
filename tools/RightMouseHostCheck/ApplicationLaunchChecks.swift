import AppKit
import Carbon
import Combine
import RightMouseCore

private struct ApplicationLaunchFailure: Error { let message: String }

@MainActor func runApplicationLaunchChecks() throws -> Int {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ApplicationLaunchFailure(message: message) }
        count += 1; print("PASS launch-policy: \(message)")
    }
    func event(_ eventID: AEEventID = AEEventID(kAEOpenApplication), property: OSType? = nil) -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: eventID, targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let property { descriptor.setParam(NSAppleEventDescriptor(enumCode: property), forKeyword: AEKeyword(keyAEPropData)) }
        return descriptor
    }
    let login = event(property: OSType(keyAELaunchedAsLogInItem))
    var policy = ApplicationLaunchPolicy(arguments: ["RightMouse"])
    try check(policy.shouldPresentInitialWindow(receivedDispatch: false), "manual launch opens settings")
    try check(!policy.shouldPresentInitialWindow(receivedDispatch: true), "Finder URL action does not open settings")
    policy.observe(login)
    try check(policy.launchedAtLogin && !policy.shouldPresentInitialWindow(receivedDispatch: false), "real login Apple-event fields suppress the initial window")
    policy.observe(nil)
    try check(policy.launchedAtLogin, "login reason survives callback with no current event")
    try check(!ApplicationLaunchPolicy.isLoginEvent(event()), "normal open event is not mistaken for login")
    try check(!ApplicationLaunchPolicy.isLoginEvent(event(AEEventID(kAEReopenApplication), property: OSType(keyAELaunchedAsLogInItem))), "login marker on a different event cannot suppress manual reopen")
    try check(!ApplicationLaunchPolicy.isLoginEvent(event(property: OSType(keyAELaunchedAsServiceItem))), "service marker is distinct from login")
    var servicePolicy = ApplicationLaunchPolicy(arguments: [])
    servicePolicy.observe(event(property: OSType(keyAELaunchedAsServiceItem)))
    try check(servicePolicy.launchedForService && !servicePolicy.shouldPresentInitialWindow(receivedDispatch: false), "system service launch suppresses settings")
    servicePolicy.observe(nil)
    try check(servicePolicy.startsInBackground, "service launch marker survives later callback")
    try check(!ApplicationLaunchPolicy.isServiceEvent(event()), "manual open is not a service launch")
    try check(!ApplicationLaunchPolicy.isServiceEvent(event(AEEventID(kAEReopenApplication), property: OSType(keyAELaunchedAsServiceItem))), "manual reopen is not suppressed by a service marker")
    let finder = ApplicationLaunchPolicy(arguments: ["RightMouse", "--finder-wake"])
    try check(finder.startsInBackground && !finder.shouldPresentInitialWindow(receivedDispatch: false), "Finder wake argument starts without window")
    var shown = ApplicationLaunchPolicy(arguments: [])
    shown.didPresentWindow()
    try check(!shown.shouldPresentInitialWindow(receivedDispatch: false), "delayed launch callback cannot reopen a window the user already closed")

    let root = URL(fileURLWithPath: "/private/tmp/rightmouse-launch-model-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConfigurationStore(directory: root.appendingPathComponent("config"))
    let model = AppModel(configurationStore: store, templateStore: TemplateStore(directory: root.appendingPathComponent("templates")))
    var visibleChanges: [Bool] = []
    let subscription = model.$configuration.map(\.showMenuBarIcon).removeDuplicates().sink { visibleChanges.append($0) }
    defer { subscription.cancel() }
    try check(model.save { $0.showMenuBarIcon = false }, "menu-bar icon setting saves")
    let restored = try store.load()
    try check(!restored.showMenuBarIcon && visibleChanges == [true, false], "persisted icon choice publishes immediately to application delegate")
    try check(model.save { $0.showMenuBarIcon = true }, "menu-bar icon can be restored")
    try check(visibleChanges == [true, false, true], "repeated toggle does not leave a stale visibility state")
    model.isReadOnly = true
    model.setLaunchAtLogin(true)
    try check(!model.configuration.launchAtLogin && model.errorMessage != nil, "read-only config blocks login registration before touching system service")
    return count
}
