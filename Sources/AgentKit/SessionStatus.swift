import Foundation

public enum SessionStatus: Sendable, Equatable, Hashable {
    case permission
    case input
    case limited(until: Date)
    case yourTurn
    case working
    case idle
    case ended

    public init(_ session: AgentSession, limitedUntil: Date? = nil) {
        switch session.state {
        case .needsPermission: self = .permission
        case .yourTurn where session.awaitsInput: self = .input
        case .yourTurn: self = limitedUntil.map { .limited(until: $0) } ?? .yourTurn
        case .working: self = .working
        case .idle: self = .idle
        case .ended: self = .ended
        }
    }

    public init(_ session: AgentSession, limits: [LimitSample], localModelPatterns: [String] = [], now: Date = Date()) {
        self.init(session, limitedUntil: LimitedSessions.limitedUntil(session, limits: limits,
                                                                      localModelPatterns: localModelPatterns, now: now))
    }

    public var priority: Int {
        switch self {
        case .permission: return 0
        case .input: return 1
        case .limited: return 2
        case .yourTurn: return 3
        case .working: return 4
        case .idle: return 5
        case .ended: return 6
        }
    }

    public var needsAction: Bool {
        switch self {
        case .permission, .input, .yourTurn: return true
        case .limited, .working, .idle, .ended: return false
        }
    }

    public var recedes: Bool {
        switch self {
        case .limited, .idle, .ended: return true
        case .permission, .input, .yourTurn, .working: return false
        }
    }

    public var limitedUntil: Date? {
        if case .limited(let until) = self { return until }
        return nil
    }

    public var label: String {
        switch self {
        case .permission: return "Permission"
        case .input: return "Input"
        case .limited: return "Limited"
        case .yourTurn: return "Your turn"
        case .working: return "Working"
        case .idle: return "Idle"
        case .ended: return "Ended"
        }
    }
}

public enum LimitedSessions {
    public static let fullAt = 100.0

    public static func blockingWindow(for session: AgentSession, limits: [LimitSample],
                                      localModelPatterns: [String] = [], now: Date = Date()) -> LimitSample? {
        guard let provider = LimitProvider(source: session.key.source), session.state == .yourTurn,
              !session.awaitsInput else { return nil }
        let model = session.model?.lowercased()
        // An agent pointed at a local model does not draw on the plan.
        if let model, localModelPatterns.contains(where: { !$0.isEmpty && model.contains($0.lowercased()) }) {
            return nil
        }
        var latest: [LimitKind: LimitSample] = [:]
        for sample in limits where sample.kind.provider == provider
            && sample.ts >= (latest[sample.kind]?.ts ?? .distantPast) {
            latest[sample.kind] = sample
        }
        return latest.values
            .filter { sample in
                // `resetsAt > now`: a stale reading of a window that has since reset holds nothing up.
                guard sample.utilization >= fullAt, let resetsAt = sample.resetsAt, resetsAt > now else { return false }
                return applies(sample.kind, toModel: model)
            }
            .max { ($0.resetsAt ?? .distantPast, $1.kind) < ($1.resetsAt ?? .distantPast, $0.kind) }
    }

    public static func limitedUntil(_ session: AgentSession, limits: [LimitSample], localModelPatterns: [String] = [],
                                    now: Date = Date()) -> Date? {
        blockingWindow(for: session, limits: limits, localModelPatterns: localModelPatterns, now: now)?.resetsAt
    }

    static func applies(_ kind: LimitKind, toModel model: String?) -> Bool {
        guard kind.isModelScoped else { return true }
        // A Codex limit id is a code name (`codex_bengalfox`), not a model family.
        guard kind.provider == .claude, let model,
              let family = kind.scopeName.split(separator: " ").first?.lowercased() else { return false }
        return model.contains(family)
    }
}
