import Foundation

public struct AgentSourceInfo: Sendable {
    public struct Tint: Sendable, Equatable {
        public let red: Double
        public let green: Double
        public let blue: Double
    }

    public static let sessionIDPlaceholder = "{session}"

    public let displayName: String
    public let symbol: String
    public let tint: Tint
    public let ledger: UsageLedger
    public let resumeArguments: [String]?
    public let processNames: Set<String>
    public let processPathFragments: [String]

    public func resumeArguments(sessionID: String) -> [String]? {
        resumeArguments?.map { $0.replacingOccurrences(of: Self.sessionIDPlaceholder, with: sessionID) }
    }
}

extension AgentSource {
    public var info: AgentSourceInfo {
        let id = AgentSourceInfo.sessionIDPlaceholder
        switch self {
        case .claudeCode:
            return AgentSourceInfo(displayName: "Claude Code", symbol: "asterisk",
                                   tint: .init(red: 0.85, green: 0.47, blue: 0.34), ledger: .transcripts,
                                   resumeArguments: ["claude", "--resume", id],
                                   processNames: ["claude"], processPathFragments: ["/claude-code/", "/claude/versions/"])
        case .copilotCLI:
            // `--resume[=value]` takes an optional value; a separate argument is not read as the id.
            return AgentSourceInfo(displayName: "Copilot CLI", symbol: "terminal",
                                   tint: .init(red: 0.43, green: 0.33, blue: 0.84), ledger: .copilotStore,
                                   resumeArguments: ["copilot", "--resume=\(id)"],
                                   processNames: ["copilot"], processPathFragments: ["/@github/copilot/"])
        case .copilotIDE:
            return AgentSourceInfo(displayName: "Copilot IDE", symbol: "curlybraces",
                                   tint: .init(red: 0.30, green: 0.42, blue: 0.86), ledger: .telemetry,
                                   resumeArguments: nil, processNames: [], processPathFragments: [])
        case .qwenCode:
            return AgentSourceInfo(displayName: "Qwen Code", symbol: "cpu",
                                   tint: .init(red: 0.20, green: 0.60, blue: 0.55), ledger: .telemetry,
                                   resumeArguments: ["qwen", "--resume", id],
                                   processNames: ["qwen"], processPathFragments: ["/@qwen-code/"])
        case .codexCLI:
            return AgentSourceInfo(displayName: "Codex CLI", symbol: "hexagon",
                                   tint: .init(red: 0.38, green: 0.44, blue: 0.54), ledger: .codexRollouts,
                                   resumeArguments: ["codex", "resume", id],
                                   processNames: ["codex"], processPathFragments: ["/@openai/codex/"])
        }
    }

    public var displayName: String { info.displayName }
}
