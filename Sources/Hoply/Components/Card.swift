import SwiftUI

/// The white rounded surface everything in the panel sits on. `prominent` marks the active tile.
struct Card<Content: View>: View {
    var prominent = false
    var tint: Color?
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(base)
                if let tint { shape.fill(tint.opacity(colorScheme == .dark ? 0.16 : 0.09)) }
            }
            .overlay(shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 0.5))
            .shadow(color: .black.opacity(prominent && colorScheme == .light ? 0.07 : 0), radius: 8, y: 2)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    private var base: Color {
        if reduceTransparency { return Color(nsColor: .controlBackgroundColor) }
        if colorScheme == .dark { return .white.opacity(prominent ? 0.12 : 0.06) }
        return .white.opacity(prominent ? 1 : 0.62)
    }
}
