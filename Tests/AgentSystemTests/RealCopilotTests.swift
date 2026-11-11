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

    func testEventsFilesNeverDoubleTheStore() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOPLY_REAL_COPILOT"] == "1",
                          "Set HOPLY_REAL_COPILOT=1 to ingest a copy of the real ~/.copilot")
        let real = CopilotStoreIngester()
        let realEvents = CopilotEventsIngester(home: real.home)
        let directory = try TempDirectory()
        let home = directory.path("copilot")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: real.databasePath + suffix) {
            try FileManager.default.copyItem(atPath: real.databasePath + suffix,
                                             toPath: home + "/" + CopilotStoreIngester.databaseName + suffix)
        }
        var fileCalls: [String: Int] = [:]
        var checkpoints: [String: (nano: Double, premium: Double)] = [:]
        for file in realEvents.discover() {
            let folder = URL(fileURLWithPath: file.path).deletingLastPathComponent()
            let id = folder.lastPathComponent
            let target = home + "/session-state/" + id
            try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
            for name in [CopilotEventsIngester.eventsName, CopilotEventsIngester.workspaceName]
            where FileManager.default.fileExists(atPath: folder.path + "/" + name) {
                try FileManager.default.copyItem(atPath: folder.path + "/" + name, toPath: target + "/" + name)
            }
            let lines = JSONLines.complete(in: try Data(contentsOf: URL(fileURLWithPath: target + "/events.jsonl"))).lines
            for line in lines {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let type = object["type"] as? String else { continue }
                if type == "session.usage_record" { fileCalls[id, default: 0] += 1 }
                if type == "session.usage_checkpoint", let data = object["data"] as? [String: Any] {
                    checkpoints[id] = ((data["totalNanoAiu"] as? NSNumber)?.doubleValue ?? 0,
                                       (data["totalPremiumRequests"] as? NSNumber)?.doubleValue ?? 0)
                }
            }
        }
        var storeCalls: [String: Int] = [:]
        if FileManager.default.fileExists(atPath: home + "/" + CopilotStoreIngester.databaseName) {
            let copy = try SQLiteConnection(path: "file:\(home)/\(CopilotStoreIngester.databaseName)?mode=ro",
                                            readOnly: true)
            for (id, calls) in try copy.query("SELECT session_id, COUNT(*) FROM assistant_usage_events GROUP BY 1",
                                              [], { ($0.text(0), $0.int(1)) }) {
                storeCalls[id] = calls
            }
        }

        let ledger = try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                                   claudeConfigDirectory: directory.path("claude"),
                                                                   copilotHome: home, pricingOverridesURL: nil,
                                                                   watchForChanges: false))
        await ledger.ingest.start()
        let progress = await ledger.ingest.progress
        XCTAssertNil(progress.lastError)
        let ids = Set(storeCalls.keys).union(fileCalls.filter { $0.value > 0 }.keys).sorted()
        var expectedCalls = 0
        for id in ids {
            let totals = try await ledger.reader.session(SessionKey(source: .copilotCLI, id: id))?.totals ?? .zero
            let store = storeCalls[id] ?? 0
            let file = fileCalls[id] ?? 0
            let source = store > 0 && totals.calls == store ? "store" : file > 0 && totals.calls == file ? "events" : "?"
            print(String(format: "%@…  store %d  events %d  ledger %d (%@)  $%.4f  %.2f premium%@", String(id.prefix(8)),
                         store, file, totals.calls, source, totals.costUSD, totals.premiumRequests,
                         totals.hasUnpriced ? "  unpriced" : ""))
            XCTAssertNotEqual(source, "?", "\(id): one ledger per session")
            expectedCalls += source == "store" ? store : file
            if store == 0, let point = checkpoints[id] {
                XCTAssertEqual(totals.premiumRequests, point.premium, accuracy: 1e-9, id)
                if !totals.hasUnpriced { XCTAssertEqual(totals.costUSD, point.nano / 1e11, accuracy: 1e-9, id) }
            }
        }
        let all = try await ledger.reader.totalsBySource(in: DateInterval(start: .distantPast, end: .distantFuture))
        XCTAssertEqual(all[.copilotCLI]?.calls ?? 0, expectedCalls)
    }
}
