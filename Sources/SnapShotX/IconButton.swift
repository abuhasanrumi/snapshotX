import SwiftUI

/// An icon-only button. Every one has a tooltip, which also serves as its accessibility label, so the
/// interface can lean on symbols instead of words without becoming a guessing game.
struct IconButton: View {
    enum Style {
        /// Quiet: shows only on hover or when switched on.
        case plain
        /// The main action of a panel.
        case accent
        /// Stop, discard, delete.
        case destructive
        /// On top of a thumbnail or other dark media.
        case overMedia
        /// On top of anything, including a light screenshot: a dark backing keeps it visible.
        case dark
    }

    enum Shape {
        case circle, square
    }

    let symbol: String
    let help: String
    var style: Style = .plain
    var shape: Shape = .circle
    var size: CGFloat = 30
    var isOn = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(outline.fill(background))
                .contentShape(outline)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var outline: AnyShape {
        switch shape {
        case .circle: return AnyShape(Circle())
        case .square: return AnyShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        }
    }

    private var foreground: Color {
        switch style {
        case .plain: return isOn ? .accentColor : .primary
        case .accent, .destructive, .overMedia, .dark: return .white
        }
    }

    private var background: Color {
        switch style {
        case .plain:
            if isOn { return Color.accentColor.opacity(hovering ? 0.34 : 0.24) }
            return hovering ? Color.primary.opacity(0.12) : .clear
        case .accent: return Color.accentColor.opacity(hovering ? 0.85 : 1)
        case .destructive: return Color.red.opacity(hovering ? 0.85 : 1)
        case .overMedia: return Color.white.opacity(hovering ? 0.38 : 0.24)
        case .dark: return Color.black.opacity(hovering ? 0.8 : 0.58)
        }
    }
}
