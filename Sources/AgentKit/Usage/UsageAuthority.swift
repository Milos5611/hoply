import Foundation

public enum UsageLedger: String, Sendable, CaseIterable {
    case transcripts
    case copilotStore
    case telemetry
    case codexRollouts
}

public enum UsageAuthority {
    public static func ledger(for source: AgentSource) -> UsageLedger {
        source.info.ledger
    }

    public static func persistsTelemetry(from source: AgentSource) -> Bool {
        ledger(for: source) == .telemetry
    }
}
