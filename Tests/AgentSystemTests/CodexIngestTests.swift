import AgentKit
import AgentSystem
import Foundation
import XCTest

final class CodexIngestTests: XCTestCase {
    private let threadID = "019c0000-0000-7000-8000-000000000001"
    private var key: SessionKey { SessionKey(source: .codexCLI, id: threadID) }
    private var rolloutFile: String { "codex/sessions/2026/11/10/rollout-2026-11-10T10-00-00-\(threadID).jsonl" }
    private var archivedFile: String { "codex/archived_sessions/rollout-2026-11-10T10-00-00-\(threadID).jsonl" }

    private func line(_ time: String, _ type: String, _ payload: String) -> String {
        #"{"timestamp":"\#(time)","type":"\#(type)","payload":\#(payload)}"# + "\n"
    }

    private func tokens(_ time: String, input: Int, cached: Int, output: Int) -> String {
        line(time, "event_msg", #"{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(input + output)},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0},"model_context_window":258400},"rate_limits":null}"#)
    }

    private var head: String {
        line("2026-11-10T10:00:00.000Z", "session_meta",
             #"{"id":"\#(threadID)","timestamp":"2026-11-10T10:00:00.000Z","cwd":"/Users/dev/Project/demo","originator":"codex_cli_rs","cli_version":"0.144.6","source":"cli","model_provider":"openai","git":{"branch":"main"}}"#)
            + line("2026-11-10T10:00:01.000Z", "event_msg", #"{"type":"task_started","turn_id":"t1"}"#)
            + line("2026-11-10T10:00:01.100Z", "turn_context", #"{"cwd":"/Users/dev/Project/demo","model":"gpt-6.1-sol"}"#)
            + line("2026-11-10T10:00:01.200Z", "response_item", #"{"type":"message","role":"user","content":[{"type":"input_text","text":"x"}]}"#)
    }

    private func makeLedger(_ directory: TempDirectory) throws -> Ledger {
        try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                      claudeConfigDirectory: directory.path("claude"),
                                                      copilotHome: directory.path("copilot"),
                                                      pricingOverridesURL: nil, watchForChanges: false,
                                                      codexHome: directory.path("codex")))
    }

    func testBackfillTailRelaunchArchiveAndReindex() async throws {
        let directory = try TempDirectory()
        try directory.write(rolloutFile, head
                            + tokens("2026-11-10T10:00:05.000Z", input: 1_000, cached: 600, output: 40)
                            + tokens("2026-11-10T10:00:05.500Z", input: 1_000, cached: 600, output: 40)
                            + tokens("2026-11-10T10:00:09.000Z", input: 2_500, cached: 1_600, output: 90))
        try directory.write("codex/history.jsonl", #"{"session_id":"x","text":"x"}"# + "\n")
        try directory.write("codex/sessions/2026/11/10/notes.jsonl", head)

        var ledger = try makeLedger(directory)
        await ledger.ingest.start()
        var summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals.calls, 2)
        XCTAssertEqual(summary?.totals.tokens, TokenCounts(input: 900, output: 90, cacheRead: 1_600))
        XCTAssertEqual(summary?.turns, 1)
        XCTAssertEqual(summary?.transcriptPath?.hasSuffix(rolloutFile), true)
        XCTAssertEqual(summary?.totals.hasUnpriced, false)
        let expected = (900 * 2.0 + 90 * 10.0 + 1_600 * 0.1) / 1_000_000
        XCTAssertEqual(try XCTUnwrap(summary?.totals.apiEquivUSD), expected, accuracy: 1e-12)
        let progress = await ledger.ingest.progress
        XCTAssertEqual(progress.filesTotal, 1)
        XCTAssertNil(progress.lastError)

        try directory.append(rolloutFile, tokens("2026-11-10T10:01:00.000Z", input: 3_000, cached: 2_000, output: 100))
        await ledger.ingest.tailTranscript(atPath: directory.path(rolloutFile))
        summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals.calls, 3)
        XCTAssertEqual(summary?.totals.tokens, TokenCounts(input: 1_000, output: 100, cacheRead: 2_000))

        // A relaunch tails from the saved cursor: the model and the previous total come from the lines before it.
        await ledger.ingest.stop()
        ledger = try makeLedger(directory)
        await ledger.ingest.start()
        try directory.append(rolloutFile, line("2026-11-10T10:02:00.000Z", "event_msg", #"{"type":"task_started","turn_id":"t2"}"#)
                             + tokens("2026-11-10T10:02:05.000Z", input: 3_500, cached: 2_400, output: 130))
        await ledger.ingest.tailTranscript(atPath: directory.path(rolloutFile))
        summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals.calls, 4)
        XCTAssertEqual(summary?.totals.tokens, TokenCounts(input: 1_100, output: 130, cacheRead: 2_400))
        XCTAssertEqual(summary?.totals.hasUnpriced, false, "the tail kept the model")
        XCTAssertEqual(summary?.turns, 2)
        let settled = summary?.totals

        try FileManager.default.createDirectory(atPath: directory.path("codex/archived_sessions"),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: directory.path(rolloutFile), toPath: directory.path(archivedFile))
        await ledger.ingest.rescan()
        summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals, settled, "an archived rollout is the same calls")

        await ledger.ingest.reindex()
        summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals, settled)
        XCTAssertEqual(summary?.turns, 2)
    }

    func testRolloutPathShapes() throws {
        let directory = try TempDirectory()
        let ingester = CodexRolloutIngester(home: directory.path("codex"))
        let home = ingester.home
        XCTAssertTrue(ingester.isRollout(home + "/sessions/2026/11/10/rollout-2026-11-10T10-00-00-\(threadID).jsonl"))
        XCTAssertTrue(ingester.isRollout(home + "/archived_sessions/rollout-2026-11-10T10-00-00-\(threadID).jsonl"))
        XCTAssertFalse(ingester.isRollout(home + "/sessions/2026/11/rollout-x.jsonl"))
        XCTAssertFalse(ingester.isRollout(home + "/sessions/2026/11/10/history.jsonl"))
        XCTAssertFalse(ingester.isRollout(home + "/history.jsonl"))
        XCTAssertFalse(ingester.isRollout("/elsewhere/sessions/2026/11/10/rollout-x.jsonl"))
    }
}
