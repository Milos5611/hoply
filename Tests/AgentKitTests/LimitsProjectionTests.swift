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
