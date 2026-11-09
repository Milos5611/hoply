import Foundation

/// Where an agent's usage history comes from. Each agent has exactly one, so no call is ever counted twice.
public enum UsageLedger: String, Sendable, CaseIterable {
    /// Claude Code's transcripts under `<config>/projects`.
    case transcripts
    /// Copilot CLI's `session-store.db`.
    case copilotStore
    /// OTLP that reaches Hoply, persisted as it arrives.
    case telemetry
}

public enum UsageAuthority {
    public static func ledger(for source: AgentSource) -> UsageLedger {
        switch source {
        case .claudeCode: return .transcripts
        case .copilotCLI: return .copilotStore
        case .copilotIDE, .qwenCode: return .telemetry
        }
    }

    /// True when this source's OTel usage must be persisted; for the others it is live display only.
    public static func persistsTelemetry(from source: AgentSource) -> Bool {
        ledger(for: source) == .telemetry
    }
}
