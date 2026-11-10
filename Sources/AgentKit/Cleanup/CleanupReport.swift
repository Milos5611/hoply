import Foundation

public struct CleanupLogEntry: Sendable, Equatable {
    public var timestamp: Date
    public var kind: CleanupKind
    public var path: String
    public var bytes: Int64?
    public var project: ProjectRef?
    public var detail: String?

    public init(timestamp: Date, kind: CleanupKind, path: String, bytes: Int64? = nil, project: ProjectRef? = nil,
                detail: String? = nil) {
        self.timestamp = timestamp
        self.kind = kind
        self.path = path
        self.bytes = bytes
        self.project = project
        self.detail = detail
    }
}

public struct CleanupReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case trashed
        case terminated
        case killed
        case skipped([CleanupKeepReason])
        case failed(String)

        public var isRemoved: Bool { self == .trashed || self == .terminated || self == .killed }
    }

    public struct Item: Identifiable, Sendable, Equatable {
        public var candidate: CleanupCandidate
        public var outcome: Outcome

        public init(candidate: CleanupCandidate, outcome: Outcome) {
            self.candidate = candidate
            self.outcome = outcome
        }

        public var id: String { candidate.id }
    }

    public var items: [Item]
    public var finishedAt: Date

    public init(items: [Item] = [], finishedAt: Date = Date()) {
        self.items = items
        self.finishedAt = finishedAt
    }

    public var removed: [Item] { items.filter(\.outcome.isRemoved) }

    public var skipped: [Item] {
        items.filter {
            if case .skipped = $0.outcome { return true }
            return false
        }
    }

    public var failed: [Item] {
        items.filter {
            if case .failed = $0.outcome { return true }
            return false
        }
    }

    public var bytesFreed: Int64 {
        CleanupCandidate.distinctBytes(of: items.filter { $0.outcome == .trashed }.map(\.candidate))
    }

    // An item inside another trashed item left with it; a log row of its own would count its bytes twice.
    public var logEntries: [CleanupLogEntry] {
        let trashed = removed.compactMap(\.candidate.path)
        return removed.filter { !$0.candidate.isInside(anyOf: trashed) }.map { item in
            let candidate = item.candidate
            return CleanupLogEntry(timestamp: finishedAt, kind: candidate.kind,
                                   path: candidate.path ?? candidate.orphan?.cwd ?? "",
                                   bytes: candidate.path == nil ? nil : candidate.bytes, project: candidate.project,
                                   detail: Self.detail(candidate, outcome: item.outcome))
        }
    }

    private static func detail(_ candidate: CleanupCandidate, outcome: Outcome) -> String {
        guard let orphan = candidate.orphan else { return candidate.branch ?? candidate.title }
        return "\(orphan.name) · pid \(orphan.identity.pid) · \(outcome == .killed ? "killed" : "terminated")"
    }
}
