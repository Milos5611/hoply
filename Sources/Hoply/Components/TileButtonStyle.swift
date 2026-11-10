import SwiftUI

struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration)
    }

    private struct Tile: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.13 : hovering ? 0.085 : 0.055)))
                .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : 0.07), lineWidth: 0.5))
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == TileButtonStyle {
    static var tile: TileButtonStyle { TileButtonStyle() }
}
