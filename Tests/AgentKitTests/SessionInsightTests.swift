@testable import AgentKit
import XCTest

final class HookMapperInputTests: XCTestCase {
    private func events(_ name: String) throws -> [AgentEvent] {
        let json = try XCTUnwrap(Fixture.hookPayloads("claude_hooks.json")[name], name)
        return HookMapper.events(source: .claudeCode, eventName: nil, json: json)
    }

    private func kinds(_ name: String) throws -> [AgentEvent.Kind] { try events(name).map(\.kind) }

    func testAQuestionIsInputNotPermission() throws {
        XCTAssertEqual(try kinds("AskUserQuestion"), [.questionAsked("x?")])
        XCTAssertEqual(try kinds("AskUserQuestionPermission"), [.questionAsked("x?")])
        XCTAssertEqual(try kinds("AskUserQuestionAnswered"), [.toolFinished("AskUserQuestion")])
        XCTAssertEqual(try kinds("PermissionRequest"), [.needsPermission("Allow Bash?")])
        XCTAssertEqual(try kinds("PermissionNotification"), [.needsPermission("Claude needs your permission to use Bash")])
        XCTAssertEqual(HookMapper.notification(["notification_type": "permission_prompt",
                                                "message": "Claude needs your permission to use AskUserQuestion"]),
                       .questionAsked("Claude needs your permission to use AskUserQuestion"))
    }

    func testElicitation() throws {
        XCTAssertEqual(try kinds("Elicitation"), [.questionAsked("x")])
        XCTAssertEqual(try kinds("ElicitationNotification"), [.questionAsked("x")])
        XCTAssertEqual(try kinds("ElicitationResult"), [.activity])
        XCTAssertEqual(try kinds("ElicitationResponseNotification"), [.activity])
        XCTAssertEqual(try kinds("IdleNotification"), [.waitingForInput("Claude is waiting for your input")])
    }

    func testSubagentHooks() throws {
        XCTAssertEqual(try kinds("SubagentStart"), [.subagentStarted(id: "agent-abc123", type: "Explore")])
        XCTAssertEqual(try kinds("SubagentStop"), [.subagentStopped(id: "agent-abc123", type: "Explore")])
        XCTAssertEqual(try kinds("InternalSubagentStop"), [.subagentStopped(id: "internal-1", type: nil)])
        let inside = try XCTUnwrap(events("SubagentPreToolUse").first)
        XCTAssertEqual(inside.kind, .toolStarted("Grep"))
        XCTAssertEqual(inside.agentID, "agent-abc123")
        XCTAssertEqual(inside.agentType, "Explore")
        XCTAssertNil(try events("PreToolUse").first?.agentID)
        XCTAssertEqual(HookMapper.events(source: .claudeCode, eventName: "SubagentStart", json: ["session_id": "s"]), [])
    }

    func testStopFailureEndsTheTurn() throws {
        XCTAssertEqual(try kinds("StopFailure"),
                       [.turnFailed(error: "rate_limit", message: "API Error: Rate limit reached")])
        XCTAssertEqual(HookMapper.events(source: .copilotCLI, eventName: "errorOccurred",
                                         json: ["sessionId": "c", "error": "boom"]).map(\.kind), [.error("boom")])
    }
}

