@testable import AgentKit
import Foundation
import XCTest

final class CodexLimitKindTests: XCTestCase {
    func testBothRawFormsRoundTrip() throws {
        let fiveHour = try XCTUnwrap(LimitKind.codex(windowMinutes: 300))
        XCTAssertEqual(fiveHour.rawValue, "codex_300m")
        XCTAssertEqual(LimitKind.codex(windowMinutes: 300, limitID: "codex"), fiveHour)
        XCTAssertEqual(LimitKind.codex(windowMinutes: 300, limitID: " Codex "), fiveHour)
        XCTAssertEqual(LimitKind.codex(windowMinutes: 300, limitID: ""), fiveHour)
        let scoped = try XCTUnwrap(LimitKind.codex(windowMinutes: 300, limitID: "codex_bengalfox"))
        XCTAssertEqual(scoped.rawValue, "codex_bengalfox_300m")
        XCTAssertEqual(LimitKind.codex(windowMinutes: 1440, limitID: "codex_secondary")?.rawValue, "codex_secondary_1440m")
        XCTAssertEqual(LimitKind.codex(windowMinutes: 60, limitID: "other-limit")?.rawValue, "codex_other_limit_60m")
        XCTAssertNil(LimitKind.codex(windowMinutes: 0))
        XCTAssertNil(LimitKind.codex(windowMinutes: 300, limitID: "codex_·"))

        for raw in ["codex_300m", "codex_10080m", "codex_43200m", "codex_bengalfox_300m", "codex_gpt_5_2_300m",
                    "codex_300m_300m"] {
            let kind = try XCTUnwrap(LimitKind(rawValue: raw), raw)
            XCTAssertEqual(kind.rawValue, raw)
            XCTAssertEqual(kind.provider, .codex)
            let encoded = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(LimitKind.self, from: encoded), kind)
        }
        for invalid in ["codex_", "codex_m", "codex_0m", "codex_0300m", "codex_300", "codex_bengalfox",
                        "codex__300m", "codex_x__300m", "codex_X_300m", "codex_x_-5m", "codex300m"] {
            XCTAssertNil(LimitKind(rawValue: invalid), invalid)
        }
        XCTAssertEqual(LimitKind(rawValue: "five_hour")?.provider, .claude)
        XCTAssertEqual(LimitKind(rawValue: "seven_day_fable")?.provider, .claude)
    }

    func testWindowsAndNames() throws {
        func kind(_ minutes: Int, _ id: String? = nil) throws -> LimitKind {
            try XCTUnwrap(LimitKind.codex(windowMinutes: minutes, limitID: id))
        }
        XCTAssertEqual(try kind(300).windowLength, 5 * 3600)
        XCTAssertEqual(try kind(43_200).windowLength, 30 * 86_400)
        XCTAssertEqual(try [300, 10_080, 43_200, 1440, 120, 90].map { try kind($0).displayName },
                       ["5-hour", "Weekly", "30-day", "1-day", "2-hour", "90-minute"])
        XCTAssertEqual(try kind(300).limitPhrase, "5-hour limit")
        XCTAssertEqual(try kind(10_080).limitPhrase, "weekly limit")
        XCTAssertEqual(try kind(43_200).limitPhrase, "30-day limit")
        XCTAssertFalse(try kind(300).isModelScoped)

        let scoped = try kind(10_080, "codex_bengalfox")
        XCTAssertTrue(scoped.isModelScoped)
        XCTAssertEqual(scoped.scope, "bengalfox")
        XCTAssertEqual(scoped.displayName, "Weekly Bengalfox")
        XCTAssertEqual(scoped.limitPhrase, "weekly Bengalfox limit")
        XCTAssertNotEqual(scoped.limitGroup, try kind(10_080).limitGroup)
        XCTAssertEqual(try kind(300).limitGroup, try kind(10_080).limitGroup)

        XCTAssertEqual(LimitKind.fiveHour.windowMinutes, 300)
        XCTAssertEqual(LimitKind.sevenDayOpus.windowLength, 7 * 86_400)
        XCTAssertEqual(LimitKind.sevenDayOpus.displayName, "Weekly Opus")
        XCTAssertEqual(LimitKind.sevenDayOpus.limitPhrase, "weekly Opus limit")
        XCTAssertEqual(LimitKind.sevenDay.limitGroup, LimitKind.sevenDayOpus.limitGroup)
        XCTAssertFalse(LimitKind.sevenDay.isModelScoped)
        XCTAssertTrue(LimitKind.sevenDaySonnet.isModelScoped)
        XCTAssertEqual(LimitProvider(source: .codexCLI), .codex)
        XCTAssertNil(LimitProvider(source: .copilotCLI))
        XCTAssertEqual(LimitProvider.codex.source, .codexCLI)
    }

    func testClaudeFirstThenCodexByLimitAndWindow() {
        let kinds = ["codex_bengalfox_300m", "codex_10080m", "seven_day_fable", "codex_300m", "five_hour",
                     "codex_43200m", "seven_day"].compactMap(LimitKind.init(rawValue:))
        XCTAssertEqual(kinds.sorted().map(\.rawValue), ["five_hour", "seven_day", "seven_day_fable", "codex_300m",
                                                        "codex_10080m", "codex_43200m", "codex_bengalfox_300m"])
    }

    func testBurnRateSpansFollowTheWindow() throws {
        XCTAssertEqual(try XCTUnwrap(LimitKind.codex(windowMinutes: 300)).burnRateLookback, 3600)
        XCTAssertEqual(try XCTUnwrap(LimitKind.codex(windowMinutes: 43_200)).burnRateLookback, 86_400)
        XCTAssertEqual(try XCTUnwrap(LimitKind.codex(windowMinutes: 10_080)).burnRateMinimumSpan, 3600)
        XCTAssertEqual(LimitKind.fiveHour.burnRateMinimumSpan, 600)
    }
}

