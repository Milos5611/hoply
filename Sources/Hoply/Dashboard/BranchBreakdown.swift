import AgentKit
import SwiftUI

struct BranchBreakdown: View {
    @Environment(\.clock) private var clock
    let branches: ProjectBranches
    let range: HistoryRange

    var body: some View {
        let rows = branches.rows
        let byDollars = rows.contains { $0.totals.apiEquivUSD > 0 }
        let top = max(rows.map { byDollars ? $0.totals.apiEquivUSD : Double($0.totals.tokens.total) }.max() ?? 0, 0.000_001)
        DashboardCard(title: "Branches", subtitle: subtitle) {
            VStack(spacing: 14) {
                ForEach(rows) { row in
                    BranchRow(summary: row, now: clock.now,
                              fraction: (byDollars ? row.totals.apiEquivUSD : Double(row.totals.tokens.total)) / top)
                }
            }
        }
        .environment(\.breakdownListCap, 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var subtitle: String {
        branches.coversOnlyThisMac ? "\(range.label) · this Mac only" : range.label
    }
}

private struct BranchRow: View {
    let summary: BranchSummary
    let now: Date
    let fraction: Double

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: "arrow.triangle.branch", tint: summary.branch == nil ? .secondary : .indigo, size: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let branch = summary.branch {
                        Text(branch)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    } else {
                        Text("No branch")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(Format.spend(summary.totals))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(summary.totals.hasUnpriced && summary.totals.apiEquivUSD == 0
                                         ? Color.orange : Color.primary)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                ShareBar(fraction: fraction, tint: summary.branch == nil ? .secondary : .indigo)
                Text(subtitle)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                changes
            }
        }
    }

    private var subtitle: String {
        var parts = ["\(Format.tokens(summary.totals.tokens.total)) tokens",
                     summary.sessionCount == 1 ? "1 session" : "\(Format.count(summary.sessionCount)) sessions"]
        if let last = summary.lastActive { parts.append("last active \(Format.lastActive(last, now: now))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var changes: some View {
        let hasLines = summary.linesAdded != nil || summary.linesRemoved != nil
        if hasLines || !summary.prURLs.isEmpty || !summary.sources.isEmpty {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(summary.sources, id: \.self) { SourceBadge(source: $0, size: 18) }
                }
                if hasLines {
                    HStack(spacing: 6) {
                        Text("+\(Format.count(summary.linesAdded ?? 0))")
                            .foregroundStyle(.green)
                        Text("−\(Format.count(summary.linesRemoved ?? 0))")
                            .foregroundStyle(.red)
                    }
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .tooltip(linesOnlyClaudeCode ? Self.claudeOnly : "Lines added and removed")
                    if linesOnlyClaudeCode {
                        Text("Claude Code only")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .tooltip(Self.claudeOnly)
                    }
                }
                ForEach(summary.prURLs, id: \.self) { pull in
                    if let url = URL(string: pull) {
                        Link(destination: url) {
                            Label(Self.pullName(url), systemImage: "arrow.triangle.pull")
                                .lineLimit(1)
                        }
                        .font(.system(size: 11.5))
                        .help(pull)
                    }
                }
            }
        }
    }

    private static let claudeOnly = "Lines from Claude Code sessions only"

    private var linesOnlyClaudeCode: Bool {
        summary.sources.contains { $0 != .claudeCode }
    }

    private static func pullName(_ url: URL) -> String {
        let last = url.lastPathComponent
        return Int(last) != nil ? "#\(last)" : (url.path.isEmpty ? url.absoluteString : String(url.path.dropFirst()))
    }
}