final class SessionInsightBoardTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = SessionKey(source: .claudeCode, id: "abc123")
    private var board = SessionBoard()

    @discardableResult
    private func hook(_ kind: AgentEvent.Kind, at seconds: TimeInterval, agent: String? = nil,
                      cwd: String = "/r/fiba") -> StateChange? {
        board.apply(AgentEvent(key: key, kind: kind, time: t0.addingTimeInterval(seconds), cwd: cwd, fromHook: true,
                               agentID: agent, agentType: agent == nil ? nil : "Explore"))
    }

    private var session: AgentSession { board.sessions[key]! }

    func testQuestionIsYourTurnWithInputUntilAnswered() throws {
        hook(.promptSubmitted("Go"), at: 0)
        let asked = try XCTUnwrap(hook(.questionAsked("Which framework?"), at: 5))
        XCTAssertEqual(asked.to, .yourTurn)
        XCTAssertTrue(asked.session.awaitsInput)
        XCTAssertEqual(SessionStatus(session), .input)
        XCTAssertEqual(session.lastMessage, "Which framework?")

        XCTAssertNil(hook(.questionAsked("Which framework?"), at: 6), "the permission-shaped repeat is no new change")
        XCTAssertNil(hook(.waitingForInput("Claude is waiting for your input"), at: 70))
        XCTAssertTrue(session.awaitsInput, "the idle reminder does not close the question")

        hook(.toolFinished("AskUserQuestion"), at: 80)
        XCTAssertEqual(session.state, .working)
        XCTAssertFalse(session.awaitsInput)

        hook(.turnFinished("Done"), at: 90)
        XCTAssertEqual(SessionStatus(session), .yourTurn)
    }

    func testTelemetryCannotOpenAQuestionOnAHookSession() {
        hook(.promptSubmitted("Go"), at: 0)
        board.apply(AgentEvent(key: key, kind: .questionAsked("?"), time: t0.addingTimeInterval(1), fromHook: false))
        XCTAssertEqual(session.state, .working)
        XCTAssertFalse(session.awaitsInput)
    }

    func testTurnFailureWaitsOnTheUserAndKeepsTheErrorType() {
        hook(.promptSubmitted("Go"), at: 0)
        hook(.turnFailed(error: "rate_limit", message: "API Error: Rate limit reached"), at: 40)
        XCTAssertEqual(session.state, .yourTurn)
        XCTAssertEqual(session.failure, "rate_limit")
        XCTAssertEqual(session.lastMessage, "API Error: Rate limit reached")
        hook(.promptSubmitted("Again"), at: 50)
        XCTAssertNil(session.failure)
    }

    func testSubagentsAreCountedAndNeverChangeTheParentsPlace() {
        hook(.promptSubmitted("Go"), at: 0)
        XCTAssertNil(hook(.subagentStarted(id: "a1", type: "Explore"), at: 1))
        hook(.subagentStarted(id: "a2", type: "general-purpose"), at: 2)
        hook(.toolStarted("Grep"), at: 3, agent: "a3", cwd: "/r/fiba/.claude/worktrees/w1")
        XCTAssertEqual(session.subagents.map(\.id), ["a1", "a2", "a3"])
        XCTAssertEqual(session.workingSubagentCount, 3)
        XCTAssertEqual(session.cwd, "/r/fiba", "a subagent's worktree is not the session's cwd")
        XCTAssertNil(session.lastTool)

        hook(.subagentStopped(id: "a1", type: "Explore"), at: 10)
        XCTAssertEqual(session.workingSubagentCount, 2)
        XCTAssertEqual(session.subagents.count, 3)
        XCTAssertEqual(session.subagents[0].endedAt, t0.addingTimeInterval(10))
        XCTAssertEqual(session.state, .working)

        hook(.subagentStopped(id: "internal-1", type: nil), at: 11)
        XCTAssertEqual(session.subagents.count, 3, "Claude Code's internal agents are not subagents")
        hook(.subagentStopped(id: "early", type: "Plan"), at: 12)
        XCTAssertEqual(session.subagents.count, 4, "one that started before Hoply did still counts")
        XCTAssertEqual(session.workingSubagentCount, 2)

        hook(.subagentStarted(id: "a1", type: "Explore"), at: 13)
        XCTAssertEqual(session.workingSubagentCount, 3, "a resumed subagent works again")
        XCTAssertEqual(session.subagents.count, 4)

        hook(.sessionEnded(nil), at: 20)
        XCTAssertEqual(session.workingSubagentCount, 0)
    }

    func testBackgroundSubagentDoesNotReopenAFinishedTurn() {
        hook(.promptSubmitted("Go"), at: 0)
        hook(.subagentStarted(id: "bg", type: "Explore"), at: 1)
        hook(.turnFinished("Started it"), at: 5)
        XCTAssertNil(hook(.toolStarted("Grep"), at: 6, agent: "bg"))
        XCTAssertNil(hook(.toolFinished("Grep"), at: 7, agent: "bg"))
        XCTAssertEqual(session.state, .yourTurn)

        XCTAssertEqual(hook(.needsPermission("Allow Bash?"), at: 8, agent: "bg")?.to, .needsPermission)
        XCTAssertEqual(hook(.toolFinished("Bash"), at: 9, agent: "bg")?.to, .yourTurn)

        XCTAssertNil(hook(.subagentStopped(id: "bg", type: "Explore"), at: 10))
        XCTAssertEqual(session.state, .yourTurn)
        hook(.promptSubmitted("<task-notification>"), at: 11)
        XCTAssertEqual(hook(.toolStarted("Read"), at: 12, agent: "other")?.to, nil)
        XCTAssertEqual(session.state, .working)
    }

    func testForegroundSubagentKeepsTheParentWorkingAfterAPermission() {
        hook(.promptSubmitted("Go"), at: 0)
        hook(.needsPermission("Allow Bash?"), at: 2, agent: "fg")
        XCTAssertEqual(hook(.toolFinished("Bash"), at: 3, agent: "fg")?.to, .working)
    }

    func testSubagentListIsCapped() {
        hook(.promptSubmitted("Go"), at: 0)
        for index in 0..<(AgentSession.maxSubagents + 5) {
            hook(.subagentStarted(id: "a\(index)", type: "Explore"), at: Double(index))
            hook(.subagentStopped(id: "a\(index)", type: "Explore"), at: Double(index) + 0.5)
        }
        XCTAssertEqual(session.subagents.count, AgentSession.maxSubagents)
        XCTAssertEqual(session.subagents.last?.id, "a\(AgentSession.maxSubagents + 4)")
    }
}

