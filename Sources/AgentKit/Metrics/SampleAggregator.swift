import Foundation

public enum SampleKind: String, Sendable {
    case gauge
    case counter
}

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

public struct SampleBucket: Sendable, Equatable, Hashable {
    public var series: String
    public var resolution: Int
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

    public func merged(with other: SampleBucket) -> SampleBucket {
        var result = self
        result.n += other.n
        result.sum += other.sum
        result.min = [min, other.min].compactMap { $0 }.min()
        result.max = [max, other.max].compactMap { $0 }.max()
        return result
    }
}

public struct CounterReading: Sendable, Equatable {
    public var ts: Date
    public var value: Double

    public init(ts: Date, value: Double) {
        self.ts = ts
        self.value = value
    }
}

public struct SampleRollup: Sendable, Equatable {
    public var from: Int
    public var to: Int
    public var after: TimeInterval

    public init(from: Int, to: Int, after: TimeInterval) {
        self.from = from
        self.to = to
        self.after = after
    }

    public func cutoff(now: Date) -> Int {
        SampleAggregator.floor(now.timeIntervalSince1970 - after, to)
    }
}

public struct SampleAggregator: Sendable {
    public static let resolution = 60
    public static let rollups = [SampleRollup(from: 60, to: 900, after: 7 * 86_400),
                                 SampleRollup(from: 900, to: 3600, after: 90 * 86_400)]

    public var counterGapLimit: TimeInterval
    public private(set) var lastCounter: [String: CounterReading]

    public init(counterGapLimit: TimeInterval = 6 * 3600, lastCounter: [String: CounterReading] = [:]) {
        self.counterGapLimit = counterGapLimit
        self.lastCounter = lastCounter
    }

    public mutating func seed(_ series: String, _ reading: CounterReading) {
        if let known = lastCounter[series], known.ts >= reading.ts { return }
        lastCounter[series] = reading
    }

    public mutating func forget(_ series: String) {
        lastCounter[series] = nil
    }

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

public struct DailySampleSum: Sendable, Equatable, Identifiable {
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
