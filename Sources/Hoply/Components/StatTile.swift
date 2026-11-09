import SwiftUI

struct StatTile<Accessory: View>: View {
    let label: String
    let value: String
    var unit: String?
    var valueColor: Color = .primary
    var tag: String?
    var tagColor: Color = .green
    var prominent = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        Card(prominent: prominent, padding: 11) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(label)
                        .foregroundStyle(prominent ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if let tag {
                        Text(tag)
                            .fontWeight(.medium)
                            .foregroundStyle(tagColor)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 12.5))
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        .foregroundStyle(prominent ? valueColor : valueColor.opacity(0.75))
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(2)
                    if let unit {
                        Text(unit)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 4)
                    accessory
                        .frame(minWidth: 18, maxWidth: 46)
                        .frame(height: 20)
                }
            }
        }
    }
}