final class StatusPriorityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var board = SessionBoard()

    @discardableResult
    private func add(_ id: String, _ kinds: [AgentEvent.Kind], source: AgentSource = .claudeCode,
                              model: String? = nil, at seconds: TimeInterval = 0) -> SessionKey {
        let key = SessionKey(source: source, id: id)
        for kind in kinds {
            board.apply(AgentEvent(key: key, kind: kind, time: t0.addingTimeInterval(seconds), cwd: "/r/\(id)",
                                   model: model, fromHook: true))
        }
        return key
    }

    private func full(_ kind: LimitKind = .fiveHour, resetsIn seconds: TimeInterval = 3600,
                      utilization: Double = 100) -> LimitSample {
        LimitSample(kind: kind, ts: t0, utilization: utilization, resetsAt: t0.addingTimeInterval(seconds))
    }

    func testOrder() {
        let until = t0.addingTimeInterval(60)
        let order: [SessionStatus] = [.permission, .input, .limited(until: until), .yourTurn, .working, .idle, .ended]
        XCTAssertEqual(order.map(\.priority), Array(0..<7))
        XCTAssertEqual(order.shuffled().sorted { $0.priority < $1.priority }, order)
        XCTAssertEqual(order.filter(\.recedes), [.limited(until: until), .idle, .ended])
        XCTAssertEqual(order.filter(\.needsAction), [.permission, .input, .yourTurn])
        XCTAssertEqual(order.map(\.label), ["Permission", "Input", "Limited", "Your turn", "Working", "Idle", "Ended"])
    }

    func testBoardOrderPutsInputBetweenPermissionAndYourTurn() {
        add("turn", [.promptSubmitted("a"), .turnFinished(nil)], at: 30)
        add("input", [.promptSubmitted("a"), .questionAsked("?")], at: 10)
        add("work", [.promptSubmitted("a")], at: 40)
        add("perm", [.promptSubmitted("a"), .needsPermission("Allow?")], at: 0)
        add("idle", [.sessionStarted], at: 50)
        XCTAssertEqual(board.ordered.map(\.key.id), ["perm", "input", "turn", "work", "idle"])
    }

    func testLimitedIsDerivedFromAWaitingClaudeSessionAndAFullWindow() {
        let turn = add("turn", [.promptSubmitted("a"), .turnFinished(nil)])
        let work = add("work", [.promptSubmitted("a")])
        let input = add("input", [.promptSubmitted("a"), .questionAsked("?")])
        let copilot = add("cp", [.promptSubmitted("a"), .turnFinished(nil)], source: .copilotCLI)
        let local = add("local", [.sessionStarted, .promptSubmitted("a"), .turnFinished(nil)], model: "Qwen3-coder")
        let sessions = board.sessions
        let now = t0.addingTimeInterval(10)
        func status(_ key: SessionKey, _ limits: [LimitSample]) -> SessionStatus {
            SessionStatus(sessions[key]!, limits: limits, localModelPatterns: ["qwen"], now: now)
        }

        XCTAssertEqual(status(turn, [full()]), .limited(until: t0.addingTimeInterval(3600)))
        XCTAssertEqual(status(turn, [full(utilization: 99.4)]), .yourTurn)
        XCTAssertEqual(status(turn, [full(resetsIn: 5)]), .yourTurn, "a stale reading of a window that has reset")
        XCTAssertEqual(status(turn, []), .yourTurn)
        XCTAssertEqual(status(work, [full()]), .working)
        XCTAssertEqual(status(input, [full()]), .input)
        XCTAssertEqual(status(copilot, [full()]), .yourTurn)
        XCTAssertEqual(status(local, [full()]), .yourTurn)

        XCTAssertEqual(status(turn, [full(), full(.sevenDay, resetsIn: 86_400)]),
                       .limited(until: t0.addingTimeInterval(86_400)), "the window that resets last holds it")
        let newer = LimitSample(kind: .fiveHour, ts: t0.addingTimeInterval(5), utilization: 3,
                                resetsAt: t0.addingTimeInterval(18_000))
        XCTAssertEqual(status(turn, [full(), newer]), .yourTurn, "only each window's latest reading counts")
    }

    func testModelScopedWindowHoldsOnlyThatModel() {
        let opus = add("opus", [.sessionStarted, .promptSubmitted("a"), .turnFinished(nil)], model: "claude-opus-5-5")
        let sonnet = add("sonnet", [.sessionStarted, .promptSubmitted("a"), .turnFinished(nil)], model: "claude-sonnet-5")
        let unknown = add("unknown", [.promptSubmitted("a"), .turnFinished(nil)])
        let limits = [full(.sevenDayOpus, resetsIn: 7200)]
        let sessions = board.sessions
        XCTAssertNotNil(LimitedSessions.limitedUntil(sessions[opus]!, limits: limits, now: t0))
        XCTAssertNil(LimitedSessions.limitedUntil(sessions[sonnet]!, limits: limits, now: t0))
        XCTAssertNil(LimitedSessions.limitedUntil(sessions[unknown]!, limits: limits, now: t0))
    }

    func testEachAgentIsHeldOnlyByItsOwnProvidersLimits() throws {
        let claude = add("claude", [.promptSubmitted("a"), .turnFinished(nil)])
        let codex = add("codex", [.promptSubmitted("a"), .turnFinished(nil)], source: .codexCLI, model: "gpt-6.1-sol")
        let oss = add("oss", [.promptSubmitted("a"), .turnFinished(nil)], source: .codexCLI, model: "qwen3-coder")
        let copilot = add("copilot", [.promptSubmitted("a"), .turnFinished(nil)], source: .copilotCLI)
        let sessions = board.sessions
        let codexFive = full(try XCTUnwrap(LimitKind.codex(windowMinutes: 300)))
        let codexMonth = full(try XCTUnwrap(LimitKind.codex(windowMinutes: 43_200)), resetsIn: 20 * 86_400)
        let codeName = full(try XCTUnwrap(LimitKind.codex(windowMinutes: 300, limitID: "codex_bengalfox")))
        func until(_ key: SessionKey, _ limits: [LimitSample]) -> Date? {
            LimitedSessions.limitedUntil(sessions[key]!, limits: limits, localModelPatterns: ["qwen"], now: t0)
        }

        XCTAssertEqual(until(codex, [codexFive]), t0.addingTimeInterval(3600))
        XCTAssertEqual(until(codex, [codexFive, codexMonth]), t0.addingTimeInterval(20 * 86_400))
        XCTAssertNil(until(codex, [full()]), "Claude's windows never hold a Codex session")
        XCTAssertNil(until(claude, [codexFive]), "nor Codex's a Claude session")
        XCTAssertEqual(until(claude, [full(), codexMonth]), t0.addingTimeInterval(3600))
        XCTAssertNil(until(codex, [codeName]), "a limit id names no model, so it holds nothing")
        XCTAssertNil(until(oss, [codexFive]), "a local model draws on no plan")
        XCTAssertNil(until(copilot, [full(), codexFive]))
        XCTAssertNil(until(codex, [full(try XCTUnwrap(LimitKind.codex(windowMinutes: 300)), resetsIn: -1)]))
    }

    func testGroupingSortsWaitingByStatusPriority() {
        add("turn", [.promptSubmitted("a"), .turnFinished(nil)], source: .copilotCLI, at: 50)
        add("limited", [.promptSubmitted("a"), .turnFinished(nil)], at: 40)
        add("input", [.promptSubmitted("a"), .questionAsked("?")], at: 10)
        add("perm", [.promptSubmitted("a"), .needsPermission("Allow?")], at: 0)
        add("work", [.promptSubmitted("a")], at: 60)
        let ordered = board.ordered
        XCTAssertEqual(SessionGrouping(sessions: ordered).waiting.map(\.key.id), ["perm", "input", "turn", "limited"])

        let grouping = SessionGrouping(sessions: ordered, limits: [full()], now: t0.addingTimeInterval(70))
        XCTAssertEqual(grouping.waiting.map(\.key.id), ["perm", "input", "limited", "turn"])
        XCTAssertEqual(grouping.projects.map(\.name), ["work"])
        XCTAssertEqual(grouping.waiting.map { grouping.status(of: $0).label }, ["Permission", "Input", "Limited", "Your turn"])
        XCTAssertEqual(grouping.limitedUntil.count, 1)
    }
}

