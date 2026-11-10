import AgentKit
import SwiftUI

extension EnvironmentValues {
    @Entry var dashboardStandIn = false
}

struct PageHeader<Controls: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var controls: Controls

    @Environment(\.dashboardStandIn) private var standIn

    var body: some View {
        if standIn {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                    caption
                }
                Spacer(minLength: 12)
                controls
            }
        } else {
            caption
                .frame(maxWidth: .infinity, alignment: .leading)
                .navigationTitle(title)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) { controls }
                }
        }
    }

    private var caption: some View {
        Text(subtitle ?? "")
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct DashboardBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if contrast == .increased {
            Color(nsColor: .windowBackgroundColor)
        } else if colorScheme == .dark {
            LinearGradient(colors: [Color(red: 0.11, green: 0.125, blue: 0.16), Color(red: 0.115, green: 0.115, blue: 0.125)],
                           startPoint: .topLeading, endPoint: UnitPoint(x: 0.7, y: 0.8))
        } else {
            LinearGradient(colors: [Color(red: 0.90, green: 0.925, blue: 0.965), Color(red: 0.95, green: 0.953, blue: 0.96)],
                           startPoint: .topLeading, endPoint: UnitPoint(x: 0.7, y: 0.8))
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

struct BreakdownRow<Icon: View>: View {
    let title: String
    let value: String
    var valueIsWarning = false
    let fraction: Double
    var tint: Color = .blue
    let subtitle: String
    var detail: String?
    var showsChevron = false
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(value)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(valueIsWarning ? Color.orange : Color.primary)
                }
                ShareBar(fraction: fraction, tint: tint)
                Text(subtitle)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration)
    }

    private struct Highlight: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : hovering ? 0.045 : 0)))
                .padding(.horizontal, -8)
                .padding(.vertical, -6)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
}

struct BreakdownList: View {
    enum Kind { case project, model }

    let slices: [SpendSlice]
    let kind: Kind
    var limit: Int?
    var open: ((SpendSlice) -> Void)?

    var body: some View {
        let shown = limit.map { Array(slices.prefix($0)) } ?? slices
        let top = max(slices.map(\.totals.apiEquivUSD).max() ?? 0, 0.000_001)
        if shown.isEmpty {
            EmptyNote(text: kind == .project ? "No project usage in this range" : "No model usage in this range")
        } else {
            VStack(spacing: 12) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, slice in
                    if let open {
                        Button { open(slice) } label: { row(slice, index: index, top: top, chevron: true) }
                            .buttonStyle(.row)
                            .help("Show \(title(slice)) in Projects")
                    } else {
                        row(slice, index: index, top: top, chevron: false)
                    }
                }
            }
        }
    }

    private func row(_ slice: SpendSlice, index: Int, top: Double, chevron: Bool) -> some View {
        BreakdownRow(title: title(slice), value: Format.spend(slice.totals),
                     valueIsWarning: slice.totals.hasUnpriced && slice.totals.apiEquivUSD == 0,
                     fraction: slice.totals.apiEquivUSD / top, tint: color(index: index), subtitle: subtitle(slice),
                     detail: Format.copilot(slice.totals), showsChevron: chevron) {
            icon(slice, index: index)
        }
    }

    @ViewBuilder
    private func icon(_ slice: SpendSlice, index: Int) -> some View {
        switch kind {
        case .project:
            ProjectIcon(project: slice.project, size: 30)
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
            parts.append(Format.path(root))
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
