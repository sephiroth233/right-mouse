import AppKit
import SwiftUI

/// Glass belongs to navigation and controls; reading surfaces stay quiet and legible.
private struct RightMouseGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.secondary.opacity(0.35)))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.22)))
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        }
    }
}

extension View {
    func rightMouseGlass(radius: CGFloat = 20) -> some View { modifier(RightMouseGlass(radius: radius)) }
}

struct RightMouseBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        ZStack {
            if reduceTransparency || contrast == .increased {
                Color(nsColor: .windowBackgroundColor)
            } else {
                WindowMaterial()
                LinearGradient(colors: [.blue.opacity(0.09), .clear, .cyan.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct RightMouseGroupBoxStyle: GroupBoxStyle {
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.headline)
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(contrast == .increased ? 1 : 0.80), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(contrast == .increased ? 0.3 : 0.06)))
    }
}
