import SwiftUI

struct CountChip: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        let color: Color = value > 0 ? tint : .secondary
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}
