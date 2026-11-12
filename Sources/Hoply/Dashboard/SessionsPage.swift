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
            ProjectEditBanner()
            HStack(alignment: .top, spacing: 12) {
                Card(prominent: true, padding: 0, clipsContent: true) {
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
    @Environment(AppModel.self) private var model
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
        .contextMenu(forSelectionType: SessionSummary.ID.self) { ids in
            if ids.count == 1, let session = sessions.first(where: { ids.contains($0.id) }) {
                let edits = model.projectEdits
                ProjectMenu(projects: edits.targets(excluding: session.project),
                            choose: { edits.assign(session.key, to: $0) }) {
                    Text(session.project == nil ? "Assign to Project" : "Move to Project")
                }
                if edits.assignment(of: session.key) != nil {
                    Button("Undo Project Assignment") { edits.unassign(session.key) }
                }
            }
        }
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
                .tooltip("Newer sessions")
            Button { go(offset + History.pageSize) } label: { Image(systemName: "chevron.right") }
                .disabled(offset + count >= total)
                .tooltip("Older sessions")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct SessionDetail: View {
    @Environment(AppModel.self) private var model
    let session: SessionSummary?
    @State private var resumeFailed: SessionKey?

    var body: some View {
        if let session {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(session)
                    cost(session)
                    SessionTimelineCard(spans: model.history.insights[session.key]?.spans ?? [])
                    insight(session)
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
                        Label(model.projectEdits.assignment(of: session.key) == nil ? project : "\(project) · assigned by you",
                              systemImage: "folder")
                    } else {
                        Label("Unassigned", systemImage: "questionmark.folder")
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
                if model.history.isReady { SessionProjectControls(session: session) }
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

    @ViewBuilder
    private func insight(_ session: SessionSummary) -> some View {
        let insight = model.history.insights[session.key]
        let live = model.sessions.first { $0.key == session.key }
        if let context = insight?.context {
            Card(prominent: true, padding: 14) {
                ContextGauge(context: context, source: session.key.source)
            }
        }
        let rows = SubagentRow.rows(ledger: insight?.subagents ?? [], live: live?.subagents ?? [])
        if !rows.isEmpty {
            Card(prominent: true, padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionTitle("Subagents")
                        Spacer()
                        let working = rows.count { $0.isWorking }
                        Text(working > 0 ? "\(rows.count) · \(working) working" : "\(rows.count)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(working > 0 ? Color.blue : Color.secondary)
                    }
                    ForEach(rows) { SubagentRowView(row: $0) }
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

    private func canResume(_ session: SessionSummary) -> Bool {
        guard ResumeScript.isSupported(session.key.source), session.cwd?.isEmpty == false else { return false }
        return model.session(session.key).map { $0.state == .ended } ?? true
    }

    @ViewBuilder
    private func actions(_ session: SessionSummary) -> some View {
        if resumeFailed == session.key {
            Hint("Couldn't resume: the session's folder is gone, or the script couldn't be written.")
        }
        HStack(spacing: 8) {
            if canResume(session), let cwd = session.cwd {
                Button {
                    let started = ResumeLauncher.resume(source: session.key.source, sessionID: session.key.id, cwd: cwd)
                    resumeFailed = started ? nil : session.key
                } label: { Image(systemName: "play.fill") }
                    .tooltip("Resume this session in Terminal")
            }
            if let cwd = session.cwd, let editor = model.defaultEditor {
                Button { model.openInEditor(cwd) } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                    .tooltip("Open the session's folder in \(editor.name)")
            }
            if let path = session.transcriptPath {
                Button { WorkspaceActions.revealInFinder(path) } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .tooltip("Show the transcript file in Finder")
            }
            if let cwd = session.cwd {
                Button { WorkspaceActions.openInTerminal(cwd) } label: { Image(systemName: "apple.terminal") }
                    .tooltip("Open Terminal in the session's folder")
            }
            Button { WorkspaceActions.copy(session.key.id) } label: { Image(systemName: "number") }
                .tooltip("Copy the session ID")
        }
        .buttonStyle(.tile)
    }
}

struct ContextGauge: View {
    let context: ContextWindow
    let source: AgentSource

    var body: some View {
        let tint: Color = context.fraction >= 0.95 ? .red : context.isWarning ? .orange : .blue
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Context window")
                Spacer()
                if context.isWarning {
                    Label("Nearly full", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.tokens(context.used))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                Text("of \(Format.tokens(context.limit))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(context.fraction))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(context.isWarning ? tint : Color.primary)
            }
            ShareBar(fraction: context.fraction, tint: tint)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Color.primary.opacity(0.35))
                            .frame(width: 1.5, height: 9)
                            .offset(x: geometry.size.width * ContextWindow.warnFraction, y: -2)
                    }
                }
            Text("\(Format.tokens(context.remaining)) left · \(reported ? "the latest call, prompt and reply" : "the latest main call's prompt")")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(reported
              ? "The session's latest call, prompt and reply, against the context window Codex reports for the model. The tick marks 80%, where the panel starts to warn."
              : "Input, cache reads and cache writes of the session's latest main-agent call against the model's window. The tick marks 80%, where the panel starts to warn.")
    }

    private var reported: Bool { source == .codexCLI
    }
}

struct SubagentRow: Identifiable, Equatable {
    var id: String
    var name: String
    var note: String?
    var model: String?
    var duration: TimeInterval
    var totals: LedgerTotals?
    var isWorking: Bool

    static func rows(ledger: [SubagentSummary], live: [LiveSubagent], now: Date = Date()) -> [SubagentRow] {
        var rows = ledger.map { summary in
            let running = live.first { $0.id == summary.agentID }
            return SubagentRow(id: summary.agentID, name: summary.agentType ?? running?.type ?? summary.name,
                               note: summary.agentType == nil ? nil : summary.description, model: summary.model,
                               duration: running.map { ($0.endedAt ?? now).timeIntervalSince($0.startedAt) }
                                   ?? summary.duration,
                               totals: summary.totals, isWorking: running?.isWorking ?? false)
        }
        for subagent in live where !ledger.contains(where: { $0.agentID == subagent.id }) {
            rows.append(SubagentRow(id: subagent.id, name: subagent.type ?? "Subagent", note: nil, model: nil,
                                    duration: (subagent.endedAt ?? now).timeIntervalSince(subagent.startedAt),
                                    totals: nil, isWorking: subagent.isWorking))
        }
        return rows
    }
}

struct SubagentRowView: View {
    let row: SubagentRow

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if row.isWorking {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5.5))
                        .foregroundStyle(.blue)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                        .help("Working now")
                }
                Text(row.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(row.totals.map(Format.spend) ?? "–")
                    .font(.system(size: 12.5).monospacedDigit())
            }
            Text(caption)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(row.isWorking ? Color.blue : Color.secondary)
                .lineLimit(1)
        }
        .help(row.note ?? row.name)
    }

    private var caption: String {
        var parts: [String] = []
        if row.isWorking { parts.append("working") }
        if let model = row.model, !model.isEmpty { parts.append(Format.model(model)) }
        parts.append(Format.span(max(row.duration, 0)))
        if let totals = row.totals { parts.append("\(Format.tokens(totals.tokens.total)) tok") }
        return parts.joined(separator: " · ")
    }
}

extension SessionSummary {
    var displayTitle: String {
        title ?? "\(key.source.displayName) session"
    }
}
