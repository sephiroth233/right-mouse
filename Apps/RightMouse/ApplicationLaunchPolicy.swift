import AppKit
import Carbon

/// Use the launch event, not the saved login-item preference: a user can still
/// open settings manually when launch-at-login is enabled.
struct ApplicationLaunchPolicy {
    private(set) var launchedAtLogin = false
    private(set) var launchedForService = false
    private(set) var presentedWindow = false
    let finderWake: Bool

    init(arguments: [String] = CommandLine.arguments) {
        finderWake = arguments.contains("--finder-wake")
    }
    mutating func observe(_ event: NSAppleEventDescriptor?) {
        if Self.isLoginEvent(event) { launchedAtLogin = true }
        if Self.isServiceEvent(event) { launchedForService = true }
    }
    mutating func didPresentWindow() { presentedWindow = true }
    var startsInBackground: Bool { launchedAtLogin || launchedForService || finderWake }
    func shouldPresentInitialWindow(receivedDispatch: Bool) -> Bool {
        !startsInBackground && !receivedDispatch && !presentedWindow
    }
    static func isLoginEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
    static func isServiceEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventID == AEEventID(kAEOpenApplication)
            && (event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsServiceItem)
                || event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsServiceItem))?.booleanValue == true)
    }
}
