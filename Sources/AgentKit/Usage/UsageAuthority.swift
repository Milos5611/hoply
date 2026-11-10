import Foundation

public enum UsageLedger: String, Sendable, CaseIterable {
    case transcripts
    case copilotStore
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

    public static func persistsTelemetry(from source: AgentSource) -> Bool {
        ledger(for: source) == .telemetry
    }
}
