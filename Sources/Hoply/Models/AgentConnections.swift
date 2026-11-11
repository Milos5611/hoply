import AgentKit
import AgentSystem
import Foundation
import Observation

@MainActor
@Observable
final class AgentConnections {
    enum Nudge: Equatable {
        case connect([ConnectableAgent])
        case update([ConnectableAgent])
    }

    struct Notice: Equatable {
        var text: String
        var detail: String?
        var isError = false
    }

    static let dismissedKey = "HoplyAgentsNudgeDismissed"

    private(set) var statuses: [ConnectableAgent: ConnectionStatus] = [:]
    private(set) var running: ConnectableAgent?
    private(set) var notices: [ConnectableAgent: Notice] = [:]
    private(set) var dismissed: String?

    @ObservationIgnored var settings: () -> AppSettings = { AppSettings() }
    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var epoch = 0

    init(live: Bool = true) {
        isLive = live
        if live { dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey) }
    }

    var connector: AgentConnector { AgentConnector(settings: settings()) }

    func status(of agent: ConnectableAgent) -> ConnectionStatus? { statuses[agent] }

    var nudge: Nudge? {
        guard let problem = problem, signature != dismissed else { return nil }
        return problem
    }

    private var problem: Nudge? {
        let outdated = ConnectableAgent.allCases.filter { statuses[$0] == .outdated }
        if !outdated.isEmpty { return .update(outdated) }
        guard !statuses.values.contains(.connected) else { return nil }
        let installed = ConnectableAgent.allCases.filter { statuses[$0].map { $0 != .notInstalled } ?? false }
        return installed.isEmpty ? nil : .connect(installed)
    }

    private var signature: String {
        ConnectableAgent.allCases.map { agent in
            let kind = switch statuses[agent] {
            case nil: "unknown"
            case .notInstalled: "not-installed"
            case .notConnected: "not-connected"
            case .connected: "connected"
            case .outdated: "outdated"
            case .unreadable: "unreadable"
            }
            return "\(agent.rawValue)=\(kind)"
        }.joined(separator: ",")
    }

    func dismissNudge() {
        dismissed = signature
        if isLive { UserDefaults.standard.set(dismissed, forKey: Self.dismissedKey) }
    }

    func refresh() {
        Task { await reload() }
    }

    func settingsChanged() {
        notices = [:]
        refresh()
    }

    func connect(_ agent: ConnectableAgent) {
        run(agent, connecting: true)
    }

    func disconnect(_ agent: ConnectableAgent) {
        run(agent, connecting: false)
    }

    // A read that started before a write (or before a folder or port change) must not overwrite a newer one.
    private func reload() async {
        guard isLive else { return }
        epoch += 1
        let started = epoch
        let connector = connector
        let found = await Task.detached { connector.statuses() }.value
        guard started == epoch, found != statuses else { return }
        statuses = found
    }

    private func run(_ agent: ConnectableAgent, connecting: Bool) {
        guard isLive, running == nil else { return }
        running = agent
        notices[agent] = nil
        let connector = connector
        Task {
            let result = await Task.detached { () -> Result<ConnectOutcome, AgentConnectorError> in
                do throws(AgentConnectorError) {
                    return .success(connecting ? try connector.connect(agent) : try connector.disconnect(agent))
                } catch {
                    return .failure(error)
                }
            }.value
            notices[agent] = Self.notice(for: result, agent: agent, connecting: connecting)
            await reload()
            running = nil
        }
    }

    private static func notice(for result: Result<ConnectOutcome, AgentConnectorError>, agent: ConnectableAgent,
                               connecting: Bool) -> Notice? {
        switch result {
        case .failure(let error):
            return Notice(text: error.message, isError: true)
        case .success(let outcome):
            guard outcome.changed else { return nil }
            let detail = outcome.backupPath.map { "The previous file was backed up to \(Format.path($0))." }
                ?? outcome.renamedPath.map { "The hooks file was renamed to \(Format.path($0))." }
            let verb = connecting ? "load" : "drop"
            // Codex runs a hook only after the user has reviewed and trusted it.
            if agent == .codexCLI, connecting {
                return Notice(text: "Run /hooks in Codex and trust Hoply's hooks, then restart running sessions.",
                              detail: detail)
            }
            return Notice(text: "Restart running \(agent.displayName) sessions to \(verb) the hooks.", detail: detail)
        }
    }

    func show(statuses: [ConnectableAgent: ConnectionStatus], notices: [ConnectableAgent: Notice] = [:],
              running: ConnectableAgent? = nil) {
        self.statuses = statuses
        self.notices = notices
        self.running = running
    }
}
