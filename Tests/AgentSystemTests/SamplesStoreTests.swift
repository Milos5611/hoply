import AgentKit
import AgentSystem
import Foundation
import XCTest

final class SamplesStoreTests: XCTestCase {
    /// On a whole hour (UTC midnight is 4 h earlier, 1_794_182_400).
    private let t0 = Date(timeIntervalSince1970: 1_794_196_800)
    private var base: Int { Int(t0.timeIntervalSince1970) }
    private let allTime = DateInterval(start: .distantPast, end: .distantFuture)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func open(_ directory: TempDirectory) throws -> (Store, StoreReader, String) {
        let path = directory.path("hoply.sqlite")
        let store = try Store(path: path, resolver: ProjectResolver(home: "/Users/dev"))
        return (store, try StoreReader(path: path), path)
    }

    private func gauge(_ value: Double, at seconds: TimeInterval, _ series: String = "g") -> SampleObservation {
        SampleObservation(series: series, ts: t0.addingTimeInterval(seconds), value: value, kind: .gauge)
    }

    private func counter(_ value: Double, at seconds: TimeInterval, _ series: String = "c") -> SampleObservation {
        SampleObservation(series: series, ts: t0.addingTimeInterval(seconds), value: value, kind: .counter)
    }

    private func insert(_ db: SQLiteConnection, _ series: String, res: Int, at bucket: Int, n: Int = 1, sum: Double) throws {
        try db.run("INSERT INTO samples (series, res, bucket, n, sum, min, max) VALUES (?, ?, ?, ?, ?, ?, ?)",
                   [series, res, bucket, n, sum, sum / Double(n), sum / Double(n)])
    }

    private func rows(_ db: SQLiteConnection, _ series: String) throws -> [(res: Int, bucket: Int, n: Int, sum: Double)] {
        try db.query("SELECT res, bucket, n, sum FROM samples WHERE series = ? ORDER BY res, bucket", [series]) {
            (res: $0.int(0), bucket: $0.int(1), n: $0.int(2), sum: $0.double(3))
        }
    }

    func testPollsMergeIntoTheirBucket() async throws {
        let (store, reader, _) = try open(try TempDirectory())
        try await store.recordSamples([gauge(10, at: 5)], now: t0)
        try await store.recordSamples([gauge(30, at: 35)], now: t0)
        try await store.recordSamples([gauge(20, at: 65)], now: t0)
        let buckets = try await reader.samples("g", in: allTime)
        XCTAssertEqual(buckets, [
            SampleBucket(series: "g", resolution: 60, start: base, n: 2, sum: 40, min: 10, max: 30),
            SampleBucket(series: "g", resolution: 60, start: base + 60, n: 1, sum: 20, min: 20, max: 20),
        ])
        let fiveMinutes = try await reader.samples("g", resolution: 300, in: allTime)
        XCTAssertEqual(fiveMinutes, [SampleBucket(series: "g", resolution: 300, start: base, n: 3, sum: 60, min: 10, max: 30)])
        let none = try await reader.samples("other", in: allTime)
        XCTAssertEqual(none, [])
    }

    func testACounterKeepsItsBaselineAcrossARestart() async throws {
        let directory = try TempDirectory()
        do {
            let (store, _, _) = try open(directory)
            try await store.recordSamples([counter(100, at: 0)], now: t0)
            try await store.recordSamples([counter(150, at: 30)], now: t0)
        }
        let (store, reader, _) = try open(directory)
        let added = try await store.recordSamples([counter(180, at: 90), gauge(1, at: 90)], now: t0)
        XCTAssertEqual(added.first { $0.series == "c" }?.sum, 30, "the increase since the last stored reading")
        try await store.recordSamples([counter(20, at: 150)], now: t0)
        let sums = try await reader.samples("c", in: allTime).map(\.sum)
        XCTAssertEqual(sums, [50, 30, 20], "a restart of the server counts from 0")
    }

    func testResettingABaselineIgnoresTheNewServersFirstReading() async throws {
        let directory = try TempDirectory()
        do {
            let (store, _, _) = try open(directory)
            try await store.recordSamples([counter(5000, at: 0)], now: t0)
        }
        let (store, reader, _) = try open(directory)
        await store.resetCounterBaselines(["c"])
        try await store.recordSamples([counter(800, at: 60)], now: t0)
        try await store.recordSamples([counter(850, at: 120)], now: t0)
        let sums = try await reader.samples("c", in: allTime).map(\.sum)
        XCTAssertEqual(sums, [0, 0, 50], "neither the stored nor the old in-memory baseline counts against the new server")
    }

