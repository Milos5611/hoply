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
        switch source {
        case .claudeCode: return "asterisk"
        case .copilotCLI: return "terminal"
        case .copilotIDE: return "curlybraces"
        case .qwenCode: return "cpu"
        }
    }

    static func color(for source: AgentSource) -> Color {
        switch source {
        case .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .copilotCLI: return Color(red: 0.43, green: 0.33, blue: 0.84)
        case .copilotIDE: return Color(red: 0.30, green: 0.42, blue: 0.86)
        case .qwenCode: return Color(red: 0.20, green: 0.60, blue: 0.55)
        }
    }
}
