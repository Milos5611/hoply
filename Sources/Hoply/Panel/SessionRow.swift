import AgentKit
import SwiftUI

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    var showsProject = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SourceBadge(source: session.key.source)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(prefix)\(Text(stateText).foregroundStyle(stateColor))\(suffix)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(session.state == .needsPermission ? Color.red : Color.primary.opacity(0.75))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if session.state.needsAttention {
                    StatePill(state: session.state)
                }
                if session.totalTokens > 0 {
                    Text(usage)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let cwd = session.cwd {
                Button("Reveal in Finder") { WorkspaceActions.revealInFinder(cwd) }
                Button("Open in Terminal") { WorkspaceActions.openInTerminal(cwd) }
                Button("Copy Path") { WorkspaceActions.copy(cwd) }
                Divider()
            }
            Button("Dismiss") { model.dismiss(session.key) }
        }
    }

    private var title: String {
        session.title ?? session.project ?? session.key.source.displayName
    }

    private var prefix: String {
        var parts: [String] = []
        if showsProject, let project = session.project { parts.append(project) }
        parts.append(session.key.source.displayName)
        return parts.joined(separator: " · ") + " · "
    }

    private var suffix: String {
        session.model.map { " · \($0)" } ?? ""
    }

    private var stateText: String {
        let age = Format.age(since: session.stateSince)
        switch session.state {
        case .needsPermission, .yourTurn: return "waiting \(age)"
        case .working: return "working \(age)"
        case .idle: return "idle \(age)"
        case .ended: return "ended \(age)"
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .needsPermission: return .red
        case .yourTurn: return .orange
        case .working: return .blue
        case .idle, .ended: return .secondary
        }
    }

    private var detail: String? {
        switch session.state {
        case .needsPermission: return session.lastMessage ?? "Waiting for your approval"
        case .yourTurn: return session.lastMessage
        case .working: return session.lastTool.map { "Last tool: \($0)" }
        case .idle, .ended: return nil
        }
    }

    private var usage: String {
        var text = "\(Format.tokens(session.totalTokens)) tok"
        if session.costUSD > 0 { text += " · \(Format.cost(session.costUSD))" }
        return text
    }
}
