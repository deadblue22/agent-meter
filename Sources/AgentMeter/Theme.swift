import AppKit
import SwiftUI

/// One look for the whole window: the title bar, the process list and the disk chart all sit on the same deep purple
/// and use the same panels, buttons and accent.
enum Theme {
    static let top = Color(red: 0.11, green: 0.07, blue: 0.19)
    static let bottom = Color(red: 0.07, green: 0.045, blue: 0.13)
    static var background: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
    /// The window's own background, for the moments before the gradient is drawn
    static let base = NSColor(red: 0.09, green: 0.057, blue: 0.16, alpha: 1)

    static let panel = Color.white.opacity(0.07)
    static let panelStroke = Color.white.opacity(0.08)
    /// Links and highlights
    static let accent = Color(red: 0.72, green: 0.62, blue: 1.0)
    /// Prominent buttons and selections
    static let accentStrong = Color(red: 0.49, green: 0.36, blue: 0.95)
    static let positive = Color(red: 0.55, green: 0.95, blue: 0.65)
    static let destructive = Color(red: 1.0, green: 0.58, blue: 0.52)
}

extension View {
    /// A rounded translucent panel, like the list of the disk chart
    func themedPanel(cornerRadius: CGFloat = 16) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.panelStroke))
    }
}

/// Buttons that belong to the theme: a soft rounded fill, brighter when pressed, filled with the accent when prominent
struct ThemeButtonStyle: ButtonStyle {
    var prominent = false
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, prominent: prominent, large: large)
    }

    private struct ButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: large ? 14 : 13, weight: .medium))
                .padding(.horizontal, large ? 16 : 10)
                .padding(.vertical, large ? 8 : 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(fill))
                .foregroundStyle(configuration.role == .destructive ? Theme.destructive : Color.white)
                .opacity(isEnabled ? 1 : 0.4)
        }

        private var fill: Color {
            if prominent { return Theme.accentStrong.opacity(configuration.isPressed ? 0.8 : 1) }
            return Color.white.opacity(configuration.isPressed ? 0.2 : 0.11)
        }
    }
}

/// Makes the window's title bar part of the theme: transparent over the same background, dark whatever the system
/// appearance is
struct WindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.style(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.style(view.window) }
    }

    static func style(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = Theme.base
        window.appearance = NSAppearance(named: .darkAqua)
    }
}
