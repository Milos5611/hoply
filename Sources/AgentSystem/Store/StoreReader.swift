import AgentKit
import Foundation

public actor StoreReader {
    let db: SQLiteConnection

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

    public func sessionTitles(for keys: [SessionKey]) throws -> [SessionKey: String] {
        var result: [SessionKey: String] = [:]
        for (source, ids) in Dictionary(grouping: keys, by: \.source) {
            let rows = try db.query("""
                SELECT id, title FROM sessions
                WHERE source = ? AND id IN (SELECT value FROM json_each(?)) AND title <> ''
                """, [source.rawValue, Self.jsonArray(ids.map(\.id))]) { row in
                (SessionKey(source: source, id: row.text(0)), row.text(1))
            }
            for (key, title) in rows { result[key] = title }
        }
        return result
    }

    public func totalsBySource(in range: DateInterval, scope: MacScope = .thisMac) throws -> [AgentSource: LedgerTotals] {
        let rows = Self.rows(scope, where: "ts >= ? AND ts < ?", Self.bounds(range))
        let found = try db.query("""
            SELECT source, \(Self.totals(scoped: true)) FROM (\(rows.sql)) GROUP BY source
            """, rows.values) { row in (AgentSource(rawValue: row.text(0)), Self.totals(row, from: 1)) }
        var result: [AgentSource: LedgerTotals] = [:]
        for case let (source?, totals) in found { result[source] = totals }
        return result
    }

    public func todayBySource(now: Date = Date(), calendar: Calendar = .current) throws -> [AgentSource: LedgerTotals] {
        try totalsBySource(in: Self.days(1, endingAt: now, calendar: calendar))
    }

    public func sessions(in range: DateInterval, source: AgentSource? = nil, project: ProjectFilter? = nil,
                         limit: Int = 50, offset: Int = 0, scope: MacScope = .thisMac) throws -> SessionPage {
        var filter = "s.last_at >= ? AND s.first_at < ?"
        var values: [any SQLiteBindable] = Self.bounds(range)
        if let source {
            filter += " AND s.source = ?"
            values.append(source.rawValue)
        }
        Self.append(project, column: "s.project_id", to: &filter, values: &values)
        var arms: [String] = []
        var armValues: [any SQLiteBindable] = []
        var total = 0
        if scope.includesThisMac {
            total += try db.queryOne("SELECT COUNT(*) FROM sessions s WHERE \(filter)", values) { $0.int(0) } ?? 0
            arms.append("""
                SELECT NULL AS device, \(Self.sessionColumns), \(Self.totals(prefix: "u."))
                FROM sessions s
                LEFT JOIN projects p ON p.id = s.project_id
                LEFT JOIN usage u ON u.source = s.source AND u.session_id = s.id
                WHERE \(filter)
                GROUP BY s.source, s.id
                """)
            armValues += values
        }
        if scope.includesOtherMacs {
            let remote = Self.remoteSessions(scope)
            total += try db.queryOne("""
                WITH s AS (\(remote.sql)) SELECT COUNT(*) FROM s WHERE \(filter)
                """, remote.values + values) { $0.int(0) } ?? 0
            arms.append("""
                SELECT * FROM (WITH s AS (\(remote.sql))
                SELECT s.device, \(Self.remoteSessionColumns), \(Self.totals(prefix: "u.", scoped: true))
                FROM s
                LEFT JOIN projects p ON p.id = s.project_id
                LEFT JOIN remote_usage u ON u.device = s.device AND u.source = s.source AND u.session_id = s.id
                    AND \(Self.counted("u"))
                WHERE \(filter)
                GROUP BY s.device, s.source, s.id)
                """)
            armValues += remote.values + values
        }
        guard !arms.isEmpty else { return SessionPage(sessions: [], totalCount: 0) }
        var summaries = try db.query("""
            \(arms.joined(separator: "\nUNION ALL\n"))
            ORDER BY 7 DESC, 2, 3, 1
            LIMIT ? OFFSET ?
            """, armValues + [limit, offset]) { row in Self.session(row, from: 1) }.compactMap { $0 }
        try attachModels(&summaries)
        try attachDeviceNames(&summaries)
        return SessionPage(sessions: summaries, totalCount: total)
    }

    public func session(_ key: SessionKey, device: String? = nil) throws -> SessionSummary? {
        if let device {
            let remote = Self.remoteSessions(.device(device))
            var found = try db.query("""
                WITH s AS (\(remote.sql))
                SELECT s.device, \(Self.remoteSessionColumns), \(Self.totals(prefix: "u.", scoped: true))
                FROM s
                LEFT JOIN projects p ON p.id = s.project_id
                LEFT JOIN remote_usage u ON u.device = s.device AND u.source = s.source AND u.session_id = s.id
                    AND \(Self.counted("u"))
                WHERE s.source = ? AND s.id = ?
                GROUP BY s.device, s.source, s.id
                """, remote.values + [key.source.rawValue, key.id]) { row in Self.session(row, from: 1) }.compactMap { $0 }
            try attachModels(&found)
            try attachDeviceNames(&found)
            return found.first
        }
        var found = try db.query("""
            SELECT NULL, \(Self.sessionColumns), \(Self.totals(prefix: "u."))
            FROM sessions s
            LEFT JOIN projects p ON p.id = s.project_id
            LEFT JOIN usage u ON u.source = s.source AND u.session_id = s.id
            WHERE s.source = ? AND s.id = ?
            GROUP BY s.source, s.id
            """, [key.source.rawValue, key.id]) { row in Self.session(row, from: 1) }.compactMap { $0 }
        try attachModels(&found)
        return found.first
    }

    public func sessionFile(_ key: SessionKey) throws -> (transcriptPath: String?, cwd: String?)? {
        try db.query("SELECT transcript_path, cwd FROM sessions WHERE source = ? AND id = ?",
                     [key.source.rawValue, key.id]) { row in (row.optionalText(0), row.optionalText(1)) }.first
    }

    public func recentSessions(limit: Int, sources: Set<AgentSource>? = nil) throws -> [RecentSession] {
        let wanted = (sources ?? Set(AgentSource.allCases)).map(\.rawValue).sorted()
        return try db.query("""
            SELECT s.source, s.id, s.title, s.cwd, s.last_at, p.id, p.root, p.name, p.display_name, p.kind
            FROM sessions s LEFT JOIN projects p ON p.id = s.project_id
            WHERE s.last_at IS NOT NULL AND s.cwd IS NOT NULL AND s.cwd != ''
                  AND s.source IN (SELECT value FROM json_each(?))
            ORDER BY s.last_at DESC, s.source, s.id
            LIMIT ?
            """, [Self.jsonArray(wanted), max(limit, 0)]) { row -> RecentSession? in
            guard let source = AgentSource(rawValue: row.text(0)) else { return nil }
            return RecentSession(key: SessionKey(source: source, id: row.text(1)), project: Self.project(row, from: 5),
                                 title: row.optionalText(2), cwd: row.text(3),
                                 lastAt: Date(timeIntervalSince1970: row.double(4)))
        }.compactMap { $0 }
    }

    public func recentProjects(limit: Int) throws -> [RecentProject] {
        try db.query("""
            SELECT p.id, p.root, p.name, p.display_name, p.kind, MAX(s.last_at), COUNT(*)
            FROM sessions s JOIN projects p ON p.id = s.project_id
            WHERE s.last_at IS NOT NULL
            GROUP BY p.id
            ORDER BY MAX(s.last_at) DESC, p.id
            LIMIT ?
            """, [max(limit, 0)]) { row -> RecentProject? in
            Self.project(row, from: 0).map {
                RecentProject(project: $0, lastActive: Date(timeIntervalSince1970: row.double(5)), sessionCount: row.int(6))
            }
        }.compactMap { $0 }
    }

    public func dailySpend(days: Int, split: SpendSeriesSplit, project: ProjectFilter? = nil, localOnly: Bool = false,
                           now: Date = Date(), calendar: Calendar = .current,
                           scope: MacScope = .thisMac) throws -> DailySpendSeries {
        let count = max(days, 1)
        let start = calendar.startOfDay(for: now)
        let dayStarts = (0...count).compactMap { calendar.date(byAdding: .day, value: $0 - count + 1, to: start) }
        guard dayStarts.count == count + 1 else { return DailySpendSeries(days: [], points: []) }
        let ranges = (0..<count).map { [dayStarts[$0].timeIntervalSince1970, dayStarts[$0 + 1].timeIntervalSince1970] }
        let rangesJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: ranges)) ?? Data("[]".utf8),
                                as: UTF8.self)
        let series = split == .model ? "COALESCE(u.model, '')" : "u.source"
        var filter = "ts >= ? AND ts < ?" + (localOnly ? " AND is_local = 1" : "")
        var values: [any SQLiteBindable] = [dayStarts[0].timeIntervalSince1970, dayStarts[count].timeIntervalSince1970]
        Self.append(project, column: "project_id", to: &filter, values: &values)
        let rows = Self.rows(scope, where: filter, values)
        let points = try db.query("""
            WITH days(idx, start_ts, end_ts) AS (
                SELECT CAST(key AS INTEGER), json_extract(value, '$[0]'), json_extract(value, '$[1]') FROM json_each(?)
            )
            SELECT days.idx, \(series), \(Self.totals(prefix: "u.", scoped: true))
            FROM days JOIN (\(rows.sql)) u ON u.ts >= days.start_ts AND u.ts < days.end_ts
            GROUP BY days.idx, 2
            ORDER BY days.idx, 2
            """, [rangesJSON] + rows.values) { row in
            DailySpendPoint(day: dayStarts[row.int(0)], series: row.text(1), totals: Self.totals(row, from: 2))
        }
        return DailySpendSeries(days: Array(dayStarts.dropLast()), points: points)
    }

    public func spendByProject(in range: DateInterval, scope: MacScope = .thisMac) throws -> [SpendSlice] {
        let rows = Self.rows(scope, where: "ts >= ? AND ts < ?", Self.bounds(range))
        return try db.query("""
            SELECT u.project_id, p.root, p.name, p.display_name, p.kind, \(Self.totals(prefix: "u.", scoped: true)),
                   COUNT(DISTINCT \(Self.sessionIdentity("u.")))
            FROM (\(rows.sql)) u LEFT JOIN projects p ON p.id = u.project_id
            GROUP BY u.project_id
            ORDER BY COALESCE(SUM(u.api_equiv_usd), 0) DESC
            """, rows.values) { row in
            let project = Self.project(row, from: 0)
            return SpendSlice(id: project.map { String($0.id) } ?? "", label: project?.title ?? "Unassigned",
                              project: project, totals: Self.totals(row, from: 5),
                              sessionCount: row.int(5 + Self.totalsColumnCount))
        }
    }

    public func projects(in range: DateInterval, topModels: Int = 3,
                         scope: MacScope = .thisMac) throws -> [ProjectSummary] {
        let rows = Self.rows(scope, where: "ts >= ? AND ts < ?", Self.bounds(range))
        var summaries = try db.query("""
            SELECT u.project_id, p.root, p.name, p.display_name, p.kind, \(Self.totals(prefix: "u.", scoped: true)),
                   COUNT(DISTINCT \(Self.sessionIdentity("u."))), MAX(u.ts), MIN(u.ts)
            FROM (\(rows.sql)) u LEFT JOIN projects p ON p.id = u.project_id
            GROUP BY u.project_id
            ORDER BY COALESCE(SUM(u.api_equiv_usd), 0) DESC, MAX(u.ts) DESC
            """, rows.values) { row in
            ProjectSummary(project: Self.project(row, from: 0), totals: Self.totals(row, from: 5),
                           sessionCount: row.int(5 + Self.totalsColumnCount),
                           firstActive: row.optionalDouble(7 + Self.totalsColumnCount).map(Date.init(timeIntervalSince1970:)),
                           lastActive: row.optionalDouble(6 + Self.totalsColumnCount).map(Date.init(timeIntervalSince1970:)))
        }
        guard !summaries.isEmpty else { return [] }

        var bySource: [Int64?: [AgentSource: LedgerTotals]] = [:]
        for (projectID, source, totals) in try db.query("""
            SELECT project_id, source, \(Self.totals(scoped: true)) FROM (\(rows.sql)) GROUP BY project_id, source
            """, rows.values, { row in (row.optionalInt64(0), AgentSource(rawValue: row.text(1)), Self.totals(row, from: 2)) }) {
            if let source { bySource[projectID, default: [:]][source] = totals }
        }
        var models: [Int64?: [ModelShare]] = [:]
        for (projectID, share) in try db.query("""
            SELECT project_id, COALESCE(model, ''), \(Self.totals(scoped: true)) FROM (\(rows.sql))
            GROUP BY project_id, model
            """, rows.values, { row in (row.optionalInt64(0), ModelShare(model: row.text(1), totals: Self.totals(row, from: 2))) }) {
            models[projectID, default: []].append(share)
        }
        for index in summaries.indices {
            let id = summaries[index].project?.id
            summaries[index].bySource = bySource[id] ?? [:]
            summaries[index].topModels = Array(Self.largestFirst(models[id] ?? []).prefix(max(topModels, 0)))
        }
        return summaries
    }

    public func branches(in range: DateInterval, project: ProjectFilter) throws -> [BranchSummary] {
        var filter = "ts >= ? AND ts < ?"
        var values: [any SQLiteBindable] = Self.bounds(range)
        Self.append(project, column: "project_id", to: &filter, values: &values)
        let rows = Self.rows(.thisMac, where: filter, values)
        var summaries = try db.query("""
            SELECT NULLIF(s.branch, '') AS branch, \(Self.totals(prefix: "u.", scoped: true)),
                   COUNT(DISTINCT \(Self.sessionIdentity("u."))), MAX(u.ts), MIN(u.ts)
            FROM (\(rows.sql)) u LEFT JOIN sessions s ON s.source = u.source AND s.id = u.session_id
            GROUP BY 1
            ORDER BY branch IS NULL, COALESCE(SUM(u.api_equiv_usd), 0) DESC, MAX(u.ts) DESC, branch
            """, rows.values) { row in
            BranchSummary(branch: row.optionalText(0), totals: Self.totals(row, from: 1),
                          sessionCount: row.int(1 + Self.totalsColumnCount),
                          firstActive: row.optionalDouble(3 + Self.totalsColumnCount).map(Date.init(timeIntervalSince1970:)),
                          lastActive: row.optionalDouble(2 + Self.totalsColumnCount).map(Date.init(timeIntervalSince1970:)))
        }
        guard !summaries.isEmpty else { return [] }

        struct Facts {
            var sources: Set<AgentSource> = []
            var added: Int?
            var removed: Int?
            var urls: [(url: String, lastAt: Double)] = []
        }
        var facts: [String?: Facts] = [:]
        for (branch, source, added, removed, url, lastAt) in try db.query("""
            SELECT NULLIF(s.branch, ''), u.source, s.lines_added, s.lines_removed, s.pr_url, COALESCE(s.last_at, 0)
            FROM (SELECT DISTINCT source, session_id FROM (\(rows.sql))) u
            LEFT JOIN sessions s ON s.source = u.source AND s.id = u.session_id
            """, rows.values, { row in
            (row.optionalText(0), AgentSource(rawValue: row.text(1)), row.optionalInt(2), row.optionalInt(3),
             row.optionalText(4), row.double(5))
        }) {
            if let source { facts[branch, default: Facts()].sources.insert(source) }
            if let added { facts[branch, default: Facts()].added = (facts[branch]?.added ?? 0) + added }
            if let removed { facts[branch, default: Facts()].removed = (facts[branch]?.removed ?? 0) + removed }
            if let url { facts[branch, default: Facts()].urls.append((url, lastAt)) }
        }
        for index in summaries.indices {
            let found = facts[summaries[index].branch] ?? Facts()
            summaries[index].sources = AgentSource.allCases.filter(found.sources.contains)
            // A Claude session with a cost record and no line counts stores 0 and 0, so a zero sum is unknown.
            if (found.added ?? 0) + (found.removed ?? 0) > 0 {
                summaries[index].linesAdded = found.added ?? 0
                summaries[index].linesRemoved = found.removed ?? 0
            }
            var seen: Set<String> = []
            summaries[index].prURLs = found.urls.sorted { ($1.lastAt, $0.url) < ($0.lastAt, $1.url) }
                .compactMap { seen.insert($0.url).inserted ? $0.url : nil }
        }
        return summaries
    }

    public func spendByModel(in range: DateInterval, scope: MacScope = .thisMac) throws -> [SpendSlice] {
        let rows = Self.rows(scope, where: "ts >= ? AND ts < ?", Self.bounds(range))
        return try db.query("""
            SELECT COALESCE(model, ''), \(Self.totals(scoped: true)), COUNT(DISTINCT \(Self.sessionIdentity()))
            FROM (\(rows.sql))
            GROUP BY 1
            ORDER BY COALESCE(SUM(api_equiv_usd), 0) DESC
            """, rows.values) { row in
            let model = row.text(0)
            return SpendSlice(id: model, label: model.isEmpty ? "Unknown model" : model,
                              totals: Self.totals(row, from: 1), sessionCount: row.int(1 + Self.totalsColumnCount))
        }
    }

    public func overview(now: Date = Date(), calendar: Calendar = .current,
                         scope: MacScope = .thisMac) throws -> SpendOverview {
        func sum(_ range: DateInterval?) throws -> LedgerTotals {
            let rows = range.map { Self.rows(scope, where: "ts >= ? AND ts < ?", Self.bounds($0)) }
                ?? Self.rows(scope, where: "1", [])
            return try db.queryOne("SELECT \(Self.totals(scoped: true)) FROM (\(rows.sql))", rows.values) {
                Self.totals($0, from: 0)
            } ?? .zero
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
            let limits = try db.query("""
                SELECT id, context_window FROM sessions
                WHERE source = ? AND id IN (SELECT value FROM json_each(?)) AND context_window > 0
                """, [source.rawValue, Self.jsonArray(rows.map(\.key.id))]) { row in (row.text(0), row.int(1)) }
            let windows = Dictionary(limits, uniquingKeysWith: { first, _ in first })
            for var call in rows {
                call.contextLimit = windows[call.key.id]
                result[call.key] = call
            }
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

    public func modelEfficiency(in range: DateInterval, project: ProjectFilter? = nil, pricing: PricingTable,
                                scope: MacScope = .thisMac) throws -> [ModelEfficiency] {
        var filter = "ts >= ? AND ts < ?"
        var values: [any SQLiteBindable] = Self.bounds(range)
        Self.append(project, column: "project_id", to: &filter, values: &values)
        let rows = Self.rows(scope, where: filter, values)
        var models = try db.query("""
            SELECT COALESCE(model, ''), \(Self.totals(scoped: true)) FROM (\(rows.sql))
            GROUP BY 1 ORDER BY COALESCE(SUM(api_equiv_usd), 0) DESC, 1
            """, rows.values) { row in ModelEfficiency(model: row.text(0), totals: Self.totals(row, from: 1)) }
        let fast = try db.query("""
            SELECT COALESCE(model, ''), input, output, reasoning, cache_read, cache_write_5m, cache_write_1h,
                   api_equiv_usd, native_usd, calls, prompt
            FROM (\(rows.sql)) WHERE lower(speed) = 'fast'
            """, rows.values) { row in
            (model: row.text(0),
             tokens: TokenCounts(input: row.int(1), output: row.int(2), reasoning: row.int(3), cacheRead: row.int(4),
                                 cacheWrite5m: row.int(5), cacheWrite1h: row.int(6)),
             usd: row.optionalDouble(7), native: !row.isNull(8), calls: row.int(9), prompt: row.int(10))
        }
        for call in fast {
            guard let index = models.firstIndex(where: { $0.model == call.model }) else { continue }
            models[index].fastCalls += call.calls
            models[index].fastUSD += call.usd ?? 0
            if !call.native, let usd = call.usd,
               let standard = pricing.price(model: call.model, tokens: call.tokens, speed: nil,
                                            promptTokens: call.prompt).apiEquivUSD {
                models[index].fastPremiumUSD += usd - standard
            }
        }
        return models
    }

    public func unpricedModels() throws -> [UnpricedModel] {
        func fold(_ row: SQLiteRow) -> UnpricedModel {
            UnpricedModel(model: row.text(0), calls: row.int(1),
                          tokens: TokenCounts(input: row.int(2), output: row.int(3), reasoning: row.int(4),
                                              cacheRead: row.int(5), cacheWrite5m: row.int(6), cacheWrite1h: row.int(7)),
                          firstSeen: Date(timeIntervalSince1970: row.double(8)),
                          lastSeen: Date(timeIntervalSince1970: row.double(9)))
        }
        let own = try db.query("""
            SELECT COALESCE(model, ''), COUNT(*), SUM(input), SUM(output), SUM(reasoning), SUM(cache_read),
                   SUM(cache_write_5m), SUM(cache_write_1h), MIN(ts), MAX(ts)
            FROM usage WHERE cost_usd IS NULL AND is_local = 0 AND native_usd IS NULL
            GROUP BY 1
            """) { fold($0) }
        let others = try db.query("""
            SELECT COALESCE(model, ''), SUM(calls), SUM(input), SUM(output), SUM(reasoning), SUM(cache_read),
                   SUM(cache_write_5m), SUM(cache_write_1h), MIN(ts), MAX(last_ts)
            FROM remote_usage
            WHERE cost_usd IS NULL AND is_local = 0 AND native_usd IS NULL AND \(Self.counted("remote_usage"))
            GROUP BY 1
            """) { fold($0) }
        var merged: [String: UnpricedModel] = [:]
        for entry in own + others {
            guard var total = merged[entry.model] else {
                merged[entry.model] = entry
                continue
            }
            total.calls += entry.calls
            total.tokens = total.tokens + entry.tokens
            total.firstSeen = [total.firstSeen, entry.firstSeen].compactMap { $0 }.min()
            total.lastSeen = [total.lastSeen, entry.lastSeen].compactMap { $0 }.max()
            merged[entry.model] = total
        }
        return merged.values.sorted { ($1.calls, $0.model) < ($0.calls, $1.model) }
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
            SELECT kind, ts, utilization, resets_at, plan FROM limit_samples WHERE \(filter) ORDER BY ts, kind
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
        let rows = try db.query("SELECT kind, MAX(ts), utilization, resets_at, plan FROM limit_samples GROUP BY kind") {
            Self.limitSample($0)
        }
        return Dictionary(rows.compactMap { $0.map { ($0.kind, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    static func limitSample(_ row: SQLiteRow) -> LimitSample? {
        guard let kind = LimitKind(rawValue: row.text(0)) else { return nil }
        return LimitSample(kind: kind, ts: Date(timeIntervalSince1970: row.double(1)), utilization: row.double(2),
                           resetsAt: row.optionalDouble(3).map(Date.init(timeIntervalSince1970:)),
                           plan: row.optionalText(4))
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

    // `scoped` reads `rows(_:where:)` or `remote_usage`, where one row can stand for several calls.
    private static func totals(prefix p: String = "", scoped: Bool = false) -> String {
        """
        COALESCE(SUM(\(p)cost_usd), 0), COALESCE(SUM(\(p)api_equiv_usd), 0), COALESCE(SUM(\(p)input), 0),
        COALESCE(SUM(\(p)output), 0), COALESCE(SUM(\(p)reasoning), 0), COALESCE(SUM(\(p)cache_read), 0),
        COALESCE(SUM(\(p)cache_write_5m), 0), COALESCE(SUM(\(p)cache_write_1h), 0),
        \(scoped ? "COALESCE(SUM(\(p)calls), 0)" : "COUNT(\(p)id)"),
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
        s.source, s.id, s.title, s.cwd, s.first_at, s.last_at, s.turns, s.native_cost,
        s.lines_added, s.lines_removed, s.pr_url, s.transcript_path, p.id, p.root, p.name, p.display_name, p.kind
        """

    private static let remoteSessionColumns = """
        s.source, s.id, s.title, NULL, s.first_at, s.last_at, 0, NULL,
        NULL, NULL, NULL, NULL, p.id, p.root, p.name, p.display_name, p.kind
        """

    private static func session(_ row: SQLiteRow, from start: Int32) -> SessionSummary? {
        guard let source = AgentSource(rawValue: row.text(start)) else { return nil }
        return SessionSummary(
            key: SessionKey(source: source, id: row.text(start + 1)), project: project(row, from: start + 12),
            title: row.optionalText(start + 2), cwd: row.optionalText(start + 3),
            firstAt: row.optionalDouble(start + 4).map(Date.init(timeIntervalSince1970:)),
            lastAt: row.optionalDouble(start + 5).map(Date.init(timeIntervalSince1970:)), turns: row.int(start + 6),
            totals: totals(row, from: start + 17), nativeCostUSD: row.optionalDouble(start + 7),
            linesAdded: row.optionalInt(start + 8), linesRemoved: row.optionalInt(start + 9),
            prURL: row.optionalText(start + 10), transcriptPath: row.optionalText(start + 11),
            device: start > 0 ? row.optionalText(0) : nil)
    }

    private static let rowColumns = """
        source, session_id, project_id, ts, model, speed, is_local, input, output, reasoning, cache_read,
        cache_write_5m, cache_write_1h, cost_usd, api_equiv_usd, native_cost, native_usd, premium_requests
        """

    // `filter` goes into each arm, not around the UNION, so the ts index still serves it.
    static func rows(_ scope: MacScope, where filter: String,
                     _ values: [any SQLiteBindable]) -> (sql: String, values: [any SQLiteBindable]) {
        var arms: [String] = []
        var bound: [any SQLiteBindable] = []
        if scope.includesThisMac {
            arms.append("""
                SELECT NULL AS device, \(rowColumns), 1 AS calls,
                       input + cache_read + cache_write_5m + cache_write_1h AS prompt
                FROM usage WHERE \(filter)
                """)
            bound += values
        }
        if scope.includesOtherMacs {
            var remoteFilter = "(\(filter)) AND \(counted("remote_usage"))"
            var remoteValues = values
            if case .device(let device) = scope {
                remoteFilter += " AND device = ?"
                remoteValues.append(device)
            }
            arms.append("""
                SELECT device, \(rowColumns), calls,
                       CASE WHEN prompt > 0 THEN prompt ELSE input + cache_read + cache_write_5m + cache_write_1h END
                FROM remote_usage WHERE \(remoteFilter)
                """)
            bound += remoteValues
        }
        return (arms.joined(separator: "\nUNION ALL\n"), bound)
    }

    // A session id seen twice is a copied ledger or the other edition: this Mac's rows win, a remote row counts only
    // past this Mac's last call, then the latest `last_at` among other Macs. Per row, so every scope sums to All Macs.
    static func counted(_ u: String) -> String {
        """
        COALESCE((SELECT MAX(l.ts) FROM usage l WHERE l.source = \(u).source AND l.session_id = \(u).session_id), -1)
            < \(u).ts
        AND NOT EXISTS (SELECT 1 FROM remote_sessions o
            WHERE o.source = \(u).source AND o.id = \(u).session_id AND o.device <> \(u).device
            AND (o.last_at > (SELECT MAX(m.last_at) FROM remote_sessions m WHERE m.device = \(u).device
                              AND m.source = \(u).source AND m.id = \(u).session_id)
                 OR (o.last_at = (SELECT MAX(m.last_at) FROM remote_sessions m WHERE m.device = \(u).device
                                  AND m.source = \(u).source AND m.id = \(u).session_id)
                     AND o.device > \(u).device)))
        """
    }

    static func hasCountedUsage(_ r: String) -> String {
        """
        EXISTS (SELECT 1 FROM remote_usage cu WHERE cu.device = \(r).device AND cu.source = \(r).source
                AND cu.session_id = \(r).id AND \(counted("cu")))
        """
    }

    private static func sessionIdentity(_ p: String = "") -> String {
        "COALESCE(\(p)device, '') || ':' || \(p)source || ':' || \(p)session_id"
    }

    static func remoteSessions(_ scope: MacScope) -> (sql: String, values: [any SQLiteBindable]) {
        var filter = hasCountedUsage("r")
        var values: [any SQLiteBindable] = []
        if case .device(let device) = scope {
            filter += " AND r.device = ?"
            values.append(device)
        }
        return ("""
            SELECT r.device AS device, r.source AS source, r.id AS id, MIN(r.first_at) AS first_at,
                   MAX(r.last_at) AS last_at,
                   (SELECT t.title FROM remote_sessions t WHERE t.device = r.device AND t.source = r.source
                        AND t.id = r.id AND t.title IS NOT NULL ORDER BY t.day DESC, t.part LIMIT 1) AS title,
                   (SELECT t.project_id FROM remote_sessions t WHERE t.device = r.device AND t.source = r.source
                        AND t.id = r.id ORDER BY t.day DESC, t.part LIMIT 1) AS project_id
            FROM remote_sessions r WHERE \(filter)
            GROUP BY r.device, r.source, r.id
            """, values)
    }

    static func project(_ row: SQLiteRow, from start: Int32) -> ProjectRef? {
        guard let id = row.optionalInt64(start) else { return nil }
        return ProjectRef(id: id, root: row.text(start + 1), name: row.text(start + 2),
                          displayName: row.optionalText(start + 3),
                          kind: ProjectKind(rawValue: row.text(start + 4)) ?? .folder)
    }

    private func attachModels(_ summaries: inout [SessionSummary]) throws {
        guard !summaries.isEmpty else { return }
        var shares: [SessionKey: [ModelShare]] = [:]
        var remoteShares: [String: [ModelShare]] = [:]
        for (device, items) in Dictionary(grouping: summaries.filter(\.isRemote), by: { $0.device ?? "" }) {
            for (source, keys) in Dictionary(grouping: items.map(\.key), by: \.source) {
                let rows = try db.query("""
                    SELECT session_id, COALESCE(model, ''), \(Self.totals(scoped: true))
                    FROM remote_usage WHERE device = ? AND source = ? AND session_id IN (SELECT value FROM json_each(?))
                          AND \(Self.counted("remote_usage"))
                    GROUP BY session_id, model
                    """, [device, source.rawValue, Self.jsonArray(keys.map(\.id))]) { row in
                    (row.text(0), ModelShare(model: row.text(1), totals: Self.totals(row, from: 2)))
                }
                for (id, share) in rows {
                    remoteShares["\(device)/\(source.rawValue):\(id)", default: []].append(share)
                }
            }
        }
        for (source, items) in Dictionary(grouping: summaries.filter { !$0.isRemote }.map(\.key), by: \.source) {
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
            let summary = summaries[index]
            summaries[index].models = Self.largestFirst(summary.isRemote ? remoteShares[summary.id] ?? []
                                                                         : shares[summary.key] ?? [])
        }
    }

    private func attachDeviceNames(_ summaries: inout [SessionSummary]) throws {
        guard summaries.contains(where: \.isRemote) else { return }
        let names = Dictionary(try remoteDevices().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for index in summaries.indices {
            if let device = summaries[index].device { summaries[index].deviceName = names[device] ?? nil }
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

    static func jsonArray(_ values: [String]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: values)) ?? Data("[]".utf8), as: UTF8.self)
    }
}
