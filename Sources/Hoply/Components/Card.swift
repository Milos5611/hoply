import SwiftUI

enum CardMetrics {
    static let cornerRadius: CGFloat = 18
}

struct Card<Content: View>: View {
    var prominent = false
    var tint: Color?
    var padding: CGFloat = 13
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(base)
                    .shadow(color: .black.opacity(shadowOpacity), radius: 12, y: 4)
                if let tint { shape.fill(tint.opacity(dark ? 0.16 : 0.08)) }
            }
            .overlay(shape.strokeBorder(border, lineWidth: contrast == .increased ? 1 : 0.5))
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: CardMetrics.cornerRadius, style: .continuous) }

    private var dark: Bool { colorScheme == .dark }

    // The opaque tones are what the translucent ones give over the popover and page backgrounds.
    private var base: Color {
        if reduceTransparency || contrast == .increased {
            if dark { return Color(white: prominent ? 0.22 : 0.18) }
            return Color(white: prominent ? 1 : 0.965)
        }
        if dark { return .white.opacity(prominent ? 0.11 : 0.06) }
        return .white.opacity(prominent ? 1 : 0.5)
    }

    private var border: Color {
        if contrast == .increased { return Color.primary.opacity(0.45) }
        if dark { return .white.opacity(prominent ? 0.14 : 0.09) }
        return prominent ? Color.black.opacity(0.04) : Color.white.opacity(0.75)
    }

    private var shadowOpacity: Double {
        guard prominent, contrast != .increased else { return 0 }
        return dark ? 0.22 : 0.08
    }
}
