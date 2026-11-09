import AgentKit
import SwiftUI

/// Today's ledger totals: API-equivalent dollars (what the same tokens would cost on the API), split by source.
struct TodayWidget: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        let total = history.todayTotal
        WidgetTile(title: "Today", symbol: "chart.bar.fill", tint: .blue, footer: footer(history, total),
                   footerColor: history.unavailableReason == nil ? .secondary : .red) {
            VStack(alignment: .leading, spacing: 10) {
                Text(history.isReady ? Format.spend(total) : "–")
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                StackedBar(segments: segments(history.today, total: total))
                    .frame(height: 6)
            }
        }
        .help(history.unavailableReason ?? "API-equivalent cost of today's usage, from the usage ledger")
    }

    private func footer(_ history: History, _ total: LedgerTotals) -> String {
        switch history.status {
        case .unavailable: return "History off"
        case .opening, .off: return "Opening history…"
        case .ready: return total.calls > 0 ? "API equiv · \(Format.tokens(total.tokens.total)) tok" : "No usage yet"
        }
    }

    private func segments(_ today: [AgentSource: LedgerTotals], total: LedgerTotals) -> [(value: Double, color: Color)] {
        let byDollars = total.apiEquivUSD > 0
        return AgentSource.allCases.compactMap { source in
            guard let totals = today[source] else { return nil }
            let value = byDollars ? totals.apiEquivUSD : Double(totals.tokens.total)
            return value > 0 ? (value, SourceBadge.color(for: source)) : nil
        }
    }
}