final class ContextWindowTests: XCTestCase {
    func testWindowPerModel() {
        XCTAssertEqual(ContextWindow.limit(model: "claude-opus-4-6"), 200_000)
        XCTAssertEqual(ContextWindow.limit(model: "claude-sonnet-4-6"), 200_000)
        XCTAssertEqual(ContextWindow.limit(model: "claude-haiku-4-5-20251001"), 200_000)
        XCTAssertEqual(ContextWindow.limit(model: "claude-opus-4-6[1m]"), 1_000_000)
        XCTAssertEqual(ContextWindow.limit(model: "claude-opus-4-6", liveModel: "claude-opus-4-6[1m]"), 1_000_000)
        XCTAssertEqual(ContextWindow.limit(model: "claude-opus-4-7"), 1_000_000)
        XCTAssertEqual(ContextWindow.limit(model: "claude-opus-5-5"), 1_000_000)
        XCTAssertEqual(ContextWindow.limit(model: "claude-sonnet-5"), 1_000_000)
        XCTAssertEqual(ContextWindow.limit(model: "claude-haiku-5-5"), 1_000_000)
        XCTAssertEqual(ContextWindow.limit(model: "us.anthropic.claude-fable-5-1-v1:0"), 1_000_000)
        XCTAssertEqual(ContextWindow.limit(model: "claude-opus-4-6", used: 240_000), 1_000_000,
                       "a prompt past 200k proves the larger window")
    }

