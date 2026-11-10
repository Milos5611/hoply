import AgentKit
import Foundation
import XCTest

final class SampleAggregatorTests: XCTestCase {
    /// On a whole hour, so 60, 900 and 3600 s buckets all start here.
    private let t0 = Date(timeIntervalSince1970: 1_794_200_400)
    private var base: Int { Int(t0.timeIntervalSince1970) }

    private func gauge(_ value: Double, at seconds: TimeInterval, _ series: String = "g") -> SampleObservation {
        SampleObservation(series: series, ts: t0.addingTimeInterval(seconds), value: value, kind: .gauge)
    }

    private func counter(_ value: Double, at seconds: TimeInterval, _ series: String = "c") -> SampleObservation {
        SampleObservation(series: series, ts: t0.addingTimeInterval(seconds), value: value, kind: .counter)
    }

    private func bucket(_ series: String, _ offset: Int, res: Int = 60, n: Int, sum: Double, min: Double?,
                        max: Double?) -> SampleBucket {
        SampleBucket(series: series, resolution: res, start: base + offset, n: n, sum: sum, min: min, max: max)
    }

    func testGaugeBuckets() throws {
        var aggregator = SampleAggregator()
        let buckets = aggregator.add([gauge(30, at: 20), gauge(10, at: 0), gauge(20, at: 59.9), gauge(5, at: 60)])
        XCTAssertEqual(buckets, [bucket("g", 0, n: 3, sum: 60, min: 10, max: 30),
                                 bucket("g", 60, n: 1, sum: 5, min: 5, max: 5)])
        XCTAssertEqual(buckets.first?.mean, 20)
        XCTAssertEqual(buckets.first?.startDate, t0)
        XCTAssertEqual(aggregator.add([gauge(.nan, at: 120), gauge(.infinity, at: 121)]), [])
    }

    func testCounterDeltas() {
        var aggregator = SampleAggregator()
        XCTAssertEqual(aggregator.add([counter(100, at: 5)]), [bucket("c", 0, n: 1, sum: 0, min: 100, max: 100)],
                       "the first reading only sets the baseline")
        XCTAssertEqual(aggregator.add([counter(150, at: 30), counter(210, at: 65), counter(210, at: 70)]),
                       [bucket("c", 0, n: 1, sum: 50, min: 150, max: 150),
                        bucket("c", 60, n: 2, sum: 60, min: 210, max: 210)])
        XCTAssertEqual(aggregator.lastCounter["c"], CounterReading(ts: t0.addingTimeInterval(70), value: 210))
    }

    func testCounterReset() {
        var aggregator = SampleAggregator()
        let buckets = aggregator.add([counter(1000, at: 0), counter(1200, at: 60), counter(30, at: 120),
                                      counter(80, at: 180)])
        XCTAssertEqual(buckets.map(\.sum), [0, 200, 30, 50], "after a drop the new value counts from 0")
        XCTAssertEqual(buckets.map(\.max), [1000, 1200, 30, 80])
    }

    func testLateDuplicateAndSeededCounterReadings() {
        var aggregator = SampleAggregator()
        _ = aggregator.add([counter(500, at: 120)])
        XCTAssertEqual(aggregator.add([counter(400, at: 60), counter(500, at: 120)]), [],
                       "readings not after the last one are skipped")

        var restarted = SampleAggregator()
        restarted.seed("c", CounterReading(ts: t0, value: 500))
        restarted.seed("c", CounterReading(ts: t0.addingTimeInterval(-60), value: 450))
        XCTAssertEqual(restarted.lastCounter["c"]?.value, 500, "an older seed doesn't replace a newer baseline")
        XCTAssertEqual(restarted.add([counter(530, at: 90)]).map(\.sum), [30])
    }

    func testAGap() {
        var aggregator = SampleAggregator(counterGapLimit: 3600)
        let gauges = aggregator.add([gauge(1, at: 0), gauge(2, at: 1800)])
        XCTAssertEqual(gauges.map(\.start), [base, base + 1800], "nothing is filled in for the silence")

        XCTAssertEqual(aggregator.add([counter(100, at: 0), counter(400, at: 3600)]).map(\.sum), [0, 300],
                       "a short gap's increase lands in the bucket after it")
        XCTAssertEqual(aggregator.add([counter(900, at: 7201), counter(950, at: 7260)]).map(\.sum), [0, 50],
                       "after a longer gap the increase can't be placed, so it starts a new baseline")
    }

    func testARollupBoundary() {
        let now = t0.addingTimeInterval(7 * 86_400 + 1000)
        let rollup = SampleAggregator.rollups[0]
        XCTAssertEqual(rollup.cutoff(now: now), base + 900, "now − 7 days, floored to 15 minutes")
        XCTAssertEqual(SampleAggregator.rollups[1], SampleRollup(from: 900, to: 3600, after: 90 * 86_400))

        let fine = [bucket("g", 840, n: 2, sum: 10, min: 4, max: 6),
                    bucket("g", 0, n: 1, sum: 3, min: 3, max: 3),
                    bucket("g", 900, n: 1, sum: 9, min: 9, max: 9),
                    bucket("h", 60, n: 1, sum: 1, min: 1, max: 1)]
        let old = fine.filter { $0.start < rollup.cutoff(now: now) }
        XCTAssertEqual(old.count, 3, "the 15:00 bucket stays fine")
        XCTAssertEqual(SampleAggregator.rollup(old, to: 900),
                       [bucket("g", 0, res: 900, n: 3, sum: 13, min: 3, max: 6),
                        bucket("h", 0, res: 900, n: 1, sum: 1, min: 1, max: 1)])
    }

