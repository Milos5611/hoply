import AgentKit
import SwiftUI

enum SessionPlace: Equatable {
    case project(String)
    case worktree(String)
    case subfolder(String)

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
    let status: SessionStatus
    var place: SessionPlace?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SourceBadge(source: session.key.source)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(placeText)\(prefix)\(Text(age).foregroundStyle(ageColor))\(suffix)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(stateHelp)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(detailColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                if let subagents {
                    Label(subagents, systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11.5))
                        .foregroundStyle(session.workingSubagentCount > 0 ? Color.blue : Color.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                        .help(subagentHelp)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                StatePill(status: status, failed: failed)
                    .help(stateHelp)
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
                SessionFacts(diff: model.diffStat(for: session), context: model.contextWindow(for: session.key),
                             path: session.cwd)
            }
            .fixedSize()
        }
        .opacity(status.recedes ? 0.6 : 1)
        .contentShape(Rectangle())
        .contextMenu {
            if let cwd = session.cwd {
                if let editor = model.defaultEditor {
                    Button("Open in \(editor.name)") { model.openInEditor(cwd) }
                }
                Button("Reveal in Finder") { WorkspaceActions.revealInFinder(cwd) }
                Button("Open in Terminal") { WorkspaceActions.openInTerminal(cwd) }
                Button("Copy Path") { WorkspaceActions.copy(cwd) }
                Divider()
            }
            Button("Dismiss") { model.dismiss(session.key) }
        }
    }

    private var failed: Bool { status == .yourTurn && session.failure != nil }

    private var title: String {
        session.title ?? session.project ?? session.key.source.displayName
    }

    private var placeText: Text {
        place.map { Text("\($0.text) · ") } ?? Text(verbatim: "")
    }

    private var prefix: String {
        place == nil ? session.key.source.displayName + " · " : ""
    }

    private var suffix: String {
        session.model.map { " · \(Format.model($0))" } ?? ""
    }

    private var age: String { Format.age(since: session.stateSince) }

    private var ageColor: Color {
        status.recedes ? .secondary : StatePill.color(for: status, failed: failed)
    }

    private var stateHelp: String {
        let since = Format.clock(session.stateSince)
        var text: String
        switch status {
        case .permission: text = "Waiting for your approval since \(since)"
        case .input: text = "Asked you a question at \(since)"
        case .limited(let until):
            text = "Waiting since \(since). The Claude plan limit is reached; it resets at \(Format.clock(until))"
        case .yourTurn: text = failed ? "The turn failed at \(since)" : "Finished its turn at \(since)"
        case .working: text = "Working since \(since)"
        case .idle: text = "Idle since \(since)"
        case .ended: text = "Ended at \(since)"
        }
        if let model = session.model { text += " · \(model)" }
        return text
    }

    private var detail: String? {
        switch status {
        case .permission: return session.lastMessage ?? "Waiting for your approval"
        case .input: return session.lastMessage ?? "Asked you a question"
        case .yourTurn where failed: return session.lastMessage ?? "The turn ended with an error"
        case .yourTurn, .limited: return session.lastMessage
        case .working: return session.lastTool.map { "Last tool: \($0)" }
        case .idle, .ended: return nil
        }
    }

    private var detailColor: Color {
        switch status {
        case .permission: return .orange
        case .input: return .indigo
        case .yourTurn where failed: return .red
        default: return Color.primary.opacity(0.75)
        }
    }

    private var subagents: String? {
        let count = model.subagentCount(for: session)
        guard count > 0 else { return nil }
        let text = count == 1 ? "1 subagent" : "\(count) subagents"
        let working = session.workingSubagentCount
        return working > 0 ? "\(text) · \(working) working" : text
    }

    private var subagentHelp: String {
        let working = session.subagents.filter(\.isWorking).map { $0.type ?? "subagent" }
        return working.isEmpty ? "Subagents this session started" : "Working: " + working.joined(separator: ", ")
    }

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

struct SessionFacts: View {
    let diff: GitDiffStat?
    let context: ContextWindow?
    var path: String?

    var body: some View {
        let diff = diff.flatMap { $0.isClean ? nil : $0 }
        let context = context.flatMap { $0.isWarning ? $0 : nil }
        if diff != nil || context != nil {
            HStack(spacing: 6) {
                if let diff {
                    HStack(spacing: 4) {
                        if diff.added > 0 || diff.removed > 0 {
                            Text("+\(diff.added)")
                                .foregroundStyle(.green)
                            Text("−\(diff.removed)")
                                .foregroundStyle(.red)
                        } else {
                            Text("\(diff.untracked) new")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help(Format.diffSummary(diff, path: path))
                }
                if let context {
                    Text("ctx \(Format.percent(context.fraction))")
                        .foregroundStyle(context.fraction >= 0.95 ? Color.red : Color.orange)
                        .help(Format.contextSummary(context))
                }
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        }
    }
}