    func testAFailedRollupKeepsTheWrittenBaselineAndIsRetried() async throws {
        let (store, reader, path) = try open(try TempDirectory())
        let raw = try SQLiteConnection(path: path)
        let start = Date(timeIntervalSince1970: TimeInterval(Int(Date().timeIntervalSince1970) / 60 * 60))
        func reading(_ value: Double, at seconds: TimeInterval) -> SampleObservation {
            SampleObservation(series: "c", ts: start.addingTimeInterval(seconds), value: value, kind: .counter)
        }
        let old = Int(start.timeIntervalSince1970) / 900 * 900 - 8 * 86_400
        try insert(raw, "g", res: 60, at: old, sum: 1)
        try raw.execute("CREATE TRIGGER no_delete BEFORE DELETE ON samples BEGIN SELECT RAISE(ABORT, 'no'); END")

        let nextDay = start.addingTimeInterval(Store.sampleRollupInterval + 600)
        try await store.recordSamples([reading(100, at: 0)], now: start)
        let written = try await store.recordSamples([reading(150, at: 60)], now: nextDay)
        XCTAssertEqual(written.map(\.sum), [50], "the write stands although the rollup failed")
        XCTAssertEqual(try rows(raw, "g").map(\.res), [60])

        try raw.execute("DROP TRIGGER no_delete")
        try await store.recordSamples([reading(180, at: 120)], now: nextDay)
        let sums = try await reader.samples("c", in: allTime).map(\.sum)
        XCTAssertEqual(sums, [0, 50, 30], "the committed increase is not counted again")
        XCTAssertEqual(try rows(raw, "g").map(\.res), [900], "the failed rollup ran again on the next write")
    }

    func testAFailedWriteKeepsTheStoredSeedAndBaseline() async throws {
        let directory = try TempDirectory()
        do {
            let (store, _, _) = try open(directory)
            try await store.recordSamples([counter(100, at: 0)], now: t0)
            try await store.recordSamples([counter(150, at: 30)], now: t0)
        }
        let (store, reader, path) = try open(directory)
        let raw = try SQLiteConnection(path: path)
        try raw.execute("CREATE TRIGGER no_insert BEFORE INSERT ON samples BEGIN SELECT RAISE(ABORT, 'no'); END")
        do {
            try await store.recordSamples([counter(180, at: 90)], now: t0)
            XCTFail("the write should fail")
        } catch {}
        try raw.execute("DROP TRIGGER no_insert")
        try await store.recordSamples([counter(190, at: 150)], now: t0)
        let sums = try await reader.samples("c", in: allTime).map(\.sum)
        XCTAssertEqual(sums, [50, 40], "counted from the stored 150, not from the reading whose write failed")
    }

    func testRollupAtOpenMovesOldBucketsAndIsIdempotent() async throws {
        let directory = try TempDirectory()
        let path = directory.path("hoply.sqlite")
        _ = try Store(path: path, resolver: ProjectResolver(home: "/Users/dev"))
        let raw = try SQLiteConnection(path: path)
        let now = Int(Date().timeIntervalSince1970) / 3600 * 3600
        let eightDays = now - 8 * 86_400
        let hundredDays = now - 100 * 86_400
        for minute in 0..<30 { try insert(raw, "g", res: 60, at: eightDays + minute * 60, sum: Double(minute)) }
        try insert(raw, "g", res: 60, at: now - 3600, sum: 7)
        for quarter in 0..<4 { try insert(raw, "g", res: 900, at: hundredDays + quarter * 900, n: 15, sum: 15) }

        let (store, reader, _) = try open(directory)
        let afterOpen = try rows(raw, "g")
        XCTAssertEqual(afterOpen.filter { $0.res == 60 }.map(\.bucket), [now - 3600], "only the recent minute stays fine")
        XCTAssertEqual(afterOpen.filter { $0.res == 900 }.map(\.bucket), [eightDays, eightDays + 900])
        XCTAssertEqual(afterOpen.filter { $0.res == 900 }.map(\.n), [15, 15])
        XCTAssertEqual(afterOpen.filter { $0.res == 3600 }.map(\.bucket), [hundredDays])
        XCTAssertEqual(afterOpen.filter { $0.res == 3600 }.map(\.n), [60])
        XCTAssertEqual(afterOpen.map(\.sum).reduce(0, +), Double((0..<30).reduce(0, +)) + 7 + 60, "nothing is lost")

        let movedAgain = try await store.rollUpSamples()
        XCTAssertEqual(movedAgain, 0)
        XCTAssertEqual(try rows(raw, "g").map(\.sum), afterOpen.map(\.sum))

        let month = try await reader.samples("g", resolution: 60,
                                             in: DateInterval(start: Date(timeIntervalSince1970: TimeInterval(eightDays)),
                                                              end: Date(timeIntervalSince1970: TimeInterval(now))))
        XCTAssertEqual(month.map(\.resolution), [900, 900, 60], "rolled-up stretches come back at their resolution")
    }