    func testUnknownWindows() {
        XCTAssertNil(ContextWindow.limit(model: "qwen3-coder"))
        XCTAssertNil(ContextWindow.limit(model: "gpt-5.2"))
        XCTAssertNil(ContextWindow.limit(model: nil))
        XCTAssertNil(ContextWindow.limit(model: ""))
        XCTAssertNil(ContextWindow(used: 1000, model: "Qwen/Qwen3.8-Flash-Next", liveModel: "qwen"))
    }

    func testUsedIsTheLastCallsPromptAndWarnsFrom80Percent() throws {
        let key = SessionKey(source: .claudeCode, id: "s")
        func window(input: Int, read: Int, write5m: Int = 0, write1h: Int = 0, output: Int = 9000) -> ContextWindow? {
            ContextWindow(lastCall: SessionLastCall(key: key, model: "claude-opus-4-6", timestamp: Date(),
                                                    tokens: TokenCounts(input: input, output: output, cacheRead: read,
                                                                        cacheWrite5m: write5m, cacheWrite1h: write1h)))
        }
        let half = try XCTUnwrap(window(input: 10, read: 90_000, write5m: 4_000, write1h: 5_990))
        XCTAssertEqual(half.used, 100_000, "output is not part of the context sent")
        XCTAssertEqual(half.limit, 200_000)
        XCTAssertEqual(half.fraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.remaining, 100_000)
        XCTAssertFalse(half.isWarning)

        XCTAssertFalse(try XCTUnwrap(window(input: 159_999, read: 0)).isWarning)
        XCTAssertTrue(try XCTUnwrap(window(input: 0, read: 160_000)).isWarning)
        XCTAssertEqual(ContextWindow(used: 300, limit: 200).fraction, 1)
        XCTAssertEqual(ContextWindow(used: 300, limit: 200).remaining, 0)
    }

