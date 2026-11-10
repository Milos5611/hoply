import Foundation

/// A Claude plan-usage window, stored as `limit_samples.kind`. The fixed windows use the API's keys; a
/// model-scoped weekly window is `seven_day_<slug of its display name>`, so it keeps one kind across fetches and
/// a scoped "Opus" window is the same kind as `seven_day_opus`.
public struct LimitKind: RawRepresentable, Hashable, Comparable, Codable, Sendable, CaseIterable,
                         CustomStringConvertible {
    public let rawValue: String

    public static let fiveHour = LimitKind(checked: "five_hour")
    public static let sevenDay = LimitKind(checked: "seven_day")
    public static let sevenDayOpus = LimitKind(checked: "seven_day_opus")
    public static let sevenDaySonnet = LimitKind(checked: "seven_day_sonnet")

    /// The fixed windows, in display order. Scoped windows come and go with the API's response.
    public static var allCases: [LimitKind] { [.fiveHour, .sevenDay, .sevenDayOpus, .sevenDaySonnet] }

    /// `five_hour`, `seven_day` or `seven_day_<slug>`; anything else is not a window this build understands.
    public init?(rawValue: String) {
        if rawValue == "five_hour" || rawValue == "seven_day" {
            self.rawValue = rawValue
            return
        }
        let prefix = "seven_day_"
        guard rawValue.hasPrefix(prefix) else { return nil }
        let slug = String(rawValue.dropFirst(prefix.count))
        guard !slug.isEmpty, Self.slug(slug) == slug else { return nil }
        self.rawValue = rawValue
    }

    private init(checked rawValue: String) {
        self.rawValue = rawValue
    }

    /// The weekly window of one model (the API's `model_scoped` entries); nil for a name without letters or digits.
    public static func scoped(displayName: String) -> LimitKind? {
        let slug = slug(displayName)
        return slug.isEmpty ? nil : LimitKind(checked: "seven_day_" + slug)
    }

    /// Lowercase ASCII letters and digits, every other run of characters collapsed to one `_`.
    static func slug(_ text: String) -> String {
        var result = ""
        var pendingSeparator = false
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingSeparator, !result.isEmpty { result.append("_") }
                pendingSeparator = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        return result
    }

    public var isFixed: Bool { Self.allCases.contains(self) }

    public var windowLength: TimeInterval {
        self == .fiveHour ? 5 * 3600 : 7 * 86_400
    }

    /// "5-hour", "Weekly", "Weekly Opus"; a scoped window's name is rebuilt from its slug ("Weekly Sonnet 4.5"),
    /// so prefer `ClaudeLimits.ScopedWindow.displayName` while a live fetch has it.
    public var displayName: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .sevenDay: return "Weekly"
        default: return "Weekly \(scopeName)"
        }
    }

    /// The model part of a weekly window's name ("Opus", "Sonnet 4.5"); empty for the 5-hour and weekly windows.
    public var scopeName: String {
        guard rawValue.hasPrefix("seven_day_") else { return "" }
        var name = ""
        var previousWasNumber = false
        for part in rawValue.dropFirst("seven_day_".count).split(separator: "_") {
            let isNumber = part.allSatisfy(\.isNumber)
            if !name.isEmpty { name += isNumber && previousWasNumber ? "." : " " }
            name += isNumber ? String(part) : part.prefix(1).uppercased() + part.dropFirst()
            previousWasNumber = isNumber
        }
        return name
    }

    public var description: String { rawValue }

    /// Fixed windows first, in `allCases` order, then scoped windows by name.
    public static func < (lhs: LimitKind, rhs: LimitKind) -> Bool {
        let order = allCases
        switch (order.firstIndex(of: lhs), order.firstIndex(of: rhs)) {
        case let (l?, r?): return l < r
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.rawValue < rhs.rawValue
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = LimitKind(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown limit kind \(raw)"))
        }
        self = kind
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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
    /// Every window present: the fixed ones, then model-scoped weekly windows whose kind isn't already among
    /// them (a scoped "Opus" next to `seven_day_opus` is the same window).
    public func samples(at time: Date) -> [LimitSample] {
        windows.map { LimitSample(kind: $0.kind, ts: time, utilization: $0.window.utilization,
                                  resetsAt: $0.window.resetsAt) }
    }

    public var windows: [(kind: LimitKind, window: Window)] {
        let fixed: [(LimitKind, Window?)] = [(.fiveHour, fiveHour), (.sevenDay, sevenDay),
                                             (.sevenDayOpus, sevenDayOpus), (.sevenDaySonnet, sevenDaySonnet)]
        var result = fixed.compactMap { kind, window in window.map { (kind: kind, window: $0) } }
        for entry in scoped where !result.contains(where: { $0.kind == entry.kind }) {
            result.append((kind: entry.kind, window: entry.window))
        }
        return result
    }

    public func window(_ kind: LimitKind) -> Window? {
        windows.first { $0.kind == kind }?.window
    }
}

/// How a window's use compares with the time gone by: `utilization − elapsed%`. Needs only one reading and the
/// reset time, so it works before a burn rate has history.
public struct LimitPace: Sendable, Equatable {
    public enum Band: String, Sendable {
        /// Burning faster than linear.
        case ahead
        case onTrack
        case under
    }

    /// Percent of the window gone by at the reading, 0…100.
    public var elapsedPercent: Double
    /// Percentage points: utilization − elapsed%.
    public var delta: Double
    public var band: Band

    /// A delta beyond ± this many points leaves "on track".
    public static let tolerance = 5.0

    /// Nil without a reset time, or once the window has reset (the reading is stale).
    public init?(utilization: Double, resetsAt: Date?, windowLength: TimeInterval, at time: Date) {
        guard let resetsAt, windowLength > 0, time < resetsAt else { return nil }
        let start = resetsAt.addingTimeInterval(-windowLength)
        elapsedPercent = min(max(time.timeIntervalSince(start) / windowLength * 100, 0), 100)
        delta = utilization - elapsedPercent
        band = delta > Self.tolerance ? .ahead : delta < -Self.tolerance ? .under : .onTrack
    }
}

extension LimitSample {
    /// Pass the time the utilization was read (or now, for a live reading).
    public func pace(at time: Date) -> LimitPace? {
        LimitPace(utilization: utilization, resetsAt: resetsAt, windowLength: kind.windowLength, at: time)
    }
}

extension ClaudeLimits.Window {
    /// For the panel ring, which has one live reading and no history.
    public func pace(_ kind: LimitKind, at time: Date) -> LimitPace? {
        LimitPace(utilization: utilization, resetsAt: resetsAt, windowLength: kind.windowLength, at: time)
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

    public func pace(at time: Date) -> LimitPace? { current.pace(at: time) }

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
