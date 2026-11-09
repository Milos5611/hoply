import AgentKit
import Foundation
import XCTest

final class SpendChartTests: XCTestCase {
    private let calendar = Calendar.current
    private lazy var days: [Date] = {
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_793_000_000))
        return (0..<5).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }()

    private func point(_ day: Int, _ series: String, _ usd: Double, unpriced: Bool = false) -> DailySpendPoint {
        DailySpendPoint(day: days[day], series: series,
                        totals: LedgerTotals(costUSD: usd, apiEquivUSD: usd, calls: 1, hasUnpriced: unpriced))
    }

    private func chart(_ points: [DailySpendPoint], split: SpendSeriesSplit = .model, maxSeries: Int = 6,
                       modelLabel: (String) -> String = { $0 }) -> SpendChartData {
        SpendChartData(DailySpendSeries(days: days, points: points), split: split, maxSeries: maxSeries,
                       modelLabel: modelLabel)
    }

    func testSeriesRankByTotalAcrossDays() {
        let data = chart([point(0, "a", 1), point(1, "a", 1), point(0, "b", 5), point(2, "c", 3)])
        XCTAssertEqual(data.labels, ["b", "c", "a"])
        XCTAssertEqual(data.series.map(\.isOther), [false, false, false])
        XCTAssertEqual(data.bars.map(\.label), ["b", "a", "a", "c"], "by day, then rank")
        XCTAssertEqual(data.bars.map(\.rank), [0, 2, 2, 1])
        XCTAssertEqual(data.entries(on: days[0]).map(\.label), ["b", "a"])
        XCTAssertEqual(data.total(on: days[0]), 6)
    }

    func testSmallestSeriesFoldIntoOther() {
        let points = (0..<8).map { point($0 % 2, "m\($0)", Double(8 - $0)) }
        let data = chart(points)
        XCTAssertEqual(data.labels, ["m0", "m1", "m2", "m3", "m4", SpendChartData.otherLabel])
        XCTAssertEqual(data.series.map(\.isOther), [false, false, false, false, false, true])
        XCTAssertNil(data.series.last?.source)
        let other = data.bars.filter { $0.label == SpendChartData.otherLabel }
        XCTAssertEqual(other.map(\.rank), [5, 5])
        XCTAssertEqual(other.map(\.value), [2, 4], "m6 on day 0; m5 + m7 on day 1")
        XCTAssertEqual(data.total(on: days[0]) + data.total(on: days[1]), points.reduce(0) { $0 + $1.totals.apiEquivUSD })
    }

    func testNoOtherWhenSeriesFit() {
        let data = chart((0..<6).map { point(0, "m\($0)", Double($0 + 1)) })
        XCTAssertEqual(data.labels.count, 6)
        XCTAssertFalse(data.labels.contains(SpendChartData.otherLabel))
    }

    func testEmptyDaysHaveNoBars() {
        let data = chart([point(1, "a", 2), point(3, "a", 4)])
        XCTAssertEqual(data.days, days)
        XCTAssertEqual(Set(data.bars.map(\.day)), [days[1], days[3]])
        XCTAssertEqual(data.total(on: days[2]), 0)
        XCTAssertTrue(data.entries(on: days[2]).isEmpty)
        XCTAssertEqual(data.day(containing: days[2].addingTimeInterval(3_600)), days[2])
        XCTAssertNil(data.day(containing: days[0].addingTimeInterval(-1)))
        XCTAssertEqual(data.domain, days[0]...calendar.date(byAdding: .day, value: 1, to: days[4])!)
        XCTAssertFalse(data.isEmpty)

        let none = chart([])
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(none.labels.isEmpty)
        XCTAssertNil(DailySpendSeries(days: days, points: []).busiestDay)
    }

    func testTiesAreDeterministic() {
        let data = chart([point(0, "zeta", 2), point(1, "alpha", 2), point(1, "mid", 1)], maxSeries: 2)
        XCTAssertEqual(data.labels, ["alpha", SpendChartData.otherLabel], "equal totals rank by label")
        let sameDay = chart([point(0, "zeta", 2), point(0, "alpha", 2)])
        XCTAssertEqual(sameDay.entries(on: days[0]).map(\.label), ["alpha", "zeta"], "equal values keep legend order")

        let series = DailySpendSeries(days: days, points: [point(0, "a", 1), point(0, "b", 2), point(3, "a", 3),
                                                           point(2, "a", 1.5)])
        XCTAssertEqual(series.busiestDay, DaySpend(day: days[3], value: 3), "the latest of two equal days")
    }

    func testBusiestDaySumsAllSeries() {
        let series = DailySpendSeries(days: days, points: [point(0, "a", 4), point(1, "a", 3), point(1, "b", 2)])
        XCTAssertEqual(series.busiestDay, DaySpend(day: days[1], value: 5))
    }

    func testUnpricedDays() {
        let data = chart([point(0, "a", 1), point(2, "mystery", 0, unpriced: true)])
        XCTAssertEqual(data.unpricedDays, [days[2]])
        XCTAssertTrue(data.entries(on: days[2]).isEmpty, "a $0 bar is not listed")
        XCTAssertEqual(data.labels, ["a", "mystery"])

        let onlyUnpriced = chart([point(1, "mystery", 0, unpriced: true)])
        XCTAssertFalse(onlyUnpriced.isEmpty, "unpriced usage still shows the chart")
        XCTAssertNil(DailySpendSeries(days: days, points: [point(1, "mystery", 0, unpriced: true)]).busiestDay)

        let folded = chart([point(0, "a", 3), point(0, "b", 2), point(1, "c", 0, unpriced: true)], maxSeries: 2)
        XCTAssertEqual(folded.labels, ["a", SpendChartData.otherLabel])
        XCTAssertEqual(folded.unpricedDays, [days[1]], "folding keeps the unpriced marker")
    }

    func testSourceSplitUsesAgentNames() {
        let data = chart([point(0, "claude-code", 3), point(0, "qwen-code", 1), point(1, "custom", 2)], split: .source)
        XCTAssertEqual(data.labels, ["Claude Code", "custom", "Qwen Code"])
        XCTAssertEqual(data.series.map(\.source), [.claudeCode, nil, .qwenCode])
    }

    func testModelLabelsMergeSeries() {
        let data = chart([point(0, "claude-opus-5-5", 1), point(1, "claude-opus-5-5-20261101", 2),
                          point(0, "claude-code", 0.5)],
                         modelLabel: { $0.replacingOccurrences(of: "-20261101", with: "") })
        XCTAssertEqual(data.labels, ["claude-opus-5-5", "claude-code"])
        XCTAssertEqual(data.series.map(\.source), [nil, nil], "sources only for the source split")
        XCTAssertEqual(data.total(on: days[1]), 2)
    }
}
