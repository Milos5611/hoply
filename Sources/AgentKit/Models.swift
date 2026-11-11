import Foundation

public enum AgentSource: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case copilotCLI = "copilot-cli"
    case copilotIDE = "copilot-ide"
    case qwenCode = "qwen-code"
    case codexCLI = "codex-cli"
}

public enum SessionState: String, Codable, Sendable {
    case working
    case needsPermission
    case yourTurn
    case idle
    case ended

    public var priority: Int {
        switch self {
        case .needsPermission: return 0
        case .yourTurn: return 1
        case .working: return 2
        case .idle: return 3
        case .ended: return 4
        }
    }

    public var needsAttention: Bool {
        self == .needsPermission || self == .yourTurn
    }
}

public struct SessionKey: Hashable, Sendable {
    public let source: AgentSource
    public let id: String

    public init(source: AgentSource, id: String) {
        self.source = source
        self.id = id
    }
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    public var key: SessionKey
    public var state: SessionState
    public var title: String?
    public var cwd: String?
    public var model: String?
    public var lastTool: String?
    public var lastMessage: String?
    public var startedAt: Date
    public var lastEventAt: Date
    public var stateSince: Date
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheTokens: Int
    public var costUSD: Double
    public var hasLiveState: Bool
    public var awaitsInput: Bool
    public var failure: String?
    public var turnEnded: Bool
    public var subagents: [LiveSubagent]
    public var reportedPID: Int32?
    public var pidReportedAt: Date?

    public static let maxSubagents = 50

    public var workingSubagentCount: Int { subagents.count { $0.isWorking } }

    public var id: String { "\(key.source.rawValue):\(key.id)" }

    public var project: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    public var totalTokens: Int { inputTokens + outputTokens + cacheTokens }

    init(key: SessionKey, at time: Date) {
        self.key = key
        self.state = .idle
        self.title = nil
        self.cwd = nil
        self.model = nil
        self.lastTool = nil
        self.lastMessage = nil
        self.startedAt = time
        self.lastEventAt = time
        self.stateSince = time
        self.inputTokens = 0
        self.outputTokens = 0
        self.cacheTokens = 0
        self.costUSD = 0
        self.hasLiveState = false
        self.awaitsInput = false
        self.failure = nil
        self.turnEnded = false
        self.subagents = []
        self.reportedPID = nil
        self.pidReportedAt = nil
    }
}

public struct LiveSubagent: Identifiable, Equatable, Sendable {
    public var id: String
    public var type: String?
    public var startedAt: Date
    public var lastEventAt: Date
    public var endedAt: Date?

    public var isWorking: Bool { endedAt == nil }

    public init(id: String, type: String? = nil, startedAt: Date, lastEventAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id
        self.type = type
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt ?? startedAt
        self.endedAt = endedAt
    }
}

public struct AgentEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case sessionStarted
        case promptSubmitted(String?)
        case toolStarted(String?)
        case toolFinished(String?)
        case needsPermission(String?)
        case waitingForInput(String?)
        case questionAsked(String?)
        case turnFinished(String?)
        case turnFailed(error: String?, message: String?)
        case subagentStarted(id: String, type: String?)
        case subagentStopped(id: String, type: String?)
        case sessionEnded(String?)
        case error(String?)
        case usage(Usage)
        case activity
    }

    public struct Usage: Sendable, Equatable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheTokens: Int
        public var costUSD: Double

        public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheTokens: Int = 0, costUSD: Double = 0) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheTokens = cacheTokens
            self.costUSD = costUSD
        }
    }

    public var key: SessionKey
    public var kind: Kind
    public var time: Date
    public var cwd: String?
    public var model: String?
    public var fromHook: Bool
    public var transcriptPath: String?
    public var agentID: String?
    public var agentType: String?
    public var agentPID: Int32?

    public init(key: SessionKey, kind: Kind, time: Date, cwd: String? = nil, model: String? = nil, fromHook: Bool,
                transcriptPath: String? = nil, agentID: String? = nil, agentType: String? = nil,
                agentPID: Int32? = nil) {
        self.key = key
        self.kind = kind
        self.time = time
        self.cwd = cwd
        self.model = model
        self.fromHook = fromHook
        self.transcriptPath = transcriptPath
        self.agentID = agentID
        self.agentType = agentType
        self.agentPID = agentPID
    }
}