final class CodexRolloutLimitsTests: XCTestCase {
    static let path = "/x/sessions/2026/11/10/rollout-2026-11-10T10-00-00-019c0000-0000-7000-8000-0000000000aa.jsonl"
    private let fiveHour = LimitKind.codex(windowMinutes: 300)!
    private let weekly = LimitKind.codex(windowMinutes: 10_080)!
    private let monthly = LimitKind.codex(windowMinutes: 43_200)!

    private func parse(_ lines: [Data], path: String = path) -> LedgerBatch {
        var state = CodexRolloutState(path: path)
        return CodexRolloutParser.batch(lines: lines, state: &state, transcriptPath: path, startsAtFileStart: true)
    }

    private func parse(_ lines: [String]) -> LedgerBatch { parse(lines.map { Data($0.utf8) }) }

    private func fixture(_ name: String) throws -> [Data] {
        JSONLines.complete(in: try Fixture.data(name)).lines
    }

    private func limits(_ time: String, _ rateLimits: String) -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":\#(rateLimits)}}"#
    }

    private func window(_ used: Double, _ minutes: Int?, resets: Int = 1_794_300_000) -> String {
        let minutes = minutes.map(String.init) ?? "null"
        return #"{"used_percent":\#(used),"window_minutes":\#(minutes),"resets_at":\#(resets)}"#
    }

    private func snapshot(_ primary: String, _ secondary: String = "null", plan: String = "\"plus\"",
                          limitID: String = "\"codex\"") -> String {
        #"{"limit_id":\#(limitID),"limit_name":null,"primary":\#(primary),"secondary":\#(secondary),"credits":null,"individual_limit":null,"plan_type":\#(plan),"rate_limit_reached_type":null}"#
    }

    func testOlderSnapshotWithoutLimitIDAndBothWindows() throws {
        let batch = parse(try fixture("codex_rollout_cli.jsonl"))
        XCTAssertEqual(Set(batch.limits.map(\.kind)), [fiveHour, weekly])
        XCTAssertTrue(batch.limits.allSatisfy { $0.plan == nil })
        let first = try XCTUnwrap(batch.limits.first { $0.kind == fiveHour })
        XCTAssertEqual(first.ts, Timestamps.parse("2026-02-11T16:01:17.091Z"), "a snapshot with no usage info still counts")
        XCTAssertEqual(first.utilization, 0)
        XCTAssertEqual(first.resetsAt, Date(timeIntervalSince1970: 1_770_843_676))
        let lastWeekly = try XCTUnwrap(batch.limits.last { $0.kind == weekly })
        XCTAssertEqual(lastWeekly.resetsAt?.timeIntervalSince1970 ?? 0, 1_771_430_479, accuracy: 1)
        XCTAssertLessThan(batch.limits.count, 56, "repeated readings are thinned inside the batch")
        XCTAssertEqual(batch.limits.filter { $0.kind == fiveHour }.map(\.utilization),
                       batch.limits.filter { $0.kind == fiveHour }.map(\.utilization).sorted(),
                       "in time order")
    }

    func testFreePlanHasOneThirtyDayWindowAndNoSecondary() throws {
        let batch = parse(try fixture("codex_rollout_exec.jsonl"))
        XCTAssertEqual(batch.limits.map(\.kind), Array(repeating: monthly, count: 6))
        XCTAssertEqual(batch.limits.map(\.utilization), [6, 7, 8, 9, 10, 10], "the repeat of 8 goes; the last 10 stays")
        XCTAssertEqual(batch.limits.last?.ts, Timestamps.parse("2026-07-20T15:43:05.602Z"))
        XCTAssertTrue(batch.limits.allSatisfy { $0.plan == "free" })
        XCTAssertEqual(batch.limits.first?.resetsAt, Date(timeIntervalSince1970: 1_787_154_065))
        XCTAssertEqual(batch.sessions.first?.contextWindow, 258_400)
        XCTAssertTrue(batch.activity.isEmpty, "a root thread reports no subagent activity")
    }

    func testTailBatchesKeepEveryReadingTheWholeReadKeeps() throws {
        let all = try fixture("codex_rollout_cli.jsonl")
        let whole = parse(all)
        for split in [10, 40, all.count - 3] {
            var state = CodexRolloutState(path: Self.path)
            let first = CodexRolloutParser.batch(lines: all[..<split], state: &state, transcriptPath: Self.path,
                                                 startsAtFileStart: true)
            let second = CodexRolloutParser.batch(lines: all[split...], state: &state, transcriptPath: Self.path,
                                                  startsAtFileStart: false)
            XCTAssertTrue(Set(whole.limits).isSubset(of: Set(first.limits + second.limits)), "split at \(split)")
        }
    }

    func testPlanChangeAndLimitIDs() throws {
        let batch = parse([
            limits("2026-11-10T10:00:00Z", snapshot(window(40, 43_200), plan: "\"free\"")),
            limits("2026-11-10T10:05:00Z", snapshot(window(2, 300), window(1, 10_080))),
            limits("2026-11-10T10:06:00Z", snapshot(window(80, 300), limitID: "\"codex_bengalfox\"")),
            limits("2026-11-10T10:07:00Z", snapshot(window(5, nil), window(3, 10_080), limitID: "null")),
            limits("2026-11-10T10:08:00Z", snapshot("null", plan: "null")),
        ])
        let bengalfox = try XCTUnwrap(LimitKind(rawValue: "codex_bengalfox_300m"))
        XCTAssertEqual(batch.limits.map(\.kind), [monthly, fiveHour, weekly, bengalfox, weekly])
        XCTAssertEqual(batch.limits.map(\.plan), ["free", "plus", "plus", "plus", "plus"])
        XCTAssertEqual(batch.limits.map(\.utilization), [40, 2, 1, 80, 3],
                       "a window without window_minutes is skipped; a missing limit_id is the default limit")
    }

    func testRepeatsKeepTheFirstAHeartbeatAndTheLast() {
        let formatter = ISO8601DateFormatter()
        let start = Date(timeIntervalSince1970: 1_794_296_400)
        let lines = stride(from: 0.0, to: 1800, by: 60).map { second in
            limits(formatter.string(from: start.addingTimeInterval(second)), snapshot(window(12, 300)))
        }
        XCTAssertEqual(parse(lines).limits.map { $0.ts.timeIntervalSince(start) }, [0, 900, 1740])
    }

    func testContextWindowIsTheLatestReportedOnRootThreadsOnly() {
        let root = parse([
            CodexRolloutParserTests.meta(id: "019c0000-0000-7000-8000-0000000000aa"),
            #"{"timestamp":"2026-11-10T10:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1","model_context_window":258400}}"#,
            #"{"timestamp":"2026-11-10T10:00:02.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t2","model_context_window":128000}}"#,
        ])
        XCTAssertEqual(root.sessions.first?.contextWindow, 128_000)
        let plain = parse([CodexRolloutParserTests.meta(id: "019c0000-0000-7000-8000-0000000000aa")])
        XCTAssertNil(plain.sessions.first?.contextWindow)
        let subagent = parse([Self.subagentMeta(nickname: "Hume", role: "explorer"),
                              CodexRolloutParserTests.tokens(input: 10, cached: 0, output: 1, total: 11,
                                                             at: "2026-11-10T10:00:02Z")])
        XCTAssertNil(subagent.sessions.first?.contextWindow)
    }

    static let root = "019c0000-0000-7000-8000-0000000000aa"
    static let thread = "019c0000-0000-7000-8000-0000000000bb"

    static func subagentMeta(nickname: String?, role: String?, sessionID: String? = root) -> String {
        func field(_ key: String, _ value: String?) -> String { value.map { #","\#(key)":"\#($0)""# } ?? "" }
        let spawn = #"{"thread_spawn":{"parent_thread_id":"\#(root)","depth":1\#(field("agent_nickname", nickname))\#(field("agent_role", role))}}"#
        return #"{"timestamp":"2026-11-10T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(thread)"\#(field("session_id", sessionID)),"cwd":"/Users/dev/project","source":{"subagent":\#(spawn)}\#(field("agent_nickname", nickname))\#(field("agent_role", role))}}"#
    }

    func testSubagentNames() {
        let named = parse([Self.subagentMeta(nickname: "Hume", role: "explorer")])
        XCTAssertEqual(named.subagents, [SubagentInfo(session: SessionKey(source: .codexCLI, id: Self.root),
                                                      agentID: Self.thread, agentType: "Hume", description: "explorer")])
        let roleOnly = parse([Self.subagentMeta(nickname: nil, role: "worker")])
        XCTAssertEqual(roleOnly.subagents.first?.agentType, "worker")
        XCTAssertNil(roleOnly.subagents.first?.description)
        let unnamed = parse([Self.subagentMeta(nickname: nil, role: nil)])
        XCTAssertTrue(unnamed.subagents.isEmpty)

        let review = parse([#"{"timestamp":"2026-11-10T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(Self.thread)","session_id":"\#(Self.root)","source":{"subagent":"review"}}}"#])
        XCTAssertEqual(review.subagents.first?.agentType, "review")
        XCTAssertEqual(review.sessions.first?.key.id, Self.root)

        let older = parse([Self.subagentMeta(nickname: "Hume", role: nil, sessionID: nil),
                           CodexRolloutParserTests.context(model: "gpt-6-luna"),
                           CodexRolloutParserTests.tokens(input: 10, cached: 0, output: 1, total: 11,
                                                          at: "2026-11-10T10:00:02Z")])
        XCTAssertEqual(older.subagents.first?.session.id, Self.root, "no session_id: the spawning thread")
        XCTAssertEqual(older.usage.first?.sessionID, Self.root)
        XCTAssertEqual(older.usage.first?.agentID, Self.thread)

        let root = parse([CodexRolloutParserTests.meta(id: Self.root)])
        XCTAssertTrue(root.subagents.isEmpty)
    }

    func testSubagentTurnsBecomeActivity() {
        let batch = parse([
            Self.subagentMeta(nickname: "Hume", role: "explorer"),
            #"{"timestamp":"2026-11-10T10:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#,
            #"{"timestamp":"2026-11-10T10:00:05.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"#,
            #"{"timestamp":"2026-11-10T10:01:00.000Z","type":"event_msg","payload":{"type":"turn_started","turn_id":"t2"}}"#,
            #"{"timestamp":"2026-11-10T10:01:09.000Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#,
        ])
        let key = SessionKey(source: .codexCLI, id: Self.root)
        XCTAssertEqual(batch.activity.map(\.ended), [false, true, false, true])
        XCTAssertTrue(batch.activity.allSatisfy { $0.session == key && $0.agentID == Self.thread && $0.type == "Hume" })
        XCTAssertEqual(batch.activity.last?.time, Timestamps.parse("2026-11-10T10:01:09.000Z"))
    }
}

final class CodexSessionIndexTests: XCTestCase {
    private let first = "019c0000-0000-7000-8000-0000000000a1"
    private let second = "019c0000-0000-7000-8000-0000000000a2"
    private let cleared = "019c0000-0000-7000-8000-0000000000a3"

    func testNewestEntryPerIDWinsAndAnEmptyNameNamesNothing() throws {
        var names: [String: String] = [:]
        let touched = CodexSessionIndex.apply(lines: JSONLines.complete(in: try Fixture.data("codex_session_index.jsonl")).lines,
                                              to: &names)
        XCTAssertEqual(touched, [first, second, cleared])
        XCTAssertEqual(names, [first: "Fix login redirect loop", second: "Add billing export", cleared: ""])
        XCTAssertEqual(CodexSessionIndex.titles(names), [first: "Fix login redirect loop", second: "Add billing export"])
        XCTAssertEqual(CodexSessionIndex.titles(names, ids: [second, cleared]), [second: "Add billing export"])

        let again = CodexSessionIndex.apply(lines: [Data(#"{"id":"\#(second)","thread_name":"Add billing export","updated_at":"x"}"#.utf8)],
                                            to: &names)
        XCTAssertTrue(again.isEmpty, "an unchanged name touches nothing")
        XCTAssertEqual(CodexSessionIndex.titleRank, ClaudeTitleKind.custom.rawValue)
    }
}

final class CurrentLimitWindowsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_300_000)

    private func sample(_ raw: String, at seconds: TimeInterval, plan: String? = nil) -> LimitSample {
        LimitSample(kind: LimitKind(rawValue: raw)!, ts: t0.addingTimeInterval(seconds), utilization: 10,
                    resetsAt: t0.addingTimeInterval(86_400), plan: plan)
    }

    private func current(_ samples: LimitSample...) -> [String] {
        LimitSample.current(Dictionary(uniqueKeysWithValues: samples.map { ($0.kind, $0) })).keys.map(\.rawValue).sorted()
    }

    func testAPlanChangeDropsTheOldWindowAtOnce() {
        XCTAssertEqual(current(sample("codex_43200m", at: -60, plan: "free"), sample("codex_300m", at: 0, plan: "plus"),
                               sample("codex_10080m", at: 0, plan: "plus")),
                       ["codex_10080m", "codex_300m"])
    }

    func testAWindowLaggingItsLimitBeyondTheToleranceIsGone() {
        XCTAssertEqual(current(sample("codex_300m", at: 0), sample("codex_10080m", at: -LimitSample.currentTolerance)),
                       ["codex_10080m", "codex_300m"], "a stored row may lag its reading by up to 15 minutes")
        XCTAssertEqual(current(sample("codex_300m", at: 0), sample("codex_43200m", at: -LimitSample.currentTolerance - 1)),
                       ["codex_300m"])
    }

    func testEachLimitAndProviderStandsAlone() {
        XCTAssertEqual(current(sample("codex_300m", at: 0), sample("codex_bengalfox_300m", at: -86_400),
                               sample("five_hour", at: -7200), sample("seven_day", at: -7200),
                               sample("seven_day_opus", at: -86_400)),
                       ["codex_300m", "codex_bengalfox_300m", "five_hour", "seven_day"])
    }
}

final class CodexBurnRateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_300_000)
    private let week = LimitKind.codex(windowMinutes: 10_080)!
    private let five = LimitKind.codex(windowMinutes: 300)!

    private func reading(_ kind: LimitKind, _ utilization: Double, at hours: Double, resets: Double) -> LimitSample {
        LimitSample(kind: kind, ts: now.addingTimeInterval(hours * 3600), utilization: utilization,
                    resetsAt: now.addingTimeInterval(resets * 3600), plan: "plus")
    }

    func testABurstInAnIdleDayIsSpreadOverTheDay() throws {
        let earlier = [reading(week, 2, at: -96, resets: 72), reading(week, 30, at: -72, resets: 72)]
        let burst = stride(from: 0.0, through: 6, by: 1).map {
            reading(week, 30 + $0 * 10 / 6, at: -20 + $0 * 5 / 60, resets: 72)
        }
        let projection = try XCTUnwrap(LimitsProjection(samples: earlier + burst, now: now))
        XCTAssertEqual(try XCTUnwrap(projection.burnRatePerHour) * 24, 10, accuracy: 1e-9, "10 points in 24 h")
        XCTAssertEqual(try XCTUnwrap(projection.projectedUtilization), 40 + 10.0 / 24 * 72, accuracy: 1e-9)
        XCTAssertNil(projection.limitReachedAt)
    }

    func testABurstThatEndedFortyMinutesAgoCountsTheIdleMinutes() throws {
        let burst = stride(from: -60.0, through: -40, by: 2).map {
            reading(five, 18 * ($0 + 60) / 20, at: $0 / 60, resets: 4)
        }
        let projection = try XCTUnwrap(LimitsProjection(samples: burst, now: now))
        XCTAssertEqual(try XCTUnwrap(projection.burnRatePerHour), 18, accuracy: 1e-9, "not the session's 54 %/h")
        XCTAssertEqual(try XCTUnwrap(projection.projectedUtilization), 18 + 18 * 4, accuracy: 1e-9)
        XCTAssertNil(projection.limitReachedAt)
        let atLastReading = try XCTUnwrap(LimitsProjection(samples: burst))
        XCTAssertEqual(try XCTUnwrap(atLastReading.burnRatePerHour), 18 / (20.0 / 60), accuracy: 1e-9,
                       "without a clock the newest reading is the end")
    }

    func testSteadyUseMatchesTheRegression() throws {
        let steady = stride(from: -48.0, through: 0, by: 0.25).map { reading(week, 30 + 0.5 * ($0 + 48), at: $0, resets: 60) }
        let codex = try XCTUnwrap(LimitsProjection(samples: steady, now: now))
        XCTAssertEqual(try XCTUnwrap(codex.burnRatePerHour), 0.5, accuracy: 1e-9)
        let asClaude = steady.map { LimitSample(kind: .sevenDay, ts: $0.ts, utilization: $0.utilization, resetsAt: $0.resetsAt) }
        XCTAssertEqual(try XCTUnwrap(LimitsProjection(samples: asClaude, now: now)?.burnRatePerHour), 0.5, accuracy: 1e-9)

        let session = stride(from: -50.0, through: 0, by: 2).map { reading(five, 0.5 * ($0 + 50), at: $0 / 60, resets: 250.0 / 60) }
        XCTAssertEqual(try XCTUnwrap(LimitsProjection(samples: session, now: now)?.burnRatePerHour), 30, accuracy: 1e-9,
                       "a window that began inside the lookback grows from 0 at its start")
    }

    func testAResetInsideTheLookbackStartsFromTheNewWindow() throws {
        let old = stride(from: -30.0, through: -10, by: 1).map { reading(week, 60 + ($0 + 30), at: $0, resets: -6) }
        let new = stride(from: -6.0, through: 0, by: 0.5).map { reading(week, $0 + 6, at: $0, resets: 162) }
        let projection = try XCTUnwrap(LimitsProjection(samples: old + new, now: now))
        XCTAssertEqual(projection.windowSamples, new)
        XCTAssertEqual(try XCTUnwrap(projection.burnRatePerHour), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(projection.limitReachedAt).timeIntervalSince(now), 94 * 3600, accuracy: 1e-6)
    }

    func testOneReadingOrATooShortSpanGivesNoRate() throws {
        XCTAssertNil(LimitsProjection(samples: [reading(week, 40, at: -3, resets: 72)], now: now)?.burnRatePerHour)
        let fresh = [reading(five, 1, at: -2.0 / 60, resets: 5 - 3.0 / 60), reading(five, 3, at: 0, resets: 5 - 3.0 / 60)]
        XCTAssertNil(LimitsProjection(samples: fresh, now: now)?.burnRatePerHour, "3 minutes of window is under 10")
    }
}
