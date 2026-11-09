import AgentKit
import SwiftUI

struct PageHeader<Controls: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            controls
        }
    }
}

extension PageHeader where Controls == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct DashboardCard<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String?
    var padding: CGFloat = 16
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        Card(prominent: true, padding: padding) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                content
            }
        }
    }
}

extension DashboardCard where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, padding: padding, trailing: { EmptyView() }, content: content)
    }
}

struct HeadlineTile: View {
    let label: String
    let value: String
    var detail: String?
    var symbol: String?
    var tint: Color = .blue

    var body: some View {
        Card(prominent: true, padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    if let symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(tint)
                    }
                    Text(label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.system(size: 12.5, weight: .medium))
                Text(value)
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(detail ?? " ")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

extension HeadlineTile {
    init(label: String, totals: LedgerTotals, symbol: String? = nil, tint: Color = .blue) {
        self.init(label: label, value: Format.spend(totals),
                  detail: "\(Format.tokens(totals.tokens.total)) tokens · \(Format.count(totals.calls)) calls",
                  symbol: symbol, tint: tint)
    }
}

struct ShareBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: max(3, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

struct BreakdownList: View {
    enum Kind { case project, model }

    let slices: [SpendSlice]
    let kind: Kind
    var limit: Int?

    var body: some View {
        let shown = limit.map { Array(slices.prefix($0)) } ?? slices
        let top = max(slices.map(\.totals.apiEquivUSD).max() ?? 0, 0.000_001)
        if shown.isEmpty {
            EmptyNote(text: kind == .project ? "No project usage in this range" : "No model usage in this range")
        } else {
            VStack(spacing: 12) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, slice in
                    HStack(alignment: .center, spacing: 10) {
                        icon(slice, index: index)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(title(slice))
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(Format.spend(slice.totals))
                                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(slice.totals.hasUnpriced && slice.totals.apiEquivUSD == 0
                                                     ? Color.orange : Color.primary)
                            }
                            ShareBar(fraction: slice.totals.apiEquivUSD / top, tint: color(index: index))
                            Text(subtitle(slice))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func icon(_ slice: SpendSlice, index: Int) -> some View {
        switch kind {
        case .project:
            IconTile(symbol: slice.project == nil ? "questionmark.folder" : "folder.fill",
                     tint: slice.project == nil ? .secondary : .blue, size: 30)
        case .model:
            IconTile(symbol: "cube.fill", tint: color(index: index), size: 30)
        }
    }

    private func title(_ slice: SpendSlice) -> String {
        kind == .model ? Format.model(slice.id) : slice.label
    }

    private func subtitle(_ slice: SpendSlice) -> String {
        let sessions = slice.sessionCount == 1 ? "1 session" : "\(slice.sessionCount) sessions"
        var parts = [sessions, "\(Format.tokens(slice.totals.tokens.total)) tokens"]
        if kind == .project, let root = slice.project?.root {
            parts.append((root as NSString).abbreviatingWithTildeInPath)
        }
        if kind == .model, slice.totals.apiEquivUSD > 0, slice.totals.costUSD == 0 {
            parts.append("local")
        }
        return parts.joined(separator: " · ")
    }

    private func color(index: Int) -> Color {
        kind == .model ? SeriesPalette.color(index) : .blue
    }
}

enum SeriesPalette {
    private static let colors: [Color] = [
        Color(red: 0.85, green: 0.47, blue: 0.34), .blue, .purple, .teal, .pink, .indigo, .mint, .brown,
    ]

    static func color(_ index: Int) -> Color { colors[index % colors.count] }
    static let other = Color.gray.opacity(0.55)
}

struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
    }
}

struct HistoryBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        if let reason = history.unavailableReason {
            Card(prominent: true, tint: .red) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.red)
            }
        } else if history.progress.isBackfilling {
            let progress = history.progress
            Card(prominent: true, tint: .blue) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Indexing Claude Code transcripts", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(Format.percent(progress.fraction))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    }
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                    Text("\(progress.filesDone) of \(progress.filesTotal) files · \(Format.bytes(progress.bytesDone)) of \(Format.bytes(progress.bytesTotal)) · newest first, totals fill in as it goes")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