    func testRerollingUpChangesNothing() {
        let fine = (0..<120).map { bucket("c", $0 * 60, n: 1, sum: Double($0), min: Double($0), max: Double($0)) }
        let quarter = SampleAggregator.rollup(fine, to: 900)
        XCTAssertEqual(quarter.count, 8)
        XCTAssertEqual(quarter.map(\.sum).reduce(0, +), fine.map(\.sum).reduce(0, +))
        XCTAssertEqual(SampleAggregator.rollup(quarter, to: 900), quarter)
        let hourly = SampleAggregator.rollup(quarter, to: 3600)
        XCTAssertEqual(hourly, SampleAggregator.rollup(fine, to: 3600))
        XCTAssertEqual(hourly.map(\.n), [60, 60])
        XCTAssertEqual(SampleAggregator.rollup(hourly, to: 900), hourly, "coarser buckets are never split")
    }

    func testMergeKeepsMissingBounds() {
        let empty = SampleBucket(series: "g", resolution: 60, start: base, n: 0, sum: 0, min: nil, max: nil)
        XCTAssertNil(empty.mean)
        XCTAssertEqual(empty.merged(with: bucket("g", 0, n: 1, sum: 2, min: 2, max: 2)),
                       bucket("g", 0, n: 1, sum: 2, min: 2, max: 2))
    }
}

final class ModelServerSeriesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_400)

    private func snapshot(finished: Int, running: Int, prompt: Int = 1000, kv: Double = 0.25,
                          at seconds: TimeInterval) throws -> ModelServerSnapshot {
        let text = """
            tensorfold:num_requests_running 1
            tensorfold:num_requests_waiting 2
            tensorfold:generation_tokens_total \(finished)
            tensorfold:generation_tokens_running \(running)
            tensorfold:prompt_tokens_total \(prompt)
            tensorfold:kv_cache_usage_perc{stream="0"} \(kv)
            """
        return try metrics(text, at: t0.addingTimeInterval(seconds))
    }

    private func metrics(_ text: String, at time: Date) throws -> ModelServerSnapshot {
        try ModelServerDetector.snapshot(from: [.metrics: .success(Data(text.utf8))], engine: nil, at: time,
                                         endpoint: "Box").get()
    }

    private func observations(current: ModelServerSnapshot, previous: ModelServerSnapshot?) -> [SampleObservation] {
        ModelServerSeries.observations(ModelServerStatus.compute(previous: previous, current: current),
                                       server: ModelServer.legacyID)
    }

    func testTheFixtureMapsToTheStableSet() throws {
        let snapshot = try metrics(try Fixture.text("tensorfold_metrics.txt"), at: t0)
        XCTAssertEqual(snapshot.metrics.generationTokensCounter, 54353)
        let first = observations(current: snapshot, previous: nil)
        XCTAssertEqual(first.map(\.series), [ModelServerSeries.kvCachePercent, ModelServerSeries.running,
                                             ModelServerSeries.waiting, ModelServerSeries.memoryBytes,
                                             ModelServerSeries.generatedTokens, ModelServerSeries.promptTokens],
                       "no rates without a previous poll")
        XCTAssertEqual(first.filter { $0.kind == .counter }.map(\.value), [54353, 7_725_987])
        XCTAssertTrue(first.allSatisfy { $0.ts == t0 })
        XCTAssertEqual(Set(ModelServerSeries.all).count, 8)
    }

    func testRatesGaugesAndCounters() throws {
        let previous = try snapshot(finished: 1000, running: 0, at: 0)
        let current = try snapshot(finished: 1000, running: 250, prompt: 3000, at: 5)
        let values = Dictionary(uniqueKeysWithValues: observations(current: current, previous: previous)
            .map { ($0.series, ($0.value, $0.kind)) })
        XCTAssertEqual(values[ModelServerSeries.generationTokensPerSecond]?.0, 50, "live streams count toward tok/s")
        XCTAssertEqual(values[ModelServerSeries.promptTokensPerSecond]?.0, 400)
        XCTAssertEqual(values[ModelServerSeries.kvCachePercent]?.0, 25)
        XCTAssertEqual(values[ModelServerSeries.running]?.0, 1)
        XCTAssertEqual(values[ModelServerSeries.waiting]?.0, 2)
        XCTAssertEqual(values[ModelServerSeries.generatedTokens]?.0, 1000, "finished tokens only")
        XCTAssertEqual(values[ModelServerSeries.generatedTokens]?.1, .counter)
        XCTAssertEqual(values[ModelServerSeries.waiting]?.1, .gauge)
    }

    func testACancelledStreamIsNotARestart() throws {
        var aggregator = SampleAggregator()
        let polls = [try snapshot(finished: 1000, running: 0, at: 0), try snapshot(finished: 1000, running: 400, at: 5),
                     try snapshot(finished: 1000, running: 0, at: 10), try snapshot(finished: 1300, running: 0, at: 15)]
        var generated = 0.0
        for (index, poll) in polls.enumerated() {
            let polled = observations(current: poll, previous: index > 0 ? polls[index - 1] : nil)
            generated += aggregator.add(polled)
                .filter { $0.series == ModelServerSeries.generatedTokens }.map(\.sum).reduce(0, +)
        }
        XCTAssertEqual(generated, 300, "the 400 tokens of the cancelled stream never count as a restart")
    }
}