    func testRollupBoundaryAndDailyRun() async throws {
        let (store, reader, path) = try open(try TempDirectory())
        let raw = try SQLiteConnection(path: path)
        let later = Date().addingTimeInterval(2 * 86_400)
        let cutoff = SampleAggregator.rollups[0].cutoff(now: later)
        try insert(raw, "g", res: 60, at: cutoff - 960, sum: 1)
        try insert(raw, "g", res: 60, at: cutoff - 60, sum: 2)
        try insert(raw, "g", res: 60, at: cutoff, sum: 4)
        try insert(raw, "g", res: 60, at: cutoff + 840, sum: 8)

        try await store.recordSamples([], now: Date().addingTimeInterval(3600))
        XCTAssertEqual(try rows(raw, "g").filter { $0.res == 60 }.count, 4, "not a day since the rollup at open")

        try await store.recordSamples([], now: later)
        let after = try rows(raw, "g")
        XCTAssertEqual(after.map(\.res), [60, 60, 900, 900])
        XCTAssertEqual(after.filter { $0.res == 60 }.map(\.bucket), [cutoff, cutoff + 840],
                       "the quarter hour at the cutoff stays whole at 60 s")
        XCTAssertEqual(after.filter { $0.res == 900 }.map(\.bucket), [cutoff - 1800, cutoff - 900])
        let total = try await reader.samples("g", resolution: 3600, in: allTime).map(\.sum).reduce(0, +)
        XCTAssertEqual(total, 15)
    }

    func testRecentSamplesAndTokensPerDay() async throws {
        let (store, reader, _) = try open(try TempDirectory())
        let generated = ModelServerSeries.generatedTokens
        let prompt = ModelServerSeries.promptTokens
        let rate = ModelServerSeries.generationTokensPerSecond
        // t0 is 04:00 UTC; the day before starts 28 h earlier.
        try await store.recordSamples([counter(1000, at: -6 * 3600, generated), counter(5000, at: -6 * 3600, prompt)],
                                      now: t0)
        try await store.recordSamples([counter(1600, at: -5 * 3600, generated), counter(5900, at: -5 * 3600, prompt)],
                                      now: t0)
        try await store.recordSamples([counter(1800, at: -1800, generated), gauge(40, at: -1800, rate)], now: t0)
        try await store.recordSamples([counter(1900, at: 600, generated), gauge(55, at: 600, rate)], now: t0)

        let days = try await reader.dailySums(generated, days: 3, now: t0, calendar: utc)
        XCTAssertEqual(days.map(\.day.timeIntervalSince1970), [1_794_009_600, 1_794_096_000, 1_794_182_400])
        XCTAssertEqual(days.map(\.sum), [0, 600, 300])
        XCTAssertEqual(days.map(\.readings), [0, 2, 2])

        let ledger = try Ledger(configuration: LedgerConfiguration(
            databasePath: store.databasePath, claudeConfigDirectory: "/nonexistent/claude",
            copilotHome: "/nonexistent/copilot", pricingOverridesURL: nil, watchForChanges: false))
        let perDay = try await ledger.modelTokensPerDay(days: 2, now: t0, calendar: utc)
        XCTAssertEqual(perDay.map(\.generated), [600, 300])
        XCTAssertEqual(perDay.map(\.prompt), [900, 0])
        XCTAssertEqual(perDay.map(\.observed), [true, true])

        let recent = try await reader.recentSamples([rate, generated, "missing"], since: t0.addingTimeInterval(-3600),
                                                    now: t0.addingTimeInterval(700))
        XCTAssertEqual(recent[rate]?.map(\.max), [40, 55])
        XCTAssertEqual(recent[generated]?.map(\.sum), [200, 100])
        XCTAssertNil(recent["missing"])
    }

