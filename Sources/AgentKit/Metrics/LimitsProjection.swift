import Foundation

public struct LimitKind: RawRepresentable, Hashable, Comparable, Codable, Sendable, CaseIterable,
                         CustomStringConvertible {
    public let rawValue: String

    public static let fiveHour = LimitKind(checked: "five_hour")
    public static let sevenDay = LimitKind(checked: "seven_day")
    public static let sevenDayOpus = LimitKind(checked: "seven_day_opus")
    public static let sevenDaySonnet = LimitKind(checked: "seven_day_sonnet")

    public static var allCases: [LimitKind] { [.fiveHour, .sevenDay, .sevenDayOpus, .sevenDaySonnet] }

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

    public static func scoped(displayName: String) -> LimitKind? {
        let slug = slug(displayName)
        return slug.isEmpty ? nil : LimitKind(checked: "seven_day_" + slug)
    }

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

    public var displayName: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .sevenDay: return "Weekly"
        default: return "Weekly \(scopeName)"
        }
    }

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

    var burnRateLookback: TimeInterval { self == .fiveHour ? 3600 : 86_400 }
    var burnRateMinimumSpan: TimeInterval { self == .fiveHour ? 600 : 3600 }
}

public struct LimitSample: Sendable, Equatable, Hashable {
    public var kind: LimitKind
    public var ts: Date
    public var utilization: Double
    public var resetsAt: Date?

    public init(kind: LimitKind, ts: Date, utilization: Double, resetsAt: Date?) {
        self.kind = kind
        self.ts = ts
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public static let windowTolerance: TimeInterval = 300

    public func isSameWindow(as other: LimitSample) -> Bool {
        guard kind == other.kind else { return false }
        switch (resetsAt, other.resetsAt) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) <= Self.windowTolerance
        default: return false
        }
    }

    public var windowStart: Date? { resetsAt.map { $0.addingTimeInterval(-kind.windowLength) } }
}

extension ClaudeLimits {
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

public struct LimitPace: Sendable, Equatable {
    public enum Band: String, Sendable {
        case ahead
        case onTrack
        case under
    }

    public var elapsedPercent: Double
    public var delta: Double
    public var band: Band

    public static let tolerance = 5.0

    public init?(utilization: Double, resetsAt: Date?, windowLength: TimeInterval, at time: Date) {
        guard let resetsAt, windowLength > 0, time < resetsAt else { return nil }
        let start = resetsAt.addingTimeInterval(-windowLength)
        elapsedPercent = min(max(time.timeIntervalSince(start) / windowLength * 100, 0), 100)
        delta = utilization - elapsedPercent
        band = delta > Self.tolerance ? .ahead : delta < -Self.tolerance ? .under : .onTrack
    }
}

extension LimitSample {
    public func pace(at time: Date) -> LimitPace? {
        LimitPace(utilization: utilization, resetsAt: resetsAt, windowLength: kind.windowLength, at: time)
    }
}

extension ClaudeLimits.Window {
    public func pace(_ kind: LimitKind, at time: Date) -> LimitPace? {
        LimitPace(utilization: utilization, resetsAt: resetsAt, windowLength: kind.windowLength, at: time)
    }
}

public struct LimitsProjection: Sendable, Equatable {
    public var kind: LimitKind
    public var current: LimitSample
    public var windowSamples: [LimitSample]
    public var burnRatePerHour: Double?
    public var projectedUtilization: Double?
    public var limitReachedAt: Date?

    public var utilization: Double { current.utilization }
    public var resetsAt: Date? { current.resetsAt }
    public var windowStart: Date? { current.windowStart }
    public var isAtLimit: Bool { current.utilization >= 100 }

    public func pace(at time: Date) -> LimitPace? { current.pace(at: time) }

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
