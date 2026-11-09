import SwiftUI

struct StackedBar: View {
    let segments: [(value: Double, color: Color)]

    var body: some View {
        GeometryReader { geometry in
            let total = segments.reduce(0) { $0 + max($1.value, 0) }
            HStack(spacing: 2) {
                if total <= 0 {
                    Capsule().fill(Color.primary.opacity(0.10))
                } else {
                    ForEach(segments.indices, id: \.self) { index in
                        Capsule()
                            .fill(segments[index].color.opacity(0.85))
                            .frame(width: max(3, (geometry.size.width - CGFloat(segments.count - 1) * 2)
                                * max(segments[index].value, 0) / total))
                    }
                }
            }
        }
    }
}
