import AgentKit
import Charts
import SwiftUI

extension SpendChartData {
    struct Row: Identifiable {
        let label: String
        let value: Double
        let color: Color
        var id: String { label }
    }

    var colors: [Color] {
        series.enumerated().map { index, entry in
            entry.isOther ? SeriesPalette.other : entry.source.map(SourceBadge.color(for:)) ?? SeriesPalette.color(index)
        }
    }

    func rows(on day: Date) -> [Row] {
        let colors = colors
        return entries(on: day).map { bar in
            Row(label: bar.label, value: bar.value,
                color: labels.firstIndex(of: bar.label).map { colors[$0] } ?? SeriesPalette.other)
        }
    }
}

struct SpendChart: View {
    let data: SpendChartData
    @State private var selection: Date?

    init(series: DailySpendSeries, split: SpendSeriesSplit) {
        data = SpendChartData(series, split: split, modelLabel: { Format.model($0) })
    }

    var body: some View {
        if data.isEmpty {
            EmptyNote(text: "No usage in this range yet")
                .frame(maxHeight: .infinity)
        } else {
            chart
        }
    }

    private var chart: some View {
        let selected = selection.flatMap(data.day(containing:))
        return Chart {
            ForEach(data.bars) { bar in
                BarMark(x: .value("Day", bar.day, unit: .day), y: .value("API-equivalent", bar.value), width: .ratio(0.72))
                    .foregroundStyle(by: .value("Series", bar.label))
                    .cornerRadius(2.5)
                    .opacity(selected == nil || selected == bar.day ? 1 : 0.45)
            }
            if let selected {
                RuleMark(x: .value("Day", selected, unit: .day))
                    .foregroundStyle(Color.primary.opacity(0.12))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: tooltipSide(for: selected), alignment: .top, spacing: 8,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        SpendTooltip(day: selected, rows: data.rows(on: selected), total: data.total(on: selected),
                                     unpriced: data.unpricedDays.contains(selected))
                    }
            }
        }
        .chartForegroundStyleScale(domain: data.labels, range: data.colors)
        .chartXScale(domain: data.domain)
        .chartXSelection(value: $selection)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: strideDays)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(amount >= 10 || amount == 0 ? String(format: "$%.0f", amount) : String(format: "$%.1f", amount))
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
        .accessibilityLabel("Daily API-equivalent spend")
    }

    /// Beside the hovered bar, towards the middle, so the tooltip never covers the bar or leaves the chart.
    private func tooltipSide(for day: Date) -> AnnotationPosition {
        let index = data.days.firstIndex(of: day) ?? 0
        return index < data.days.count / 2 ? .trailing : .leading
    }

    private var strideDays: Int {
        switch data.days.count {
        case ..<10: return 1
        case ..<45: return 7
        default: return 14
        }
    }
}

struct SpendTooltip: View {
    let day: Date
    let rows: [SpendChartData.Row]
    let total: Double
    let unpriced: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Format.day(day))
                .font(.system(size: 11.5, weight: .semibold))
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.color).frame(width: 7, height: 7)
                    Text(row.label)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(Format.cost(row.value))
                        .monospacedDigit()
                }
                .font(.system(size: 11.5))
            }
            Divider()
            HStack {
                Text("Total")
                Spacer(minLength: 12)
                Text(Format.cost(total) + (unpriced ? " + unpriced" : ""))
                    .monospacedDigit()
            }
            .font(.system(size: 11.5, weight: .semibold))
        }
        .padding(10)
        .frame(minWidth: 170)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: colorScheme == .dark ? .controlBackgroundColor : .white))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
