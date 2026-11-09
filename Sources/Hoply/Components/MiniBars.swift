import SwiftUI

struct MiniBars: View {
    let values: [Double]
    var highlightLast = 1
    var tint: Color = .accentColor
    var maxBars = 12

    var body: some View {
        let values = Array(values.suffix(maxBars))
        GeometryReader { geometry in
            let top = max(values.max() ?? 0, 0.000_001)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(values.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                        .fill(index >= values.count - highlightLast ? tint : Color.primary.opacity(0.16))
                        .frame(height: max(2, geometry.size.height * values[index] / top))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}
