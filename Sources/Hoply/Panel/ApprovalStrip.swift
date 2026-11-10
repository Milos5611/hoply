import AgentKit
import SwiftUI

struct ApprovalStrip: View {
    @Environment(AppModel.self) private var model
    let approval: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let detail = approval.detail {
                Text(detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help(detail)
            }
            HStack(spacing: 6) {
                Text(approval.agentID == nil ? approval.tool : "\(approval.tool) · subagent")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button("Deny") { model.decide(approval.id, .deny) }
                    .buttonStyle(.bordered)
                    .help("Deny this once; Claude is told you declined and carries on")
                Button("Allow") { model.decide(approval.id, .allow) }
                    .buttonStyle(.borderedProminent)
                    .help("Allow this once. The terminal prompt closes; no rule is saved")
            }
            .controlSize(.small)
        }
    }
}
