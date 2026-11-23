import Foundation

public enum RemoteHistoryPolicy {
    public static let byteLimit = 700_000
    public static let checkEvery: TimeInterval = 300
    public static let fetchEvery: TimeInterval = 300
    public static let backfillPause: TimeInterval = 2
    public static let daysPerPass = 10
    public static let titleSpanDays = 31
}

public struct RemoteHistoryPublished: Codable, Sendable, Equatable {
    public var fingerprint: String?
    public var parts: Int
    public var at: Date

    public init(fingerprint: String?, parts: Int, at: Date) {
        self.fingerprint = fingerprint
        self.parts = parts
        self.at = at
    }
}

public enum RemoteHistoryChanges: Sendable, Equatable {
    case all
    case days(Set<Int>)

    public static let none = RemoteHistoryChanges.days([])

    public mutating func formUnion(_ other: RemoteHistoryChanges) {
        switch (self, other) {
        case (.all, _), (_, .all): self = .all
        case (.days(let mine), .days(let theirs)): self = .days(mine.union(theirs))
        }
    }
}

public struct RemoteHistoryOutbox: Sendable, Equatable {
    public private(set) var pending: Set<Int> = []
    public private(set) var needsScan = true

    public init() {}

    public var isEmpty: Bool { pending.isEmpty && !needsScan }

    public mutating func note(_ changes: RemoteHistoryChanges) {
        switch changes {
        case .all: needsScan = true
        case .days(let days): pending.formUnion(days)
        }
    }

    public mutating func scanned(ledgerDays: Set<Int>) {
        pending.formUnion(ledgerDays)
        needsScan = false
    }

    public func next(limit: Int) -> [Int] {
        Array(pending.sorted(by: >).prefix(max(limit, 0)))
    }

    public mutating func done(_ day: Int) {
        pending.remove(day)
    }

    public static func needsPublish(_ fingerprint: String, published: RemoteHistoryPublished?) -> Bool {
        published?.fingerprint != fingerprint
    }

    // A receiver keeps the newer build of a part, so a clock set back must not make a rebuild look older.
    public static func buildTime(now: Date, previous: RemoteHistoryPublished?) -> Date {
        guard let previous, now <= previous.at else { return now }
        return previous.at.addingTimeInterval(0.001)
    }

    public static func extraParts(device: String, day: String, previous: RemoteHistoryPublished?,
                                  parts: Int) -> [String] {
        guard let previous, previous.parts > parts else { return [] }
        return (parts..<previous.parts).map { RemoteSchema.historyRecordName(device: device, day: day, part: $0) }
    }

    public static func stale(_ published: [String: RemoteHistoryPublished], ledgerDays: Set<Int>?,
                             enabled: Bool) -> [String] {
        guard enabled else { return published.keys.sorted() }
        guard let ledgerDays else { return [] }
        let present = Set(ledgerDays.map(RemoteHistoryCalendar.name(of:)))
        return published.keys.filter { !present.contains($0) }.sorted()
    }

    public static func recordNames(device: String, day: String, published: RemoteHistoryPublished) -> [String] {
        (0..<max(published.parts, 1)).map { RemoteSchema.historyRecordName(device: device, day: day, part: $0) }
    }
}

public struct RemoteHistoryStoredPart: Sendable, Equatable {
    public var builtAt: Date
    public var parts: Int

    public init(builtAt: Date, parts: Int) {
        self.builtAt = builtAt
        self.parts = parts
    }
}

public enum RemoteHistoryMerge {
    public struct Plan: Sendable, Equatable {
        public var replace: [RemoteHistoryDay] = []
        public var remove: [RemoteHistoryPartKey] = []

        public init(replace: [RemoteHistoryDay] = [], remove: [RemoteHistoryPartKey] = []) {
            self.replace = replace
            self.remove = remove
        }

        public var isEmpty: Bool { replace.isEmpty && remove.isEmpty }
    }

