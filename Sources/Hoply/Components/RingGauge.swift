import SwiftUI

struct RingGauge<Center: View>: View {
    let fraction: Double
    let tint: Color
    var lineWidth: CGFloat = 7
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .padding(lineWidth / 2)
    }
}
