import Foundation

public enum SampleKind: String, Sendable {
    /// A level read as is (tok/s, KV cache %, queue length).
    case gauge
    /// A running total; buckets hold its increase.
    case counter
}

/// One raw reading of a series.
public struct SampleObservation: Sendable, Equatable {
    public var series: String
    public var ts: Date
    public var value: Double
    public var kind: SampleKind

    public init(series: String, ts: Date, value: Double, kind: SampleKind) {
        self.series = series
        self.ts = ts
        self.value = value
        self.kind = kind
    }
}

/// A `samples` row: the readings of one series in `[start, start + resolution)`.
///
/// Gauges: `sum` adds the readings, `min`/`max` bound them, `mean` is their average. Counters: `sum` is the
/// counter's increase in the bucket and `min`/`max` bound the raw counter readings, so the latest bucket's `max`
/// is the baseline for the next increase after a restart.
public struct SampleBucket: Sendable, Equatable, Hashable {
    public var series: String
    /// Seconds.
    public var resolution: Int
    /// Unix seconds, a multiple of `resolution`.
    public var start: Int
    public var n: Int
    public var sum: Double
    public var min: Double?
    public var max: Double?

    public init(series: String, resolution: Int, start: Int, n: Int, sum: Double, min: Double?, max: Double?) {
        self.series = series
        self.resolution = resolution
        self.start = start
        self.n = n
        self.sum = sum
        self.min = min
        self.max = max
    }

    public var startDate: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
    public var mean: Double? { n > 0 ? sum / Double(n) : nil }

    /// Adds `other`'s readings to this bucket (n and sum add, min/max widen), keeping this bucket's place.
    public func merged(with other: SampleBucket) -> SampleBucket {
        var result = self
        result.n += other.n
        result.sum += other.sum
        result.min = [min, other.min].compactMap { $0 }.min()
        result.max = [max, other.max].compactMap { $0 }.max()
        return result
    }
}

/// The last raw reading of a counter, the base for its next increase.
public struct CounterReading: Sendable, Equatable {
    public var ts: Date
    public var value: Double

    public init(ts: Date, value: Double) {
        self.ts = ts
        self.value = value
    }
}

/// Moving buckets older than `after` from `from` to the coarser `to` resolution.
public struct SampleRollup: Sendable, Equatable {
    public var from: Int
    public var to: Int
    public var after: TimeInterval

    public init(from: Int, to: Int, after: TimeInterval) {
        self.from = from
        self.to = to
        self.after = after
    }

    /// Buckets starting before this (unix seconds) roll up. Aligned to `to`, so a coarse bucket is filled from
    /// all of its fine buckets at once and never ends up split across two resolutions.
    public func cutoff(now: Date) -> Int {
        SampleAggregator.floor(now.timeIntervalSince1970 - after, to)
    }
}

/// Turns raw observations into 60 s buckets for the `samples` table and rolls old buckets up. Pure; the Store
/// keeps one instance, so counter baselines live as long as the app runs (and are re-seeded from the latest
/// stored bucket after a restart).
public struct SampleAggregator: Sendable {
    public static let resolution = 60
    public static let rollups = [SampleRollup(from: 60, to: 900, after: 7 * 86_400),
                                 SampleRollup(from: 900, to: 3600, after: 90 * 86_400)]

    /// A counter increase across a longer silence (app quit, Mac asleep) can't be placed in time, so it starts
    /// a new baseline instead of landing as one spike in the bucket after the gap.
    public var counterGapLimit: TimeInterval
    public private(set) var lastCounter: [String: CounterReading]

    public init(counterGapLimit: TimeInterval = 6 * 3600, lastCounter: [String: CounterReading] = [:]) {
        self.counterGapLimit = counterGapLimit
        self.lastCounter = lastCounter
    }

    /// Seeds a counter's baseline (e.g. from the latest stored bucket) unless a later reading is already known.
    public mutating func seed(_ series: String, _ reading: CounterReading) {
        if let known = lastCounter[series], known.ts >= reading.ts { return }
        lastCounter[series] = reading
    }

    public mutating func forget(_ series: String) {
        lastCounter[series] = nil
    }

    /// The buckets these observations add, sorted by series and start; merge them into what is stored.
    ///
    /// A counter's increase goes to the bucket of the reading that shows it. A drop means the server restarted,
    /// so the new value counts from 0. The first reading of a counter (no baseline) only sets the baseline. Late
    /// counter readings (not after the last one) and non-finite values are skipped.
    public mutating func add(_ observations: [SampleObservation]) -> [SampleBucket] {
        var buckets: [BucketKey: SampleBucket] = [:]
        func put(_ series: String, _ ts: Date, n: Int, sum: Double, reading: Double) {
            let start = Self.floor(ts.timeIntervalSince1970, Self.resolution)
            let key = BucketKey(series: series, start: start)
            let bucket = SampleBucket(series: series, resolution: Self.resolution, start: start, n: n, sum: sum,
                                      min: reading, max: reading)
            buckets[key] = buckets[key]?.merged(with: bucket) ?? bucket
        }
        for observation in observations.sorted(by: { $0.ts < $1.ts }) where observation.value.isFinite {
            switch observation.kind {
            case .gauge:
                put(observation.series, observation.ts, n: 1, sum: observation.value, reading: observation.value)
            case .counter:
                let previous = lastCounter[observation.series]
                if let previous, observation.ts <= previous.ts { continue }
                var increase = 0.0
                if let previous, observation.ts.timeIntervalSince(previous.ts) <= counterGapLimit {
                    increase = observation.value >= previous.value ? observation.value - previous.value : observation.value
                }
                lastCounter[observation.series] = CounterReading(ts: observation.ts, value: observation.value)
                put(observation.series, observation.ts, n: 1, sum: increase, reading: observation.value)
            }
        }
        return buckets.values.sorted { ($0.series, $0.start) < ($1.series, $1.start) }
    }

    /// Regroups buckets into `resolution`-second buckets, merging n/sum/min/max. Buckets already at least that
    /// coarse keep their own resolution, so re-running a rollup changes nothing.
    public static func rollup(_ buckets: [SampleBucket], to resolution: Int) -> [SampleBucket] {
        var result: [RollupKey: SampleBucket] = [:]
        for bucket in buckets {
            let target = Swift.max(bucket.resolution, resolution)
            let start = floor(TimeInterval(bucket.start), target)
            var moved = bucket
            moved.resolution = target
            moved.start = start
            let key = RollupKey(series: bucket.series, resolution: target, start: start)
            result[key] = result[key]?.merged(with: moved) ?? moved
        }
        return result.values.sorted { ($0.series, $0.start, $0.resolution) < ($1.series, $1.start, $1.resolution) }
    }

    static func floor(_ seconds: TimeInterval, _ resolution: Int) -> Int {
        Int((seconds / TimeInterval(resolution)).rounded(.down)) * resolution
    }

    private struct BucketKey: Hashable {
        var series: String
        var start: Int
    }

    private struct RollupKey: Hashable {
        var series: String
        var resolution: Int
        var start: Int
    }
}

/// One local day of a series: the sum of its buckets (a counter's increase) and how many readings it had, so a
/// day without readings (server off, app not running) can be told from an idle one.
public struct DailySampleSum: Sendable, Equatable, Identifiable {
    /// Local midnight.
    public var day: Date
    public var sum: Double
    public var readings: Int

    public init(day: Date, sum: Double, readings: Int) {
        self.day = day
        self.sum = sum
        self.readings = readings
    }

    public var id: Date { day }
}
