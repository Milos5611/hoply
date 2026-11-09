import SwiftUI

struct WidgetTile<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var footer: String?
    var footerColor: Color = .secondary
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                    Text(title)
                        .lineLimit(1)
                }
                .font(.system(size: 12.5, weight: .medium))
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                if let footer {
                    Text(footer)
                        .font(.system(size: 11.5))
                        .foregroundStyle(footerColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
