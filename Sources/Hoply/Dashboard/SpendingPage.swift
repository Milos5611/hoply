import AgentKit
import SwiftUI

struct SpendingPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        let spending = history.spending
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Spending", subtitle: "What your agents' tokens would cost on the API") {
                    Picker("Split", selection: Binding(get: { history.spendingSplit },
                                                       set: { history.setSpending(split: $0) })) {
                        Text("By model").tag(SpendSeriesSplit.model)
                        Text("By source").tag(SpendSeriesSplit.source)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Picker("Range", selection: Binding(get: { history.spendingRange },
                                                       set: { history.setSpending(range: $0) })) {
                        ForEach(HistoryRange.spendingRanges) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                HistoryBanner()
                headlines(spending)
                DashboardCard(title: "Daily spend",
                              subtitle: "\(history.spendingRange.label) · \(history.spendingSplit == .model ? "by model" : "by source")") {
                    SpendChart(series: spending?.daily ?? DailySpendSeries(days: [], points: []),
                               split: spending?.split ?? history.spendingSplit)
                        .frame(height: 260)
                }
                HStack(alignment: .top, spacing: 12) {
                    DashboardCard(title: "By project", subtitle: history.spendingRange.label) {
                        BreakdownList(slices: spending?.projects ?? [], kind: .project) { slice in
                            model.history.openProject(slice.project, range: history.spendingRange)
                        }
                    }
                    DashboardCard(title: "By model", subtitle: history.spendingRange.label) {
                        BreakdownList(slices: spending?.models ?? [], kind: .model)
                    }
                }
                DashboardCard(title: "Model efficiency",
                              subtitle: "\(history.spendingRange.label) · cache hit rate and effective price per million tokens") {
                    EfficiencyTable(models: spending?.efficiency ?? [])
                }
            }
            .padding(24)
        }
    }

    private func headlines(_ spending: SpendingData?) -> some View {
        let total = spending?.total ?? .zero
        let days = max(spending?.daily.days.count ?? 1, 1)
        let busiest = spending?.daily.busiestDay
        let local = (spending?.models ?? []).filter { $0.totals.costUSD == 0 && $0.totals.apiEquivUSD > 0 }
            .reduce(LedgerTotals.zero) { $0 + $1.totals }
        return HStack(spacing: 12) {
            HeadlineTile(label: "Total", totals: total, symbol: "sum")
            HeadlineTile(label: "Per day", value: Format.cost(total.apiEquivUSD / Double(days)),
                         detail: "average over \(days) days", symbol: "chart.line.flattrend.xyaxis")
            HeadlineTile(label: "Busiest day", value: busiest.map { Format.cost($0.value) } ?? "–",
                         detail: busiest.map { Format.day($0.day) } ?? "No usage yet", symbol: "flame.fill", tint: .orange)
            HeadlineTile(label: "Ran locally", value: Format.cost(local.apiEquivUSD),
                         detail: local.calls > 0 ? "API-equivalent, $0 spent" : "No local model usage",
                         symbol: "cpu", tint: SourceBadge.color(for: .qwenCode))
        }
    }
}

struct EfficiencyTable: View {
    let models: [ModelEfficiency]

    var body: some View {
        let ranked = models.sorted { ($0.totals.apiEquivUSD, $1.model) > ($1.totals.apiEquivUSD, $0.model) }
        if ranked.isEmpty {
            EmptyNote(text: "No model usage in this range")
        } else {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                GridRow {
                    Text("Model")
                    Text("Cache hit rate")
                    Text("Effective $/Mtok")
                        .gridColumnAlignment(.trailing)
                    Text("Tokens")
                        .gridColumnAlignment(.trailing)
                    Text("Calls")
                        .gridColumnAlignment(.trailing)
                    Text("Spend")
                        .gridColumnAlignment(.trailing)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                ForEach(Array(ranked.enumerated()), id: \.element.id) { index, entry in
                    Divider()
                    GridRow {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(SeriesPalette.color(index))
                                .frame(width: 7, height: 7)
                            Text(entry.model.isEmpty ? "Unknown model" : Format.model(entry.model))
                                .fontWeight(.medium)
                                .lineLimit(1)
                            if entry.totals.costUSD == 0, entry.totals.apiEquivUSD > 0 {
                                Text("local")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        cacheHit(entry.cacheHitRate)
                        Text(entry.usdPerMillionTokens.map(Format.usdPerMillion) ?? (entry.totals.hasUnpriced ? "unpriced" : "–"))
                            .foregroundStyle(entry.usdPerMillionTokens == nil && entry.totals.hasUnpriced
                                             ? Color.orange : Color.primary)
                            .help("API-equivalent spend divided by all tokens, cache reads included")
                        Text(Format.tokens(entry.totals.tokens.total))
                        Text(Format.count(entry.totals.calls))
                        Text(Format.spend(entry.totals))
                            .fontWeight(.semibold)
                    }
                    if entry.fastCalls > 0 {
                        GridRow {
                            Label(fastLine(entry), systemImage: "bolt.fill")
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(.orange)
                                .padding(.leading, 14)
                                .gridCellColumns(6)
                                .help("Calls made in fast mode, and what they cost above the model's standard price")
                        }
                    }
                }
            }
            .font(.system(size: 12.5).monospacedDigit())
        }
    }

    private func cacheHit(_ rate: Double?) -> some View {
        HStack(spacing: 8) {
            Text(rate.map(Format.percent) ?? "–")
                .frame(width: 36, alignment: .trailing)
            if let rate {
                ShareBar(fraction: rate, tint: .teal)
                    .frame(width: 90)
            }
        }
        .help("Cache reads as a share of all prompt tokens (input, cache reads and cache writes)")
    }

    private func fastLine(_ entry: ModelEfficiency) -> String {
        let calls = entry.fastCalls == 1 ? "1 call" : "\(Format.count(entry.fastCalls)) calls"
        var text = "Fast mode · \(calls) · \(Format.cost(entry.fastUSD))"
        if entry.fastPremiumUSD > 0 { text += " · \(Format.cost(entry.fastPremiumUSD)) above standard price" }
        return text
    }
}
