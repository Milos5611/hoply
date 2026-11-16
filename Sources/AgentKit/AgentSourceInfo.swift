import Foundation

public struct AgentSourceInfo: Sendable {
    public struct Tint: Sendable, Equatable {
        public let red: Double
        public let green: Double
        public let blue: Double
    }

    public static let sessionIDPlaceholder = "{session}"
    public static let promptPlaceholder = "{prompt}"

    public let displayName: String
    public let symbol: String
    public let tint: Tint
    public let ledger: UsageLedger
    public let resumeArguments: [String]?
    public let startArguments: [String]?
    public let continueArguments: [String]?
    public let processNames: Set<String>
    public let processPathFragments: [String]

    public func resumeArguments(sessionID: String) -> [String]? {
        resumeArguments?.map { $0.replacingOccurrences(of: Self.sessionIDPlaceholder, with: sessionID) }
    }

    public func startArguments(prompt: String) -> [String]? {
        startArguments?.map { $0.replacingOccurrences(of: Self.promptPlaceholder, with: prompt) }
    }

    // The id goes in first: a prompt may contain "{session}", a validated id never contains "{prompt}".
    public func continueArguments(sessionID: String, prompt: String) -> [String]? {
        continueArguments?.map {
            $0.replacingOccurrences(of: Self.sessionIDPlaceholder, with: sessionID)
                .replacingOccurrences(of: Self.promptPlaceholder, with: prompt)
        }
    }
}

extension AgentSource {
    public var info: AgentSourceInfo {
        let id = AgentSourceInfo.sessionIDPlaceholder
        let prompt = AgentSourceInfo.promptPlaceholder
        // A prompt follows `--` or sits inside `--interactive=`, so one starting with "-" is never read as a flag.
        switch self {
        case .claudeCode:
            return AgentSourceInfo(displayName: "Claude Code", symbol: "asterisk",
                                   tint: .init(red: 0.85, green: 0.47, blue: 0.34), ledger: .transcripts,
                                   resumeArguments: ["claude", "--resume", id],
                                   startArguments: ["claude", "--", prompt],
                                   continueArguments: ["claude", "--resume", id, "--", prompt],
                                   processNames: ["claude"], processPathFragments: ["/claude-code/", "/claude/versions/"])
        case .copilotCLI:
            // `--resume[=value]` takes an optional value; a separate argument is not read as the id.
            return AgentSourceInfo(displayName: "Copilot CLI", symbol: "terminal",
                                   tint: .init(red: 0.43, green: 0.33, blue: 0.84), ledger: .copilotStore,
                                   resumeArguments: ["copilot", "--resume=\(id)"],
                                   startArguments: ["copilot", "--interactive=\(prompt)"],
                                   continueArguments: ["copilot", "--resume=\(id)", "--interactive=\(prompt)"],
                                   processNames: ["copilot"], processPathFragments: ["/@github/copilot/"])
        case .copilotIDE:
            return AgentSourceInfo(displayName: "Copilot IDE", symbol: "curlybraces",
                                   tint: .init(red: 0.30, green: 0.42, blue: 0.86), ledger: .telemetry,
                                   resumeArguments: nil, startArguments: nil, continueArguments: nil,
                                   processNames: [], processPathFragments: [])
        case .qwenCode:
            return AgentSourceInfo(displayName: "Qwen Code", symbol: "cpu",
                                   tint: .init(red: 0.20, green: 0.60, blue: 0.55), ledger: .telemetry,
                                   resumeArguments: ["qwen", "--resume", id],
                                   startArguments: nil, continueArguments: nil,
                                   processNames: ["qwen"], processPathFragments: ["/@qwen-code/"])
        case .codexCLI:
            return AgentSourceInfo(displayName: "Codex CLI", symbol: "hexagon",
                                   tint: .init(red: 0.38, green: 0.44, blue: 0.54), ledger: .codexRollouts,
                                   resumeArguments: ["codex", "resume", id],
                                   startArguments: ["codex", "--", prompt],
                                   continueArguments: ["codex", "resume", id, "--", prompt],
                                   processNames: ["codex"], processPathFragments: ["/@openai/codex/"])
        }
    }

    public var displayName: String { info.displayName }
}
