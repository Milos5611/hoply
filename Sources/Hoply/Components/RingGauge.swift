import SwiftUI

struct RingGauge<Center: View>: View {
    let fraction: Double
    let tint: Color
    var lineWidth: CGFloat = 7
    var marker: Double?
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let marker {
                GeometryReader { proxy in
                    let radius = min(proxy.size.width, proxy.size.height) / 2
                    Capsule()
                        .fill(Color.primary.opacity(0.78))
                        .frame(width: 2, height: lineWidth + 4)
                        .offset(y: -radius)
                        .rotationEffect(.degrees(min(max(marker, 0), 1) * 360))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            center
        }
        .padding(lineWidth / 2)
    }
}
