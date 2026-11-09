@testable import AgentKit
import XCTest

final class SessionBoardTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let claude = SessionKey(source: .claudeCode, id: "abc123")

    private func hook(_ kind: AgentEvent.Kind, at seconds: TimeInterval, key: SessionKey? = nil) -> AgentEvent {
        AgentEvent(key: key ?? claude, kind: kind, time: t0.addingTimeInterval(seconds),
                   cwd: "/Users/milos/Project/fiba", fromHook: true)
    }

    private func telemetry(_ kind: AgentEvent.Kind, at seconds: TimeInterval, key: SessionKey? = nil) -> AgentEvent {
        AgentEvent(key: key ?? claude, kind: kind, time: t0.addingTimeInterval(seconds), fromHook: false)
    }

    func testClaudeLifecycle() throws {
        var board = SessionBoard()
        board.apply(hook(.sessionStarted, at: 0))
        XCTAssertEqual(board.sessions[claude]?.state, .idle)
        XCTAssertEqual(board.sessions[claude]?.project, "fiba")

        board.apply(hook(.promptSubmitted("Fix the flaky login test\nand explain why"), at: 1))
        XCTAssertEqual(board.sessions[claude]?.state, .working)
        XCTAssertEqual(board.sessions[claude]?.title, "Fix the flaky login test")

        board.apply(hook(.toolStarted("Bash"), at: 2))
        XCTAssertEqual(board.sessions[claude]?.lastTool, "Bash")

        let permission = try XCTUnwrap(board.apply(hook(.needsPermission("Allow Bash?"), at: 3)))
        XCTAssertEqual(permission.from, .working)
        XCTAssertEqual(permission.to, .needsPermission)

        board.apply(hook(.toolFinished("Bash"), at: 10))
        XCTAssertEqual(board.sessions[claude]?.state, .working)

        let done = try XCTUnwrap(board.apply(hook(.turnFinished("Added an await."), at: 60)))
        XCTAssertEqual(done.to, .yourTurn)
        XCTAssertEqual(done.previousDuration, 50, accuracy: 0.001)
        XCTAssertEqual(board.sessions[claude]?.lastMessage, "Added an await.")

        // The idle reminder 60 s later is not a new state change.
        XCTAssertNil(board.apply(hook(.waitingForInput("Claude is waiting for your input"), at: 120)))

        board.apply(hook(.sessionEnded("prompt_input_exit"), at: 130))
        XCTAssertEqual(board.sessions[claude]?.state, .ended)
    }

    func testDelayedTelemetryDoesNotOverrideHookState() {
        var board = SessionBoard()
        board.apply(hook(.promptSubmitted("Hi"), at: 0))
        board.apply(hook(.turnFinished(nil), at: 10))
        board.apply(telemetry(.usage(.init(inputTokens: 100, outputTokens: 20, costUSD: 0.01)), at: 12))
        board.apply(telemetry(.toolFinished("Read"), at: 12))
        XCTAssertEqual(board.sessions[claude]?.state, .yourTurn)
        XCTAssertEqual(board.sessions[claude]?.inputTokens, 100)
        XCTAssertEqual(board.sessions[claude]?.outputTokens, 20)
        XCTAssertEqual(board.sessions[claude]?.costUSD ?? 0, 0.01, accuracy: 1e-9)
    }

    func testTelemetryOnlySessionGoesIdleAfterSilence() {
        var board = SessionBoard()
        let qwen = SessionKey(source: .qwenCode, id: "q1")
        board.apply(telemetry(.activity, at: 0, key: qwen))
        XCTAssertEqual(board.sessions[qwen]?.state, .working)
        XCTAssertTrue(board.tick(now: t0.addingTimeInterval(30)).isEmpty)
        let changes = board.tick(now: t0.addingTimeInterval(60))
        XCTAssertEqual(changes.map(\.to), [.idle])
        XCTAssertEqual(board.sessions[qwen]?.state, .idle)
    }

    func testEndedAndStaleSessionsAreRemoved() {
        var board = SessionBoard()
        board.apply(hook(.sessionEnded(nil), at: 0))
        let other = SessionKey(source: .copilotCLI, id: "cp")
        board.apply(hook(.promptSubmitted("x"), at: 0, key: other))
        board.tick(now: t0.addingTimeInterval(601))
        XCTAssertNil(board.sessions[claude])
        XCTAssertNotNil(board.sessions[other])
        board.tick(now: t0.addingTimeInterval(5 * 3600))
        XCTAssertNil(board.sessions[other])
    }

    func testEndedSessionIgnoresLateEvents() {
        var board = SessionBoard()
        board.apply(hook(.sessionEnded(nil), at: 0))
        board.apply(hook(.toolFinished("Bash"), at: 1))
        XCTAssertEqual(board.sessions[claude]?.state, .ended)
    }

    func testOrderingPutsAttentionFirst() {
        var board = SessionBoard()
        let a = SessionKey(source: .claudeCode, id: "a")
        let b = SessionKey(source: .copilotCLI, id: "b")
        let c = SessionKey(source: .claudeCode, id: "c")
        board.apply(hook(.promptSubmitted("working"), at: 5, key: a))
        board.apply(hook(.turnFinished(nil), at: 1, key: b))
        board.apply(hook(.needsPermission(nil), at: 0, key: c))
        XCTAssertEqual(board.ordered.map(\.key.id), ["c", "b", "a"])
    }

    func testTitleIgnoresRedactedPrompts() {
        XCTAssertNil(SessionBoard.title(from: "<REDACTED>"))
        XCTAssertNil(SessionBoard.title(from: "<agent-message from=\"a402ec81\">\nreport"))
        XCTAssertNil(SessionBoard.title(from: "<task-notification>x</task-notification>"))
        XCTAssertNil(SessionBoard.title(from: "<command-name>/clear</command-name>"))
        XCTAssertEqual(SessionBoard.title(from: "Fix <Button> padding"), "Fix <Button> padding")
        XCTAssertNil(SessionBoard.title(from: "   \n  "))
        XCTAssertEqual(SessionBoard.title(from: String(repeating: "a", count: 100))?.count, 80)
    }
}

