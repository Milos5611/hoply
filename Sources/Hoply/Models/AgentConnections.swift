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

    private struct Reading: Sendable {
        var statuses: [ConnectableAgent: ConnectionStatus] = [:]
        var access: [AgentFolder: FolderAccess] = [:]
        var problems: [ConnectableAgent: AgentConnectorError.Kind] = [:]
        var claudeHooksTwice = false
    }

    static let dismissedKey = "HoplyAgentsNudgeDismissed"
    static let folderCardDismissedKey = "HoplyFolderAccessDismissed"

    private(set) var statuses: [ConnectableAgent: ConnectionStatus] = [:]
    private(set) var access: [AgentFolder: FolderAccess] = [:]
    private(set) var problems: [ConnectableAgent: AgentConnectorError.Kind] = [:]
    private(set) var claudeHooksTwice = false
    private(set) var running: ConnectableAgent?
    private(set) var isBusy = false
    private(set) var notices: [ConnectableAgent: Notice] = [:]
    private(set) var folderNotices: [AgentFolder: Notice] = [:]
    private(set) var dismissed: String?
    private(set) var folderCardDismissed: String?

    @ObservationIgnored var settings: () -> AppSettings = { AppSettings() }
    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var epoch = 0

    init(live: Bool = true) {
        isLive = live
        guard live else { return }
        dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey)
        folderCardDismissed = UserDefaults.standard.string(forKey: Self.folderCardDismissedKey)
    }

    var connector: AgentConnector {
        guard isLive else { return AgentConnector(settings: settings(), environment: [:], home: PreviewData.home) }
        return AgentConnector(settings: settings())
    }

    func status(of agent: ConnectableAgent) -> ConnectionStatus? { statuses[agent] }

    func access(of agent: ConnectableAgent) -> FolderAccess? { access[agent.folder] }

    var connectable: [ConnectableAgent] {
        ConnectableAgent.allCases.filter { agent in
            switch statuses[agent] {
            case .notConnected?, .outdated?: true
            case .unreadable?: problems[agent] != nil
            case nil: access[agent.folder]?.asksForGrant == true
            case .connected?, .notInstalled?: false
            }
        }
    }

    var needingAccess: [ConnectableAgent] {
        ConnectableAgent.allCases.filter { statuses[$0] != .notInstalled && access[$0.folder]?.asksForGrant == true }
    }

    var showsFolderCard: Bool {
        guard !access.isEmpty, folderSignature != folderCardDismissed else { return false }
        if !needingAccess.isEmpty { return true }
        return access.values.allSatisfy { $0 == .notFound }
    }

    private var folderSignature: String {
        AgentFolder.allCases.map { folder in
            let kind = switch access[folder] {
            case nil: "unknown"
            case .notNeeded: "not-needed"
            case .granted: "granted"
            case .missing: "missing"
            case .notFound: "not-found"
            case .elsewhere: "elsewhere"
            case .readOnly: "read-only"
            case .broken: "broken"
            }
            return "\(folder.rawValue)=\(kind)"
        }.joined(separator: ",")
    }

    func dismissFolderCard() {
        folderCardDismissed = folderSignature
        if isLive { UserDefaults.standard.set(folderCardDismissed, forKey: Self.folderCardDismissedKey) }
    }

    func note(_ notice: Notice?, for agent: ConnectableAgent) {
        notices[agent] = notice
    }

    func note(_ notice: Notice?, for folder: AgentFolder) {
        folderNotices[folder] = notice
    }

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

    func begin(_ agents: [ConnectableAgent]) -> Bool {
        guard isLive, !isBusy, running == nil else { return false }
        isBusy = true
        for agent in agents { notices[agent] = nil }
        return true
    }

    func end() {
        isBusy = false
    }

    func accessProblems(for agents: [ConnectableAgent]) async -> [ConnectableAgent: AgentConnectorError] {
        let connector = connector
        return await Task.detached {
            var problems: [ConnectableAgent: AgentConnectorError] = [:]
            for agent in agents { problems[agent] = connector.accessProblem(for: agent) }
            return problems
        }.value
    }

    func attempt(_ agent: ConnectableAgent, connecting: Bool) async -> Result<ConnectOutcome, AgentConnectorError> {
        running = agent
        defer { running = nil }
        let connector = connector
        return await Task.detached { () -> Result<ConnectOutcome, AgentConnectorError> in
            do throws(AgentConnectorError) {
                return .success(connecting ? try connector.connect(agent) : try connector.disconnect(agent))
            } catch {
                return .failure(error)
            }
        }.value
    }

    func finish(_ agent: ConnectableAgent, _ result: Result<ConnectOutcome, AgentConnectorError>, connecting: Bool) {
        notices[agent] = Self.notice(for: result, agent: agent, connecting: connecting)
    }

    // A read that started before a write (or before a folder or port change) must not overwrite a newer one.
    func reload() async {
        guard isLive else { return }
        epoch += 1
        let started = epoch
        let connector = connector
        let settings = settings()
        let found = await Task.detached { Self.read(connector, settings: settings) }.value
        guard started == epoch else { return }
        if found.statuses != statuses { statuses = found.statuses }
        if found.access != access { access = found.access }
        if found.problems != problems { problems = found.problems }
        if found.claudeHooksTwice != claudeHooksTwice { claudeHooksTwice = found.claudeHooksTwice }
    }

    // Sandboxed, reading an ungranted folder is a denial: status comes only from folders Hoply may read, and a
    // missing status means installed but not readable.
    private nonisolated static func read(_ connector: AgentConnector, settings: AppSettings) -> Reading {
        var reading = Reading(access: FolderGrants.shared.access(settings: settings))
        for agent in ConnectableAgent.allCases {
            let access = reading.access[agent.folder] ?? .notNeeded
            guard access.allowsReading || !connector.isInstalled(agent) else { continue }
            reading.statuses[agent] = connector.status(of: agent)
        }
        guard connector.edition.needsFolderGrants else { return reading }
        for agent in ConnectableAgent.allCases where reading.statuses[agent] != .notInstalled {
            reading.problems[agent] = connector.accessProblem(for: agent)?.kind
        }
        if reading.access[.claude]?.allowsReading == true,
           let data = try? Data(contentsOf: URL(fileURLWithPath: connector.claudeSettingsPath)),
           let file = try? SettingsJSON.parse(data) {
            reading.claudeHooksTwice = ClaudeCodePlugin.isInstalledTwice(inSettings: file)
        }
        return reading
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

    func show(access: [AgentFolder: FolderAccess], notices: [AgentFolder: Notice] = [:],
              problems: [ConnectableAgent: AgentConnectorError.Kind] = [:], claudeHooksTwice: Bool = false) {
        self.access = access
        folderNotices = notices
        self.problems = problems
        self.claudeHooksTwice = claudeHooksTwice
    }
}