    func testAReportedWindowCountsTheWholeLastCall() throws {
        let key = SessionKey(source: .codexCLI, id: "c")
        let tokens = TokenCounts(input: 4_000, output: 1_200, reasoning: 300, cacheRead: 200_000)
        let window = try XCTUnwrap(ContextWindow(lastCall: SessionLastCall(key: key, model: "gpt-6.1-sol",
                                                                            timestamp: Date(), tokens: tokens,
                                                                            contextLimit: 258_400)))
        XCTAssertEqual(window.used, 205_200, "Codex's tokens_in_context_window is the call's total_tokens")
        XCTAssertEqual(window.limit, 258_400)
        XCTAssertFalse(window.isWarning)
        XCTAssertNil(ContextWindow(lastCall: SessionLastCall(key: key, model: "gpt-6.1-sol", timestamp: Date(),
                                                             tokens: tokens)),
                     "without a reported window a Codex model has no known limit")
        let busy = TokenCounts(input: 10_000, output: 2_000, cacheRead: 200_000)
        XCTAssertTrue(try XCTUnwrap(ContextWindow(lastCall: SessionLastCall(key: key, model: nil, timestamp: Date(),
                                                                            tokens: busy, contextLimit: 258_400))).isWarning)
    }
}

final class LiveSubagentActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = SessionKey(source: .codexCLI, id: "root")

    private func activity(_ id: String, ended: Bool, at seconds: TimeInterval, session: SessionKey? = nil) -> SubagentActivity {
        SubagentActivity(session: session ?? key, agentID: id, type: "Hume", time: t0.addingTimeInterval(seconds),
                         ended: ended)
    }

    func testRolloutActivityUpdatesALiveSessionAndNeverCreatesOne() throws {
        var board = SessionBoard()
        XCTAssertFalse(board.noteSubagents([activity("t1", ended: false, at: 1)]))
        XCTAssertTrue(board.sessions.isEmpty)

        board.apply(AgentEvent(key: key, kind: .promptSubmitted("Go"), time: t0, fromHook: true))
        XCTAssertTrue(board.noteSubagents([activity("t1", ended: false, at: 1), activity("t2", ended: false, at: 2)]))
        var session = try XCTUnwrap(board.sessions[key])
        XCTAssertEqual(session.subagents.map(\.id), ["t1", "t2"])
        XCTAssertEqual(session.subagents.map(\.type), ["Hume", "Hume"])
        XCTAssertEqual(session.workingSubagentCount, 2)
        XCTAssertEqual(session.state, .working, "subagent activity never moves the session")

        XCTAssertTrue(board.noteSubagents([activity("t1", ended: true, at: 5)]))
        XCTAssertFalse(board.noteSubagents([activity("t1", ended: true, at: 5)]), "a repeat changes nothing")
        session = try XCTUnwrap(board.sessions[key])
        XCTAssertEqual(session.subagents.first?.endedAt, t0.addingTimeInterval(5))
        XCTAssertEqual(session.workingSubagentCount, 1)
        XCTAssertTrue(board.noteSubagents([activity("t1", ended: false, at: 9)]))
        XCTAssertEqual(board.sessions[key]?.workingSubagentCount, 2, "a later turn works again")

        board.apply(AgentEvent(key: key, kind: .sessionEnded(nil), time: t0.addingTimeInterval(20), fromHook: true))
        XCTAssertFalse(board.noteSubagents([activity("t3", ended: false, at: 21)]))
        XCTAssertEqual(board.sessions[key]?.subagents.count, 2)
    }
}

