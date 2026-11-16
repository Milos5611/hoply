import Foundation

public struct RemoteSnapshot: Codable, Sendable, Equatable {
    public struct Session: Codable, Sendable, Equatable, Identifiable {
        public var key: String
        public var agent: String
        public var project: String?
        public var title: String?
        public var state: RemoteSessionState
        public var since: Date
        public var limitedUntil: Date?
        public var cost: RemoteCost?
        public var waiting: RemoteRequest.Kind?

        public init(key: String, agent: String, project: String? = nil, title: String? = nil,
                    state: RemoteSessionState, since: Date, limitedUntil: Date? = nil, cost: RemoteCost? = nil,
                    waiting: RemoteRequest.Kind? = nil) {
            self.key = key
            self.agent = agent
            self.project = project
            self.title = title
            self.state = state
            self.since = since
            self.limitedUntil = limitedUntil
            self.cost = cost
            self.waiting = waiting
        }

        public var id: String { key }
        public var source: AgentSource? { AgentSource(rawValue: agent) }
    }

    public struct AgentSpend: Codable, Sendable, Equatable {
        public var agent: String
        public var today: RemoteCost

        public init(agent: String, today: RemoteCost) {
            self.agent = agent
            self.today = today
        }

        public var source: AgentSource? { AgentSource(rawValue: agent) }
    }

    public struct Spend: Codable, Sendable, Equatable {
        public var today: RemoteCost?
        public var week: RemoteCost?
        public var byAgent: [AgentSpend]

        public init(today: RemoteCost? = nil, week: RemoteCost? = nil, byAgent: [AgentSpend] = []) {
            self.today = today
            self.week = week
            self.byAgent = byAgent
        }
    }

    public var device: String
    public var deviceName: String?
    public var away: Bool
    public var updatedAt: Date
    public var sessions: [Session]
    public var spend: Spend
    public var launch: RemoteLaunch?

    public init(device: String, deviceName: String? = nil, away: Bool, updatedAt: Date, sessions: [Session] = [],
                spend: Spend = Spend(), launch: RemoteLaunch? = nil) {
        self.device = device
        self.deviceName = deviceName
        self.away = away
        self.updatedAt = updatedAt
        self.sessions = sessions
        self.spend = spend
        self.launch = launch
    }

    public static let maxSessions = 50

    public static func build(device: String, deviceName: String? = nil, away: Bool, sessions: [AgentSession],
                             projects: [String: ProjectRef] = [:], sessionTotals: [SessionKey: LedgerTotals] = [:],
                             limitedUntil: [SessionKey: Date] = [:], approvals: [ApprovalRequest] = [],
                             replies: [TurnReplyRequest] = [], today: [AgentSource: LedgerTotals]?,
                             week: LedgerTotals? = nil, launch: RemoteLaunch? = nil, now: Date) -> RemoteSnapshot {
        let approving = Set(approvals.map(\.key))
        let replying = Set(replies.map(\.key))
        let rows = sessions.map { session -> Session in
            let waiting: RemoteRequest.Kind? = approving.contains(session.key) ? .approval
                : replying.contains(session.key) ? .reply : nil
            let until = limitedUntil[session.key]
            return Session(key: RemoteSchema.sessionKey(session.key), agent: session.key.source.rawValue,
                           project: projectName(session, projects: projects), title: RemoteSchema.title(session.title),
                           state: RemoteSessionState(SessionStatus(session, limitedUntil: until)),
                           since: session.stateSince, limitedUntil: until,
                           cost: cost(session, ledger: sessionTotals[session.key]), waiting: waiting)
        }
        let ordered = rows.enumerated()
            .sorted { ($0.element.waiting == nil ? 1 : 0, $0.offset) < ($1.element.waiting == nil ? 1 : 0, $1.offset) }
            .prefix(maxSessions)
            .map(\.element)
        let byAgent = AgentSource.allCases.compactMap { source in
            today?[source].map { AgentSpend(agent: source.rawValue, today: RemoteCost($0)) }
        }
        let spend = Spend(today: today.map { RemoteCost($0.values.reduce(.zero, +)) }, week: week.map(RemoteCost.init),
                          byAgent: byAgent)
        return RemoteSnapshot(device: device, deviceName: deviceName, away: away, updatedAt: now, sessions: ordered,
                              spend: spend, launch: launch)
    }

    public static func projectName(_ session: AgentSession?, projects: [String: ProjectRef]) -> String? {
        session?.cwd.flatMap { projects[$0]?.title } ?? session?.project
    }

    static func cost(_ session: AgentSession, ledger: LedgerTotals?) -> RemoteCost? {
        if let ledger { return RemoteCost(ledger) }
        guard session.totalTokens > 0 || session.costUSD > 0 else { return nil }
        return RemoteCost(usd: session.costUSD > 0 ? session.costUSD : nil, tokens: session.totalTokens)
    }

    public func sameContent(as other: RemoteSnapshot) -> Bool {
        var mine = self
        mine.updatedAt = other.updatedAt
        return mine == other
    }

    var attention: [String] {
        sessions.map { "\($0.key)|\($0.state.rawValue)|\($0.waiting?.rawValue ?? "")" }
    }
}

public struct RemoteCost: Codable, Sendable, Equatable {
    public var usd: Double?
    public var hasUnpriced: Bool
    public var tokens: Int

    public init(usd: Double?, hasUnpriced: Bool = false, tokens: Int = 0) {
        self.usd = usd
        self.hasUnpriced = hasUnpriced
        self.tokens = tokens
    }

    // Same reading as `Format.spend`: unpriced usage is nil ("unpriced") or a lower bound ("$x+"), never $0.
    public init(_ totals: LedgerTotals) {
        usd = totals.hasUnpriced && totals.apiEquivUSD <= 0 ? nil : totals.apiEquivUSD
        hasUnpriced = totals.hasUnpriced
        tokens = totals.tokens.total
    }
}

public enum RemoteSessionState: String, Codable, Sendable {
    case permission
    case input
    case limited
    case yourTurn
    case working
    case idle
    case ended
    case unknown

    public init(_ status: SessionStatus) {
        switch status {
        case .permission: self = .permission
        case .input: self = .input
        case .limited: self = .limited
        case .yourTurn: self = .yourTurn
        case .working: self = .working
        case .idle: self = .idle
        case .ended: self = .ended
        }
    }

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum RemoteLinkPolicy {
    public static let publishInterval: TimeInterval = 30
    public static let heartbeat: TimeInterval = 600
    public static let pollWhileOpen: TimeInterval = 5
    public static let pollIdle: TimeInterval = 60

    public static func shouldPublish(_ snapshot: RemoteSnapshot, last: RemoteSnapshot?, at lastAt: Date?,
                                     now: Date) -> Bool {
        guard let last, let lastAt else { return true }
        let elapsed = now.timeIntervalSince(lastAt)
        if snapshot.sameContent(as: last) { return elapsed >= heartbeat }
        if snapshot.away != last.away || snapshot.attention != last.attention { return true }
        if (snapshot.launch == nil) != (last.launch == nil) || snapshot.launch?.last != last.launch?.last { return true }
        return elapsed >= publishInterval
    }

    public static func pollInterval(openRequests: Int) -> TimeInterval {
        openRequests > 0 ? pollWhileOpen : pollIdle
    }
}
