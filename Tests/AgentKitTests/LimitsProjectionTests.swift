import AgentKit
import Foundation
import XCTest

final class LimitsProjectionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_400)
    private lazy var reset = t0.addingTimeInterval(3 * 3600)

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// One sample every `step` minutes from `from` to `to` (minutes relative to t0), utilization from `value`.
    private func series(_ kind: LimitKind = .fiveHour, from: Double, to: Double, step: Double = 5,
                        resets: Date? = nil, value: (Double) -> Double) -> [LimitSample] {
        stride(from: from, through: to, by: step).map {
            LimitSample(kind: kind, ts: at($0), utilization: value($0), resetsAt: resets ?? reset)
        }
    }

    func testABurnRateThatRunsOutBeforeTheReset() throws {
        let projection = try XCTUnwrap(LimitsProjection(samples: series(from: -60, to: 0) { 60 + 0.5 * $0 }))
        XCTAssertEqual(projection.kind, .fiveHour)
        XCTAssertEqual(projection.utilization, 60)
        XCTAssertEqual(try XCTUnwrap(projection.burnRatePerHour), 30, accuracy: 1e-9)
        XCTAssertEqual(projection.projectedUtilization, 100)
        XCTAssertEqual(try XCTUnwrap(projection.limitReachedAt).timeIntervalSince(t0), 4800, accuracy: 1e-6)
        XCTAssertEqual(projection.windowStart, reset.addingTimeInterval(-5 * 3600))
        XCTAssertEqual(projection.windowSamples.count, 13)
        XCTAssertFalse(projection.isAtLimit)
    }

    func testASlowRateWontReachTheLimit() throws {
        reset = t0.addingTimeInterval(2 * 3600)
        let projection = try XCTUnwrap(LimitsProjection(samples: series(from: -60, to: 0) { 25 + $0 / 12 }))
        XCTAssertEqual(try XCTUnwrap(projection.burnRatePerHour), 5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(projection.projectedUtilization), 35, accuracy: 1e-9)
        XCTAssertNil(projection.limitReachedAt)
    }

    func testAFlatRateProjectsTheCurrentValue() throws {
        let projection = try XCTUnwrap(LimitsProjection(samples: series(from: -60, to: 0) { _ in 40 }))
        XCTAssertEqual(projection.burnRatePerHour, 0)
        XCTAssertEqual(projection.projectedUtilization, 40)
        XCTAssertNil(projection.limitReachedAt)
    }

    func testTooFewSamplesOrTooShortASpanGiveNoRate() throws {
        XCTAssertNil(LimitsProjection(samples: []))
        let single = try XCTUnwrap(LimitsProjection(samples: series(from: 0, to: 0) { _ in 12 }))
        XCTAssertEqual(single.utilization, 12)
        XCTAssertNil(single.burnRatePerHour)
        XCTAssertNil(single.projectedUtilization)

        XCTAssertNil(LimitsProjection(samples: series(from: -9, to: 0, step: 3) { 50 + $0 })?.burnRatePerHour,
                     "9 minutes is under the 10 minute minimum")
        XCTAssertNotNil(LimitsProjection(samples: series(from: -10, to: 0, step: 10) { 50 + $0 })?.burnRatePerHour)

        let noReset = series(from: -30, to: 0, resets: nil) { 10 + $0 / 6 }.map {
            LimitSample(kind: $0.kind, ts: $0.ts, utilization: $0.utilization, resetsAt: nil)
        }
        let unstarted = try XCTUnwrap(LimitsProjection(samples: noReset))
        XCTAssertNotNil(unstarted.burnRatePerHour)
        XCTAssertNil(unstarted.projectedUtilization, "no reset time to project to")
        XCTAssertNil(unstarted.windowStart)
    }

    func testOnlyTheLatestWindowCounts() throws {
        let previous = series(from: -300, to: -40, step: 20, resets: t0.addingTimeInterval(-30 * 60)) { _ in 90 }
        let jittered = t0.addingTimeInterval(4 * 3600)
        let current = series(from: -30, to: 0, resets: jittered) { 10 + $0 / 3 }
            + [LimitSample(kind: .fiveHour, ts: at(1), utilization: 10.4, resetsAt: jittered.addingTimeInterval(25))]
        let projection = try XCTUnwrap(LimitsProjection(samples: (current + previous).shuffled()))
        XCTAssertEqual(projection.windowSamples.count, current.count)
        XCTAssertEqual(projection.windowSamples.first?.ts, at(-30))
        XCTAssertEqual(projection.current.ts, at(1), "the jittered reset is the same window")
        XCTAssertGreaterThan(try XCTUnwrap(projection.burnRatePerHour), 0)
    }

    func testSamplesBeforeTheLastDropAreIgnored() throws {
        let beforeDrop = series(from: -60, to: -35) { 80 + $0 / 10 }
        let afterDrop = series(from: -30, to: 0) { 20 + $0 / 3 }
        let projection = try XCTUnwrap(LimitsProjection(samples: beforeDrop + afterDrop))
        XCTAssertEqual(projection.windowSamples, afterDrop)
        XCTAssertEqual(try XCTUnwrap(projection.burnRatePerHour), 20, accuracy: 1e-9)
    }

    func testTheFiveHourRateLooksBackOneHour() throws {
        let samples = [(-120.0, 0.0), (-60, 50), (-30, 55), (0, 60)].map {
            LimitSample(kind: .fiveHour, ts: at($0.0), utilization: $0.1, resetsAt: reset)
        }
        let projection = try XCTUnwrap(LimitsProjection(samples: samples))
        XCTAssertEqual(try XCTUnwrap(projection.burnRatePerHour), 10, accuracy: 1e-9)
        XCTAssertEqual(projection.windowSamples.count, 4)
    }

    func testTheWeeklyRateLooksBackOneDay() throws {
        let weeklyReset = t0.addingTimeInterval(2 * 86_400)
        let early = series(.sevenDay, from: -40 * 60, to: -25 * 60, step: 60, resets: weeklyReset) { 52 + 2 * ($0 / 60 + 25) }
        let lastDay = series(.sevenDay, from: -24 * 60, to: 0, step: 60, resets: weeklyReset) { 66 + 0.5 * $0 / 60 }
        XCTAssertLessThan(early.last?.utilization ?? 100, lastDay.first?.utilization ?? 0, "rising throughout")
        let projection = try XCTUnwrap(LimitsProjection(samples: early + lastDay))
        XCTAssertEqual(projection.kind, .sevenDay)
        XCTAssertEqual(projection.windowSamples.count, early.count + lastDay.count)
        XCTAssertEqual(try XCTUnwrap(projection.burnRatePerHour), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(projection.projectedUtilization), 66 + 0.5 * 48, accuracy: 1e-9)
        XCTAssertNil(projection.limitReachedAt)
        XCTAssertEqual(projection.windowStart, weeklyReset.addingTimeInterval(-7 * 86_400))

        let short = series(.sevenDay, from: -50, to: 0, step: 25, resets: weeklyReset) { 30 + $0 / 60 }
        XCTAssertNil(LimitsProjection(samples: short)?.burnRatePerHour, "under the 1 hour minimum")
    }

    func testClaudeLimitsMapToStableKinds() throws {
        let json = #"{"five_hour":{"utilization":37,"resets_at":"2026-11-09T18:00:00.123+00:00"},"seven_day_opus":{"utilization":12.5,"resets_at":null},"seven_day":null}"#
        let samples = try ClaudeLimits.decode(Data(json.utf8)).samples(at: t0)
        XCTAssertEqual(samples.map(\.kind.rawValue), ["five_hour", "seven_day_opus"])
        XCTAssertEqual(samples.map(\.utilization), [37, 12.5])
        XCTAssertEqual(samples.map(\.ts), [t0, t0])
        XCTAssertNotNil(samples[0].resetsAt)
        XCTAssertNil(samples[1].resetsAt)
        XCTAssertEqual(LimitKind.allCases.map(\.rawValue), ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"])

        let both = series(from: -30, to: 0) { _ in 5 } + series(.sevenDaySonnet, from: -30, to: 0) { _ in 7 }
        let projections = LimitsProjection.projections(both)
        XCTAssertEqual(projections[.fiveHour]?.utilization, 5)
        XCTAssertEqual(projections[.sevenDaySonnet]?.utilization, 7)
        XCTAssertNil(projections[.sevenDay])
    }
}

