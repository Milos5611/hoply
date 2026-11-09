import AgentSystem
import Foundation
import XCTest

final class SchemaTests: XCTestCase {
    private func tables(_ db: SQLiteConnection) throws -> Set<String> {
        Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.text(0) })
    }

    func testFreshDatabaseGetsEveryV1Table() throws {
        let directory = try TempDirectory()
        let path = directory.path("hoply.sqlite")
        let db = try SQLiteConnection(path: path)
        try Schema.configure(db)
        try Schema.migrate(db, databasePath: path)
        XCTAssertEqual(try db.userVersion(), Schema.migrations.count)
        XCTAssertEqual(try tables(db), ["projects", "path_map", "sessions", "usage", "ingest_cursors", "samples",
                                        "limit_samples", "state_spans", "cleanup_log"])
        XCTAssertEqual(try db.queryOne("PRAGMA journal_mode") { $0.text(0) }, "wal")
        XCTAssertEqual(try db.queryOne("PRAGMA synchronous") { $0.int(0) }, 1, "NORMAL")
        XCTAssertEqual(try db.queryOne("PRAGMA busy_timeout") { $0.int(0) }, 2000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Backups.slot(1, databasePath: path).path),
                       "an empty database is not backed up")

        try Schema.migrate(db, databasePath: path)
        XCTAssertEqual(try db.userVersion(), Schema.migrations.count, "migrating again is a no-op")
    }

    func testEachLaterMigrationBacksUpFirstAndKeepsTwo() throws {
        let directory = try TempDirectory()
        let path = directory.path("hoply.sqlite")
        let db = try SQLiteConnection(path: path)
        try Schema.configure(db)
        var migrations = Schema.migrations
        try Schema.migrate(db, databasePath: path, migrations: migrations)
        try db.run("INSERT INTO projects (root, name, kind) VALUES ('/a', 'a', 'folder')")

        for step in 1...3 {
            migrations.append("CREATE TABLE extra\(step) (id INTEGER PRIMARY KEY)")
            try Schema.migrate(db, databasePath: path, migrations: migrations)
            XCTAssertEqual(try db.userVersion(), migrations.count)
        }
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: Backups.slot(1, databasePath: path).path))
        XCTAssertTrue(fileManager.fileExists(atPath: Backups.slot(2, databasePath: path).path))
        XCTAssertFalse(fileManager.fileExists(atPath: Backups.slot(3, databasePath: path).path))

        let newest = try SQLiteConnection(path: Backups.slot(1, databasePath: path).path, readOnly: true)
        XCTAssertEqual(try newest.userVersion(), migrations.count - 1, "the backup is the state before the migration")
        XCTAssertEqual(try newest.queryOne("SELECT COUNT(*) FROM projects") { $0.int(0) }, 1)
        let older = try SQLiteConnection(path: Backups.slot(2, databasePath: path).path, readOnly: true)
        XCTAssertEqual(try older.userVersion(), migrations.count - 2)
    }

    func testV2AddsNativePricingAndPremiumColumnsToAFilledV1Ledger() throws {
        let directory = try TempDirectory()
        let path = directory.path("hoply.sqlite")
        let db = try SQLiteConnection(path: path)
        try Schema.configure(db)
        try Schema.migrate(db, databasePath: path, migrations: Array(Schema.migrations.prefix(1)))
        try db.run("""
            INSERT INTO usage (dedupe_key, source, session_id, ts, model, output, cost_usd, api_equiv_usd, pricing_rev)
            VALUES ('cc:a:1', 'claude-code', 's1', 1, 'claude-opus-5-5', 10, 0.5, 0.5, 'rev')
            """)
        try Schema.migrate(db, databasePath: path)
        XCTAssertEqual(try db.userVersion(), 2)
        let row = try XCTUnwrap(db.queryOne("SELECT native_usd, premium_requests, cost_usd FROM usage") {
            ($0.optionalDouble(0), $0.double(1), $0.double(2))
        })
        XCTAssertNil(row.0)
        XCTAssertEqual(row.1, 0)
        XCTAssertEqual(row.2, 0.5)
        let backup = try SQLiteConnection(path: Backups.slot(1, databasePath: path).path, readOnly: true)
        XCTAssertEqual(try backup.userVersion(), 1, "the v1 ledger was backed up before migrating")
    }

    func testFailedMigrationRollsBack() throws {
        let directory = try TempDirectory()
        let path = directory.path("hoply.sqlite")
        let db = try SQLiteConnection(path: path)
        try Schema.migrate(db, databasePath: path)
        let broken = Schema.migrations + ["CREATE TABLE half (id INTEGER); SELEKT nonsense;"]
        XCTAssertThrowsError(try Schema.migrate(db, databasePath: path, migrations: broken))
        XCTAssertEqual(try db.userVersion(), Schema.migrations.count)
        XCTAssertFalse(try tables(db).contains("half"))
    }

    func testStatementsBindAndReadBack() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE t (i INTEGER, r REAL, s TEXT, n TEXT)")
        try db.run("INSERT INTO t VALUES (?, ?, ?, ?)", [Int64.max, 1.5, "it's", String?.none])
        let row = try XCTUnwrap(db.queryOne("SELECT i, r, s, n FROM t") { ($0.int64(0), $0.double(1), $0.text(2), $0.optionalText(3)) })
        XCTAssertEqual(row.0, Int64.max)
        XCTAssertEqual(row.1, 1.5)
        XCTAssertEqual(row.2, "it's")
        XCTAssertNil(row.3)
        XCTAssertThrowsError(try db.transaction { try db.run("INSERT INTO t (i) VALUES (1)"); try db.run("SELEKT") })
        XCTAssertEqual(try db.queryOne("SELECT COUNT(*) FROM t") { $0.int(0) }, 1)
    }
}
