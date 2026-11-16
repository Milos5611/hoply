import Foundation

public struct RemoteLaunch: Codable, Sendable, Equatable {
    public struct Project: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var agents: [String]

        public init(id: String, name: String, agents: [String]) {
            self.id = id
            self.name = name
            self.agents = agents
        }

        public var sources: [AgentSource] { agents.compactMap(AgentSource.init(rawValue:)) }
    }

    public struct Resumable: Codable, Sendable, Equatable, Identifiable {
        public var key: String
        public var agent: String
        public var projectID: String
        public var title: String?
        public var endedAt: Date

        public init(key: String, agent: String, projectID: String, title: String? = nil, endedAt: Date) {
            self.key = key
            self.agent = agent
            self.projectID = projectID
            self.title = title
            self.endedAt = endedAt
        }

        public var id: String { key }
        public var source: AgentSource? { AgentSource(rawValue: agent) }
    }

    public enum Outcome: String, Codable, Sendable {
        case started
        case refused
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public enum Reason: String, Codable, Sendable {
        case disabled
        case noDevice
        case expired
        case emptyPrompt
        case shellMode
        case promptTooLong
        case unsupportedAgent
        case unknownProject
        case unknownSession
        case launchFailed
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public struct Result: Codable, Sendable, Equatable {
        public var answerID: String
        public var outcome: Outcome
        public var reason: Reason?
        public var at: Date

        public init(answerID: String, outcome: Outcome, reason: Reason? = nil, at: Date) {
            self.answerID = answerID
            self.outcome = outcome
            self.reason = reason
            self.at = at
        }

        public static func refused(_ answerID: String, _ reason: Reason, at time: Date) -> Result {
            Result(answerID: answerID, outcome: .refused, reason: reason, at: time)
        }
    }

    public var projects: [Project]
    public var resumable: [Resumable]
    public var promptLimit: Int
    public var last: Result?

    public init(projects: [Project] = [], resumable: [Resumable] = [], promptLimit: Int = LaunchScript.maxPromptLength,
                last: Result? = nil) {
        self.projects = projects
        self.resumable = resumable
        self.promptLimit = promptLimit
        self.last = last
    }
}

public struct LaunchCatalog: Sendable, Equatable {
    public struct Project: Sendable, Equatable {
        public var id: String
        public var name: String
        public var root: String
        public var agents: [AgentSource]

        public init(id: String, name: String, root: String, agents: [AgentSource]) {
            self.id = id
            self.name = name
            self.root = root
            self.agents = agents
        }
    }

    public struct Session: Sendable, Equatable {
        public var key: SessionKey
        public var projectID: String
        public var title: String?
        public var cwd: String
        public var endedAt: Date

        public init(key: SessionKey, projectID: String, title: String? = nil, cwd: String, endedAt: Date) {
            self.key = key
            self.projectID = projectID
            self.title = title
            self.cwd = cwd
            self.endedAt = endedAt
        }
    }

    public var projects: [Project]
    public var sessions: [Session]
    public var available: Set<AgentSource>

    public init(projects: [Project] = [], sessions: [Session] = [], available: Set<AgentSource> = []) {
        self.projects = projects
        self.sessions = sessions
        self.available = available
    }

    public static let maxProjects = 20
    public static let maxSessions = 10

    public static func projectID(root: String) -> String { FNV1a.hex64(root.utf8) }

    public static func available(_ statuses: [ConnectableAgent: ConnectionStatus]) -> Set<AgentSource> {
        Set(statuses.compactMap { agent, status in
            status == .connected || status == .outdated ? agent.source : nil
        })
    }

    public static func build(projects: [ProjectRef], sessions: [RecentSession], board: [AgentSession] = [],
                             available: Set<AgentSource>) -> LaunchCatalog {
        let offered = AgentSource.allCases.filter {
            available.contains($0) && (LaunchScript.canStart($0) || LaunchScript.canContinue($0))
        }
        var seen: Set<String> = []
        let rows = projects
            .filter { $0.kind != .scratch && $0.root.hasPrefix("/") && seen.insert($0.root).inserted }
            .prefix(maxProjects)
            .map { Project(id: projectID(root: $0.root), name: $0.title, root: $0.root,
                           agents: offered.filter(LaunchScript.canStart)) }
        let known = Set(rows.map(\.id))
        let live = Set(board.filter { $0.state != .ended }.map(\.key))
        let resumable = sessions.enumerated()
            .sorted { ($1.element.lastAt, $0.offset) < ($0.element.lastAt, $1.offset) }
            .map(\.element)
            .compactMap { session -> Session? in
                let source = session.key.source
                guard !live.contains(session.key), offered.contains(source), LaunchScript.canContinue(source),
                      ResumeScript.isPlausibleSessionID(session.key.id), session.cwd.hasPrefix("/"),
                      let root = session.project?.root, known.contains(projectID(root: root)) else { return nil }
                return Session(key: session.key, projectID: projectID(root: root), title: session.title,
                               cwd: session.cwd, endedAt: session.lastAt)
            }
            .prefix(maxSessions)
        return LaunchCatalog(projects: Array(rows), sessions: Array(resumable), available: Set(offered))
    }

    public func project(id: String?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    public func session(key: String) -> Session? {
        sessions.first { RemoteSchema.sessionKey($0.key) == key }
    }

    public func remote(last: RemoteLaunch.Result? = nil) -> RemoteLaunch {
        RemoteLaunch(projects: projects.map { RemoteLaunch.Project(id: $0.id, name: $0.name,
                                                                   agents: $0.agents.map(\.rawValue)) },
                     resumable: sessions.map {
                         RemoteLaunch.Resumable(key: RemoteSchema.sessionKey($0.key), agent: $0.key.source.rawValue,
                                                projectID: $0.projectID, title: RemoteSchema.title($0.title),
                                                endedAt: $0.endedAt)
                     },
                     last: last)
    }
}

public struct RemoteLaunchOrder: Sendable, Equatable {
    public var answerID: String
    public var source: AgentSource
    public var sessionID: String?
    public var projectID: String
    public var directory: String
    public var script: String
    public var fileName: String

    public init?(answerID: String, source: AgentSource, sessionID: String?, projectID: String, directory: String,
                 prompt: String) {
        guard let script = LaunchScript.script(source: source, sessionID: sessionID, prompt: prompt, cwd: directory)
        else { return nil }
        self.answerID = answerID
        self.source = source
        self.sessionID = sessionID
        self.projectID = projectID
        self.directory = directory
        self.script = script
        fileName = LaunchScript.fileName(source: source, answerID: answerID)
    }

    public func started(at time: Date) -> RemoteLaunch.Result {
        RemoteLaunch.Result(answerID: answerID, outcome: .started, at: time)
    }

    public func failed(at time: Date) -> RemoteLaunch.Result {
        .refused(answerID, .launchFailed, at: time)
    }
}

public enum RemoteLaunchDecision: Sendable, Equatable {
    case start(RemoteLaunchOrder)
    case refuse(RemoteLaunch.Result)
}