final class MonogramTests: XCTestCase {
    func testLetters() {
        let cases: [(String, String)] = [
            ("hoply", "H"), ("yasm-backend", "YB"), ("yasm_backend", "YB"), ("yasm.backend.api", "YB"),
            ("yasmBackend", "YB"), ("HTTPServer", "HS"), ("Mobile UI", "MU"), ("fiba", "F"), ("fiba2", "F2"),
            ("v2", "V2"), ("3d-engine", "3D"), ("2048", "2"), ("UI", "UI"), ("API", "A"), (".github", "G"),
            ("@scope/pkg", "SP"), ("проект", "П"), ("мой проект", "МП"), ("東京", "東京"), ("東京プロジェクト", "東"),
            ("🚀 launch", "🚀"), ("launch 🚀", "L"), ("", "?"), ("   ", "?"), ("---", "?"), ("Unassigned", "U"),
        ]
        for (title, expected) in cases {
            XCTAssertEqual(Monogram.letters(for: title), expected, title)
        }
    }

    func testPaletteIndexIsStableAndInRange() {
        XCTAssertEqual(Monogram.paletteIndex(for: "/Users/dev/Project/hoply", count: 8),
                       Int(FNV1a.hash64("/Users/dev/Project/hoply".utf8) % 8))
        XCTAssertEqual(Monogram.paletteIndex(for: "hoply", count: 8), Monogram.paletteIndex(for: "hoply", count: 8))
        XCTAssertEqual(Monogram.paletteIndex(for: "hoply", count: 0), 0)
        XCTAssertEqual(Monogram.paletteIndex(for: "", count: 5), Int(FNV1a.hash64("".utf8) % 5))
        let spread = Set((0..<200).map { Monogram.paletteIndex(for: "project-\($0)", count: 8) })
        XCTAssertEqual(spread, Set(0..<8))
    }
}

final class GitDiffStatTests: XCTestCase {
    func testShortstat() {
        XCTAssertEqual(GitDiffStat(shortstat: " 3 files changed, 120 insertions(+), 34 deletions(-)\n"),
                       GitDiffStat(filesChanged: 3, added: 120, removed: 34))
        XCTAssertEqual(GitDiffStat(shortstat: " 1 file changed, 1 insertion(+)"), GitDiffStat(filesChanged: 1, added: 1))
        XCTAssertEqual(GitDiffStat(shortstat: " 2 files changed, 7 deletions(-)"), GitDiffStat(filesChanged: 2, removed: 7))
        XCTAssertEqual(GitDiffStat(shortstat: " 1 file changed, 0 insertions(+), 0 deletions(-)"),
                       GitDiffStat(filesChanged: 1))
        XCTAssertEqual(GitDiffStat(shortstat: ""), GitDiffStat())
        XCTAssertEqual(GitDiffStat(shortstat: "\n")?.isClean, true)
        XCTAssertNil(GitDiffStat(shortstat: "fatal: not a git repository"))
        XCTAssertNil(GitDiffStat(shortstat: "3 bananas changed"))
        XCTAssertFalse(GitDiffStat(untracked: 1).isClean)
    }

    func testUntrackedCount() {
        XCTAssertEqual(GitDiffStat.entryCount(nulSeparated: Data("a.txt\0dir/b c.txt\0".utf8)), 2)
        XCTAssertEqual(GitDiffStat.entryCount(nulSeparated: Data()), 0)
    }
}
