import AgentKit
import Foundation

/// Read-only queries over the ledger on its own connection, so reads never wait behind ingest writes.
/// Every total is a `GROUP BY` over `usage`.
public actor StoreReader {
    private let db: SQLiteConnection

    /// The database must already exist (open the `Store` first).
    public init(path: String = Store.defaultDatabaseURL.path) throws {
        let db = try SQLiteConnection(path: path, readOnly: true)
        try Schema.configure(db, readOnly: true)
        self.db = db
    }

    /// Lifetime ledger totals per session. Keys without usage are absent from the result.
    public func sessionTotals(for keys: [SessionKey]) throws -> [SessionKey: LedgerTotals] {
        var result: [SessionKey: LedgerTotals] = [:]
        for (source, ids) in Dictionary(grouping: keys, by: \.source) {
            let rows = try db.query("""
                SELECT session_id, \(Self.totals())
                FROM usage WHERE source = ? AND session_id IN (SELECT value FROM json_each(?))
                GROUP BY session_id
                """, [source.rawValue, Self.jsonArray(ids.map(\.id))]) { row in
                (SessionKey(source: source, id: row.text(0)), Self.totals(row, from: 1))
            }
            for (key, totals) in rows { result[key] = totals }
        }
        return result
    }

    public func totalsBySource(in range: DateInterval) throws -> [AgentSource: LedgerTotals] {
        let rows = try db.query("""
            SELECT source, \(Self.totals()) FROM usage WHERE ts >= ? AND ts < ? GROUP BY source
            """, Self.bounds(range)) { row in (AgentSource(rawValue: row.text(0)), Self.totals(row, from: 1)) }
        var result: [AgentSource: LedgerTotals] = [:]
        for case let (source?, totals) in rows { result[source] = totals }
        return result
    }

    public func todayBySource(now: Date = Date(), calendar: Calendar = .current) throws -> [AgentSource: LedgerTotals] {
        try totalsBySource(in: Self.days(1, endingAt: now, calendar: calendar))
    }

    /// Sessions active in `range` (newest activity first). Each row's totals cover the whole session.
    public func sessions(in range: DateInterval, source: AgentSource? = nil, projectID: Int64? = nil,
                         limit: Int = 50, offset: Int = 0) throws -> SessionPage {
        var filter = "s.last_at >= ? AND s.first_at < ?"
        var values: [any SQLiteBindable] = Self.bounds(range)
        if let source {
            filter += " AND s.source = ?"
            values.append(source.rawValue)
        }
        if let projectID {
            filter += " AND s.project_id = ?"
            values.append(projectID)
        }
        let total = try db.queryOne("SELECT COUNT(*) FROM sessions s WHERE \(filter)", values) { $0.int(0) } ?? 0
        var summaries = try db.query("""
            SELECT \(Self.sessionColumns), \(Self.totals(prefix: "u."))
            FROM sessions s
            LEFT JOIN projects p ON p.id = s.project_id
            LEFT JOIN usage u ON u.source = s.source AND u.session_id = s.id
            WHERE \(filter)
            GROUP BY s.source, s.id
            ORDER BY s.last_at DESC
            LIMIT ? OFFSET ?
            """, values + [limit, offset]) { row in Self.session(row) }.compactMap { $0 }
        try attachModels(&summaries)
        return SessionPage(sessions: summaries, totalCount: total)
    }

    public func session(_ key: SessionKey) throws -> SessionSummary? {
        var found = try db.query("""
            SELECT \(Self.sessionColumns), \(Self.totals(prefix: "u."))
            FROM sessions s
            LEFT JOIN projects p ON p.id = s.project_id
            LEFT JOIN usage u ON u.source = s.source AND u.session_id = s.id
            WHERE s.source = ? AND s.id = ?
            GROUP BY s.source, s.id
            """, [key.source.rawValue, key.id]) { row in Self.session(row) }.compactMap { $0 }
        try attachModels(&found)
        return found.first
    }

    /// The last `days` local days including today, split by model or by source.
    public func dailySpend(days: Int, split: SpendSeriesSplit, now: Date = Date(),
                           calendar: Calendar = .current) throws -> DailySpendSeries {
        let count = max(days, 1)
        let start = calendar.startOfDay(for: now)
        let dayStarts = (0...count).compactMap { calendar.date(byAdding: .day, value: $0 - count + 1, to: start) }
        guard dayStarts.count == count + 1 else { return DailySpendSeries(days: [], points: []) }
        let ranges = (0..<count).map { [dayStarts[$0].timeIntervalSince1970, dayStarts[$0 + 1].timeIntervalSince1970] }
        let rangesJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: ranges)) ?? Data("[]".utf8),
                                as: UTF8.self)
        let series = split == .model ? "COALESCE(model, '')" : "source"
        let points = try db.query("""
            WITH days(idx, start_ts, end_ts) AS (
                SELECT CAST(key AS INTEGER), json_extract(value, '$[0]'), json_extract(value, '$[1]') FROM json_each(?)
            )
            SELECT days.idx, \(series), \(Self.totals())
            FROM days JOIN usage ON usage.ts >= days.start_ts AND usage.ts < days.end_ts
            GROUP BY days.idx, 2
            ORDER BY days.idx, 2
            """, [rangesJSON]) { row in
            DailySpendPoint(day: dayStarts[row.int(0)], series: row.text(1), totals: Self.totals(row, from: 2))
        }
        return DailySpendSeries(days: Array(dayStarts.dropLast()), points: points)
    }

    /// Largest API-equivalent spend first. Usage without a project has `id == ""` and label "Unassigned".
    public func spendByProject(in range: DateInterval) throws -> [SpendSlice] {
        try db.query("""
            SELECT u.project_id, p.root, p.name, p.display_name, p.kind, \(Self.totals(prefix: "u.")),
                   COUNT(DISTINCT u.source || ':' || u.session_id)
            FROM usage u LEFT JOIN projects p ON p.id = u.project_id
            WHERE u.ts >= ? AND u.ts < ?
            GROUP BY u.project_id
            ORDER BY COALESCE(SUM(u.api_equiv_usd), 0) DESC
            """, Self.bounds(range)) { row in
            let project = Self.project(row, from: 0)
            return SpendSlice(id: project.map { String($0.id) } ?? "", label: project?.title ?? "Unassigned",
                              project: project, totals: Self.totals(row, from: 5),
                              sessionCount: row.int(5 + Self.totalsColumnCount))
        }
    }

    public func spendByModel(in range: DateInterval) throws -> [SpendSlice] {
        try db.query("""
            SELECT COALESCE(model, ''), \(Self.totals()), COUNT(DISTINCT source || ':' || session_id)
            FROM usage WHERE ts >= ? AND ts < ?
            GROUP BY 1
            ORDER BY COALESCE(SUM(api_equiv_usd), 0) DESC
            """, Self.bounds(range)) { row in
            let model = row.text(0)
            return SpendSlice(id: model, label: model.isEmpty ? "Unknown model" : model,
                              totals: Self.totals(row, from: 1), sessionCount: row.int(1 + Self.totalsColumnCount))
        }
    }

    /// Today, the last 7 and 30 local days (each including today), and everything in the ledger.
    public func overview(now: Date = Date(), calendar: Calendar = .current) throws -> SpendOverview {
        func sum(_ range: DateInterval?) throws -> LedgerTotals {
            if let range {
                return try db.queryOne("SELECT \(Self.totals()) FROM usage WHERE ts >= ? AND ts < ?",
                                       Self.bounds(range)) { Self.totals($0, from: 0) } ?? .zero
            }
            return try db.queryOne("SELECT \(Self.totals()) FROM usage") { Self.totals($0, from: 0) } ?? .zero
        }
        return SpendOverview(today: try sum(Self.days(1, endingAt: now, calendar: calendar)),
                             last7Days: try sum(Self.days(7, endingAt: now, calendar: calendar)),
                             last30Days: try sum(Self.days(30, endingAt: now, calendar: calendar)),
                             allTime: try sum(nil))
    }

    /// The last `count` local days including the one containing `now`, ending at the next midnight.
    public static func days(_ count: Int, endingAt now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let start = calendar.date(byAdding: .day, value: -(max(count, 1) - 1), to: today) ?? today
        return DateInterval(start: start, end: end)
    }

    // MARK: - Row mapping

    private static let totalsColumnCount: Int32 = 10

    private static func totals(prefix p: String = "") -> String {
        """
        COALESCE(SUM(\(p)cost_usd), 0), COALESCE(SUM(\(p)api_equiv_usd), 0), COALESCE(SUM(\(p)input), 0),
        COALESCE(SUM(\(p)output), 0), COALESCE(SUM(\(p)reasoning), 0), COALESCE(SUM(\(p)cache_read), 0),
        COALESCE(SUM(\(p)cache_write_5m), 0), COALESCE(SUM(\(p)cache_write_1h), 0), COUNT(\(p)id),
        COALESCE(MAX(\(p)cost_usd IS NULL AND \(p)is_local = 0), 0)
        """
    }

    private static func totals(_ row: SQLiteRow, from start: Int32) -> LedgerTotals {
        LedgerTotals(costUSD: row.double(start), apiEquivUSD: row.double(start + 1),
                     tokens: TokenCounts(input: row.int(start + 2), output: row.int(start + 3),
                                         reasoning: row.int(start + 4), cacheRead: row.int(start + 5),
                                         cacheWrite5m: row.int(start + 6), cacheWrite1h: row.int(start + 7)),
                     calls: row.int(start + 8), hasUnpriced: row.bool(start + 9))
    }

    private static let sessionColumns = """
        s.source, s.id, s.title, s.cwd, s.branch, s.worktree, s.first_at, s.last_at, s.turns, s.native_cost,
        s.lines_added, s.lines_removed, s.pr_url, s.transcript_path, p.id, p.root, p.name, p.display_name, p.kind
        """

    private static func session(_ row: SQLiteRow) -> SessionSummary? {
        guard let source = AgentSource(rawValue: row.text(0)) else { return nil }
        return SessionSummary(
            key: SessionKey(source: source, id: row.text(1)), project: project(row, from: 14),
            title: row.optionalText(2), cwd: row.optionalText(3), branch: row.optionalText(4),
            worktree: row.optionalText(5), firstAt: row.optionalDouble(6).map(Date.init(timeIntervalSince1970:)),
            lastAt: row.optionalDouble(7).map(Date.init(timeIntervalSince1970:)), turns: row.int(8),
            totals: totals(row, from: 19), nativeCostUSD: row.optionalDouble(9), linesAdded: row.optionalInt(10),
            linesRemoved: row.optionalInt(11), prURL: row.optionalText(12), transcriptPath: row.optionalText(13))
    }

    /// Columns: id, root, name, display_name, kind.
    private static func project(_ row: SQLiteRow, from start: Int32) -> ProjectRef? {
        guard let id = row.optionalInt64(start) else { return nil }
        return ProjectRef(id: id, root: row.text(start + 1), name: row.text(start + 2),
                          displayName: row.optionalText(start + 3),
                          kind: ProjectKind(rawValue: row.text(start + 4)) ?? .folder)
    }

    private func attachModels(_ summaries: inout [SessionSummary]) throws {
        guard !summaries.isEmpty else { return }
        var shares: [SessionKey: [ModelShare]] = [:]
        for (source, items) in Dictionary(grouping: summaries.map(\.key), by: \.source) {
            let rows = try db.query("""
                SELECT session_id, COALESCE(model, ''), \(Self.totals())
                FROM usage WHERE source = ? AND session_id IN (SELECT value FROM json_each(?))
                GROUP BY session_id, model
                """, [source.rawValue, Self.jsonArray(items.map(\.id))]) { row in
                (SessionKey(source: source, id: row.text(0)), ModelShare(model: row.text(1), totals: Self.totals(row, from: 2)))
            }
            for (key, share) in rows { shares[key, default: []].append(share) }
        }
        for index in summaries.indices {
            summaries[index].models = (shares[summaries[index].key] ?? []).sorted {
                ($0.totals.apiEquivUSD, $0.totals.tokens.total) > ($1.totals.apiEquivUSD, $1.totals.tokens.total)
            }
        }
    }

    private static func bounds(_ range: DateInterval) -> [any SQLiteBindable] {
        [range.start.timeIntervalSince1970, range.end.timeIntervalSince1970]
    }

    private static func jsonArray(_ values: [String]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: values)) ?? Data("[]".utf8), as: UTF8.self)
    }
}
