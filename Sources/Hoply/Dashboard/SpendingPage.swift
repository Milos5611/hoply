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
                    HStack(spacing: 10) {
                        Picker("Split", selection: Binding(get: { history.spendingSplit },
                                                           set: { history.setSpending(split: $0) })) {
                            Text("By model").tag(SpendSeriesSplit.model)
                            Text("By source").tag(SpendSeriesSplit.source)
                        }
                        Picker("Range", selection: Binding(get: { history.spendingRange },
                                                           set: { history.setSpending(range: $0) })) {
                            ForEach(HistoryRange.spendingRanges) { Text($0.label).tag($0) }
                        }
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
                        BreakdownList(slices: spending?.projects ?? [], kind: .project)
                    }
                    DashboardCard(title: "By model", subtitle: history.spendingRange.label) {
                        BreakdownList(slices: spending?.models ?? [], kind: .model)
                    }
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
