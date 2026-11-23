import AgentKit
import Foundation

public struct LocalHistoryDay: Sendable, Equatable {
    public struct ProjectSource: Sendable, Equatable {
        public var project: RemoteHistoryDay.Project
        public var id: Int64
        public var root: String
        public var kind: ProjectKind
    }

    public var day: Int
    public var sessions: [RemoteHistoryDay.Session]
    public var projects: [ProjectSource]
}

extension StoreReader {
    public func remoteDevices() throws -> [RemoteDevice] {
        try db.query("""
            SELECT d.device, d.name, d.updated_at FROM remote_devices d
            WHERE EXISTS (SELECT 1 FROM remote_usage u WHERE u.device = d.device AND \(Self.counted("u")))
            ORDER BY lower(COALESCE(d.name, d.device)), d.device
            """) { row in
            RemoteDevice(id: row.text(0), name: row.optionalText(1),
                         updatedAt: row.optionalDouble(2).map(Date.init(timeIntervalSince1970:)))
        }
    }

    public func ledgerDays() throws -> Set<Int> {
        Set(try db.query("SELECT DISTINCT CAST(ts / 86400 AS INTEGER) FROM usage WHERE ts >= 0") { $0.int(0) })
    }

    // Reads `usage` only: another Mac's rows are never sent back out.
    public func localHistoryDay(_ day: Int, contextThresholds: [Int] = []) throws -> LocalHistoryDay {
        let bounds = RemoteHistoryCalendar.interval(of: day)
        let prompt = "(input + cache_read + cache_write_5m + cache_write_1h)"
        // A bare integer in GROUP BY names a result column, so no tiers means no band term at all.
        let band = contextThresholds.isEmpty ? ""
            : ", " + contextThresholds.map { "(\(prompt) > \($0))" }.joined(separator: " + ")
        struct Slice {
            var key: SessionKey
            var project: Int64?
            var usage: RemoteHistoryDay.Usage
        }
        let slices = try db.query("""
            SELECT source, session_id, project_id, model, speed, MIN(ts), MAX(ts), MAX(\(prompt)),
                   SUM(input), SUM(output), SUM(reasoning), SUM(cache_read), SUM(cache_write_5m), SUM(cache_write_1h),
                   COUNT(*), SUM(native_usd), SUM(native_cost), SUM(premium_requests)
            FROM usage WHERE ts >= ? AND ts < ?
            GROUP BY source, session_id, project_id, CAST(ts / 3600 AS INTEGER), model, speed\(band),
                     native_usd IS NOT NULL
            """, [bounds.start.timeIntervalSince1970, bounds.end.timeIntervalSince1970]) { row -> Slice? in
            guard let source = AgentSource(rawValue: row.text(0)) else { return nil }
            let usage = RemoteHistoryDay.Usage(
                model: row.optionalText(3), speed: row.optionalText(4),
                at: Date(timeIntervalSince1970: row.double(5)), last: Date(timeIntervalSince1970: row.double(6)),
                prompt: row.int(7),
                tokens: TokenCounts(input: row.int(8), output: row.int(9), reasoning: row.int(10), cacheRead: row.int(11),
                                    cacheWrite5m: row.int(12), cacheWrite1h: row.int(13)),
                calls: row.int(14), nativeUSD: row.optionalDouble(15), nativeCost: row.optionalDouble(16),
                premium: row.optionalDouble(17).flatMap { $0 == 0 ? nil : $0 })
            return Slice(key: SessionKey(source: source, id: row.text(1)), project: row.optionalInt64(2), usage: usage)
        }.compactMap { $0 }
        guard !slices.isEmpty else { return LocalHistoryDay(day: day, sessions: [], projects: []) }

        var meta: [SessionKey: (title: String?, first: Double?, last: Double?, project: Int64?)] = [:]
        for (source, keys) in Dictionary(grouping: Set(slices.map(\.key)), by: \.source) {
            let rows = try db.query("""
                SELECT id, title, first_at, last_at, project_id FROM sessions
                WHERE source = ? AND id IN (SELECT value FROM json_each(?))
                """, [source.rawValue, Self.jsonArray(keys.map(\.id))]) { row in
                (row.text(0), (title: row.optionalText(1), first: row.optionalDouble(2), last: row.optionalDouble(3),
                               project: row.optionalInt64(4)))
            }
            for (id, value) in rows { meta[SessionKey(source: source, id: id)] = value }
        }
        let projectIDs = Set(slices.compactMap(\.project) + meta.values.compactMap(\.project))
        let projectRows = try db.query("""
            SELECT id, root, name, display_name, kind FROM projects WHERE id IN (SELECT value FROM json_each(?))
            """, [Store.jsonArray(Array(projectIDs))]) { row in
            (id: row.int64(0), root: row.text(1), name: row.text(2), title: row.optionalText(3),
             kind: ProjectKind(rawValue: row.text(4)) ?? .folder)
        }
        var projects: [Int64: LocalHistoryDay.ProjectSource] = [:]
        for row in projectRows {
            var origin: String?
            if row.root.hasPrefix(ProjectRef.remoteRootPrefix) {
                origin = try db.queryOne("""
                    SELECT origin FROM remote_projects WHERE project_id = ? AND origin IS NOT NULL ORDER BY device LIMIT 1
                    """, [row.id]) { $0.optionalText(0) } ?? nil
            }
            let project = RemoteHistoryDay.Project(id: RemoteHistoryDay.Project.id(root: row.root), name: row.name,
                                                   title: row.title, origin: origin, kind: .init(row.kind))
            projects[row.id] = LocalHistoryDay.ProjectSource(project: project, id: row.id, root: row.root, kind: row.kind)
        }

        var sessions: [RemoteHistoryDay.Session] = []
        for (key, group) in Dictionary(grouping: slices, by: \.key) {
            let info = meta[key]
            let sessionProject = info?.project ?? group.first?.project
            let usage = group.map { slice -> RemoteHistoryDay.Usage in
                var usage = slice.usage
                if slice.project != sessionProject { usage.project = slice.project.flatMap { projects[$0]?.project.id } }
                return usage
            }
            let start = usage.map(\.at).min() ?? bounds.start
            let end = usage.map(\.last).max() ?? start
            sessions.append(RemoteHistoryDay.Session(
                key: RemoteSchema.sessionKey(key), agent: key.source.rawValue,
                project: sessionProject.flatMap { projects[$0]?.project.id }, title: info?.title,
                start: info?.first.map(Date.init(timeIntervalSince1970:)) ?? start,
                end: info?.last.map(Date.init(timeIntervalSince1970:)) ?? end, usage: usage))
        }
        return LocalHistoryDay(day: day, sessions: sessions.sorted { $0.key < $1.key },
                               projects: projects.values.sorted { $0.project.id < $1.project.id })
    }
}