    // `machine` is this Mac's hardware fingerprint: a day carrying it comes from this Mac's other edition.
    public static func plan(_ incoming: [RemoteHistoryDay], deleted: [RemoteHistoryPartKey],
                            stored: [RemoteHistoryPartKey: RemoteHistoryStoredPart], device: String,
                            machine: String? = nil) -> Plan {
        var newest: [RemoteHistoryPartKey: RemoteHistoryDay] = [:]
        for day in incoming where day.device != device && !day.device.isEmpty && day.part >= 0 && day.part < day.parts
            && !(machine != nil && day.machine == machine) {
            if let held = newest[day.key], held.updatedAt > day.updatedAt { continue }
            newest[day.key] = day
        }
        var plan = Plan()
        var removed = Set<RemoteHistoryPartKey>()
        for key in newest.keys.sorted() {
            guard let day = newest[key] else { continue }
            if let current = stored[key], current.builtAt > day.updatedAt { continue }
            plan.replace.append(day)
            for (other, part) in stored where other.device == key.device && other.day == key.day
                && other.part >= day.parts && part.builtAt <= day.updatedAt && newest[other] == nil {
                removed.insert(other)
            }
        }
        for key in deleted where key.device != device && newest[key] == nil && stored[key] != nil {
            removed.insert(key)
        }
        plan.remove = removed.sorted()
        return plan
    }

    public static func absent(stored: Set<RemoteHistoryPartKey>, fetched: Set<RemoteHistoryPartKey>) -> [RemoteHistoryPartKey] {
        stored.subtracting(fetched).sorted()
    }
}

public struct RemoteProjectCandidate: Sendable, Equatable {
    public var id: Int64
    public var name: String
    public var origin: String?
    public var kind: ProjectKind
    public var lastActive: Double
    public var merged: Bool
    public var device: String?

    public init(id: Int64, name: String, origin: String? = nil, kind: ProjectKind, lastActive: Double = 0,
                merged: Bool = false, device: String? = nil) {
        self.id = id
        self.name = name
        self.origin = origin
        self.kind = kind
        self.lastActive = lastActive
        self.merged = merged
        self.device = device
    }
}

public enum RemoteProjectMatch {
    // `remoteOnly` keeps the caller's order (edited groups first), so a Mac arriving or leaving never splits a merge.
    // `taken` blocks name and other-Mac matches for the row's own Mac, never an origin match on this Mac.
    public static func match(_ project: RemoteHistoryDay.Project, among locals: [RemoteProjectCandidate],
                             remoteOnly: [RemoteProjectCandidate] = [], taken: Set<Int64> = []) -> Int64? {
        func best(_ found: [RemoteProjectCandidate]) -> Int64? {
            found.min { ($0.merged ? 1 : 0, -$0.lastActive, $0.id) < ($1.merged ? 1 : 0, -$1.lastActive, $1.id) }?.id
        }
        func first(_ found: [RemoteProjectCandidate]) -> Int64? { found.first?.id }
        let remoteOnly = remoteOnly.filter { !taken.contains($0.id) }
        if let origin = project.origin {
            if let hit = best(locals.filter { $0.origin == origin }) { return hit }
            if let hit = first(remoteOnly.filter { $0.origin == origin }) { return hit }
        }
        let locals = locals.filter { !taken.contains($0.id) }
        guard project.kind != .scratch, !project.name.isEmpty else { return nil }
        let name = project.name.lowercased()
        // Two repos with different origins are different projects, however their folders are named.
        func sameName(_ candidate: RemoteProjectCandidate) -> Bool {
            candidate.kind != .scratch && candidate.name.lowercased() == name
                && !(project.origin != nil && candidate.origin != nil && candidate.origin != project.origin)
        }
        return best(locals.filter(sameName)) ?? first(remoteOnly.filter(sameName))
    }
}

public struct RemoteHistoryPage: Sendable, Equatable {
    public var days: [RemoteHistoryDay]
    public var deleted: [RemoteHistoryPartKey]
    public var seen: [RemoteHistoryPartKey]
    public var fromStart: Bool
    public var more: Bool

    public init(days: [RemoteHistoryDay] = [], deleted: [RemoteHistoryPartKey] = [], seen: [RemoteHistoryPartKey] = [],
                fromStart: Bool = false, more: Bool = false) {
        self.days = days
        self.deleted = deleted
        self.seen = seen
        self.fromStart = fromStart
        self.more = more
    }
}