final class CopilotAllowanceTests: XCTestCase {
    private func utc(_ text: String) -> Date { Timestamps.parse(text)! }

    func testTheMonthIsAUTCMonth() {
        let lateInNewYork = utc("2026-11-30T23:30:00-05:00")
        let allowance = CopilotAllowance(used: 10, allowance: 300, usdPerExtraRequest: 0.04, now: lateInNewYork)
        XCTAssertEqual(allowance.month.start, utc("2026-12-01T00:00:00Z"), "already December in UTC")
        XCTAssertEqual(allowance.nextReset, utc("2027-01-01T00:00:00Z"))

        let earlyInTokyo = utc("2026-12-01T08:00:00+09:00")
        XCTAssertEqual(CopilotAllowance.month(containing: earlyInTokyo),
                       DateInterval(start: utc("2026-11-01T00:00:00Z"), end: utc("2026-12-01T00:00:00Z")),
                       "still November in UTC")
    }

    func testWithinTheAllowance() throws {
        let allowance = CopilotAllowance(used: 120, allowance: 300, usdPerExtraRequest: 0.04)
        XCTAssertTrue(allowance.isSet)
        XCTAssertEqual(allowance.remaining, 180)
        XCTAssertEqual(try XCTUnwrap(allowance.fraction), 0.4, accuracy: 1e-12)
        XCTAssertEqual(allowance.overageRequests, 0)
        XCTAssertEqual(allowance.overageUSD, 0)
    }

