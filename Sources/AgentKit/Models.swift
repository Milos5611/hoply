import Foundation

/// Where an agent session comes from.
public enum AgentSource: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case copilotCLI = "copilot-cli"
    case copilotIDE = "copilot-ide"
    case qwenCode = "qwen-code"

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .copilotCLI: return "Copilot CLI"
        case .copilotIDE: return "Copilot IDE"
        case .qwenCode: return "Qwen Code"
        }
    }
}

public enum SessionState: String, Codable, Sendable {
    case working
    case needsPermission
    case yourTurn
    case idle
    case ended

    /// Lower values sort first in the panel.
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
    /// True once a hook has reported on this session. Hooks own the state from then on;
    /// telemetry (which arrives in delayed batches) only adds usage numbers.
    public var hasLiveState: Bool

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
    }
}

/// A normalized thing that happened in some agent, from a hook or from telemetry.
public struct AgentEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case sessionStarted
        case promptSubmitted(String?)
        case toolStarted(String?)
        case toolFinished(String?)
        case needsPermission(String?)
        case waitingForInput(String?)
        case turnFinished(String?)
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
    /// The agent's transcript file (Claude Code hooks send `transcript_path`), so the ledger can tail it at once.
    public var transcriptPath: String?

    public init(key: SessionKey, kind: Kind, time: Date, cwd: String? = nil, model: String? = nil, fromHook: Bool,
                transcriptPath: String? = nil) {
        self.key = key
        self.kind = kind
        self.time = time
        self.cwd = cwd
        self.model = model
        self.fromHook = fromHook
        self.transcriptPath = transcriptPath
    }
}
