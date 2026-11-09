import AgentKit
import AgentSystem
import Foundation
import XCTest

/// Opt-in: `HOPLY_REAL_TRANSCRIPTS=1 swift test --filter RealTranscriptsTests`. Reads the real `~/.claude`
/// (read-only) into a temporary database and compares ledger totals with Claude Code's own `cost-state`.
final class RealTranscriptsTests: XCTestCase {
    func testLedgerMatchesCostState() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOPLY_REAL_TRANSCRIPTS"] == "1",
                          "Set HOPLY_REAL_TRANSCRIPTS=1 to ingest the real ~/.claude")
        let directory = try TempDirectory()
        let databasePath = directory.path("hoply.sqlite")
        let ledger = try Ledger(configuration: LedgerConfiguration(databasePath: databasePath, pricingOverridesURL: nil,
                                                                   watchForChanges: false))
        let started = Date()
        await ledger.ingest.start()
        let elapsed = Date().timeIntervalSince(started)
        let progress = await ledger.ingest.progress
        print("Ingested \(progress.filesDone)/\(progress.filesTotal) files, \(progress.bytesTotal / 1_000_000) MB in \(String(format: "%.1f", elapsed)) s; error: \(progress.lastError ?? "none")")
        XCTAssertNil(progress.lastError)
        XCTAssertFalse(progress.isBackfilling)

        let costStates = Self.lastCostStates(ClaudeTranscriptIngester())
        let table = PricingTable.bundled()
        let keys = costStates.keys.map { SessionKey(source: .claudeCode, id: $0) }
        let totals = try await ledger.reader.sessionTotals(for: keys)
        let inspector = try SQLiteConnection(path: databasePath, readOnly: true)

        var within = 0
        var compared = 0
        var lines: [String] = []
        for (id, state) in costStates.sorted(by: { $0.key < $1.key }) {
            let localReported = state.models.filter { table.isLocal($0.key) }.reduce(0) { $0 + $1.value.costUSD }
            let reported = state.totalCostUSD - localReported
            guard reported > 0.0001 else { continue }
            compared += 1
            let key = SessionKey(source: .claudeCode, id: id)
            let ledgerCost = totals[key]?.costUSD ?? 0
            let error = (ledgerCost - reported) / reported
            if abs(error) <= 0.02 {
                within += 1
                continue
            }
            let summary = try await ledger.reader.session(key)
            let subagentCost = try inspector.queryOne(
                "SELECT COALESCE(SUM(cost_usd), 0) FROM usage WHERE source = 'claude-code' AND session_id = ? AND sidechain = 1",
                [id]) { $0.double(0) } ?? 0
            lines.append(String(format: "%@  reported %8.4f  ledger %8.4f  %+6.1f%%  subagents %7.4f  %@",
                                String(id.prefix(8)), reported, ledgerCost, error * 100, subagentCost,
                                Self.reason(state: state, summary: summary, table: table, ledgerCost: ledgerCost,
                                            reported: reported)))
        }
        var flagged: [String] = []
        for state in costStates.values {
            for row in PricingCalibration.check(state, table: table) where row.isOff {
                flagged.append("\(row.model) reported \(row.reportedUSD) computed \(row.computedUSD.map { String($0) } ?? "unpriced")")
            }
        }

        // Live sessions (including the one running this test) keep writing, so compare settled history only.
        let settled = DateInterval(start: .distantPast, end: started.addingTimeInterval(-600))
        let firstPass = try await ledger.reader.overview()
        let firstSettled = try await ledger.reader.totalsBySource(in: settled)
        await ledger.ingest.reindex()
        let secondSettled = try await ledger.reader.totalsBySource(in: settled)
        XCTAssertEqual(firstSettled[.claudeCode]?.tokens, secondSettled[.claudeCode]?.tokens)
        XCTAssertEqual(firstSettled[.claudeCode]?.calls, secondSettled[.claudeCode]?.calls)
        XCTAssertEqual(firstSettled[.claudeCode]?.costUSD ?? 0, secondSettled[.claudeCode]?.costUSD ?? -1, accuracy: 1e-6)

        print("Sessions with a cost-state: \(compared); ledger within 2%: \(within)")
        print("Outliers:\n" + lines.joined(separator: "\n"))
        print("Price-level calibration flags: \(flagged.isEmpty ? "none" : flagged.joined(separator: "; "))")
        print("All time: \(String(format: "$%.2f", firstPass.allTime.costUSD)) cost, \(String(format: "$%.2f", firstPass.allTime.apiEquivUSD)) API-equivalent, \(firstPass.allTime.calls) calls, unpriced: \(firstPass.allTime.hasUnpriced)")
        XCTAssertGreaterThanOrEqual(within, 5)
    }

    private static func reason(state: ClaudeCostState, summary: SessionSummary?, table: PricingTable,
                               ledgerCost: Double, reported: Double) -> String {
        var reasons: [String] = []
        if summary?.totals.hasUnpriced == true { reasons.append("unpriced model") }
        let ledgerModels = Dictionary(uniqueKeysWithValues: (summary?.models ?? []).map { ($0.model, $0.totals.tokens) })
        for (model, usage) in state.models where !table.isLocal(model) {
            let logged = ledgerModels[model] ?? TokenCounts()
            let missing = usage.tokens.promptTokens - logged.promptTokens
            if Double(missing) > 0.02 * Double(max(usage.tokens.promptTokens, 1)) {
                reasons.append("\(model): \(missing) prompt tokens billed but not in the transcript")
            } else if Double(-missing) > 0.02 * Double(max(usage.tokens.promptTokens, 1)) {
                reasons.append("\(model): \(-missing) prompt tokens after the last cost-state (resumed or killed)")
            }
        }
        if reasons.isEmpty { reasons.append(ledgerCost > reported ? "usage after the last cost-state" : "unlogged calls") }
        return reasons.joined(separator: "; ")
    }

    /// The last `cost-state` per session, reading files oldest first so later files win.
    private static func lastCostStates(_ ingester: ClaudeTranscriptIngester) -> [String: ClaudeCostState] {
        var states: [String: ClaudeCostState] = [:]
        for file in ingester.discover().reversed() {
            guard let data = FileManager.default.contents(atPath: file.path) else { continue }
            for line in JSONLines.complete(in: data).lines {
                if case .costState(let state) = ClaudeTranscriptParser.item(from: line) { states[state.sessionID] = state }
            }
        }
        return states
    }
}
