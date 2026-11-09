import AgentKit
import SwiftUI

struct StatePill: View {
    let state: SessionState

    var body: some View {
        let color = Self.color(for: state)
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var label: String {
        switch state {
        case .needsPermission: return "Permission"
        case .yourTurn: return "Your turn"
        case .working: return "Working"
        case .idle: return "Idle"
        case .ended: return "Ended"
        }
    }

    static func color(for state: SessionState) -> Color {
        switch state {
        case .needsPermission: return .red
        case .yourTurn: return .orange
        case .working: return .blue
        case .idle: return .gray
        case .ended: return .secondary
        }
    }
}
