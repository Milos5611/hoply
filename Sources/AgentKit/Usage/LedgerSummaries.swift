import Foundation

public struct LedgerTotals: Sendable, Equatable, Hashable {
    public var costUSD: Double
    public var apiEquivUSD: Double
    public var tokens: TokenCounts
    public var calls: Int
    public var hasUnpriced: Bool
    public var aiu: Double
    public var premiumRequests: Double

    public init(costUSD: Double = 0, apiEquivUSD: Double = 0, tokens: TokenCounts = TokenCounts(),
                calls: Int = 0, hasUnpriced: Bool = false, aiu: Double = 0, premiumRequests: Double = 0) {
        self.costUSD = costUSD
        self.apiEquivUSD = apiEquivUSD
        self.tokens = tokens
        self.calls = calls
        self.hasUnpriced = hasUnpriced
        self.aiu = aiu
        self.premiumRequests = premiumRequests
    }

    public static let zero = LedgerTotals()

    public static func + (lhs: LedgerTotals, rhs: LedgerTotals) -> LedgerTotals {
        LedgerTotals(costUSD: lhs.costUSD + rhs.costUSD, apiEquivUSD: lhs.apiEquivUSD + rhs.apiEquivUSD,
                     tokens: lhs.tokens + rhs.tokens, calls: lhs.calls + rhs.calls,
                     hasUnpriced: lhs.hasUnpriced || rhs.hasUnpriced, aiu: lhs.aiu + rhs.aiu,
                     premiumRequests: lhs.premiumRequests + rhs.premiumRequests)
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

public enum ProjectFilter: Sendable, Equatable, Hashable {
    case project(Int64)
    case unassigned
}

public struct ProjectSummary: Sendable, Equatable, Identifiable {
    public var project: ProjectRef?
    public var totals: LedgerTotals
    public var sessionCount: Int
    public var bySource: [AgentSource: LedgerTotals]
    public var topModels: [ModelShare]
    public var firstActive: Date?
    public var lastActive: Date?
    public var branches: [String]
    public var worktrees: [String]

    public init(project: ProjectRef?, totals: LedgerTotals = .zero, sessionCount: Int = 0,
                bySource: [AgentSource: LedgerTotals] = [:], topModels: [ModelShare] = [], firstActive: Date? = nil,
                lastActive: Date? = nil, branches: [String] = [], worktrees: [String] = []) {
        self.project = project
        self.totals = totals
        self.sessionCount = sessionCount
        self.bySource = bySource
        self.topModels = topModels
        self.firstActive = firstActive
        self.lastActive = lastActive
        self.branches = branches
        self.worktrees = worktrees
    }

    public var id: String { project.map { String($0.id) } ?? "" }
    public var filter: ProjectFilter { project.map { .project($0.id) } ?? .unassigned }
    public var title: String { project?.title ?? "Unassigned" }
    public var kind: ProjectKind? { project?.kind }
    public var root: String? { project?.root }
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
    public var models: [ModelShare]
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
    public var day: Date
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
    public var days: [Date]
    public var points: [DailySpendPoint]

    public init(days: [Date], points: [DailySpendPoint]) {
        self.days = days
        self.points = points
    }
}

public struct SpendSlice: Sendable, Equatable, Identifiable {
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

public enum CopilotStoreStatus: Sendable, Equatable {
    case idle
    case notFound
    case ready(schemaVersion: Int?)
    case unsupported(String)
    case failed(String)
}

public struct IngestProgress: Sendable, Equatable {
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var isBackfilling: Bool
    public var lastError: String?
    public var copilot: CopilotStoreStatus

    public init(filesDone: Int = 0, filesTotal: Int = 0, bytesDone: Int64 = 0, bytesTotal: Int64 = 0,
                isBackfilling: Bool = false, lastError: String? = nil, copilot: CopilotStoreStatus = .idle) {
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.isBackfilling = isBackfilling
        self.lastError = lastError
        self.copilot = copilot
    }

    public var fraction: Double {
        bytesTotal > 0 ? min(Double(bytesDone) / Double(bytesTotal), 1) : (isBackfilling ? 0 : 1)
    }
}