final class PrometheusAndVLLMTests: XCTestCase {
    func testTensorfoldEngineUsesVLLMNamesUnderItsPrefix() throws {
        let samples = PrometheusParser.parse(try Fixture.text("tensorfold_metrics.txt"))
        XCTAssertEqual(VLLMSnapshot.engine(of: samples), "tensorfold")
        let snapshot = VLLMSnapshot.from(samples: samples, at: Date())
        XCTAssertEqual(snapshot.engine, "tensorfold")
        XCTAssertNil(snapshot.model)
        XCTAssertEqual(snapshot.running, 0)
        XCTAssertEqual(snapshot.waiting, 0)
        XCTAssertEqual(snapshot.kvCacheUsage, 0)
        XCTAssertEqual(snapshot.promptTokensTotal, 7_725_987)
        XCTAssertEqual(snapshot.generationTokensTotal, 54_353)
        XCTAssertNil(VLLMSnapshot.engine(of: PrometheusParser.parse("python_gc_objects_collected_total 1")))
    }

    func testTensorfoldRateCountsTokensOfLiveStreams() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func snapshot(total: Int, running: Int, at seconds: TimeInterval) -> VLLMSnapshot {
            let text = "tensorfold:generation_tokens_total \(total)\ntensorfold:generation_tokens_running \(running)\n"
            return VLLMSnapshot.from(samples: PrometheusParser.parse(text), at: t0.addingTimeInterval(seconds))
        }
        let start = snapshot(total: 100, running: 50, at: 0)
        let decoding = snapshot(total: 100, running: 300, at: 5)
        let finished = snapshot(total: 400, running: 0, at: 10)
        XCTAssertEqual(VLLMStatus.compute(previous: start, current: decoding).generationTokensPerSecond, 50)
        XCTAssertEqual(VLLMStatus.compute(previous: decoding, current: finished).generationTokensPerSecond, 0)
    }

    func testParsesVLLMMetrics() throws {
        let samples = PrometheusParser.parse(try Fixture.text("vllm_metrics.txt"))
        XCTAssertEqual(samples.count, 9)
        let kv = try XCTUnwrap(samples.first { $0.name == "vllm:kv_cache_usage_perc" })
        XCTAssertEqual(kv.value, 0.4375)
        XCTAssertEqual(kv.labels["model_name"], "Qwen/Qwen3-Coder-30B-A3B-Instruct")
        let infBucket = try XCTUnwrap(samples.first { $0.labels["le"] == "+Inf" })
        XCTAssertEqual(infBucket.value, 310)
    }

    func testSnapshotAndRates() throws {
        let samples = PrometheusParser.parse(try Fixture.text("vllm_metrics.txt"))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = VLLMSnapshot.from(samples: samples, at: t0.addingTimeInterval(10))
        XCTAssertEqual(snapshot.model, "Qwen/Qwen3-Coder-30B-A3B-Instruct")
        XCTAssertEqual(snapshot.running, 2)
        XCTAssertEqual(snapshot.waiting, 1)
        XCTAssertEqual(snapshot.kvCacheUsage, 0.4375)
        XCTAssertEqual(snapshot.generationTokensTotal, 45_000)

        var previous = snapshot
        previous.takenAt = t0
        previous.generationTokensTotal = 44_000
        previous.promptTokensTotal = 110_000
        let status = VLLMStatus.compute(previous: previous, current: snapshot)
        XCTAssertEqual(status.generationTokensPerSecond ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(status.promptTokensPerSecond ?? -1, 1_000, accuracy: 0.001)

        previous.generationTokensTotal = 90_000  // server restarted: counter went down
        XCTAssertNil(VLLMStatus.compute(previous: previous, current: snapshot).generationTokensPerSecond)
    }

    func testLegacyCacheMetricAndEscapedLabels() {
        let text = """
        vllm:gpu_cache_usage_perc{model_name="a \\"quoted\\" model"} 0.25
        vllm:num_requests_running 3
        """
        let samples = PrometheusParser.parse(text)
        XCTAssertEqual(samples.first?.labels["model_name"], "a \"quoted\" model")
        let snapshot = VLLMSnapshot.from(samples: samples, at: Date())
        XCTAssertEqual(snapshot.kvCacheUsage, 0.25)
        XCTAssertEqual(snapshot.running, 3)
    }
}

