import AgentKit
import AgentSystem
import Foundation
import XCTest

final class LimitSamplesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_400)
    private let allTime = DateInterval(start: .distantPast, end: .distantFuture)

    private func open(_ directory: TempDirectory) throws -> (Store, StoreReader, String) {
        let path = directory.path("hoply.sqlite")
        let store = try Store(path: path, resolver: ProjectResolver(home: "/Users/dev"))
        return (store, try StoreReader(path: path), path)
    }

    private func sample(_ utilization: Double, _ kind: LimitKind = .fiveHour, at seconds: TimeInterval,
                        resets: TimeInterval = 3 * 3600) -> LimitSample {
        LimitSample(kind: kind, ts: t0.addingTimeInterval(seconds), utilization: utilization,
                    resetsAt: t0.addingTimeInterval(resets))
    }

    func testRepeatsAreStoredAtMostEveryFifteenMinutes() async throws {
        let (store, reader, _) = try open(try TempDirectory())
        var previous = try await store.recordLimitSamples([sample(40, at: 0)])
        XCTAssertEqual(previous, [:])
        previous = try await store.recordLimitSamples([sample(40, at: 180)])
        XCTAssertEqual(previous, [.fiveHour: sample(40, at: 0)])
        try await store.recordLimitSamples([sample(40, at: 360, resets: 3 * 3600 + 30)])
        var stored = try await reader.limitSamples(in: allTime)
        XCTAssertEqual(stored, [sample(40, at: 0)], "identical (jittered reset included) and under 15 min old")

        try await store.recordLimitSamples([sample(40, at: 900)])
        try await store.recordLimitSamples([sample(41, at: 960)])
        try await store.recordLimitSamples([sample(41, at: 1020, resets: 8 * 3600)])
        previous = try await store.recordLimitSamples([sample(41, at: 1080, resets: 8 * 3600)])
        XCTAssertEqual(previous[.fiveHour], sample(41, at: 1020, resets: 8 * 3600))
        stored = try await reader.limitSamples(in: allTime)
        XCTAssertEqual(stored.map(\.ts.timeIntervalSince1970), [0, 900, 960, 1020].map { t0.timeIntervalSince1970 + $0 },
                       "a 15 min old repeat, a change and a new window are stored")
    }

    func testReadsFilterKindsRangeAndBucket() async throws {
        let (store, reader, _) = try open(try TempDirectory())
        try await store.recordLimitSamples([sample(10, at: 0), sample(30, .sevenDay, at: 0, resets: 86_400)])
        try await store.recordLimitSamples([sample(25, at: 1200), sample(31, .sevenDay, at: 1200, resets: 86_400)])
        try await store.recordLimitSamples([sample(20, at: 2400)])
        try await store.recordLimitSamples([sample(35, at: 3700)])

        let weekly = try await reader.limitSamples([.sevenDay], in: allTime)
        XCTAssertEqual(weekly.map(\.utilization), [30, 31])
        let window = DateInterval(start: t0.addingTimeInterval(600), end: t0.addingTimeInterval(2400))
        let inRange = try await reader.limitSamples(in: window)
        XCTAssertEqual(inRange.map(\.utilization), [25, 31], "half-open range")

        let hourly = try await reader.limitSamples([.fiveHour], in: allTime, bucket: 3600)
        let hourOf = { (seconds: TimeInterval) in Int((self.t0.timeIntervalSince1970 + seconds) / 3600) }
        XCTAssertEqual(hourly.count, hourOf(3700) == hourOf(0) ? 1 : 2)
        XCTAssertEqual(hourly.first?.utilization, 25, "the bucket's peak")
        XCTAssertEqual(hourly.first?.ts, t0.addingTimeInterval(1200), "with the peak's own time")

        let latest = try await reader.latestLimitSamples()
        XCTAssertEqual(latest, [.fiveHour: sample(35, at: 3700), .sevenDay: sample(31, .sevenDay, at: 1200, resets: 86_400)])
    }

    func testABucketWithAResetKeepsBothWindows() async throws {
        let (store, reader, _) = try open(try TempDirectory())
        let hour = t0.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600)
        XCTAssertEqual(hour, 0, "t0 starts an hourly bucket")
        let next: TimeInterval = 1800 + 5 * 3600
        try await store.recordLimitSamples([sample(88, at: 300, resets: 1800)])
        try await store.recordLimitSamples([sample(92, at: 900, resets: 1830)])
        try await store.recordLimitSamples([sample(91, at: 1500, resets: 1800)])
        try await store.recordLimitSamples([sample(2, at: 1900, resets: next), sample(40, .sevenDay, at: 1900, resets: 86_400)])
        try await store.recordLimitSamples([sample(6, at: 2500, resets: next + 40)])
        try await store.recordLimitSamples([sample(9, at: 3700, resets: next)])

        let hourly = try await reader.limitSamples(in: allTime, bucket: 3600)
        XCTAssertEqual(hourly, [sample(92, at: 900, resets: 1830), sample(40, .sevenDay, at: 1900, resets: 86_400),
                                sample(6, at: 2500, resets: next + 40), sample(9, at: 3700, resets: next)],
                       "each window's peak, oldest first; jittered resets are one window")
    }

    func testScopedKindsDecodeAndUnknownKindsAreSkipped() async throws {
        let (store, reader, path) = try open(try TempDirectory())
        try await store.recordLimitSamples([sample(10, at: 0)])
        let raw = try SQLiteConnection(path: path)
        try raw.run("INSERT INTO limit_samples (kind, ts, utilization, resets_at) VALUES ('seven_day_haiku', ?, 5, NULL)",
                    [t0.timeIntervalSince1970 + 60])
        try raw.run("INSERT INTO limit_samples (kind, ts, utilization, resets_at) VALUES ('monthly_spend', ?, 9, NULL)",
                    [t0.timeIntervalSince1970 + 120])
        let haiku = try XCTUnwrap(LimitKind(rawValue: "seven_day_haiku"))
        let all = try await reader.limitSamples(in: allTime)
        XCTAssertEqual(all.map(\.kind), [.fiveHour, haiku], "a weekly scoped kind decodes; a non-window kind is skipped")
        let latest = try await reader.latestLimitSamples()
        XCTAssertEqual(Set(latest.keys), [.fiveHour, haiku])
    }

    func testScopedWindowsPersistAndProject() async throws {
        let directory = try TempDirectory()
        let ledger = try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                                   claudeConfigDirectory: directory.path("claude"),
                                                                   copilotHome: directory.path("copilot"),
                                                                   pricingOverridesURL: nil, watchForChanges: false))
        let now = Date()
        func fetch(_ fable: Double) throws -> ClaudeLimits {
            try ClaudeLimits.decode(Data("""
                {"five_hour":{"utilization":5,"resets_at":"2099-01-01T00:00:00Z"},
                 "model_scoped":[{"display_name":"Fable","utilization":\(fable),"resets_at":"2099-01-05T00:00:00Z"}]}
                """.utf8))
        }
        let fable = try XCTUnwrap(LimitKind.scoped(displayName: "Fable"))
        try await ledger.recordLimits(try fetch(20), at: now.addingTimeInterval(-7200))
        let previous = try await ledger.recordLimits(try fetch(30), at: now)
        XCTAssertEqual(previous[fable]?.utilization, 20)

        let history = try await ledger.limitHistory(days: 1, now: now)
        XCTAssertEqual(history.filter { $0.kind == fable }.map(\.utilization), [20, 30])
        let projections = try await ledger.limitProjections(now: now)
        let projection = try XCTUnwrap(projections[fable])
        XCTAssertEqual(try XCTUnwrap(projection.burnRatePerHour), 5, accuracy: 1e-9)
        XCTAssertEqual(projection.windowStart, Timestamps.parse("2098-12-29T00:00:00Z"))
    }

    func testLedgerRecordsFetchesAndProjects() async throws {
        let directory = try TempDirectory()
        let ledger = try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                                   claudeConfigDirectory: directory.path("claude"),
                                                                   copilotHome: directory.path("copilot"),
                                                                   pricingOverridesURL: nil, watchForChanges: false))
        let now = Date()
        let reset = Timestamps.parse("2099-01-01T00:00:00Z")!
        func fetch(_ fiveHour: Double) throws -> ClaudeLimits {
            try ClaudeLimits.decode(Data("""
                {"five_hour":{"utilization":\(fiveHour),"resets_at":"2099-01-01T00:00:00Z"},
                 "seven_day":{"utilization":12,"resets_at":"2099-01-05T00:00:00Z"}}
                """.utf8))
        }
        let first = try await ledger.recordLimits(try fetch(20), at: now.addingTimeInterval(-7200))
        XCTAssertEqual(first, [:])
        try await ledger.recordLimits(try fetch(30), at: now.addingTimeInterval(-3000))
        let previous = try await ledger.recordLimits(try fetch(60), at: now)
        XCTAssertEqual(previous[.fiveHour]?.utilization, 30)
        XCTAssertEqual(previous[.sevenDay]?.utilization, 12)

        let history = try await ledger.limitHistory(days: 7, now: now)
        XCTAssertEqual(history.filter { $0.kind == .fiveHour }.map(\.utilization), [20, 30, 60])
        XCTAssertEqual(history.filter { $0.kind == .sevenDay }.count, 3, "repeats over 15 min apart are kept")
        let latest = try await ledger.latestLimitSamples()
        XCTAssertEqual(latest[.fiveHour]?.resetsAt, reset)

        let projections = try await ledger.limitProjections(now: now)
        let fiveHour = try XCTUnwrap(projections[.fiveHour])
        XCTAssertEqual(fiveHour.windowSamples.count, 3)
        XCTAssertEqual(try XCTUnwrap(fiveHour.burnRatePerHour), 36, accuracy: 1e-6, "the last hour only")
        XCTAssertEqual(fiveHour.projectedUtilization, 100)
        XCTAssertNotNil(fiveHour.limitReachedAt)
        XCTAssertEqual(projections[.sevenDay]?.burnRatePerHour, 0)

        let allowance = try await ledger.copilotAllowance(settings: AppSettings(), now: now)
        XCTAssertEqual(allowance.used, 0)
        XCTAssertEqual(allowance.remaining, 300)
        XCTAssertEqual(allowance.month, CopilotAllowance.month(containing: now))
    }
}
