import AgentKit
import SwiftUI

enum AwayProblem: Equatable {
    case outdated([ConnectableAgent])
    case notConnected([ConnectableAgent])
    case unreadable(ConnectableAgent, String)
    case notInstalled

    static let agents = TurnReply.sources.compactMap(ConnectableAgent.init(source:))

    init?(statuses: [ConnectableAgent: ConnectionStatus]) {
        let known = Self.agents.filter { statuses[$0] != nil }
        guard !known.isEmpty else { return nil }
        let outdated = known.filter { statuses[$0] == .outdated }
        let unreadable = known.lazy.compactMap { agent -> (ConnectableAgent, String)? in
            if case .unreadable(let reason) = statuses[agent] { (agent, reason) } else { nil }
        }.first
        if !outdated.isEmpty {
            self = .outdated(outdated)
        } else if known.contains(where: { statuses[$0] == .connected }) {
            return nil
        } else if let (agent, reason) = unreadable {
            self = .unreadable(agent, reason)
        } else {
            let connectable = known.filter { statuses[$0] == .notConnected }
            self = connectable.isEmpty ? .notInstalled : .notConnected(connectable)
        }
    }

    var fixable: [ConnectableAgent] {
        switch self {
        case .outdated(let agents), .notConnected(let agents): agents
        case .unreadable, .notInstalled: []
        }
    }
}

struct AwayChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let problem = model.awayProblem
        let color: Color = problem != nil ? .orange : .teal
        Button { model.showingSettings = true } label: {
            HStack(spacing: 4) {
                Image(systemName: problem != nil ? "exclamationmark.triangle.fill" : AwayText.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text("Away")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(AwayText.chipHelp(problem))
    }
}

struct AwayNoticeCard: View {
    let problem: AwayProblem

    var body: some View {
        Card(tint: .orange) {
            HStack(spacing: 10) {
                IconTile(symbol: AwayText.symbol, tint: .orange, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AwayText.title(problem))
                        .font(.system(size: 13, weight: .semibold))
                    Text(AwayText.problem(problem))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                AwayFixButton(problem: problem)
            }
        }
    }
}

struct AwaySetupRow: View {
    let problem: AwayProblem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
            Text(AwayText.problem(problem))
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            AwayFixButton(problem: problem)
        }
    }
}

struct AwayFixButton: View {
    @Environment(AppModel.self) private var model
    let problem: AwayProblem

    var body: some View {
        let connections = model.connections
        let agents = problem.fixable
        if let running = connections.running, agents.contains(running) {
            ProgressView()
                .controlSize(.small)
        } else if !agents.isEmpty {
            Button(title) { connections.connect(agents) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(connections.running != nil)
                .help(AwayText.fixHelp(agents))
        }
    }

    private var title: String {
        if case .outdated = problem { "Update" } else { "Connect" }
    }
}

enum AwayText {
    static let symbol = "figure.walk"

    static func agentName(_ source: AgentSource) -> String {
        switch source {
        case .claudeCode: "Claude"
        case .copilotCLI: "Copilot"
        default: source.displayName
        }
    }

    static func placeholder(_ source: AgentSource) -> String {
        "Tell \(agentName(source)) what to do next"
    }

    static var settingsHint: String {
        let agents = AwayProblem.agents
        return "\(list(agents)) \(agents.count == 1 ? "waits" : "wait") at each turn end, up to 30 minutes, until you tell \(agents.count == 1 ? "it" : "them") what to do next or press Done in the panel or the notification; Copilot CLI's terminal shows nothing while it waits. Claude Code's permission prompts come here too, and this Mac doesn't sleep (a closed lid on battery still does)."
    }

    static func chipHelp(_ problem: AwayProblem?) -> String {
        let agents = AwayProblem.agents
        switch problem {
        case nil:
            return "Away mode is on: \(list(agents)) \(agents.count == 1 ? "waits" : "wait") for your reply at each turn end, Claude Code's permission prompts come here, and this Mac stays awake. Click for Settings"
        case .outdated(let outdated):
            return "Away mode is on, but \(list(outdated)) \(outdated.count == 1 ? "needs" : "need") a hooks update. Click for Settings"
        case .notConnected, .unreadable, .notInstalled:
            return "Away mode is on, but \(noneIs(agents, "connected")). Click for Settings"
        }
    }

    static func title(_ problem: AwayProblem) -> String {
        if case .outdated = problem { "Away mode needs newer hooks" } else { "Away mode can't hold any agent yet" }
    }

    static func problem(_ problem: AwayProblem) -> String {
        switch problem {
        case .outdated(let agents) where agents.count == 1:
            "\(agents[0].displayName)'s hooks are older than Away mode, so its turns end without waiting for you. Update them, then restart running sessions."
        case .outdated(let agents):
            "\(list(agents)) have hooks older than Away mode, so their turns end without waiting for you. Update them, then restart running sessions."
        case .notConnected(let agents):
            "\(sentence(noneIs(agents, "connected"))). Connect \(agents.count == 1 ? "it" : "them"), then restart running sessions."
        case .unreadable(let agent, let reason):
            "Hoply can't read \(agent.displayName)'s \(agent == .claudeCode ? "settings" : "hooks file"): \(reason)"
        case .notInstalled:
            "\(sentence(noneIs(AwayProblem.agents, "installed"))). Away mode holds only \(AwayProblem.agents.count == 1 ? "its" : "their") turns."
        }
    }

    static func fixHelp(_ agents: [ConnectableAgent]) -> String {
        "Write Hoply's current hooks for \(list(agents)); your own hooks and settings stay"
    }

    private static func list(_ agents: [ConnectableAgent]) -> String {
        let names = agents.map(\.displayName)
        guard names.count > 2 else { return names.joined(separator: " and ") }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    private static func noneIs(_ agents: [ConnectableAgent], _ state: String) -> String {
        let names = agents.map(\.displayName)
        switch names.count {
        case 1: return "\(names[0]) isn't \(state)"
        case 2: return "neither \(names[0]) nor \(names[1]) is \(state)"
        default: return "none of \(list(agents)) is \(state)"
        }
    }

    private static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
