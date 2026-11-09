import AgentKit
import SwiftUI

struct ProjectsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        if let opened = history.openedProject {
            let detail = history.projectDetail.flatMap { $0.summary.filter == opened.filter ? $0 : nil }
            ProjectDetailView(opened: opened, detail: detail)
        } else {
            ProjectListView(list: history.projectList)
        }
    }
}

struct ProjectRangePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        Picker("Range", selection: Binding(get: { history.projectsRange }, set: { history.setProjectsRange($0) })) {
            ForEach(HistoryRange.projectRanges) { Text($0.shortLabel).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - List

struct ProjectListView: View {
    @Environment(AppModel.self) private var model
    let list: ProjectsData?

    var body: some View {
        let projects = list?.projects ?? []
        let named = projects.filter { $0.project != nil }
        let unassigned = projects.first { $0.project == nil }
        let total = projects.reduce(LedgerTotals.zero) { $0 + $1.totals }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Projects", subtitle: subtitle(named.count, total)) {
                    ProjectRangePicker()
                }
                HistoryBanner()
                if list != nil, projects.isEmpty {
                    Card(prominent: true) {
                        EmptyNote(text: "No project usage in \(rangeText.lowercased()). Try a longer range.")
                    }
                }
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(Array(stride(from: 0, to: named.count, by: 2)), id: \.self) { start in
                        GridRow {
                            ForEach(named[start..<min(start + 2, named.count)]) { summary in
                                ProjectTile(summary: summary, share: share(summary, of: total))
                            }
                            if start + 1 == named.count {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
                if let unassigned {
                    UnassignedTile(summary: unassigned, share: share(unassigned, of: total))
                }
            }
            .padding(24)
        }
    }

    private var rangeText: String {
        (list?.range ?? model.history.projectsRange).label
    }

    private func subtitle(_ count: Int, _ total: LedgerTotals) -> String {
        guard list != nil else { return "Where your agents' usage went, project by project" }
        let projects = count == 1 ? "1 project" : "\(count) projects"
        return "\(projects) · \(Format.spend(total)) API-equivalent · \(rangeText)"
    }

    private func share(_ summary: ProjectSummary, of total: LedgerTotals) -> Double? {
        total.apiEquivUSD > 0 ? summary.totals.apiEquivUSD / total.apiEquivUSD : nil
    }
}

struct ProjectTile: View {
    @Environment(AppModel.self) private var model
    let summary: ProjectSummary
    let share: Double?
    @State private var hovering = false

    var body: some View {
        Button { model.history.openProject(summary.project) } label: {
            Card(prominent: true, padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    SourceSplit(bySource: summary.bySource)
                    HStack(spacing: 10) {
                        Metric(value: Format.tokens(summary.totals.tokens.total), label: "tokens")
                        Metric(value: Format.count(summary.sessionCount),
                               label: summary.sessionCount == 1 ? "session" : "sessions")
                        Metric(value: summary.kind == .repo || !summary.branches.isEmpty ? "\(summary.branches.count)" : "–",
                               label: summary.branches.count == 1 ? "branch" : "branches")
                        Metric(value: summary.lastActive.map { Format.lastActive($0) } ?? "–", label: "last active")
                    }
                    .lineLimit(1)
                    ModelLine(models: summary.topModels, copilot: Format.copilot(summary.totals))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(hovering ? 0.55 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show \(summary.title)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(projectKind: summary.kind, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(place)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.spend(summary.totals))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(summary.totals.hasUnpriced && summary.totals.apiEquivUSD == 0
                                     ? Color.orange : Color.primary)
                Text(share.map { "\(Format.percent($0)) of spend" } ?? "API equiv")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var place: String {
        let root = summary.root.map(Format.path) ?? ""
        switch summary.worktrees.count {
        case 0: return root
        case 1: return "\(root) · 1 worktree"
        case let count: return "\(root) · \(count) worktrees"
        }
    }
}

/// Usage no project claimed: telemetry without `hoply.cwd` whose process cwd couldn't be found, and
/// sessions that never reported a cwd. Kept apart and last, since it isn't a place you can open.
struct UnassignedTile: View {
    @Environment(AppModel.self) private var model
    let summary: ProjectSummary
    let share: Double?

    var body: some View {
        Button { model.history.openProject(nil) } label: {
            Card(padding: 14) {
                HStack(alignment: .center, spacing: 12) {
                    IconTile(projectKind: nil, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Unassigned")
                                .font(.system(size: 14, weight: .semibold))
                            Text(details)
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text("Telemetry with no project. Set hoply.cwd in OTEL_RESOURCE_ATTRIBUTES to attribute it.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 12)
                    SourceSplit(bySource: summary.bySource, showsLegend: false)
                        .frame(width: 120)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.spend(summary.totals))
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        Text(share.map { "\(Format.percent($0)) of spend" } ?? "API equiv")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Show unassigned usage")
    }

    private var details: String {
        var parts = [summary.sessionCount == 1 ? "1 session" : "\(summary.sessionCount) sessions",
                     "\(Format.tokens(summary.totals.tokens.total)) tokens"]
        if let copilot = Format.copilot(summary.totals) { parts.append(copilot) }
        return parts.joined(separator: " · ")
    }
}

/// A project's spend split by agent: a stacked bar and, optionally, a legend with each source's figure.
struct SourceSplit: View {
    let bySource: [AgentSource: LedgerTotals]
    var showsLegend = true

    var body: some View {
        let sources = Self.ranked(bySource)
        let byDollars = sources.contains { $0.totals.apiEquivUSD > 0 }
        VStack(alignment: .leading, spacing: 7) {
            StackedBar(segments: sources.map { entry in
                (byDollars ? entry.totals.apiEquivUSD : Double(entry.totals.tokens.total), SourceBadge.color(for: entry.source))
            })
            .frame(height: 6)
            if showsLegend {
                HStack(spacing: 12) {
                    ForEach(sources, id: \.source) { entry in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(SourceBadge.color(for: entry.source))
                                .frame(width: 7, height: 7)
                            Text(entry.source.displayName)
                                .foregroundStyle(.secondary)
                            Text(Format.spend(entry.totals))
                                .monospacedDigit()
                        }
                        .lineLimit(1)
                        .help(Format.copilot(entry.totals).map { "\(entry.source.displayName): \($0)" } ?? entry.source.displayName)
                    }
                }
                .font(.system(size: 11.5))
            }
        }
    }

    static func ranked(_ bySource: [AgentSource: LedgerTotals]) -> [(source: AgentSource, totals: LedgerTotals)] {
        bySource.map { (source: $0.key, totals: $0.value) }.sorted { a, b in
            if a.totals.apiEquivUSD != b.totals.apiEquivUSD { return a.totals.apiEquivUSD > b.totals.apiEquivUSD }
            if a.totals.tokens.total != b.totals.tokens.total { return a.totals.tokens.total > b.totals.tokens.total }
            return a.source.rawValue < b.source.rawValue
        }
    }
}

/// The project's top models as small dots and names, plus Copilot's units when it has any.
struct ModelLine: View {
    let models: [ModelShare]
    var copilot: String?

    var body: some View {
        let shown = models.prefix(3)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                ForEach(Array(shown.enumerated()), id: \.element.model) { index, share in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(SeriesPalette.color(index))
                            .frame(width: 6, height: 6)
                        Text(Format.model(share.model))
                            .lineLimit(1)
                    }
                }
                if models.count > shown.count {
                    Text("+\(models.count - shown.count)")
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            if let copilot {
                Label(copilot, systemImage: SourceBadge.symbol(for: .copilotCLI))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Detail

struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    let opened: OpenedProject
    let detail: ProjectDetailData?

    var body: some View {
        let history = model.history
        let summary = detail?.summary ?? ProjectSummary(project: opened.project)
        let range = detail?.range ?? history.projectsRange
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(summary)
                HistoryBanner()
                if detail == nil {
                    loadingTiles
                } else {
                    tiles(summary)
                }
                DashboardCard(title: "Daily spend", subtitle: "\(range.label) · by model") {
                    SpendChart(series: detail?.daily ?? DailySpendSeries(days: [], points: []), split: .model)
                        .frame(height: 220)
                }
                HStack(alignment: .top, spacing: 12) {
                    DashboardCard(title: "By source", subtitle: range.label) {
                        SourceBreakdown(bySource: summary.bySource)
                    }
                    DashboardCard(title: "By model", subtitle: range.label) {
                        ModelBreakdown(models: summary.topModels)
                    }
                }
                sessions(detail, range: range)
            }
            .padding(24)
        }
    }

    private func header(_ summary: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { model.history.closeProject() } label: {
                    Label("Projects", systemImage: "chevron.left")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("Back to all projects")
                Spacer()
                ProjectRangePicker()
            }
            HStack(alignment: .center, spacing: 14) {
                IconTile(projectKind: summary.kind, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.title)
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)
                    Text(caption(summary))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                if let root = summary.root {
                    HStack(spacing: 8) {
                        Button { WorkspaceActions.revealInFinder(root) } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        Button { WorkspaceActions.openInTerminal(root) } label: {
                            Label("Open in Terminal", systemImage: "apple.terminal")
                        }
                        Button { WorkspaceActions.copy(root) } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy path")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
    }

    private func caption(_ summary: ProjectSummary) -> String {
        guard let root = summary.root else {
            return "Usage without a project: telemetry with no hoply.cwd and no readable process cwd"
        }
        var parts = [Format.path(root), Self.kindName(summary.kind)]
        if !summary.branches.isEmpty {
            parts.append(summary.branches.count == 1 ? "1 branch" : "\(summary.branches.count) branches")
        }
        if !summary.worktrees.isEmpty {
            parts.append(summary.worktrees.count == 1 ? "1 worktree" : "\(summary.worktrees.count) worktrees")
        }
        return parts.joined(separator: " · ")
    }

    private static func kindName(_ kind: ProjectKind?) -> String {
        switch kind {
        case .repo: return "Git repository"
        case .folder: return "Folder"
        case .home: return "Home folder"
        case .scratch: return "Scratch space"
        case nil: return "Unassigned"
        }
    }

    private var loadingTiles: some View {
        HStack(spacing: 12) {
            HeadlineTile(label: "Spend", value: "–", symbol: "dollarsign.circle")
            HeadlineTile(label: "Sessions", value: "–", symbol: "list.bullet.rectangle", tint: .teal)
            HeadlineTile(label: "Tokens", value: "–", symbol: "text.word.spacing", tint: .indigo)
            HeadlineTile(label: "Branches", value: "–", symbol: "arrow.triangle.branch", tint: .green)
        }
    }

    private func tiles(_ summary: ProjectSummary) -> some View {
        let totals = summary.totals
        let tokens = totals.tokens
        let local = summary.topModels.filter { $0.totals.costUSD == 0 && $0.totals.apiEquivUSD > 0 }
            .reduce(LedgerTotals.zero) { $0 + $1.totals }
        return HStack(spacing: 12) {
            HeadlineTile(label: "Spend", totals: totals, symbol: "dollarsign.circle")
            HeadlineTile(label: "Sessions", value: Format.count(summary.sessionCount),
                         detail: summary.lastActive.map { "last active \(Format.lastActive($0))" } ?? "No sessions in range",
                         symbol: "list.bullet.rectangle", tint: .teal)
            HeadlineTile(label: "Tokens", value: Format.tokens(tokens.total),
                         detail: tokens.total > 0
                             ? "\(Format.percent(Double(tokens.cacheRead) / Double(tokens.total))) cache reads · \(Format.tokens(tokens.output)) out"
                             : "No tokens in range",
                         symbol: "text.word.spacing", tint: .indigo)
            if totals.premiumRequests > 0 || totals.aiu > 0 {
                HeadlineTile(label: "Copilot", value: "\(Format.premiumRequests(totals.premiumRequests)) req",
                             detail: "premium requests · \(Format.aiu(totals.aiu)) AIU",
                             symbol: SourceBadge.symbol(for: .copilotCLI), tint: SourceBadge.color(for: .copilotCLI))
            } else if local.calls > 0 {
                HeadlineTile(label: "Ran locally", value: Format.cost(local.apiEquivUSD),
                             detail: "API-equivalent, $0 spent", symbol: "cpu", tint: SourceBadge.color(for: .qwenCode))
            } else {
                HeadlineTile(label: "Branches", value: "\(summary.branches.count)",
                             detail: summary.worktrees.isEmpty ? "no linked worktrees"
                                 : summary.worktrees.count == 1 ? "1 linked worktree" : "\(summary.worktrees.count) linked worktrees",
                             symbol: "arrow.triangle.branch", tint: .green)
            }
        }
    }

    private func sessions(_ detail: ProjectDetailData?, range: HistoryRange) -> some View {
        let history = model.history
        let page = detail?.sessions
        let total = page?.totalCount ?? 0
        return HStack(alignment: .top, spacing: 12) {
            Card(prominent: true, padding: 0) {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Sessions")
                            .font(.system(size: 14, weight: .semibold))
                        Text(total == 1 ? "1 session · \(range.label)" : "\(Format.count(total)) sessions · \(range.label)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                    SessionTable(sessions: page?.sessions ?? [],
                                 selection: Binding(get: { history.selectedProjectSession?.id },
                                                    set: { history.selectProjectSession(id: $0) }))
                    Divider()
                    Pager(offset: history.projectSessionsOffset, count: page?.sessions.count ?? 0, total: total) {
                        history.showProjectSessionsPage(offset: $0)
                    }
                }
            }
            .frame(height: 440)
            SessionDetail(session: history.selectedProjectSession)
                .frame(width: 290, height: 440, alignment: .top)
        }
    }
}

struct SourceBreakdown: View {
    let bySource: [AgentSource: LedgerTotals]

    var body: some View {
        let sources = SourceSplit.ranked(bySource)
        let top = max(sources.map(\.totals.apiEquivUSD).max() ?? 0, 0.000_001)
        if sources.isEmpty {
            EmptyNote(text: "No usage in this range")
        } else {
            VStack(spacing: 12) {
                ForEach(sources, id: \.source) { entry in
                    BreakdownRow(title: entry.source.displayName, value: Format.spend(entry.totals),
                                 valueIsWarning: entry.totals.hasUnpriced && entry.totals.apiEquivUSD == 0,
                                 fraction: entry.totals.apiEquivUSD / top, tint: SourceBadge.color(for: entry.source),
                                 subtitle: subtitle(entry.totals), detail: Format.copilot(entry.totals)) {
                        SourceBadge(source: entry.source, size: 30)
                    }
                }
            }
        }
    }

    private func subtitle(_ totals: LedgerTotals) -> String {
        var parts = ["\(Format.tokens(totals.tokens.total)) tokens", "\(Format.count(totals.calls)) calls"]
        if totals.apiEquivUSD > 0, totals.costUSD == 0 { parts.append("local, $0 spent") }
        return parts.joined(separator: " · ")
    }
}

struct ModelBreakdown: View {
    let models: [ModelShare]

    var body: some View {
        let top = max(models.map(\.totals.apiEquivUSD).max() ?? 0, 0.000_001)
        if models.isEmpty {
            EmptyNote(text: "No model usage in this range")
        } else {
            VStack(spacing: 12) {
                ForEach(Array(models.enumerated()), id: \.element.model) { index, share in
                    BreakdownRow(title: share.model.isEmpty ? "Unknown model" : Format.model(share.model),
                                 value: Format.spend(share.totals),
                                 valueIsWarning: share.totals.hasUnpriced && share.totals.apiEquivUSD == 0,
                                 fraction: share.totals.apiEquivUSD / top, tint: SeriesPalette.color(index),
                                 subtitle: subtitle(share.totals), detail: Format.copilot(share.totals)) {
                        IconTile(symbol: "cube.fill", tint: SeriesPalette.color(index), size: 30)
                    }
                }
            }
        }
    }

    private func subtitle(_ totals: LedgerTotals) -> String {
        var parts = ["\(Format.tokens(totals.tokens.total)) tokens", "\(Format.count(totals.calls)) calls"]
        if totals.apiEquivUSD > 0, totals.costUSD == 0 { parts.append("local") }
        return parts.joined(separator: " · ")
    }
}
