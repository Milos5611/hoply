import AgentKit
import AgentSystem
import Foundation
import XCTest

/// Opt-in: `HOPLY_REAL_COPILOT=1 swift test --filter RealCopilotTests`. Copies the real
/// `~/.copilot/session-store.db` (and its `-wal`/`-shm`) into a temp directory, ingests the copy and compares
/// the ledger with Copilot's own sums. `~/.copilot` is only read.
final class RealCopilotTests: XCTestCase {
    func testLedgerMatchesCopilotsOwnSums() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOPLY_REAL_COPILOT"] == "1",
                          "Set HOPLY_REAL_COPILOT=1 to ingest a copy of the real ~/.copilot/session-store.db")
        let real = CopilotStoreIngester()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: real.databasePath), "No \(real.databasePath)")
        let directory = try TempDirectory()
        let home = directory.path("copilot")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: real.databasePath + suffix) {
            try FileManager.default.copyItem(atPath: real.databasePath + suffix,
                                             toPath: home + "/" + CopilotStoreIngester.databaseName + suffix)
        }
        let copy = try SQLiteConnection(path: "file:\(home)/\(CopilotStoreIngester.databaseName)?mode=ro", readOnly: true)
        let expected = try XCTUnwrap(copy.queryOne("""
            SELECT COUNT(*), COALESCE(SUM(total_nano_aiu), 0), COUNT(DISTINCT session_id),
                   (SELECT COALESCE(SUM(m), 0) FROM (SELECT MAX(request_multiplier) m FROM assistant_usage_events
                                                     GROUP BY session_id, turn_index))
            FROM assistant_usage_events
            """) { (calls: $0.int(0), nano: $0.double(1), sessions: $0.int(2), premium: $0.double(3)) })

        let ledger = try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                                   claudeConfigDirectory: directory.path("claude"),
                                                                   copilotHome: home, pricingOverridesURL: nil,
                                                                   watchForChanges: false))
        let started = Date()
        await ledger.ingest.start()
        let elapsed = Date().timeIntervalSince(started)
        let progress = await ledger.ingest.progress
        let totals = try await ledger.reader.totalsBySource(in: DateInterval(start: .distantPast, end: .distantFuture))[.copilotCLI]
            ?? .zero
        let sessions = try await ledger.reader.sessions(in: DateInterval(start: .distantPast, end: .distantFuture),
                                                        source: .copilotCLI, limit: 1000)
        let projects = try await ledger.reader.projects(in: DateInterval(start: .distantPast, end: .distantFuture))

        print("Copilot store: \(progress.copilot), \(expected.calls) events in \(expected.sessions) sessions, read in \(String(format: "%.2f", elapsed)) s")
        print(String(format: "Copilot: $%.4f (%.2f AIU), %.2f premium requests", expected.nano / 1e11, expected.nano / 1e9, expected.premium))
        print(String(format: "Ledger:  $%.4f (%.2f AIU), %.2f premium requests, %d calls, %d sessions, unpriced: %@",
                     totals.costUSD, totals.aiu, totals.premiumRequests, totals.calls, sessions.totalCount,
                     totals.hasUnpriced ? "yes" : "no"))
        for project in projects {
            print(String(format: "  %@  $%.4f  %d sessions  %@", project.title, project.totals.apiEquivUSD, project.sessionCount,
                         project.branches.joined(separator: ", ")))
        }
        XCTAssertEqual(progress.copilot, .ready(schemaVersion: CopilotStoreIngester.knownSchemaVersion))
        XCTAssertEqual(totals.calls, expected.calls)
        XCTAssertEqual(totals.costUSD, expected.nano / 1e11, accuracy: 1e-9)
        XCTAssertEqual(totals.aiu, expected.nano / 1e9, accuracy: 1e-6)
        XCTAssertEqual(totals.premiumRequests, expected.premium, accuracy: 1e-9)
        XCTAssertEqual(sessions.totalCount, expected.sessions)
    }
}
