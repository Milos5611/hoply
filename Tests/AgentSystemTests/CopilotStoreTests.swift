import AgentKit
import AgentSystem
import Foundation
import XCTest

/// A Copilot CLI `session-store.db` in a temp directory, built with the tables Hoply reads, verbatim from
/// schema_version 7.
struct CopilotDatabase {
    static let ddl = """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, repository TEXT, host_type TEXT, branch TEXT, summary TEXT, created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now')));
        CREATE TABLE assistant_usage_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id), turn_index INTEGER, agent_id TEXT, parent_tool_call_id TEXT, model TEXT NOT NULL, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER, total_nano_aiu INTEGER, request_multiplier REAL, duration_ms INTEGER, time_to_first_token_ms INTEGER, output_ttft_ms REAL, inter_token_latency_ms INTEGER, initiator TEXT, api_endpoint TEXT, reasoning_effort TEXT, finish_reason TEXT, content_filter_triggered INTEGER, token_details_json TEXT, created_at TEXT DEFAULT (datetime('now')));
        CREATE TABLE turns (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id), turn_index INTEGER NOT NULL, user_message TEXT, assistant_response TEXT, timestamp TEXT DEFAULT (datetime('now')), UNIQUE(session_id, turn_index));
        INSERT INTO schema_version VALUES (7);
        """

    let home: String
    var path: String { home + "/session-store.db" }

    init(home: String, ddl: String = CopilotDatabase.ddl) throws {
        self.home = home
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let db = try SQLiteConnection(path: home + "/session-store.db")
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute(ddl)
    }

    /// Like Copilot itself, writes and closes; pass `db` to write through a connection that stays open.
    func write(_ sql: String, _ values: [any SQLiteBindable] = [], db: SQLiteConnection? = nil) throws {
        try (db ?? SQLiteConnection(path: path)).run(sql, values)
    }