    func testOverage() throws {
        let allowance = CopilotAllowance(used: 320.5, allowance: 300, usdPerExtraRequest: 0.04)
        XCTAssertEqual(allowance.remaining, 0)
        XCTAssertEqual(try XCTUnwrap(allowance.fraction), 320.5 / 300, accuracy: 1e-12)
        XCTAssertEqual(allowance.overageRequests, 20.5)
        XCTAssertEqual(try XCTUnwrap(allowance.overageUSD), 0.82, accuracy: 1e-12)
    }

    func testAZeroAllowanceMeansNotSet() {
        let allowance = CopilotAllowance(used: 50, allowance: 0, usdPerExtraRequest: 0.04)
        XCTAssertFalse(allowance.isSet)
        XCTAssertNil(allowance.remaining)
        XCTAssertNil(allowance.fraction)
        XCTAssertNil(allowance.overageRequests)
        XCTAssertNil(allowance.overageUSD)
        XCTAssertEqual(allowance.used, 50)
    }

    func testSettingsFeedTheAllowance() {
        var settings = AppSettings()
        settings.copilotMonthlyAllowance = 1500
        settings.copilotUSDPerPremiumRequest = 0.05
        let allowance = CopilotAllowance(used: 1600, settings: settings)
        XCTAssertEqual(allowance.allowance, 1500)
        XCTAssertEqual(allowance.overageUSD ?? 0, 5, accuracy: 1e-9)
    }
}

