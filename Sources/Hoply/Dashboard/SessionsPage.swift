import AgentKit
import SwiftUI

struct SessionsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        let list = history.sessionList
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Sessions", subtitle: subtitle(list)) {
                Picker("Range", selection: Binding(get: { history.sessionsRange },
                                                   set: { history.setSessionsRange($0) })) {
                    ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HistoryBanner()
            HStack(alignment: .top, spacing: 12) {
                Card(prominent: true, padding: 0) {
                    VStack(spacing: 0) {
                        SessionTable(sessions: list?.sessions ?? [],
                                     selection: Binding(get: { history.selectedSession?.id },
                                                        set: { history.selectSession(id: $0) }))
                        Divider()
                        Pager(offset: history.sessionsOffset, count: list?.sessions.count ?? 0,
                              total: list?.totalCount ?? 0) { history.showSessionsPage(offset: $0) }
                    }
                }
                .frame(maxHeight: .infinity)
                SessionDetail(session: history.selectedSession)
                    .frame(width: 290)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(24)
    }

    private func subtitle(_ list: SessionPage?) -> String {
        guard let list else { return "Every agent session in the ledger" }
        return list.totalCount == 1 ? "1 session" : "\(Format.count(list.totalCount)) sessions"
    }
}

struct SessionTable: View {
    let sessions: [SessionSummary]
    @Binding var selection: SessionSummary.ID?

    var body: some View {
        Table(sessions, selection: $selection) {
            TableColumn("Session") { session in
                HStack(spacing: 8) {
                    SourceBadge(source: session.key.source, size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayTitle)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        Text(place(session))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 160, ideal: 200)
            TableColumn("Models") { session in
                ModelMix(models: session.models)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Turns") { session in
                Text(session.turns > 0 ? "\(session.turns)" : "–")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 36, ideal: 40)
            TableColumn("Tokens") { session in
                Text(Format.tokens(session.totals.tokens.total))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 48, ideal: 54)
            TableColumn("Cost") { session in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Format.spend(session.totals))
                        .fontWeight(.medium)
                        .foregroundStyle(session.totals.hasUnpriced && session.totals.apiEquivUSD == 0
                                         ? Color.orange : Color.primary)
                    if session.totals.premiumRequests > 0 {
                        Text("\(Format.premiumRequests(session.totals.premiumRequests)) req")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .help(Format.copilot(session.totals) ?? "")
                    }
                }
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 52, ideal: 60)
            TableColumn("Last active") { session in
                Text(session.lastAt.map { Format.shortWhen($0) } ?? "–")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 78)
        }
        .tableStyle(.inset)
        .scrollContentBackground(.hidden)
        .font(.system(size: 12))
        .overlay {
            if sessions.isEmpty { EmptyNote(text: "No sessions in this range") }
        }
    }

    private func place(_ session: SessionSummary) -> String {
        var parts = [session.project?.title ?? session.cwd.map { ($0 as NSString).lastPathComponent } ?? "Unassigned"]
        if let branch = session.branch, !branch.isEmpty { parts.append(branch) }
        return parts.joined(separator: " · ")
    }
}

struct ModelMix: View {
    let models: [ModelShare]

    var body: some View {
        let total = models.reduce(0) { $0 + $1.totals.tokens.total }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(models.first.map { Format.model($0.model) } ?? "–")
                    .lineLimit(1)
                if models.count > 1 {
                    Text("+\(models.count - 1)")
                        .foregroundStyle(.secondary)
                }
            }
            if models.count > 1, total > 0 {
                StackedBar(segments: models.prefix(4).enumerated().map { index, share in
                    (Double(share.totals.tokens.total), SeriesPalette.color(index))
                })
                .frame(height: 4)
            }
        }
    }
}