    func session(_ id: String, cwd: String?, branch: String? = "main", summary: String? = nil,
                 created: String = "2026-09-17T11:00:00.000Z", updated: String = "2026-09-17T11:30:00.000Z") throws {
        try write("INSERT INTO sessions (id, cwd, branch, summary, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                  [id, cwd, branch, summary, created, updated])
    }

    func turn(_ session: String, _ index: Int) throws {
        try write("INSERT INTO turns (session_id, turn_index, user_message) VALUES (?, ?, 'x')", [session, index])
    }

    /// `nano` defaults to Opus 5 prices for the tokens (500 / 50 / 625 / 2500 AIU per 1M); `.some(nil)` stores NULL.
    func event(_ session: String, turn: Int?, multiplier: Double? = 15, model: String = "claude-opus-5",
               uncached: Int = 2, cacheRead: Int = 30_000, cacheWrite: Int = 100, output: Int = 200,
               nano: Int64?? = nil, at created: String, db: SQLiteConnection? = nil) throws {
        let computed = Int64(uncached) * 500_000 + Int64(cacheRead) * 50_000 + Int64(cacheWrite) * 625_000
            + Int64(output) * 2_500_000
        try write("""
            INSERT INTO assistant_usage_events (session_id, turn_index, model, input_tokens, output_tokens,
                cache_read_tokens, cache_write_tokens, reasoning_tokens, total_nano_aiu, request_multiplier, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
            """, [session, turn, model, uncached + cacheRead + cacheWrite, output, cacheRead, cacheWrite,
                  nano ?? computed, multiplier, created], db: db)
    }

    func scalar(_ sql: String) throws -> Double {
        try SQLiteConnection(path: path).queryOne(sql) { $0.double(0) } ?? 0
    }
}

final class CopilotStoreTests: XCTestCase {
    private func makeLedger(_ directory: TempDirectory, copilotHome: String? = nil) throws -> Ledger {
        try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                      claudeConfigDirectory: directory.path("claude"),
                                                      copilotHome: copilotHome ?? directory.path("copilot"),
                                                      pricingOverridesURL: nil, watchForChanges: false))
    }

    /// Two sessions: s1 has turn 0 (×1, ×1) and turn 1 (×15, ×0.33, ×15) = 16 premium requests;
    /// s2 has one ×0.33 turn and a SQLite-format timestamp.
    private func seed(_ copilot: CopilotDatabase, cwd: String) throws {
        try copilot.session("s1", cwd: cwd, summary: "Initialize Project Setup")
        try copilot.session("s2", cwd: "/Users/dev/Project/api", branch: nil, summary: "",
                            created: "2026-09-17 17:44:36", updated: "2026-09-17 17:44:38")
        try copilot.session("idle", cwd: cwd, summary: "never used a model")
        try copilot.turn("s1", 0)
        try copilot.turn("s1", 1)
        try copilot.turn("s2", 0)
        try copilot.event("s1", turn: 0, multiplier: 1, at: "2026-09-17T11:00:05.000Z")
        try copilot.event("s1", turn: 0, multiplier: 1, output: 50, at: "2026-09-17T11:00:09.000Z")
        try copilot.event("s1", turn: 1, multiplier: 15, at: "2026-09-17T11:10:00.000Z")
        try copilot.event("s1", turn: 1, multiplier: 0.33, model: "claude-haiku-4.5", nano: 1_234_000,
                          at: "2026-09-17T11:10:02.000Z")
        try copilot.event("s1", turn: 1, multiplier: 15, cacheWrite: 0, at: "2026-09-17T11:10:30.000Z")
        try copilot.event("s2", turn: 0, multiplier: 0.33, model: "gpt-5.4-mini", nano: 233_388_000,
                          at: "2026-09-17 17:44:37")
    }

    private func copilotTotals(_ ledger: Ledger) async throws -> LedgerTotals {
        try await ledger.reader.totalsBySource(in: DateInterval(start: .distantPast, end: .distantFuture))[.copilotCLI] ?? .zero
    }

    func testTotalsMatchCopilotsOwnFigures() async throws {
        let directory = try TempDirectory()
        try directory.mkdir("corestory/.git")
        let copilot = try CopilotDatabase(home: directory.path("copilot"))
        try seed(copilot, cwd: directory.path("corestory/src"))
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()

        let progress = await ledger.ingest.progress
        XCTAssertEqual(progress.copilot, .ready(schemaVersion: 7))
        XCTAssertNil(progress.lastError)
        let totals = try await copilotTotals(ledger)
        let nano = try copilot.scalar("SELECT SUM(total_nano_aiu) FROM assistant_usage_events")
        XCTAssertEqual(totals.calls, 6)
        XCTAssertEqual(totals.costUSD, nano / 1e11, accuracy: 1e-12)
        XCTAssertEqual(totals.apiEquivUSD, nano / 1e11, accuracy: 1e-12)
        XCTAssertEqual(totals.aiu, nano / 1e9, accuracy: 1e-9)
        XCTAssertEqual(totals.premiumRequests, 16.33, accuracy: 1e-9)
        XCTAssertFalse(totals.hasUnpriced)
        XCTAssertEqual(totals.tokens.input, 12, "uncached input only")
        XCTAssertEqual(totals.tokens.cacheRead, 180_000)

        let s1 = try await ledger.reader.session(SessionKey(source: .copilotCLI, id: "s1"))
        XCTAssertEqual(s1?.title, "Initialize Project Setup")
        XCTAssertEqual(s1?.turns, 2)
        XCTAssertEqual(s1?.branch, "main")
        XCTAssertEqual(s1?.project?.name, "corestory")
        XCTAssertEqual(s1?.project?.kind, .repo)
        XCTAssertEqual(s1?.totals.premiumRequests ?? 0, 16, accuracy: 1e-9)
        XCTAssertEqual(s1?.firstAt, CopilotUsageMapper.date("2026-09-17T11:00:00.000Z"))
        XCTAssertEqual(s1?.lastAt, CopilotUsageMapper.date("2026-09-17T11:30:00.000Z"))
        let s2 = try await ledger.reader.session(SessionKey(source: .copilotCLI, id: "s2"))
        XCTAssertNil(s2?.title)
        XCTAssertEqual(s2?.turns, 1)
        XCTAssertEqual(s2?.firstAt, CopilotUsageMapper.date("2026-09-17 17:44:36"))
        let idle = try await ledger.reader.session(SessionKey(source: .copilotCLI, id: "idle"))
        XCTAssertNil(idle, "sessions without model calls stay out of the ledger")
    }

    func testResumesFromTheCursorAndPicksUpAppendedRows() async throws {
        let directory = try TempDirectory()
        let copilot = try CopilotDatabase(home: directory.path("copilot"))
        try seed(copilot, cwd: directory.path("corestory"))
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()
        var cursor = try await ledger.store.cursors(source: .copilotCLI)[copilot.path]
        XCTAssertEqual(cursor?.offset, 6)

        try copilot.session("s3", cwd: directory.path("corestory"), summary: "Second")
        try copilot.turn("s3", 0)
        try copilot.event("s3", turn: 0, multiplier: 1, at: "2026-09-18T09:00:00.000Z")
        try copilot.write("UPDATE sessions SET summary = 'Renamed', updated_at = '2026-09-18T10:00:00.000Z' WHERE id = 's2'")
        await ledger.pollCopilot()
        cursor = try await ledger.store.cursors(source: .copilotCLI)[copilot.path]
        XCTAssertEqual(cursor?.offset, 7)
        let totals = try await copilotTotals(ledger)
        XCTAssertEqual(totals.calls, 7)
        XCTAssertEqual(totals.premiumRequests, 17.33, accuracy: 1e-9)
        let s2 = try await ledger.reader.session(SessionKey(source: .copilotCLI, id: "s2"))
        XCTAssertEqual(s2?.title, "Renamed", "session metadata is refreshed without new events")

        // A fresh ledger on the same database resumes from the stored cursor.
        let reopened = try makeLedger(directory)
        try copilot.event("s3", turn: 0, multiplier: 1, output: 9, at: "2026-09-18T09:00:04.000Z")
        await reopened.ingest.start()
        let after = try await copilotTotals(reopened)
        XCTAssertEqual(after.calls, 8)
        XCTAssertEqual(after.premiumRequests, 17.33, accuracy: 1e-9, "same turn, same premium request")
    }

    func testRecreatedDatabaseRestartsAtZeroAndKeepsHistory() async throws {
        let directory = try TempDirectory()
        let copilot = try CopilotDatabase(home: directory.path("copilot"))
        try seed(copilot, cwd: directory.path("corestory"))
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()

        try copilot.write("DELETE FROM assistant_usage_events")
        try copilot.write("DELETE FROM sqlite_sequence WHERE name = 'assistant_usage_events'")
        try copilot.event("s1", turn: 5, multiplier: 1, at: "2026-10-01T08:00:00.000Z")
        await ledger.pollCopilot()
        let totals = try await copilotTotals(ledger)
        XCTAssertEqual(totals.calls, 7, "the old rows stay; the new id 1 is read")
        let cursor = try await ledger.store.cursors(source: .copilotCLI)[copilot.path]
        XCTAssertEqual(cursor?.offset, 1)
    }

    func testMissingColumnsReportAnUnsupportedSchema() async throws {
        let directory = try TempDirectory()
        let ddl = CopilotDatabase.ddl.replacingOccurrences(of: "cache_read_tokens INTEGER, ", with: "")
        let copilot = try CopilotDatabase(home: directory.path("copilot"), ddl: ddl)
        try copilot.session("s1", cwd: "/tmp")
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()
        let progress = await ledger.ingest.progress
        guard case .unsupported(let detail) = progress.copilot else {
            return XCTFail("expected an unsupported schema, got \(progress.copilot)")
        }
        XCTAssertTrue(detail.contains("cache_read_tokens"), detail)
        XCTAssertTrue(detail.contains("schema_version 7"), detail)
        XCTAssertNil(progress.lastError)
        let totals = try await copilotTotals(ledger)
        XCTAssertEqual(totals.calls, 0)
    }

    func testMissingDatabaseIsNotFound() async throws {
        let directory = try TempDirectory()
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()
        let progress = await ledger.ingest.progress
        XCTAssertEqual(progress.copilot, .notFound)
    }

    func testIngestingTwiceChangesNothing() async throws {
        let directory = try TempDirectory()
        let copilot = try CopilotDatabase(home: directory.path("copilot"))
        try seed(copilot, cwd: directory.path("corestory"))
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()
        let first = try await copilotTotals(ledger)
        let firstSession = try await ledger.reader.session(SessionKey(source: .copilotCLI, id: "s1"))

        await ledger.ingest.reindex()
        let reindexed = try await copilotTotals(ledger)
        XCTAssertEqual(reindexed, first)
        let reopened = try makeLedger(directory)
        await reopened.ingest.start()
        let restarted = try await copilotTotals(reopened)
        XCTAssertEqual(restarted, first)
        let session = try await reopened.reader.session(SessionKey(source: .copilotCLI, id: "s1"))
        XCTAssertEqual(session, firstSession)
    }

    func testRepricingNeverTouchesNativelyPricedRows() async throws {
        let directory = try TempDirectory()
        let copilot = try CopilotDatabase(home: directory.path("copilot"))
        try seed(copilot, cwd: directory.path("corestory"))
        try copilot.event("s2", turn: 0, multiplier: 0.33, model: "claude-haiku-4.5", nano: .some(nil),
                          at: "2026-09-17T17:44:40.000Z")
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()
        let before = try await copilotTotals(ledger)
        XCTAssertEqual(before.calls, 7)

        let overrides = PricingTable.Document(models: ["claude-opus-5": ModelPrice(input: 50, output: 250),
                                                       "claude-haiku-4-5": ModelPrice(input: 2, output: 10)])
        let repriced = try await ledger.store.setPricing(.bundled(overrides: overrides))
        XCTAssertEqual(repriced, 1, "only the row Copilot did not price")
        let after = try await copilotTotals(ledger)
        let fallback = PricingTable.bundled().price(model: "claude-haiku-4.5",
                                                    tokens: TokenCounts(input: 2, output: 200, cacheRead: 30_000,
                                                                        cacheWrite5m: 100), speed: nil).costUSD ?? 0
        XCTAssertEqual(after.costUSD - before.costUSD, fallback, accuracy: 1e-12, "the table row doubled, nothing else moved")
        XCTAssertEqual(after.aiu, before.aiu)
    }

    func testMissingAIUFallsBackToThePriceTable() async throws {
        let directory = try TempDirectory()
        let copilot = try CopilotDatabase(home: directory.path("copilot"))
        try copilot.session("s1", cwd: directory.path("corestory"))
        try copilot.event("s1", turn: 0, model: "claude-haiku-4.5", nano: .some(nil), at: "2026-09-17T11:00:00.000Z")
        try copilot.event("s1", turn: 1, model: "gpt-9-preview", nano: .some(nil), at: "2026-09-17T11:01:00.000Z")
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()
        let totals = try await copilotTotals(ledger)
        let haiku = PricingTable.bundled().price(model: "claude-haiku-4-5", tokens: TokenCounts(
            input: 2, output: 200, cacheRead: 30_000, cacheWrite5m: 100), speed: nil).costUSD
        XCTAssertEqual(totals.costUSD, try XCTUnwrap(haiku), accuracy: 1e-12)
        XCTAssertTrue(totals.hasUnpriced, "an unknown model is unpriced, never $0")
        XCTAssertEqual(totals.aiu, 0)
    }

    func testReadsWALContentWhileCopilotHoldsTheDatabaseOpen() async throws {
        let directory = try TempDirectory()
        let copilot = try CopilotDatabase(home: directory.path("copilot"))
        let writer = try SQLiteConnection(path: copilot.path)
        try writer.execute("PRAGMA wal_autocheckpoint = 0")
        try copilot.write("INSERT INTO sessions (id, cwd) VALUES ('live', '/tmp')", db: writer)
        try copilot.event("live", turn: 0, at: "2026-09-17T11:00:00.000Z", db: writer)
        let walSize = (try FileManager.default.attributesOfItem(atPath: copilot.path + "-wal")[.size] as? Int) ?? 0
        XCTAssertGreaterThan(walSize, 0, "the rows are only in the WAL")

        let ledger = try makeLedger(directory)
        await ledger.ingest.start()
        let totals = try await copilotTotals(ledger)
        XCTAssertEqual(totals.calls, 1)
        try copilot.event("live", turn: 0, output: 1, at: "2026-09-17T11:00:01.000Z", db: writer)
        await ledger.pollCopilot()
        let after = try await copilotTotals(ledger)
        XCTAssertEqual(after.calls, 2)
    }

    /// Copilot's SQLite removes `-wal`/`-shm` on a clean last close. macOS's SQLite then refuses a `mode=ro` open,
    /// so the main file is read into memory; nothing may appear next to it and its bytes must not change.
    func testDatabaseWithoutWALFilesIsReadFromASnapshotAndLeftUntouched() async throws {
        let directory = try TempDirectory()
        let source = try CopilotDatabase(home: directory.path("source"))
        try seed(source, cwd: directory.path("corestory"))
        let home = directory.path("copilot")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: source.path, toPath: home + "/session-store.db")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: home + "/session-store.db"))
        XCTAssertEqual(bytes[18], 2, "still a WAL-mode database")

        let ledger = try makeLedger(directory, copilotHome: home)
        await ledger.ingest.start()
        let totals = try await copilotTotals(ledger)
        XCTAssertEqual(totals.calls, 6)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home), ["session-store.db"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: home + "/session-store.db")), bytes)
    }

    func testInPlaceReadsNeverWriteTheDatabaseOrItsWAL() async throws {
        let directory = try TempDirectory()
        let copilot = try CopilotDatabase(home: directory.path("copilot"))
        try seed(copilot, cwd: directory.path("corestory"))
        let database = try Data(contentsOf: URL(fileURLWithPath: copilot.path))
        let wal = try Data(contentsOf: URL(fileURLWithPath: copilot.path + "-wal"))
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()
        await ledger.ingest.reindex()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copilot.path)), database)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copilot.path + "-wal")), wal)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: copilot.home)),
                       ["session-store.db", "session-store.db-wal", "session-store.db-shm"])
    }

    func testCopilotChangesReachTheUpdatesStream() async throws {
        let directory = try TempDirectory()
        let copilot = try CopilotDatabase(home: directory.path("copilot"))
        try seed(copilot, cwd: directory.path("corestory"))
        let ledger = try makeLedger(directory)
        let collector = Task { () -> Set<SessionKey> in
            var changed = Set<SessionKey>()
            for await update in ledger.ingest.updates {
                changed.formUnion(update.changedSessions)
                if changed.contains(SessionKey(source: .copilotCLI, id: "s2")) { break }
            }
            return changed
        }
        await ledger.ingest.start()
        let changed = await collector.value
        XCTAssertTrue(changed.contains(SessionKey(source: .copilotCLI, id: "s1")))
    }
}