final class LimitPaceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_400)

    /// A 5-hour window half gone at t0.
    private func pace(_ utilization: Double, resetsIn seconds: TimeInterval = 9000,
                      kind: LimitKind = .fiveHour) -> LimitPace? {
        LimitSample(kind: kind, ts: t0, utilization: utilization, resetsAt: t0.addingTimeInterval(seconds)).pace(at: t0)
    }

    func testBands() throws {
        let ahead = try XCTUnwrap(pace(70))
        XCTAssertEqual(ahead.elapsedPercent, 50)
        XCTAssertEqual(ahead.delta, 20)
        XCTAssertEqual(ahead.band, .ahead)
        XCTAssertEqual(pace(30)?.band, .under)
        XCTAssertEqual(pace(30)?.delta, -20)
        XCTAssertEqual(pace(52)?.band, .onTrack)
    }

    func testEdgesAtFivePoints() {
        XCTAssertEqual(pace(55)?.delta, 5)
        XCTAssertEqual(pace(55)?.band, .onTrack, "+5 is still on track")
        XCTAssertEqual(pace(55.01)?.band, .ahead)
        XCTAssertEqual(pace(45)?.delta, -5)
        XCTAssertEqual(pace(45)?.band, .onTrack, "−5 is still on track")
        XCTAssertEqual(pace(44.99)?.band, .under)
    }

    func testNilWithoutAResetOrAfterIt() {
        XCTAssertNil(LimitSample(kind: .fiveHour, ts: t0, utilization: 40, resetsAt: nil).pace(at: t0))
        XCTAssertNil(pace(40, resetsIn: 0), "the window has reset; the reading is stale")
        XCTAssertNil(pace(40, resetsIn: -60))
    }

    func testTheWindowJustStarted() throws {
        let start = try XCTUnwrap(pace(3, resetsIn: 5 * 3600 - 60))
        XCTAssertEqual(start.elapsedPercent, 100.0 / 300, accuracy: 1e-9)
        XCTAssertEqual(start.band, .onTrack)
        XCTAssertEqual(pace(8, resetsIn: 5 * 3600 - 60)?.band, .ahead, "8% in the first minute")
        let skewed = try XCTUnwrap(pace(0, resetsIn: 6 * 3600))
        XCTAssertEqual(skewed.elapsedPercent, 0, "a reset further away than the window length clamps to 0")
        XCTAssertEqual(skewed.band, .onTrack)
    }

    func testTheWindowAlmostOver() throws {
        let end = try XCTUnwrap(pace(40, resetsIn: 60))
        XCTAssertEqual(end.elapsedPercent, 100 - 100.0 / 300, accuracy: 1e-9)
        XCTAssertEqual(end.band, .under)
        XCTAssertEqual(pace(96, resetsIn: 60)?.band, .onTrack)
    }

    func testWeeklyWindowsUseSevenDays() throws {
        let weekly = try XCTUnwrap(pace(20, resetsIn: 5 * 86_400, kind: .sevenDay))
        XCTAssertEqual(weekly.elapsedPercent, 200.0 / 7, accuracy: 1e-9)
        XCTAssertEqual(weekly.band, .under)
        let scoped = try XCTUnwrap(LimitKind.scoped(displayName: "Fable"))
        XCTAssertEqual(pace(20, resetsIn: 5 * 86_400, kind: scoped), weekly)
    }

    func testALiveWindowAndAProjectionGiveTheSamePace() throws {
        let reset = t0.addingTimeInterval(9000)
        let window = ClaudeLimits.Window(utilization: 70, resetsAt: reset)
        XCTAssertEqual(window.pace(.fiveHour, at: t0)?.band, .ahead)
        let projection = try XCTUnwrap(LimitsProjection(samples: [
            LimitSample(kind: .fiveHour, ts: t0.addingTimeInterval(-600), utilization: 60, resetsAt: reset),
            LimitSample(kind: .fiveHour, ts: t0, utilization: 70, resetsAt: reset),
        ]))
        XCTAssertEqual(projection.pace(at: t0), window.pace(.fiveHour, at: t0))
    }
}

final class ClaudeLimitsDecodeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_400)

    private func decode(_ json: String) throws -> ClaudeLimits {
        try ClaudeLimits.decode(Data(json.utf8))
    }

    func testTheOldShapeStillDecodes() throws {
        let limits = try ClaudeLimits.decode(try Fixture.data("claude_usage.json"))
        XCTAssertEqual(limits.fiveHour?.utilization, 62)
        XCTAssertEqual(limits.sevenDay?.utilization, 25)
        XCTAssertEqual(limits.sevenDayOpus?.utilization, 3.5)
        XCTAssertNil(limits.sevenDaySonnet)
        XCTAssertEqual(limits.scoped, [])
        XCTAssertEqual(limits.extraUsage?.isEnabled, false)
        XCTAssertNil(limits.spend)
        XCTAssertEqual(limits.unrecognizedKeys, [])
        XCTAssertEqual(limits.samples(at: t0).map(\.kind), [.fiveHour, .sevenDay, .sevenDayOpus])
    }

    func testModelScopedWindows() throws {
        let limits = try decode("""
            {"five_hour":{"utilization":54,"resets_at":"2026-11-09T14:39:00Z"},
             "seven_day_opus":{"utilization":3,"resets_at":null},
             "model_scoped":[
               {"display_name":"Fable","utilization":73,"resets_at":"2026-11-13T08:59:00Z"},
               {"display_name":"Ghost","utilization":null,"resets_at":null},
               {"display_name":"Opus","utilization":99,"resets_at":null},
               {"display_name":"Sonnet 4.5","utilization":12.5,"resets_at":null},
               {"display_name":"   ","utilization":5},
               {"utilization":5},
               "not an entry"
             ]}
            """)
        XCTAssertEqual(limits.scoped.map(\.displayName), ["Fable", "Opus", "Sonnet 4.5"])
        XCTAssertEqual(limits.scoped.map(\.kind.rawValue), ["seven_day_fable", "seven_day_opus", "seven_day_sonnet_4_5"])
        XCTAssertEqual(limits.scoped.first?.window.resetsAt, Timestamps.parse("2026-11-13T08:59:00Z"))

        let samples = limits.samples(at: t0)
        XCTAssertEqual(samples.map(\.kind.rawValue), ["five_hour", "seven_day_opus", "seven_day_fable", "seven_day_sonnet_4_5"])
        XCTAssertEqual(samples.map(\.utilization), [54, 3, 73, 12.5], "the fixed Opus window wins over a scoped Opus")
        XCTAssertEqual(limits.window(try XCTUnwrap(LimitKind(rawValue: "seven_day_fable")))?.utilization, 73)

        let sonnet = try XCTUnwrap(LimitKind(rawValue: "seven_day_sonnet_4_5"))
        XCTAssertEqual(sonnet.displayName, "Weekly Sonnet 4.5")
        XCTAssertEqual(sonnet.windowLength, 7 * 86_400)
        XCTAssertFalse(sonnet.isFixed)
        XCTAssertEqual(LimitKind.scoped(displayName: "Opus"), .sevenDayOpus)
        XCTAssertEqual(LimitKind.sevenDayOpus.displayName, "Weekly Opus")

        let projections = LimitsProjection.projections(samples)
        XCTAssertEqual(projections[sonnet]?.utilization, 12.5)
        XCTAssertEqual(projections.keys.sorted().map(\.rawValue),
                       ["five_hour", "seven_day_opus", "seven_day_fable", "seven_day_sonnet_4_5"])
    }

    func testWeeklyScopedLimitsEntries() throws {
        let limits = try decode("""
            {"seven_day":{"utilization":50,"resets_at":"2099-01-01T00:00:00Z"},
             "limits":[
               {"kind":"weekly_scoped","percent":80,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}},
               {"kind":"weekly_scoped","percent":81,"scope":{"model":{"display_name":"Fable"}}},
               {"kind":"session","percent":10},
               {"kind":"weekly_scoped","percent":"high","scope":{"model":{"display_name":"Ghost"}}}
             ]}
            """)
        XCTAssertEqual(limits.scoped.map(\.kind.rawValue), ["seven_day_fable"])
        XCTAssertEqual(limits.scoped.first?.window.utilization, 80, "the first entry of a kind wins")
        XCTAssertEqual(limits.unrecognizedKeys, [])
    }

    func testExtraUsageDisabledAndEnabled() throws {
        let disabled = try decode("""
            {"five_hour":{"utilization":10,"resets_at":null},
             "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}
            """).extraUsage
        XCTAssertEqual(disabled?.isEnabled, false)
        XCTAssertNil(disabled?.usedCredits)
        XCTAssertNil(disabled?.monthlyLimit)
        XCTAssertNil(disabled?.percentUsed)

        let enabled = try XCTUnwrap(decode("""
            {"extra_usage":{"is_enabled":true,"used_credits":4631,"monthly_limit":50000,"utilization":9.262,
                            "currency":"USD","decimal_places":2}}
            """).extraUsage)
        XCTAssertEqual(enabled.isEnabled, true)
        XCTAssertEqual(enabled.usedCredits, 4631)
        XCTAssertEqual(enabled.monthlyLimit, 50000)
        XCTAssertEqual(enabled.utilization, 9.262)
        XCTAssertEqual(enabled.percentUsed, 9.262)

        let derived = try XCTUnwrap(decode(#"{"extra_usage":{"is_enabled":true,"used_credits":4631,"monthly_limit":50000}}"#).extraUsage)
        XCTAssertEqual(try XCTUnwrap(derived.percentUsed), 9.262, accuracy: 1e-9)
    }

    func testSpendBudget() throws {
        let spend = try XCTUnwrap(decode("""
            {"spend":{"enabled":true,"used":{"amount_minor":4631,"currency":"USD","exponent":2},
                      "limit":{"amount_minor":50000,"currency":"USD","exponent":2},"percent":9}}
            """).spend)
        XCTAssertEqual(spend.enabled, true)
        XCTAssertEqual(try XCTUnwrap(spend.used?.amount), 46.31, accuracy: 1e-9)
        XCTAssertEqual(spend.used?.currency, "USD")
        XCTAssertEqual(try XCTUnwrap(spend.percentUsed), 9.262, accuracy: 1e-9)

        let mismatched = try XCTUnwrap(decode("""
            {"spend":{"enabled":true,"used":{"amount_minor":4631,"currency":"USD","exponent":2},
                      "limit":{"amount_minor":50000,"currency":"EUR","exponent":2}}}
            """).spend)
        XCTAssertNil(mismatched.percentUsed, "different currencies can't be compared")
    }

    func testUnknownTopLevelKeysAreListed() throws {
        let limits = try decode("""
            {"five_hour":{"utilization":1,"resets_at":null},"seven_day_oauth_apps":{"utilization":0,"resets_at":null},
             "iguana_necktie":null,"extra_usage":{"is_enabled":false},"limits":[]}
            """)
        XCTAssertEqual(limits.unrecognizedKeys, ["iguana_necktie", "seven_day_oauth_apps"])
        XCTAssertEqual(limits.samples(at: t0).map(\.kind), [.fiveHour], "unknown windows are listed, not guessed")

        let wrapped = try decode("""
            {"rate_limits_available":true,"rate_limits":{"seven_day":{"utilization":18.4,"resets_at":null},"weird":1}}
            """)
        XCTAssertEqual(wrapped.sevenDay?.utilization, 18.4, "the Agent SDK's wrapper")
        XCTAssertEqual(wrapped.unrecognizedKeys, ["weird"])
    }

    func testWrongTypesAreIgnored() throws {
        let limits = try decode("""
            {"five_hour":{"utilization":"62","resets_at":null},"seven_day":{"utilization":true},
             "seven_day_opus":[1,2],"model_scoped":"Fable","limits":{"kind":"weekly_scoped"},
             "extra_usage":5,"spend":{"enabled":"yes","used":{"amount_minor":"1","currency":"USD","exponent":2},
                                      "limit":{"amount_minor":100,"currency":"","exponent":2}}}
            """)
        XCTAssertNil(limits.fiveHour)
        XCTAssertNil(limits.sevenDay, "a boolean is not a utilization")
        XCTAssertNil(limits.sevenDayOpus)
        XCTAssertEqual(limits.scoped, [])
        XCTAssertNil(limits.extraUsage)
        XCTAssertNil(limits.spend?.enabled)
        XCTAssertNil(limits.spend?.used)
        XCTAssertNil(limits.spend?.limit)
        XCTAssertEqual(limits.unrecognizedKeys, [])
        XCTAssertThrowsError(try decode("[1,2]"))
    }

    func testStoredKindsDecodeAndSort() throws {
        XCTAssertEqual(LimitKind(rawValue: "five_hour"), .fiveHour)
        XCTAssertEqual(LimitKind(rawValue: "seven_day_sonnet"), .sevenDaySonnet)
        XCTAssertNotNil(LimitKind(rawValue: "seven_day_haiku"))
        for invalid in ["", "five_hours", "seven_day_", "seven_day_Fable", "seven_day__x", "seven_day_x_", "monthly_spend"] {
            XCTAssertNil(LimitKind(rawValue: invalid), invalid)
        }
        XCTAssertNil(LimitKind.scoped(displayName: "  ·  "))

        let kinds = ["seven_day_zeta", "seven_day", "seven_day_alpha", "seven_day_sonnet", "five_hour"]
            .compactMap(LimitKind.init(rawValue:))
        XCTAssertEqual(kinds.sorted().map(\.rawValue),
                       ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_alpha", "seven_day_zeta"])

        let encoded = try JSONEncoder().encode([LimitKind.fiveHour, try XCTUnwrap(LimitKind(rawValue: "seven_day_fable"))])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["five_hour","seven_day_fable"]"#)
        XCTAssertEqual(try JSONDecoder().decode([LimitKind].self, from: encoded).map(\.rawValue),
                       ["five_hour", "seven_day_fable"])
        XCTAssertThrowsError(try JSONDecoder().decode([LimitKind].self, from: Data(#"["monthly"]"#.utf8)))
    }
}
