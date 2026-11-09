import Foundation

/// A Claude plan-usage window. Raw values are the API's keys and the `limit_samples.kind` column.
public enum LimitKind: String, CaseIterable, Codable, Sendable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case sevenDayOpus = "seven_day_opus"
    case sevenDaySonnet = "seven_day_sonnet"

    public var windowLength: TimeInterval {
        self == .fiveHour ? 5 * 3600 : 7 * 86_400
    }

    public var displayName: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .sevenDay: return "Weekly"
        case .sevenDayOpus: return "Weekly Opus"
        case .sevenDaySonnet: return "Weekly Sonnet"
        }
    }

    /// How far back the burn rate looks, and the shortest span of samples it accepts.
    var burnRateLookback: TimeInterval { self == .fiveHour ? 3600 : 86_400 }
    var burnRateMinimumSpan: TimeInterval { self == .fiveHour ? 600 : 3600 }
}

/// One reading of a plan-usage window (a `limit_samples` row).
public struct LimitSample: Sendable, Equatable, Hashable {
    public var kind: LimitKind
    public var ts: Date
    /// Percent used, 0…100.
    public var utilization: Double
    /// Nil before the window has started.
    public var resetsAt: Date?

    public init(kind: LimitKind, ts: Date, utilization: Double, resetsAt: Date?) {
        self.kind = kind
        self.ts = ts
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    /// The API's `resets_at` jitters between calls, while two different windows of a kind reset hours or days
    /// apart, so a few minutes of slack tells them apart safely.
    public static let windowTolerance: TimeInterval = 300

    public func isSameWindow(as other: LimitSample) -> Bool {
        guard kind == other.kind else { return false }
        switch (resetsAt, other.resetsAt) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) <= Self.windowTolerance
        default: return false
        }
    }

    /// `resetsAt − windowLength`.
    public var windowStart: Date? { resetsAt.map { $0.addingTimeInterval(-kind.windowLength) } }
}

extension ClaudeLimits {
    public func samples(at time: Date) -> [LimitSample] {
        let windows: [(LimitKind, Window?)] = [(.fiveHour, fiveHour), (.sevenDay, sevenDay),
                                               (.sevenDayOpus, sevenDayOpus), (.sevenDaySonnet, sevenDaySonnet)]
        return windows.compactMap { kind, window in
            window.map { LimitSample(kind: kind, ts: time, utilization: $0.utilization, resetsAt: $0.resetsAt) }
        }
    }
}

/// Where one window is heading: its current-window samples, a burn rate and what that rate means at reset.
public struct LimitsProjection: Sendable, Equatable {
    public var kind: LimitKind
    /// The latest sample.
    public var current: LimitSample
    /// The current window's samples, oldest first: same `resetsAt` as the latest, after its last utilization drop.
    public var windowSamples: [LimitSample]
    /// Percent per hour (least squares, ≥ 0); nil with fewer than 2 samples or too short a span in the lookback.
    public var burnRatePerHour: Double?
    /// Utilization at reset at the current rate, capped at 100.
    public var projectedUtilization: Double?
    /// When the rate reaches 100%, if that is before the reset. Nil when it won't, or when already at 100%.
    public var limitReachedAt: Date?

    public var utilization: Double { current.utilization }
    public var resetsAt: Date? { current.resetsAt }
    /// Sum ledger spend from here to see what the window has cost so far.
    public var windowStart: Date? { current.windowStart }
    public var isAtLimit: Bool { current.utilization >= 100 }

    /// Samples of one kind in any order; nil when there are none. With mixed kinds, the latest sample's kind wins.
    public init?(samples: [LimitSample]) {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard let latest = sorted.last else { return nil }
        var window = sorted.filter { $0.isSameWindow(as: latest) }
        if let drop = window.indices.dropFirst().last(where: { window[$0].utilization < window[$0 - 1].utilization }) {
            window.removeFirst(drop)
        }
        kind = latest.kind
        current = latest
        windowSamples = window

        let recent = window.filter { $0.ts >= latest.ts.addingTimeInterval(-latest.kind.burnRateLookback) }
        guard recent.count >= 2, let first = recent.first,
              latest.ts.timeIntervalSince(first.ts) >= latest.kind.burnRateMinimumSpan,
              let slope = Self.slopePerHour(recent) else { return }
        let rate = max(slope, 0)
        burnRatePerHour = rate
        guard let resetsAt = latest.resetsAt else { return }
        let hoursLeft = max(resetsAt.timeIntervalSince(latest.ts), 0) / 3600
        projectedUtilization = min(latest.utilization + rate * hoursLeft, 100)
        if rate > 0, latest.utilization < 100 {
            let reached = latest.ts.addingTimeInterval((100 - latest.utilization) / rate * 3600)
            if reached < resetsAt { limitReachedAt = reached }
        }
    }

    /// One projection per kind present in `samples`.
    public static func projections(_ samples: [LimitSample]) -> [LimitKind: LimitsProjection] {
        Dictionary(grouping: samples, by: \.kind).compactMapValues { LimitsProjection(samples: $0) }
    }

    private static func slopePerHour(_ samples: [LimitSample]) -> Double? {
        guard let origin = samples.first?.ts else { return nil }
        let xs = samples.map { $0.ts.timeIntervalSince(origin) / 3600 }
        let ys = samples.map(\.utilization)
        let n = Double(samples.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var covariance = 0.0
        var variance = 0.0
        for (x, y) in zip(xs, ys) {
            covariance += (x - meanX) * (y - meanY)
            variance += (x - meanX) * (x - meanX)
        }
        return variance > 0 ? covariance / variance : nil
    }
}
