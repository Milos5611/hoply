import AgentKit
import Foundation

public actor StoreReader {
    private let db: SQLiteConnection

    public init(path: String = Store.defaultDatabaseURL.path) throws {
        let db = try SQLiteConnection(path: path, readOnly: true)
        try Schema.configure(db, readOnly: true)
        self.db = db
    }

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

    public func sessions(in range: DateInterval, source: AgentSource? = nil, project: ProjectFilter? = nil,
                         limit: Int = 50, offset: Int = 0) throws -> SessionPage {
        var filter = "s.last_at >= ? AND s.first_at < ?"
        var values: [any SQLiteBindable] = Self.bounds(range)
        if let source {
            filter += " AND s.source = ?"
            values.append(source.rawValue)
        }
        Self.append(project, column: "s.project_id", to: &filter, values: &values)
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

    public func dailySpend(days: Int, split: SpendSeriesSplit, project: ProjectFilter? = nil, localOnly: Bool = false,
                           now: Date = Date(), calendar: Calendar = .current) throws -> DailySpendSeries {
        let count = max(days, 1)
        let start = calendar.startOfDay(for: now)
        let dayStarts = (0...count).compactMap { calendar.date(byAdding: .day, value: $0 - count + 1, to: start) }
        guard dayStarts.count == count + 1 else { return DailySpendSeries(days: [], points: []) }
        let ranges = (0..<count).map { [dayStarts[$0].timeIntervalSince1970, dayStarts[$0 + 1].timeIntervalSince1970] }
        let rangesJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: ranges)) ?? Data("[]".utf8),
                                as: UTF8.self)
        let series = split == .model ? "COALESCE(model, '')" : "source"
        var filter = localOnly ? "usage.is_local = 1" : "1"
        var values: [any SQLiteBindable] = [rangesJSON]
        Self.append(project, column: "usage.project_id", to: &filter, values: &values)
        let points = try db.query("""
            WITH days(idx, start_ts, end_ts) AS (
                SELECT CAST(key AS INTEGER), json_extract(value, '$[0]'), json_extract(value, '$[1]') FROM json_each(?)
            )
            SELECT days.idx, \(series), \(Self.totals())
            FROM days JOIN usage ON usage.ts >= days.start_ts AND usage.ts < days.end_ts
            WHERE \(filter)
            GROUP BY days.idx, 2
            ORDER BY days.idx, 2
            """, values) { row in
            DailySpendPoint(day: dayStarts[row.int(0)], series: row.text(1), totals: Self.totals(row, from: 2))
        }
        return DailySpendSeries(days: Array(dayStarts.dropLast()), points: points)
    }

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

    public func projects(in range: DateInterval, topModels: Int = 3) throws -> [ProjectSummary] {
        let bounds = Self.bounds(range)
        var summaries = try db.query("""
            SELECT u.project_id, p.root, p.name, p.display_name, p.kind, \(Self.totals(prefix: "u.")),
                   COUNT(DISTINCT u.source || ':' || u.session_id), MAX(u.ts), MIN(u.ts)
            FROM usage u LEFT JOIN projects p ON p.id = u.project_id
            WHERE u.ts >= ? AND u.ts < ?
            GROUP BY u.project_id
            ORDER BY COALESCE(SUM(u.api_equiv_usd), 0) DESC, MAX(u.ts) DESC
            """, bounds) { row in
            ProjectSummary(project: Self.project(row, from: 0), totals: Self.totals(row, from: 5),
                           sessionCount: row.int(5 + Self.totalsColumnCount),
                           firstActive: row.optionalDouble(7 + Self.totalsColumnCount).map(Date.init(timeIntervalSince1970:)),
                           lastActive: row.optionalDouble(6 + Self.totalsColumnCount).map(Date.init(timeIntervalSince1970:)))
        }
        guard !summaries.isEmpty else { return [] }

        var bySource: [Int64?: [AgentSource: LedgerTotals]] = [:]
        for (projectID, source, totals) in try db.query("""
            SELECT project_id, source, \(Self.totals()) FROM usage WHERE ts >= ? AND ts < ? GROUP BY project_id, source
            """, bounds, { row in (row.optionalInt64(0), AgentSource(rawValue: row.text(1)), Self.totals(row, from: 2)) }) {
            if let source { bySource[projectID, default: [:]][source] = totals }
        }
        var models: [Int64?: [ModelShare]] = [:]
        for (projectID, share) in try db.query("""
            SELECT project_id, COALESCE(model, ''), \(Self.totals()) FROM usage WHERE ts >= ? AND ts < ?
            GROUP BY project_id, model
            """, bounds, { row in (row.optionalInt64(0), ModelShare(model: row.text(1), totals: Self.totals(row, from: 2))) }) {
            models[projectID, default: []].append(share)
        }
        var branches: [Int64?: Set<String>] = [:]
        var worktrees: [Int64?: Set<String>] = [:]
        for (projectID, branch, worktree) in try db.query("""
            SELECT DISTINCT u.project_id, s.branch, s.worktree
            FROM usage u JOIN sessions s ON s.source = u.source AND s.id = u.session_id
            WHERE u.ts >= ? AND u.ts < ?
            """, bounds, { row in (row.optionalInt64(0), row.optionalText(1), row.optionalText(2)) }) {
            if let branch, !branch.isEmpty { branches[projectID, default: []].insert(branch) }
            if let worktree, !worktree.isEmpty { worktrees[projectID, default: []].insert(worktree) }
        }
        for index in summaries.indices {
            let id = summaries[index].project?.id
            summaries[index].bySource = bySource[id] ?? [:]
            summaries[index].topModels = Array(Self.largestFirst(models[id] ?? []).prefix(max(topModels, 0)))
            summaries[index].branches = (branches[id] ?? []).sorted()
            summaries[index].worktrees = (worktrees[id] ?? []).sorted()
        }
        return summaries
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

    // MARK: - Session insight

    public func lastMainCalls(for keys: [SessionKey]) throws -> [SessionKey: SessionLastCall] {
        var result: [SessionKey: SessionLastCall] = [:]
        for (source, ids) in Dictionary(grouping: keys, by: \.source) {
            // SQLite takes the bare columns from the row that holds MAX(ts).
            let rows = try db.query("""
                SELECT session_id, MAX(ts), model, input, cache_read, cache_write_5m, cache_write_1h, output, reasoning
                FROM usage
                WHERE source = ? AND session_id IN (SELECT value FROM json_each(?)) AND sidechain = 0
                      AND dedupe_key NOT LIKE '%:advisor:%'
                GROUP BY session_id
                """, [source.rawValue, Self.jsonArray(ids.map(\.id))]) { row in
                SessionLastCall(key: SessionKey(source: source, id: row.text(0)), model: row.optionalText(2),
                                timestamp: Date(timeIntervalSince1970: row.double(1)),
                                tokens: TokenCounts(input: row.int(3), output: row.int(7), reasoning: row.int(8),
                                                    cacheRead: row.int(4), cacheWrite5m: row.int(5),
                                                    cacheWrite1h: row.int(6)))
            }
            for call in rows { result[call.key] = call }
        }
        return result
    }

    public func subagents(of key: SessionKey) throws -> [SubagentSummary] {
        var models: [String: (model: String, weight: Double)] = [:]
        for (agent, model, usd, tokens) in try db.query("""
            SELECT agent_id, model, COALESCE(SUM(api_equiv_usd), 0),
                   SUM(input + output + cache_read + cache_write_5m + cache_write_1h)
            FROM usage WHERE source = ? AND session_id = ? AND \(Self.isSubagentRow()) AND model IS NOT NULL
            GROUP BY agent_id, model ORDER BY model
            """, [key.source.rawValue, key.id], { row in (row.text(0), row.text(1), row.double(2), row.double(3)) }) {
            let weight = usd * 1e12 + tokens
            if weight > (models[agent]?.weight ?? -1) { models[agent] = (model, weight) }
        }
        return try db.query("""
            SELECT u.agent_id, MIN(u.ts), MAX(u.ts), a.agent_type, a.description, \(Self.totals(prefix: "u."))
            FROM usage u
            LEFT JOIN subagents a ON a.source = u.source AND a.session_id = u.session_id AND a.agent_id = u.agent_id
            WHERE u.source = ? AND u.session_id = ? AND \(Self.isSubagentRow("u."))
            GROUP BY u.agent_id
            ORDER BY MIN(u.ts), u.agent_id
            """, [key.source.rawValue, key.id]) { row in
            let id = row.text(0)
            return SubagentSummary(agentID: id, agentType: row.optionalText(3), description: row.optionalText(4),
                                   model: models[id]?.model, firstAt: Date(timeIntervalSince1970: row.double(1)),
                                   lastAt: Date(timeIntervalSince1970: row.double(2)), totals: Self.totals(row, from: 5))
        }
    }

    public func subagentCounts(for keys: [SessionKey]) throws -> [SessionKey: Int] {
        var result: [SessionKey: Int] = [:]
        for (source, ids) in Dictionary(grouping: keys, by: \.source) {
            let rows = try db.query("""
                SELECT session_id, COUNT(DISTINCT agent_id) FROM usage
                WHERE source = ? AND session_id IN (SELECT value FROM json_each(?)) AND \(Self.isSubagentRow())
                GROUP BY session_id
                """, [source.rawValue, Self.jsonArray(ids.map(\.id))]) { row in
                (SessionKey(source: source, id: row.text(0)), row.int(1))
            }
            for (key, count) in rows { result[key] = count }
        }
        return result
    }

    private static func isSubagentRow(_ p: String = "") -> String {
        "\(p)sidechain = 1 AND \(p)agent_id IS NOT NULL AND \(p)agent_id != ''"
    }

    public func modelEfficiency(in range: DateInterval, project: ProjectFilter? = nil,
                                pricing: PricingTable) throws -> [ModelEfficiency] {
        var filter = "ts >= ? AND ts < ?"
        var values: [any SQLiteBindable] = Self.bounds(range)
        Self.append(project, column: "project_id", to: &filter, values: &values)
        var models = try db.query("""
            SELECT COALESCE(model, ''), \(Self.totals()) FROM usage WHERE \(filter)
            GROUP BY 1 ORDER BY COALESCE(SUM(api_equiv_usd), 0) DESC, 1
            """, values) { row in ModelEfficiency(model: row.text(0), totals: Self.totals(row, from: 1)) }
        let fast = try db.query("""
            SELECT COALESCE(model, ''), input, output, reasoning, cache_read, cache_write_5m, cache_write_1h,
                   api_equiv_usd, native_usd
            FROM usage WHERE \(filter) AND lower(speed) = 'fast'
            """, values) { row in
            (model: row.text(0),
             tokens: TokenCounts(input: row.int(1), output: row.int(2), reasoning: row.int(3), cacheRead: row.int(4),
                                 cacheWrite5m: row.int(5), cacheWrite1h: row.int(6)),
             usd: row.optionalDouble(7), native: !row.isNull(8))
        }
        for call in fast {
            guard let index = models.firstIndex(where: { $0.model == call.model }) else { continue }
            models[index].fastCalls += 1
            models[index].fastUSD += call.usd ?? 0
            if !call.native, let usd = call.usd,
               let standard = pricing.price(model: call.model, tokens: call.tokens, speed: nil).apiEquivUSD {
                models[index].fastPremiumUSD += usd - standard
            }
        }
        return models
    }

    public func unpricedModels() throws -> [UnpricedModel] {
        try db.query("""
            SELECT COALESCE(model, ''), COUNT(*), SUM(input), SUM(output), SUM(reasoning), SUM(cache_read),
                   SUM(cache_write_5m), SUM(cache_write_1h), MIN(ts), MAX(ts)
            FROM usage WHERE cost_usd IS NULL AND is_local = 0 AND native_usd IS NULL
            GROUP BY 1 ORDER BY COUNT(*) DESC, 1
            """) { row in
            UnpricedModel(model: row.text(0), calls: row.int(1),
                          tokens: TokenCounts(input: row.int(2), output: row.int(3), reasoning: row.int(4),
                                              cacheRead: row.int(5), cacheWrite5m: row.int(6), cacheWrite1h: row.int(7)),
                          firstSeen: Date(timeIntervalSince1970: row.double(8)),
                          lastSeen: Date(timeIntervalSince1970: row.double(9)))
        }
    }

    // MARK: - Limit samples

    public func limitSamples(_ kinds: Set<LimitKind>? = nil, in range: DateInterval,
                             bucket: TimeInterval? = nil) throws -> [LimitSample] {
        var filter = "ts >= ? AND ts < ?"
        var values: [any SQLiteBindable] = Self.bounds(range)
        if let kinds {
            filter += " AND kind IN (SELECT value FROM json_each(?))"
            values.append(Self.jsonArray(kinds.map(\.rawValue)))
        }
        let samples = try db.query("""
            SELECT kind, ts, utilization, resets_at FROM limit_samples WHERE \(filter) ORDER BY ts, kind
            """, values) { Self.limitSample($0) }.compactMap { $0 }
        guard let bucket, bucket > 0 else { return samples }
        return Self.peaks(samples, bucket: bucket)
    }

    private static func peaks(_ samples: [LimitSample], bucket: TimeInterval) -> [LimitSample] {
        var kept: [LimitSample] = []
        var open: [LimitKind: (index: Int, slot: Double, first: LimitSample)] = [:]
        for sample in samples {
            let slot = (sample.ts.timeIntervalSince1970 / bucket).rounded(.down)
            if let run = open[sample.kind], run.slot == slot, sample.isSameWindow(as: run.first) {
                if sample.utilization > kept[run.index].utilization { kept[run.index] = sample }
            } else {
                open[sample.kind] = (kept.count, slot, sample)
                kept.append(sample)
            }
        }
        return kept.sorted { ($0.ts, $0.kind.rawValue) < ($1.ts, $1.kind.rawValue) }
    }

    public func latestLimitSamples() throws -> [LimitKind: LimitSample] {
        try Self.latestLimitSamples(db)
    }

    static func latestLimitSamples(_ db: SQLiteConnection) throws -> [LimitKind: LimitSample] {
        let rows = try db.query("SELECT kind, MAX(ts), utilization, resets_at FROM limit_samples GROUP BY kind") {
            Self.limitSample($0)
        }
        return Dictionary(rows.compactMap { $0.map { ($0.kind, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    private static func limitSample(_ row: SQLiteRow) -> LimitSample? {
        guard let kind = LimitKind(rawValue: row.text(0)) else { return nil }
        return LimitSample(kind: kind, ts: Date(timeIntervalSince1970: row.double(1)), utilization: row.double(2),
                           resetsAt: row.optionalDouble(3).map(Date.init(timeIntervalSince1970:)))
    }

    // MARK: - Samples

    public func samples(_ series: String, resolution: Int = SampleAggregator.resolution,
                        in range: DateInterval) throws -> [SampleBucket] {
        let rows = try db.query("""
            SELECT res, bucket, n, sum, min, max FROM samples
            WHERE series = ? AND bucket < ? AND bucket + res > ?
            ORDER BY bucket
            """, [series, range.end.timeIntervalSince1970, range.start.timeIntervalSince1970]) { row in
            SampleBucket(series: series, resolution: row.int(0), start: row.int(1), n: row.int(2), sum: row.double(3),
                         min: row.optionalDouble(4), max: row.optionalDouble(5))
        }
        return SampleAggregator.rollup(rows, to: resolution)
    }

    public func recentSamples(_ series: [String], since: Date, now: Date = Date()) throws -> [String: [SampleBucket]] {
        var result: [String: [SampleBucket]] = [:]
        for name in Set(series) {
            let buckets = try samples(name, in: DateInterval(start: since, end: max(now, since).addingTimeInterval(60)))
            if !buckets.isEmpty { result[name] = buckets }
        }
        return result
    }

    public func dailySums(_ series: String, days: Int, now: Date = Date(),
                          calendar: Calendar = .current) throws -> [DailySampleSum] {
        let count = max(days, 1)
        let start = calendar.startOfDay(for: now)
        let dayStarts = (0...count).compactMap { calendar.date(byAdding: .day, value: $0 - count + 1, to: start) }
        guard dayStarts.count == count + 1 else { return [] }
        let ranges = (0..<count).map { [dayStarts[$0].timeIntervalSince1970, dayStarts[$0 + 1].timeIntervalSince1970] }
        let rangesJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: ranges)) ?? Data("[]".utf8),
                                as: UTF8.self)
        let rows = try db.query("""
            WITH days(idx, start_ts, end_ts) AS (
                SELECT CAST(key AS INTEGER), json_extract(value, '$[0]'), json_extract(value, '$[1]') FROM json_each(?)
            )
            SELECT days.idx, SUM(s.sum), SUM(s.n)
            FROM days JOIN samples s ON s.series = ? AND s.bucket >= days.start_ts AND s.bucket < days.end_ts
            GROUP BY days.idx
            """, [rangesJSON, series]) { row in (row.int(0), row.double(1), row.int(2)) }
        var sums = (0..<count).map { DailySampleSum(day: dayStarts[$0], sum: 0, readings: 0) }
        for (index, sum, readings) in rows where sums.indices.contains(index) {
            sums[index].sum = sum
            sums[index].readings = readings
        }
        return sums
    }

    public static func days(_ count: Int, endingAt now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let start = calendar.date(byAdding: .day, value: -(max(count, 1) - 1), to: today) ?? today
        return DateInterval(start: start, end: end)
    }

    // MARK: - Row mapping

    private static let totalsColumnCount: Int32 = 12

    private static func totals(prefix p: String = "") -> String {
        """
        COALESCE(SUM(\(p)cost_usd), 0), COALESCE(SUM(\(p)api_equiv_usd), 0), COALESCE(SUM(\(p)input), 0),
        COALESCE(SUM(\(p)output), 0), COALESCE(SUM(\(p)reasoning), 0), COALESCE(SUM(\(p)cache_read), 0),
        COALESCE(SUM(\(p)cache_write_5m), 0), COALESCE(SUM(\(p)cache_write_1h), 0), COUNT(\(p)id),
        COALESCE(MAX(\(p)cost_usd IS NULL AND \(p)is_local = 0), 0),
        COALESCE(SUM(CASE WHEN \(p)source = 'copilot-cli' THEN \(p)native_cost END), 0),
        COALESCE(SUM(\(p)premium_requests), 0)
        """
    }

    private static func totals(_ row: SQLiteRow, from start: Int32) -> LedgerTotals {
        LedgerTotals(costUSD: row.double(start), apiEquivUSD: row.double(start + 1),
                     tokens: TokenCounts(input: row.int(start + 2), output: row.int(start + 3),
                                         reasoning: row.int(start + 4), cacheRead: row.int(start + 5),
                                         cacheWrite5m: row.int(start + 6), cacheWrite1h: row.int(start + 7)),
                     calls: row.int(start + 8), hasUnpriced: row.bool(start + 9), aiu: row.double(start + 10),
                     premiumRequests: row.double(start + 11))
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
            summaries[index].models = Self.largestFirst(shares[summaries[index].key] ?? [])
        }
    }

    private static func largestFirst(_ shares: [ModelShare]) -> [ModelShare] {
        shares.sorted {
            ($0.totals.apiEquivUSD, $0.totals.tokens.total, $1.model) > ($1.totals.apiEquivUSD, $1.totals.tokens.total, $0.model)
        }
    }

    private static func append(_ project: ProjectFilter?, column: String, to filter: inout String,
                               values: inout [any SQLiteBindable]) {
        switch project {
        case .project(let id)?:
            filter += " AND \(column) = ?"
            values.append(id)
        case .unassigned?:
            filter += " AND \(column) IS NULL"
        case nil:
            break
        }
    }

    private static func bounds(_ range: DateInterval) -> [any SQLiteBindable] {
        [range.start.timeIntervalSince1970, range.end.timeIntervalSince1970]
    }

    private static func jsonArray(_ values: [String]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: values)) ?? Data("[]".utf8), as: UTF8.self)
    }
}
