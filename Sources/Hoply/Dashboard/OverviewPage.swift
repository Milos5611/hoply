import AgentKit
import SwiftUI

struct OverviewPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let overview = model.history.overview
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Overview", subtitle: "API-equivalent cost of your agents' usage, from the usage ledger")
                HistoryBanner()
                HStack(spacing: 12) {
                    HeadlineTile(label: "Today", totals: overview?.totals.today ?? .zero, symbol: "sun.max.fill", tint: .orange)
                    HeadlineTile(label: "Last 7 days", totals: overview?.totals.last7Days ?? .zero, symbol: "calendar")
                    HeadlineTile(label: "Last 30 days", totals: overview?.totals.last30Days ?? .zero, symbol: "calendar")
                    HeadlineTile(label: "All time", totals: overview?.totals.allTime ?? .zero, symbol: "infinity",
                                 tint: .purple)
                }
                DashboardCard(title: "Daily spend", subtitle: "Last 30 days · by source", trailing: {
                    Button("Spending") { model.history.select(.spending) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }) {
                    SpendChart(series: overview?.daily ?? DailySpendSeries(days: [], points: []), split: .source)
                        .frame(height: 230)
                }
                HStack(alignment: .top, spacing: 12) {
                    DashboardCard(title: "Top projects", subtitle: "30 days", trailing: {
                        Button("Projects") { model.history.select(.projects) }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }) {
                        BreakdownList(slices: overview?.projects ?? [], kind: .project) { slice in
                            model.history.openProject(slice.project, range: .month)
                        }
                    }
                    DashboardCard(title: "Top models", subtitle: "30 days") {
                        BreakdownList(slices: overview?.models ?? [], kind: .model)
                    }
                }
            }
            .padding(24)
        }
    }
}