final class ClaudeLimitsTests: XCTestCase {
    func testDecodesUsageWindows() throws {
        let limits = try ClaudeLimits.decode(try Fixture.data("claude_usage.json"))
        XCTAssertEqual(limits.fiveHour?.utilization, 62)
        let fiveHourReset = try XCTUnwrap(limits.fiveHour?.resetsAt)
        XCTAssertEqual(fiveHourReset.timeIntervalSince1970, 1_794_238_800, accuracy: 1)
        XCTAssertEqual(limits.sevenDay?.utilization, 25)
        XCTAssertEqual(limits.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_794_556_800))
        XCTAssertEqual(limits.sevenDayOpus?.resetsAt, Date(timeIntervalSince1970: 1_794_643_200))
        XCTAssertNil(limits.sevenDaySonnet)
    }

    func testAccessTokenFromKeychainJSON() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = Data("{\"claudeAiOauth\":{\"accessToken\":\"tok\",\"expiresAt\":1800000100000}}".utf8)
        XCTAssertEqual(try ClaudeLimits.accessToken(fromCredentials: valid, now: now), "tok")

        let expired = Data("{\"claudeAiOauth\":{\"accessToken\":\"tok\",\"expiresAt\":1799999000000}}".utf8)
        XCTAssertThrowsError(try ClaudeLimits.accessToken(fromCredentials: expired, now: now)) { error in
            XCTAssertEqual(error as? ClaudeLimitsError, .tokenExpired)
        }
        XCTAssertThrowsError(try ClaudeLimits.accessToken(fromCredentials: Data("{}".utf8), now: now)) { error in
            XCTAssertEqual(error as? ClaudeLimitsError, .noCredentials)
        }
    }
}
