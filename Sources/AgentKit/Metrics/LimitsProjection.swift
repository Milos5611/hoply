import Foundation

public enum LimitProvider: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case claude
    case codex

    public init?(source: AgentSource) {
        switch source {
        case .claudeCode: self = .claude
        case .codexCLI: self = .codex
        case .copilotCLI, .copilotIDE, .qwenCode: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    public var source: AgentSource {
        switch self {
        case .claude: return .claudeCode
        case .codex: return .codexCLI
        }
    }

    public static func < (lhs: LimitProvider, rhs: LimitProvider) -> Bool {
        let order = allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

public struct LimitKind: RawRepresentable, Hashable, Comparable, Codable, Sendable, CaseIterable,
                         CustomStringConvertible {
    public let rawValue: String

    public static let fiveHour = LimitKind(checked: "five_hour")
    public static let sevenDay = LimitKind(checked: "seven_day")
    public static let sevenDayOpus = LimitKind(checked: "seven_day_opus")
    public static let sevenDaySonnet = LimitKind(checked: "seven_day_sonnet")

    public static var allCases: [LimitKind] { [.fiveHour, .sevenDay, .sevenDayOpus, .sevenDaySonnet] }

    private static let codexPrefix = "codex_"

    public init?(rawValue: String) {
        if rawValue == "five_hour" || rawValue == "seven_day" || Self.codexParts(rawValue) != nil {
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

    // The window length is in the kind: Codex's primary slot is 300 min on paid plans and 43200 on the free plan.
    public static func codex(windowMinutes: Int, limitID: String? = nil) -> LimitKind? {
        guard windowMinutes > 0 else { return nil }
        var id = (limitID ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if id == "codex" {
            id = ""
        } else if id.hasPrefix(codexPrefix) {
            id.removeFirst(codexPrefix.count)
        }
        let slug = slug(id)
        guard id.isEmpty || !slug.isEmpty else { return nil }
        return LimitKind(checked: codexPrefix + (slug.isEmpty ? "" : slug + "_") + "\(windowMinutes)m")
    }

    private static func codexParts(_ rawValue: String) -> (scope: String, minutes: Int)? {
        guard rawValue.hasPrefix(codexPrefix) else { return nil }
        var parts = rawValue.dropFirst(codexPrefix.count).split(separator: "_", omittingEmptySubsequences: false)
        guard let window = parts.popLast(), window.hasSuffix("m") else { return nil }
        let digits = window.dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }), let minutes = Int(digits),
              minutes > 0, String(minutes) == digits else { return nil }
        let scope = parts.joined(separator: "_")
        guard parts.isEmpty || (!scope.isEmpty && slug(scope) == scope) else { return nil }
        return (scope, minutes)
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

    public var provider: LimitProvider { rawValue.hasPrefix(Self.codexPrefix) ? .codex : .claude }

    public var isFixed: Bool { Self.allCases.contains(self) }

    public var windowMinutes: Int {
        if let codex = Self.codexParts(rawValue) { return codex.minutes }
        return self == .fiveHour ? 300 : 10_080
    }

    public var windowLength: TimeInterval { TimeInterval(windowMinutes) * 60 }

    public var scope: String {
        if let codex = Self.codexParts(rawValue) { return codex.scope }
        return rawValue.hasPrefix("seven_day_") ? String(rawValue.dropFirst("seven_day_".count)) : ""
    }

    public var isModelScoped: Bool { !scope.isEmpty }

    public var limitGroup: String {
        provider == .claude ? provider.rawValue : provider.rawValue + ":" + scope
    }

    public var windowName: String {
        let minutes = windowMinutes
        switch minutes {
        case 300: return "5-hour"
        case 10_080: return "Weekly"
        case _ where minutes % 1440 == 0: return "\(minutes / 1440)-day"
        case _ where minutes % 60 == 0: return "\(minutes / 60)-hour"
        default: return "\(minutes)-minute"
        }
    }

    public var displayName: String {
        let scope = scopeName
        return scope.isEmpty ? windowName : "\(windowName) \(scope)"
    }

    public var limitPhrase: String {
        let window = windowMinutes == 10_080 ? "weekly" : windowName
        let scope = scopeName
        return scope.isEmpty ? "\(window) limit" : "\(window) \(scope) limit"
    }

    public var scopeName: String {
        var name = ""
        var previousWasNumber = false
        for part in scope.split(separator: "_") {
            let isNumber = part.allSatisfy(\.isNumber)
            if !name.isEmpty { name += isNumber && previousWasNumber ? "." : " " }
            name += isNumber ? String(part) : part.prefix(1).uppercased() + part.dropFirst()
            previousWasNumber = isNumber
        }
        return name
    }

    public var description: String { rawValue }

    public static func < (lhs: LimitKind, rhs: LimitKind) -> Bool {
        if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
        if lhs.provider == .codex {
            return (lhs.scope.isEmpty ? 0 : 1, lhs.scope, lhs.windowMinutes)
                < (rhs.scope.isEmpty ? 0 : 1, rhs.scope, rhs.windowMinutes)
        }
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

    var burnRateLookback: TimeInterval { windowLength < 86_400 ? 3600 : 86_400 }
    var burnRateMinimumSpan: TimeInterval { windowLength < 86_400 ? 600 : 3600 }
}

public struct LimitSample: Sendable, Equatable, Hashable {
    public var kind: LimitKind
    public var ts: Date
    public var utilization: Double
    public var resetsAt: Date?
    public var plan: String?

    public init(kind: LimitKind, ts: Date, utilization: Double, resetsAt: Date?, plan: String? = nil) {
        self.kind = kind
        self.ts = ts
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.plan = plan
    }

    public static let windowTolerance: TimeInterval = 300
    public static let repeatInterval: TimeInterval = 900
    public static let currentTolerance: TimeInterval = repeatInterval + windowTolerance

    public func isSameWindow(as other: LimitSample) -> Bool {
        guard kind == other.kind else { return false }
        switch (resetsAt, other.resetsAt) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) <= Self.windowTolerance
        default: return false
        }
    }

    public func isSameReading(as other: LimitSample) -> Bool {
        utilization == other.utilization && plan == other.plan && isSameWindow(as: other)
    }

    public var windowStart: Date? { resetsAt.map { $0.addingTimeInterval(-kind.windowLength) } }

    // A limit's windows arrive together, but each stored row may lag its reading by up to `repeatInterval`.
    public static func current(_ latest: [LimitKind: LimitSample]) -> [LimitKind: LimitSample] {
        var result: [LimitKind: LimitSample] = [:]
        for samples in Dictionary(grouping: latest.values, by: \.kind.limitGroup).values {
            guard let newest = samples.max(by: { ($0.ts, $0.kind) < ($1.ts, $1.kind) }) else { continue }
            for sample in samples where newest.ts.timeIntervalSince(sample.ts) <= currentTolerance {
                if let plan = sample.plan, let newestPlan = newest.plan, plan != newestPlan { continue }
                result[sample.kind] = sample
            }
        }
        return result
    }
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

    public init?(samples: [LimitSample], now: Date? = nil) {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard let latest = sorted.last else { return nil }
        var window = sorted.filter { $0.isSameWindow(as: latest) }
        if let drop = window.indices.dropFirst().last(where: { window[$0].utilization < window[$0 - 1].utilization }) {
            window.removeFirst(drop)
        }
        kind = latest.kind
        current = latest
        windowSamples = window

        let rate: Double
        let origin: Date
        switch latest.kind.provider {
        case .claude:
            let recent = window.filter { $0.ts >= latest.ts.addingTimeInterval(-latest.kind.burnRateLookback) }
            guard recent.count >= 2, let first = recent.first,
                  latest.ts.timeIntervalSince(first.ts) >= latest.kind.burnRateMinimumSpan,
                  let slope = Self.slopePerHour(recent) else { return }
            (rate, origin) = (max(slope, 0), latest.ts)
        case .codex:
            guard let growth = Self.clockRate(window, now: now) else { return }
            (rate, origin) = growth
        }
        burnRatePerHour = rate
        guard let resetsAt = latest.resetsAt else { return }
        let hoursLeft = max(resetsAt.timeIntervalSince(origin), 0) / 3600
        projectedUtilization = min(latest.utilization + rate * hoursLeft, 100)
        if rate > 0, latest.utilization < 100 {
            let reached = origin.addingTimeInterval((100 - latest.utilization) / rate * 3600)
            if reached < resetsAt { limitReachedAt = reached }
        }
    }

    public static func projections(_ samples: [LimitSample], now: Date? = nil) -> [LimitKind: LimitsProjection] {
        Dictionary(grouping: samples, by: \.kind).compactMapValues { LimitsProjection(samples: $0, now: now) }
    }

    // Codex writes a reading only while it runs, so a slope through the readings is its speed in a session, not
    // over the day: count the growth over clock time instead, idle hours included, up to `now`.
    private static func clockRate(_ window: [LimitSample], now: Date?) -> (perHour: Double, origin: Date)? {
        guard window.count >= 2, let latest = window.last else { return nil }
        var end = max(now ?? latest.ts, latest.ts)
        if let resetsAt = latest.resetsAt { end = max(min(end, resetsAt), latest.ts) }
        let lookbackStart = end.addingTimeInterval(-latest.kind.burnRateLookback)
        let anchor: (ts: Date, utilization: Double)
        if let windowStart = latest.windowStart, windowStart > lookbackStart {
            anchor = (windowStart, 0)
        } else if let carried = window.last(where: { $0.ts <= lookbackStart }) {
            anchor = (lookbackStart, carried.utilization)
        } else if let windowStart = latest.windowStart {
            anchor = (windowStart, 0)
        } else {
            anchor = (window[0].ts, window[0].utilization)
        }
        let span = end.timeIntervalSince(anchor.ts)
        guard span >= latest.kind.burnRateMinimumSpan else { return nil }
        return (max(latest.utilization - anchor.utilization, 0) / (span / 3600), end)
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
