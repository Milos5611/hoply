import SwiftUI

struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.05)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == TileButtonStyle {
    static var tile: TileButtonStyle { TileButtonStyle() }
}
