import AgentKit
import SwiftUI

struct StatePill: View {
    let status: SessionStatus
    var failed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = Self.color(for: status, failed: failed)
        HStack(spacing: 4) {
            if status == .working {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5.5))
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            }
            Text(label)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.15)))
        .fixedSize()
    }

    private var label: String {
        if failed { return "Failed" }
        if let until = status.limitedUntil { return "Limited · resets \(Format.clock(until))" }
        return status.label
    }

    static func color(for status: SessionStatus, failed: Bool = false) -> Color {
        switch status {
        case .permission: return .orange
        case .input: return .indigo
        case .yourTurn: return failed ? .red : .green
        case .working: return .blue
        case .limited, .idle, .ended: return .gray
        }
    }
}
