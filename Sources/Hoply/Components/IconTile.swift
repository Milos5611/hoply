import SwiftUI

struct IconTile: View {
    let symbol: String
    var tint: Color = .secondary
    var size: CGFloat = 30

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(shape.fill(colorScheme == .dark ? Color.white.opacity(0.10) : .white))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
