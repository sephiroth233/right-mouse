import SwiftUI
import AppKit
import RightMouseCore

@MainActor enum AppIcons {
    static let brand: NSImage? = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    private static let applications = NSCache<NSString, NSImage>()
    static func application(_ integration: AppIntegration) -> NSImage {
        let key = (integration.bundleID + "|" + (integration.applicationPath ?? "")) as NSString
        if let image = applications.object(forKey: key) { return image }
        let url = integration.applicationPath.map { URL(fileURLWithPath: $0) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: integration.bundleID)
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: integration.adapterType == "terminal" ? "terminal" : "app", accessibilityDescription: nil)!
        applications.setObject(image, forKey: key)
        return image
    }
}

struct ApplicationIcon: View {
    let integration: AppIntegration
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: AppIcons.application(integration)).resizable().interpolation(.high)
            .aspectRatio(contentMode: .fit).frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct MenuEntryIcon: View {
    let entry: MenuEntry
    let integrations: [AppIntegration]
    var body: some View {
        Group {
            if case let .openWith(id, _) = entry.action, let app = integrations.first(where: { $0.id == id }) {
                ApplicationIcon(integration: app, size: 16)
            } else if entry.id == "rightmouse", let image = AppIcons.brand {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else { Image(systemName: MenuIcon.symbol(for: entry)).foregroundStyle(.secondary) }
        }.frame(width: 18, height: 18).accessibilityHidden(true)
    }
}