    func testLedgerRecordsModelPolls() async throws {
        let directory = try TempDirectory()
        let ledger = try Ledger(configuration: LedgerConfiguration(
            databasePath: directory.path("hoply.sqlite"), claudeConfigDirectory: directory.path("claude"),
            copilotHome: directory.path("copilot"), pricingOverridesURL: nil, watchForChanges: false))
        func snapshot(_ generated: Int, at time: Date) -> VLLMSnapshot {
            VLLMSnapshot.from(samples: PrometheusParser.parse("""
                vllm:num_requests_running 2
                vllm:num_requests_waiting 0
                vllm:generation_tokens_total \(generated)
                vllm:prompt_tokens_total 100
                vllm:kv_cache_usage_perc 0.5
                """), at: time)
        }
        let now = Date()
        let first = snapshot(1000, at: now.addingTimeInterval(-5))
        try await ledger.recordModelSamples(VLLMStatus.compute(previous: nil, current: first))
        try await ledger.recordModelSamples(VLLMStatus.compute(previous: first, current: snapshot(1250, at: now)))
        let recent = try await ledger.recentModelSamples(since: now.addingTimeInterval(-600), now: now)
        XCTAssertEqual(Set(recent.keys), Set(ModelServerSeries.all).subtracting([ModelServerSeries.memoryBytes]),
                       "the old poll path never reads memory")
        XCTAssertEqual(recent[ModelServerSeries.generationTokensPerSecond]?.last?.max, 50)
        XCTAssertEqual(recent[ModelServerSeries.kvCachePercent]?.last?.max, 50)
        XCTAssertEqual(recent[ModelServerSeries.generatedTokens]?.map(\.sum).reduce(0, +), 250)
        let today = try await ledger.modelTokensPerDay(days: 1, now: now)
        XCTAssertEqual(today.first?.generated, 250)
    }

    func testLocalModelSpendPerDay() async throws {
        let directory = try TempDirectory()
        let ledger = try Ledger(configuration: LedgerConfiguration(
            databasePath: directory.path("hoply.sqlite"), claudeConfigDirectory: directory.path("claude"),
            copilotHome: directory.path("copilot"), pricingOverridesURL: nil, watchForChanges: false))
        let tokens = TokenCounts(input: 1_000_000, output: 100_000)
        try await ledger.store.apply(LedgerBatch(usage: [
            UsageRecord(dedupeKey: "q1", source: .qwenCode, sessionID: "q", timestamp: t0, model: "qwen3.8-flash",
                        tokens: tokens),
            UsageRecord(dedupeKey: "c1", source: .claudeCode, sessionID: "c", timestamp: t0, model: "Qwen3.8-Flash-Next",
                        tokens: tokens),
            UsageRecord(dedupeKey: "c2", source: .claudeCode, sessionID: "c", timestamp: t0, model: "claude-opus-5-5",
                        tokens: tokens),
        ]))
        let local = try await ledger.localModelSpend(days: 1, now: t0, calendar: utc)
        XCTAssertEqual(Set(local.points.map(\.series)), ["qwen-code", "claude-code"])
        let total = local.points.map(\.totals).reduce(LedgerTotals.zero, +)
        XCTAssertEqual(total.costUSD, 0)
        XCTAssertGreaterThan(total.apiEquivUSD, 0, "saved vs API, priced at the reference model")
        XCTAssertEqual(total.tokens.input, 2_000_000)
        XCTAssertEqual(total.calls, 2)

        let everything = try await ledger.reader.dailySpend(days: 1, split: .source, now: t0, calendar: utc)
        XCTAssertEqual(everything.points.map(\.totals.calls).reduce(0, +), 3, "the default still counts every row")
    }
}
