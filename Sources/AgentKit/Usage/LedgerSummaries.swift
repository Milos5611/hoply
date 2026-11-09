import Foundation

/// Sums over usage ledger rows. `costUSD` is what was actually spent (local models count as $0);
/// `apiEquivUSD` is what the same tokens would cost on the API (for Claude the two are equal).
public struct LedgerTotals: Sendable, Equatable, Hashable {
    public var costUSD: Double
    public var apiEquivUSD: Double
    public var tokens: TokenCounts
    public var calls: Int
    /// At least one non-local call has an unknown price, so `costUSD` is a lower bound.
    public var hasUnpriced: Bool

    public init(costUSD: Double = 0, apiEquivUSD: Double = 0, tokens: TokenCounts = TokenCounts(),
                calls: Int = 0, hasUnpriced: Bool = false) {
        self.costUSD = costUSD
        self.apiEquivUSD = apiEquivUSD
        self.tokens = tokens
        self.calls = calls
        self.hasUnpriced = hasUnpriced
    }

    public static let zero = LedgerTotals()

    public static func + (lhs: LedgerTotals, rhs: LedgerTotals) -> LedgerTotals {
        LedgerTotals(costUSD: lhs.costUSD + rhs.costUSD, apiEquivUSD: lhs.apiEquivUSD + rhs.apiEquivUSD,
                     tokens: lhs.tokens + rhs.tokens, calls: lhs.calls + rhs.calls,
                     hasUnpriced: lhs.hasUnpriced || rhs.hasUnpriced)
    }
}

public struct ProjectRef: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int64
    public var root: String
    public var name: String
    public var displayName: String?
    public var kind: ProjectKind

    public init(id: Int64, root: String, name: String, displayName: String? = nil, kind: ProjectKind) {
        self.id = id
        self.root = root
        self.name = name
        self.displayName = displayName
        self.kind = kind
    }

    public var title: String { displayName ?? name }
}

public struct ModelShare: Sendable, Equatable, Hashable {
    public var model: String
    public var totals: LedgerTotals

    public init(model: String, totals: LedgerTotals) {
        self.model = model
        self.totals = totals
    }
}

public struct SessionSummary: Sendable, Equatable, Identifiable {
    public var key: SessionKey
    public var project: ProjectRef?
    public var title: String?
    public var cwd: String?
    public var branch: String?
    public var worktree: String?
    public var firstAt: Date?
    public var lastAt: Date?
    public var turns: Int
    public var totals: LedgerTotals
    /// Largest share first.
    public var models: [ModelShare]
    /// The agent's own cost figure (Claude Code `cost-state`), for comparison only.
    public var nativeCostUSD: Double?
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var prURL: String?
    public var transcriptPath: String?

    public init(key: SessionKey, project: ProjectRef? = nil, title: String? = nil, cwd: String? = nil,
                branch: String? = nil, worktree: String? = nil, firstAt: Date? = nil, lastAt: Date? = nil,
                turns: Int = 0, totals: LedgerTotals = .zero, models: [ModelShare] = [], nativeCostUSD: Double? = nil,
                linesAdded: Int? = nil, linesRemoved: Int? = nil, prURL: String? = nil, transcriptPath: String? = nil) {
        self.key = key
        self.project = project
        self.title = title
        self.cwd = cwd
        self.branch = branch
        self.worktree = worktree
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.turns = turns
        self.totals = totals
        self.models = models
        self.nativeCostUSD = nativeCostUSD
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.prURL = prURL
        self.transcriptPath = transcriptPath
    }

    public var id: String { "\(key.source.rawValue):\(key.id)" }
}

public struct SessionPage: Sendable, Equatable {
    public var sessions: [SessionSummary]
    /// All sessions matching the query, across pages.
    public var totalCount: Int

    public init(sessions: [SessionSummary], totalCount: Int) {
        self.sessions = sessions
        self.totalCount = totalCount
    }
}

public enum SpendSeriesSplit: Sendable, Equatable {
    case model
    case source
}

public struct DailySpendPoint: Sendable, Equatable, Identifiable {
    /// Local midnight of the day.
    public var day: Date
    /// The model id, or the `AgentSource` raw value, depending on the split.
    public var series: String
    public var totals: LedgerTotals

    public init(day: Date, series: String, totals: LedgerTotals) {
        self.day = day
        self.series = series
        self.totals = totals
    }

    public var id: String { "\(day.timeIntervalSince1970):\(series)" }
}

public struct DailySpendSeries: Sendable, Equatable {
    /// Every day in the range, oldest first, including days with no usage.
    public var days: [Date]
    /// Only non-empty (day, series) pairs.
    public var points: [DailySpendPoint]

    public init(days: [Date], points: [DailySpendPoint]) {
        self.days = days
        self.points = points
    }
}

public struct SpendSlice: Sendable, Equatable, Identifiable {
    /// Project id, model id or source raw value; "" for usage with no project or model.
    public var id: String
    public var label: String
    public var project: ProjectRef?
    public var totals: LedgerTotals
    public var sessionCount: Int

    public init(id: String, label: String, project: ProjectRef? = nil, totals: LedgerTotals, sessionCount: Int) {
        self.id = id
        self.label = label
        self.project = project
        self.totals = totals
        self.sessionCount = sessionCount
    }
}

public struct SpendOverview: Sendable, Equatable {
    public var today: LedgerTotals
    public var last7Days: LedgerTotals
    public var last30Days: LedgerTotals
    public var allTime: LedgerTotals

    public init(today: LedgerTotals, last7Days: LedgerTotals, last30Days: LedgerTotals, allTime: LedgerTotals) {
        self.today = today
        self.last7Days = last7Days
        self.last30Days = last30Days
        self.allTime = allTime
    }
}

public struct IngestProgress: Sendable, Equatable {
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var isBackfilling: Bool
    public var lastError: String?

    public init(filesDone: Int = 0, filesTotal: Int = 0, bytesDone: Int64 = 0, bytesTotal: Int64 = 0,
                isBackfilling: Bool = false, lastError: String? = nil) {
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.isBackfilling = isBackfilling
        self.lastError = lastError
    }

    public var fraction: Double {
        bytesTotal > 0 ? min(Double(bytesDone) / Double(bytesTotal), 1) : (isBackfilling ? 0 : 1)
    }
}
