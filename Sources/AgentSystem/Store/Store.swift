import AgentKit
import Foundation

/// The single writer of the usage ledger. Usage rows are only ever upserted, never deleted, because
/// Claude Code removes its own transcripts after about 30 days.
public actor Store {
    public static var defaultDatabaseURL: URL {
        URL.applicationSupportDirectory.appending(path: "Hoply/hoply.sqlite")
    }

    public nonisolated let databasePath: String
    private let db: SQLiteConnection
    private let registry: ProjectRegistry
    public private(set) var pricing: PricingTable

    public init(path: String = Store.defaultDatabaseURL.path, pricing: PricingTable = .bundled(),
                resolver: ProjectResolver = ProjectResolver(home: NSHomeDirectory()),
                fileSystem: any ProjectFileSystem & Sendable = LocalProjectFileSystem()) throws {
        if Backups.isPersistent(path) {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        let db = try SQLiteConnection(path: path)
        try Schema.configure(db)
        try Schema.migrate(db, databasePath: path)
        if try db.queryOne("SELECT EXISTS (SELECT 1 FROM usage)", [], { $0.bool(0) }) == true {
            try? Backups.rotateIfDue(db, databasePath: path, keep: 2, interval: 7 * 86_400)
        }
        _ = try Self.reprice(db, pricing)
        self.db = db
        self.databasePath = path
        self.pricing = pricing
        self.registry = ProjectRegistry(resolver: resolver, fileSystem: fileSystem)
    }

    /// Writes one batch and, if given, the cursor that produced it, atomically. Returns the sessions touched.
    @discardableResult
    public func apply(_ batch: LedgerBatch, cursor: IngestCursor? = nil) throws -> Set<SessionKey> {
        try db.transaction {
            var touched = Set<SessionKey>()
            for update in batch.sessions {
                try upsert(update)
                touched.insert(update.key)
            }
            var turns = Set<CopilotTurn>()
            for record in batch.usage {
                try upsert(record)
                touched.insert(SessionKey(source: record.source, id: record.sessionID))
                if record.requestMultiplier != nil {
                    turns.insert(CopilotTurn(source: record.source, session: record.sessionID, turn: record.turnIndex))
                }
            }
            for turn in turns { try bookPremiumRequests(turn) }
            if let cursor { try save(cursor) }
            return touched
        }
    }

    /// The project each cwd belongs to, resolving (and recording in `path_map`) cwds seen for the first time.
    public func projects(forCwds cwds: [String]) throws -> [String: ProjectRef] {
        let wanted = Set(cwds.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return [:] }
        let ids = wanted.allSatisfy { registry.cachedEntry(for: $0) != nil }
            ? try projectIDs(wanted)
            : try db.transaction { try projectIDs(wanted) }
        let rows = try db.query("""
            SELECT id, root, name, display_name, kind FROM projects WHERE id IN (SELECT value FROM json_each(?))
            """, [Self.jsonArray(Set(ids.values).map { $0 })]) { row in
            ProjectRef(id: row.int64(0), root: row.text(1), name: row.text(2), displayName: row.optionalText(3),
                       kind: ProjectKind(rawValue: row.text(4)) ?? .folder)
        }
        let refs = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMapValues { refs[$0] }
    }

    private func projectIDs(_ cwds: Set<String>) throws -> [String: Int64] {
        var ids: [String: Int64] = [:]
        for cwd in cwds { ids[cwd] = try registry.entry(for: cwd, db: db).projectID }
        return ids
    }

    /// Every row priced natively (`native_usd`) keeps its price; the rest are re-priced by `setPricing`.
    public static let nativePricingRevision = "native"

    public func cursors(source: AgentSource) throws -> [String: FileCursor] {
        let rows = try db.query("SELECT path, inode, size, offset, head_hash FROM ingest_cursors WHERE source = ?",
                                [source.rawValue]) { row in
            (row.text(0), FileCursor(inode: UInt64(bitPattern: row.int64(1)), size: row.int64(2),
                                     offset: row.int64(3), headHash: UInt64(bitPattern: row.int64(4))))
        }
        return Dictionary(rows, uniquingKeysWith: { _, last in last })
    }

    /// "Reindex": every file is read again from the start. Ledger rows stay; the upserts make re-reading safe.
    public func resetCursors(source: AgentSource) throws {
        try db.run("UPDATE ingest_cursors SET offset = 0, size = 0, head_hash = 0 WHERE source = ?", [source.rawValue])
    }

    /// Swaps the price table and re-prices every row priced under another revision, in one transaction.
    @discardableResult
    public func setPricing(_ table: PricingTable) throws -> Int {
        pricing = table
        return try Self.reprice(db, table)
    }

    // MARK: - Writes

    private static let upsertSession = """
        INSERT INTO sessions (source, id, project_id, cwd, branch, worktree, title, title_rank, pr_url, first_at,
                              last_at, turns, native_cost, lines_added, lines_removed, transcript_path)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
        ON CONFLICT(source, id) DO UPDATE SET
            project_id = CASE WHEN ?17 AND excluded.project_id IS NOT NULL THEN excluded.project_id
                              ELSE COALESCE(sessions.project_id, excluded.project_id) END,
            worktree = CASE WHEN (?17 AND excluded.cwd IS NOT NULL) OR sessions.cwd IS NULL THEN excluded.worktree
                            ELSE sessions.worktree END,
            cwd = CASE WHEN ?17 AND excluded.cwd IS NOT NULL THEN excluded.cwd ELSE COALESCE(sessions.cwd, excluded.cwd) END,
            branch = CASE WHEN ?17 AND excluded.branch IS NOT NULL THEN excluded.branch
                          ELSE COALESCE(sessions.branch, excluded.branch) END,
            title = CASE WHEN excluded.title IS NOT NULL AND excluded.title_rank >= sessions.title_rank
                         THEN excluded.title ELSE sessions.title END,
            title_rank = CASE WHEN excluded.title IS NOT NULL AND excluded.title_rank >= sessions.title_rank
                              THEN excluded.title_rank ELSE sessions.title_rank END,
            pr_url = COALESCE(excluded.pr_url, sessions.pr_url),
            first_at = min(COALESCE(excluded.first_at, sessions.first_at), COALESCE(sessions.first_at, excluded.first_at)),
            last_at = max(COALESCE(excluded.last_at, sessions.last_at), COALESCE(sessions.last_at, excluded.last_at)),
            turns = CASE WHEN ?18 THEN excluded.turns ELSE sessions.turns + excluded.turns END,
            native_cost = COALESCE(excluded.native_cost, sessions.native_cost),
            lines_added = COALESCE(excluded.lines_added, sessions.lines_added),
            lines_removed = COALESCE(excluded.lines_removed, sessions.lines_removed),
            transcript_path = COALESCE(excluded.transcript_path, sessions.transcript_path)
        """

    private func upsert(_ update: SessionUpdate) throws {
        let entry = try update.cwd.map { try registry.entry(for: $0, db: db) }
        try db.run(Self.upsertSession, [
            update.key.source.rawValue, update.key.id, entry?.projectID, update.cwd, update.branch, entry?.worktree,
            update.title, update.titleRank, update.prURL, update.firstAt?.timeIntervalSince1970,
            update.lastAt?.timeIntervalSince1970, update.prompts, update.nativeCostUSD, update.linesAdded,
            update.linesRemoved, update.transcriptPath, update.placeIsAuthoritative, update.resetsTurns,
        ])
        if let projectID = entry?.projectID, let lastAt = update.lastAt {
            try db.run("UPDATE projects SET last_active = max(COALESCE(last_active, 0), ?) WHERE id = ?",
                       [lastAt.timeIntervalSince1970, projectID])
        }
    }

    /// When the same call shows up under two sessions (Claude Code copies earlier messages into a continued
    /// session's file), the session that started first keeps it, whichever file was read first.
    private static let upsertUsage = """
        INSERT INTO usage (dedupe_key, source, session_id, project_id, ts, model, is_local, sidechain, agent_id,
                           input, output, reasoning, cache_read, cache_write_5m, cache_write_1h, speed,
                           native_cost, request_multiplier, turn_index, native_usd)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)
        ON CONFLICT(dedupe_key) DO UPDATE SET
            ts = min(usage.ts, excluded.ts),
            model = COALESCE(usage.model, excluded.model),
            agent_id = COALESCE(usage.agent_id, excluded.agent_id),
            input = max(usage.input, excluded.input),
            output = max(usage.output, excluded.output),
            reasoning = max(usage.reasoning, excluded.reasoning),
            cache_read = max(usage.cache_read, excluded.cache_read),
            cache_write_5m = max(usage.cache_write_5m, excluded.cache_write_5m),
            cache_write_1h = max(usage.cache_write_1h, excluded.cache_write_1h),
            speed = COALESCE(usage.speed, excluded.speed),
            native_cost = COALESCE(max(usage.native_cost, excluded.native_cost), usage.native_cost, excluded.native_cost),
            native_usd = COALESCE(max(usage.native_usd, excluded.native_usd), usage.native_usd, excluded.native_usd),
            request_multiplier = COALESCE(max(usage.request_multiplier, excluded.request_multiplier),
                                          usage.request_multiplier, excluded.request_multiplier),
            turn_index = COALESCE(usage.turn_index, excluded.turn_index),
            session_id = CASE WHEN \(startedEarlier) THEN excluded.session_id ELSE usage.session_id END,
            project_id = CASE WHEN \(startedEarlier) THEN excluded.project_id
                              ELSE COALESCE(usage.project_id, excluded.project_id) END
        RETURNING id, model, input, output, reasoning, cache_read, cache_write_5m, cache_write_1h, speed,
                  native_usd, cost_usd, api_equiv_usd, is_local, pricing_rev
        """

    private static let startedEarlier = """
        (SELECT first_at FROM sessions WHERE source = excluded.source AND id = excluded.session_id)
          < (SELECT first_at FROM sessions WHERE source = usage.source AND id = usage.session_id)
        """

    private func upsert(_ record: UsageRecord) throws {
        let projectID = try record.cwd.map { try registry.entry(for: $0, db: db).projectID }
        let tokens = record.tokens
        let stored = try db.queryOne(Self.upsertUsage, [
            record.dedupeKey, record.source.rawValue, record.sessionID, projectID, record.timestamp.timeIntervalSince1970,
            record.model, pricing.isLocal(record.model), record.isSidechain, record.agentID,
            tokens.input, tokens.output, tokens.reasoning, tokens.cacheRead, tokens.cacheWrite5m, tokens.cacheWrite1h,
            record.speed, record.nativeCost, record.requestMultiplier, record.turnIndex, record.nativeUSD,
        ]) { row in
            (id: row.int64(0), priced: Self.priced(row, pricing: pricing),
             cost: row.optionalDouble(10), apiEquiv: row.optionalDouble(11), isLocal: row.bool(12),
             revision: row.optionalText(13), native: !row.isNull(9))
        }
        guard let stored else { return }
        let priced = stored.priced
        let revision = stored.native ? Self.nativePricingRevision : pricing.revision
        if stored.revision != revision || stored.cost != priced.costUSD || stored.apiEquiv != priced.apiEquivUSD
            || stored.isLocal != priced.isLocal {
            try db.run("UPDATE usage SET cost_usd = ?, api_equiv_usd = ?, is_local = ?, pricing_rev = ? WHERE id = ?",
                       [priced.costUSD, priced.apiEquivUSD, priced.isLocal, revision, stored.id])
        }
    }

    private struct CopilotTurn: Hashable {
        var source: AgentSource
        var session: String
        var turn: Int?
    }

    /// A turn is one premium request times its highest multiplier, however many calls it made. That amount is
    /// booked on the turn's earliest call (others get 0), so range and project totals stay plain sums. A call
    /// with no turn index counts on its own.
    private func bookPremiumRequests(_ turn: CopilotTurn) throws {
        guard let index = turn.turn else {
            try db.run("""
                UPDATE usage SET premium_requests = COALESCE(request_multiplier, 0)
                WHERE source = ? AND session_id = ? AND turn_index IS NULL AND request_multiplier IS NOT NULL
                """, [turn.source.rawValue, turn.session])
            return
        }
        try db.run("""
            UPDATE usage SET premium_requests = CASE
                WHEN id = (SELECT id FROM usage WHERE source = ?1 AND session_id = ?2 AND turn_index = ?3
                           AND request_multiplier IS NOT NULL ORDER BY ts, dedupe_key LIMIT 1)
                THEN (SELECT MAX(request_multiplier) FROM usage WHERE source = ?1 AND session_id = ?2
                      AND turn_index = ?3 AND request_multiplier IS NOT NULL)
                ELSE 0 END
            WHERE source = ?1 AND session_id = ?2 AND turn_index = ?3 AND request_multiplier IS NOT NULL
            """, [turn.source.rawValue, turn.session, index])
    }

    private func save(_ cursor: IngestCursor) throws {
        try db.run("""
            INSERT INTO ingest_cursors (source, path, inode, size, offset, head_hash) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(source, path) DO UPDATE SET
                inode = excluded.inode, size = excluded.size, offset = excluded.offset, head_hash = excluded.head_hash
            """, [cursor.source.rawValue, cursor.path, Int64(bitPattern: cursor.file.inode), cursor.file.size,
                  cursor.file.offset, Int64(bitPattern: cursor.file.headHash)])
    }

    /// Columns 1…9 of the row must be model, the six token columns, speed and native_usd.
    private static func priced(_ row: SQLiteRow, pricing: PricingTable) -> PricedUsage {
        if let native = row.optionalDouble(9) {
            return PricedUsage(costUSD: native, apiEquivUSD: native, isLocal: false)
        }
        let tokens = TokenCounts(input: row.int(2), output: row.int(3), reasoning: row.int(4), cacheRead: row.int(5),
                                 cacheWrite5m: row.int(6), cacheWrite1h: row.int(7))
        return pricing.price(model: row.optionalText(1), tokens: tokens, speed: row.optionalText(8))
    }

    private static func reprice(_ db: SQLiteConnection, _ pricing: PricingTable) throws -> Int {
        let stale = try db.queryOne("SELECT 1 FROM usage WHERE pricing_rev IS NOT ? AND native_usd IS NULL LIMIT 1",
                                    [pricing.revision]) { _ in true }
        guard stale == true else { return 0 }
        return try db.transaction {
            let rows = try db.query("""
                SELECT id, model, input, output, reasoning, cache_read, cache_write_5m, cache_write_1h, speed, native_usd
                FROM usage WHERE pricing_rev IS NOT ? AND native_usd IS NULL
                """, [pricing.revision]) { row in (row.int64(0), priced(row, pricing: pricing)) }
            for (id, priced) in rows {
                try db.run("UPDATE usage SET cost_usd = ?, api_equiv_usd = ?, is_local = ?, pricing_rev = ? WHERE id = ?",
                           [priced.costUSD, priced.apiEquivUSD, priced.isLocal, pricing.revision, id])
            }
            return rows.count
        }
    }
}

extension Store {
    static func jsonArray(_ values: [Int64]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: values)) ?? Data("[]".utf8), as: UTF8.self)
    }
}

public struct IngestCursor: Sendable, Equatable {
    public var source: AgentSource
    public var path: String
    public var file: FileCursor

    public init(source: AgentSource, path: String, file: FileCursor) {
        self.source = source
        self.path = path
        self.file = file
    }
}
