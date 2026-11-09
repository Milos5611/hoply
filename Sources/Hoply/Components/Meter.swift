import SwiftUI

struct Meter: View {
    let label: String
    let fraction: Double
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(caption)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, geometry.size.width * clamped))
                }
            }
            .frame(height: 5)
        }
    }

    private var clamped: Double { min(max(fraction, 0), 1) }

    private var tint: Color {
        if clamped >= 0.9 { return .red }
        if clamped >= 0.7 { return .orange }
        return .accentColor
    }
}
