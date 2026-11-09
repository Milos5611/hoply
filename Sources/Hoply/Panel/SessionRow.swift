import AgentKit
import SwiftUI

/// Where a session runs, shown before its source: the project in "Waiting on you", or inside a project
/// card the worktree or subfolder when it isn't the project root.
enum SessionPlace: Equatable {
    case project(String)
    case worktree(String)
    case subfolder(String)

    /// nil when `cwd` is the root itself.
    init?(cwd: String?, root: String?) {
        guard let cwd, let root, cwd != root else { return nil }
        if cwd.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            self = .subfolder(String(cwd.dropFirst(root.count).drop { $0 == "/" }))
        } else {
            self = .worktree((cwd as NSString).lastPathComponent)
        }
    }

    var text: Text {
        switch self {
        case .project(let name), .subfolder(let name): return Text(name)
        case .worktree(let name): return Text("\(Image(systemName: "arrow.triangle.branch")) \(name)")
        }
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    var place: SessionPlace?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SourceBadge(source: session.key.source)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(placeText)\(prefix)\(Text(stateText).foregroundStyle(stateColor))\(suffix)")
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
                if let usage {
                    Text(usage)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(usageHelp)
                }
                if let totals = model.ledgerTotals(for: session.key), let copilot = Format.copilot(totals, compact: true) {
                    Text(copilot)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .help(Format.copilot(totals) ?? "")
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

    private var placeText: Text {
        place.map { Text("\($0.text) · ") } ?? Text(verbatim: "")
    }

    /// Inside a project card a worktree or subfolder takes the source's place (the badge shows the source),
    /// so the state never truncates.
    private var prefix: String {
        switch place {
        case .worktree, .subfolder: return ""
        case .project, nil: return session.key.source.displayName + " · "
        }
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

    /// Ledger totals when the session has any (the same numbers as the Dashboard); otherwise the live
    /// telemetry counts, for sources whose usage isn't in the ledger yet.
    private var usage: String? {
        if let totals = model.ledgerTotals(for: session.key) {
            return "\(Format.tokens(totals.tokens.total)) tok · \(Format.spend(totals))"
        }
        guard session.totalTokens > 0 else { return nil }
        var text = "\(Format.tokens(session.totalTokens)) tok"
        if session.costUSD > 0 { text += " · \(Format.cost(session.costUSD))" }
        return text
    }

    private var usageHelp: String {
        model.ledgerTotals(for: session.key) == nil ? "Live telemetry for this session"
                                                    : "API-equivalent cost from the usage ledger"
    }
}
