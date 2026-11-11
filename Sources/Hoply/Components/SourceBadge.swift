import AgentKit
import SwiftUI

struct SourceBadge: View {
    let source: AgentSource
    var size: CGFloat = 30

    var body: some View {
        IconTile(symbol: Self.symbol(for: source), tint: Self.color(for: source), size: size)
            .help(source.displayName)
    }

    static func symbol(for source: AgentSource) -> String {
        source.info.symbol
    }

    static func color(for source: AgentSource) -> Color {
        let tint = source.info.tint
        return Color(red: tint.red, green: tint.green, blue: tint.blue)
    }
}
