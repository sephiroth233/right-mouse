import AppKit

enum WindowLayout {
    static let settingsSize = NSSize(width: 960, height: 680)
    static let minimumSettingsSize = NSSize(width: 820, height: 540)
    static let tasksSize = NSSize(width: 760, height: 560)

    /// Geometric centering in usable screen space, including screens with negative origins.
    static func centeredFrame(preferred: NSSize, visibleFrame: NSRect) -> NSRect {
        let margin: CGFloat = 24
        let width = min(preferred.width, max(1, visibleFrame.width - margin * 2))
        let height = min(preferred.height, max(1, visibleFrame.height - margin * 2))
        return NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2, width: width, height: height)
    }

    @MainActor static func prepare(_ window: NSWindow, preferred: NSSize, minimum: NSSize) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            window.setFrame(centeredFrame(preferred: preferred, visibleFrame: screen.visibleFrame), display: false)
        }
        window.minSize = NSSize(width: min(minimum.width, window.frame.width), height: min(minimum.height, window.frame.height))
    }

    @MainActor static func centerForReopen(_ window: NSWindow) {
        guard !window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? window.screen ?? NSScreen.main
        if let screen { window.setFrame(centeredFrame(preferred: window.frame.size, visibleFrame: screen.visibleFrame), display: false) }
    }
}
