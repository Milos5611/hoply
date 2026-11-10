import Foundation

public struct SpendChartData: Sendable, Equatable {
    public struct Bar: Sendable, Equatable, Identifiable {
        public let day: Date
        public let label: String
        public let rank: Int
        public let value: Double

        public var id: String { "\(day.timeIntervalSince1970)|\(label)" }
    }

    public struct Series: Sendable, Equatable {
        public let label: String
        public let source: AgentSource?
        public let isOther: Bool
    }

    public static let otherLabel = "Other"

    public let days: [Date]
    public let bars: [Bar]
    public let series: [Series]
    public let unpricedDays: Set<Date>

    public init(_ series: DailySpendSeries, split: SpendSeriesSplit, maxSeries: Int = 6,
                modelLabel: (String) -> String = { $0 }) {
        func label(_ raw: String) -> String {
            split == .source ? AgentSource(rawValue: raw)?.displayName ?? raw : modelLabel(raw)
        }
        var totals: [String: Double] = [:]
        var sources: [String: AgentSource] = [:]
        for point in series.points {
            let name = label(point.series)
            totals[name, default: 0] += point.totals.apiEquivUSD
            if split == .source, let source = AgentSource(rawValue: point.series) { sources[name] = source }
        }
        let ranked = totals.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        let kept = ranked.count > maxSeries ? Array(ranked.prefix(maxSeries - 1)) : ranked
        let hasOther = kept.count < ranked.count
        let rank = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })

        var values: [Date: [String: Double]] = [:]
        var unpriced: Set<Date> = []
        for point in series.points {
            let name = rank[label(point.series)] == nil ? Self.otherLabel : label(point.series)
            values[point.day, default: [:]][name, default: 0] += point.totals.apiEquivUSD
            if point.totals.hasUnpriced { unpriced.insert(point.day) }
        }
        bars = values.flatMap { day, entries in
            entries.map { Bar(day: day, label: $0.key, rank: rank[$0.key] ?? kept.count, value: $0.value) }
        }.sorted { ($0.day, $0.rank) < ($1.day, $1.rank) }

        days = series.days
        self.series = kept.map { Series(label: $0, source: sources[$0], isOther: false) }
            + (hasOther ? [Series(label: Self.otherLabel, source: nil, isOther: true)] : [])
        unpricedDays = unpriced
    }

    public var labels: [String] { series.map(\.label) }

    public var isEmpty: Bool { bars.allSatisfy { $0.value <= 0 } && unpricedDays.isEmpty }

    public var domain: ClosedRange<Date> {
        guard let first = days.first, let last = days.last,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else {
            let now = Date()
            return now...now.addingTimeInterval(86_400)
        }
        return first...end
    }

    public func day(containing date: Date) -> Date? {
        days.last { $0 <= date }
    }

    public func entries(on day: Date) -> [Bar] {
        bars.filter { $0.day == day && $0.value > 0 }
            .sorted { ($0.value, $1.rank) > ($1.value, $0.rank) }
    }

    public func total(on day: Date) -> Double {
        bars.filter { $0.day == day }.reduce(0) { $0 + $1.value }
    }
}

public struct DaySpend: Sendable, Equatable {
    public let day: Date
    public let value: Double

    public init(day: Date, value: Double) {
        self.day = day
        self.value = value
    }
}

extension DailySpendSeries {
    public var busiestDay: DaySpend? {
        var byDay: [Date: Double] = [:]
        for point in points { byDay[point.day, default: 0] += point.totals.apiEquivUSD }
        guard let best = byDay.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }), best.value > 0 else { return nil }
        return DaySpend(day: best.key, value: best.value)
    }
}