struct Pager: View {
    let offset: Int
    let count: Int
    let total: Int
    let go: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(total == 0 ? "No sessions" : "\(offset + 1)–\(offset + count) of \(Format.count(total))")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button { go(offset - History.pageSize) } label: { Image(systemName: "chevron.left") }
                .disabled(offset == 0)
                .help("Newer sessions")
            Button { go(offset + History.pageSize) } label: { Image(systemName: "chevron.right") }
                .disabled(offset + count >= total)
                .help("Older sessions")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct SessionDetail: View {
    let session: SessionSummary?

    var body: some View {
        if let session {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(session)
                    cost(session)
                    if !session.models.isEmpty { models(session) }
                    changes(session)
                    actions(session)
                }
            }
            .scrollIndicators(.never)
        } else {
            Card(prominent: true) {
                EmptyNote(text: "Select a session")
            }
        }
    }

    private func header(_ session: SessionSummary) -> some View {
        Card(prominent: true, padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SourceBadge(source: session.key.source, size: 26)
                    Text(session.key.source.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(session.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 3) {
                    if let project = session.project?.title ?? session.cwd.map({ ($0 as NSString).lastPathComponent }) {
                        Label(project, systemImage: "folder")
                    }
                    if let branch = session.branch, !branch.isEmpty {
                        Label(branch, systemImage: "arrow.triangle.branch")
                    }
                    if let first = session.firstAt, let last = session.lastAt {
                        Label("\(Format.when(first)) – \(Format.when(last)) · \(Format.duration(from: first, to: last))",
                              systemImage: "clock")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
    }

    private func cost(_ session: SessionSummary) -> some View {
        let tokens = session.totals.tokens
        return Card(prominent: true, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.spend(session.totals))
                        .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    Text(costCaption(session))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Metric(value: Format.tokens(tokens.input), label: "Input")
                        Metric(value: Format.tokens(tokens.output), label: "Output")
                        Metric(value: session.turns > 0 ? "\(session.turns)" : "–", label: "Turns")
                    }
                    GridRow {
                        Metric(value: Format.tokens(tokens.cacheRead), label: "Cache read")
                        Metric(value: Format.tokens(tokens.cacheWrite), label: "Cache write")
                        Metric(value: Format.count(session.totals.calls), label: "Calls")
                    }
                }
            }
        }
    }

    private func costCaption(_ session: SessionSummary) -> String {
        var caption = "API-equivalent"
        if session.totals.costUSD == 0, session.totals.apiEquivUSD > 0 { caption += " · ran locally, $0 spent" }
        if let native = session.nativeCostUSD { caption += " · Claude Code says \(Format.cost(native))" }
        if let copilot = Format.copilot(session.totals) { caption += " · \(copilot)" }
        return caption
    }

    private func models(_ session: SessionSummary) -> some View {
        let top = max(session.models.map(\.totals.tokens.total).max() ?? 0, 1)
        return Card(prominent: true, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Models")
                ForEach(Array(session.models.enumerated()), id: \.element.model) { index, share in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(Format.model(share.model))
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text(Format.spend(share.totals))
                                .font(.system(size: 12.5).monospacedDigit())
                        }
                        ShareBar(fraction: Double(share.totals.tokens.total) / Double(top), tint: SeriesPalette.color(index))
                        Text("\(Format.tokens(share.totals.tokens.total)) tokens · \(share.totals.calls) calls")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func changes(_ session: SessionSummary) -> some View {
        let hasLines = session.linesAdded != nil || session.linesRemoved != nil
        if hasLines || session.prURL != nil {
            Card(prominent: true, padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Changes")
                    if hasLines {
                        HStack(spacing: 10) {
                            Text("+\(session.linesAdded ?? 0)")
                                .foregroundStyle(.green)
                            Text("−\(session.linesRemoved ?? 0)")
                                .foregroundStyle(.red)
                            Text("lines")
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    }
                    if let pr = session.prURL, let url = URL(string: pr) {
                        Link(destination: url) {
                            Label(url.path.isEmpty ? pr : String(url.path.dropFirst()), systemImage: "arrow.triangle.pull")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
        }
    }

    private func actions(_ session: SessionSummary) -> some View {
        HStack(spacing: 8) {
            if let path = session.transcriptPath {
                Button { WorkspaceActions.revealInFinder(path) } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .help("Reveal transcript in Finder")
            }
            if let cwd = session.cwd {
                Button { WorkspaceActions.openInTerminal(cwd) } label: { Image(systemName: "apple.terminal") }
                    .help("Open in Terminal")
            }
            Button { WorkspaceActions.copy(session.key.id) } label: { Image(systemName: "number") }
                .help("Copy session ID")
        }
        .buttonStyle(.tile)
    }
}

extension SessionSummary {
    /// Telemetry sessions (Qwen Code, Copilot IDE) carry no prompt text, so they have no title.
    var displayTitle: String {
        title ?? "\(key.source.displayName) session"
    }
}
