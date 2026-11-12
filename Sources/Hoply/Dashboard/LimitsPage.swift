import AgentKit
import Charts
import SwiftUI

struct LimitsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        let data = history.limits
        let now = Date()
        let live = model.claudeLimits
        let windows = claudeWindows(data, now: now)
        let codex = codexWindows(data)
        let extras = model.settings.claudeLimitsEnabled && (live?.extraUsage != nil || live?.spend != nil) ? live : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Limits", subtitle: "Claude and Codex plan windows, and Copilot premium requests")
                HistoryBanner()
                if !codex.isEmpty {
                    LimitsProviderHeader(provider: .claude, detail: "Read with Claude Code's login every 3 minutes")
                }
                if !model.settings.claudeLimitsEnabled {
                    LimitsConnectCard()
                } else if windows.isEmpty {
                    LimitsLoadingCard()
                } else {
                    LimitWindowGrid(windows: windows, spend: data?.windowSpend ?? [:], live: live, extras: extras, now: now)
                }
                if let extras, windows.count % 2 == 0 {
                    PlanExtrasCard(limits: extras)
                }
                if !codex.isEmpty {
                    LimitsProviderHeader(provider: .codex, plan: codexPlan,
                                         detail: "From Codex's session files: no login, no network")
                        .padding(.top, 6)
                    LimitWindowGrid(windows: codex, spend: data?.windowSpend ?? [:], live: nil, now: now)
                }
                if model.settings.claudeLimitsEnabled || !(data?.samples.isEmpty ?? true) {
                    LimitHistoryCard(data: data, now: now)
                }
                CopilotAllowanceCard(data: data, historyOff: history.unavailableReason != nil)
                if model.settings.claudeLimitsEnabled, let keys = live?.unrecognizedKeys, !keys.isEmpty {
                    UnrecognizedKeysNote(keys: keys)
                }
            }
            .padding(24)
        }
    }

    private func claudeWindows(_ data: LimitsData?, now: Date) -> [LimitsProjection] {
        guard model.settings.claudeLimitsEnabled else { return [] }
        var projections = (data?.projections ?? [:]).filter { $0.key.provider == .claude }
        if projections.isEmpty, let live = model.claudeLimits {
            projections = LimitsProjection.projections(live.samples(at: model.claudeLimitsFetchedAt ?? now))
        }
        // A window the latest fetch no longer returns (a model's weekly window that went away) isn't kept alive
        // by its older readings.
        if let live = model.claudeLimits {
            let current = Set(live.windows.map(\.kind))
            projections = projections.filter { current.contains($0.key) }
        }
        return projections.keys.sorted().compactMap { projections[$0] }
    }

    // Only the windows Codex still reports; once the page has loaded, a reading older than the projections'
    // lookback has no card, so a Codex left unused for weeks doesn't keep a stale section.
    private func codexWindows(_ data: LimitsData?) -> [LimitsProjection] {
        let current = model.history.codexLimits
        return current.keys.sorted().compactMap { kind in
            guard let data else { return current[kind].flatMap { LimitsProjection(samples: [$0]) } }
            return data.projections[kind]
        }
    }

    private var codexPlan: String? {
        Format.codexPlan(model.history.codexLimits.values.max { $0.ts < $1.ts }?.plan)
    }
}

private struct LimitsProviderHeader: View {
    let provider: LimitProvider
    var plan: String?
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            SourceBadge(source: provider.source, size: 22)
            Text(provider.displayName)
                .font(.system(size: 15, weight: .semibold))
            if let plan {
                LimitChip(text: "\(plan) plan", color: .primary)
                    .help("The plan Codex reported with its latest reading")
            }
            Spacer(minLength: 12)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
    }
}

private struct LimitWindowGrid: View {
    let windows: [LimitsProjection]
    let spend: [LimitKind: LedgerTotals]
    let live: ClaudeLimits?
    var extras: ClaudeLimits?
    let now: Date

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: windows.count, by: 2)), id: \.self) { start in
                GridRow {
                    ForEach(windows[start..<min(start + 2, windows.count)], id: \.kind) { projection in
                        LimitWindowCard(projection: projection, title: LimitsStyle.title(projection.kind, live: live),
                                        spend: spend[projection.kind], now: now)
                    }
                    if start + 1 == windows.count {
                        if let extras {
                            PlanExtrasCard(limits: extras, stacked: true)
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }
}

enum LimitsStyle {
    static func color(_ kind: LimitKind) -> Color {
        if kind.provider == .codex {
            if kind.isModelScoped { return scopedColor(kind) }
            if isShort(kind) { return Color(red: 0.06, green: 0.64, blue: 0.5) }
            return kind.windowMinutes == 10_080 ? .blue : .purple
        }
        switch kind {
        case .fiveHour: return SourceBadge.color(for: .claudeCode)
        case .sevenDay: return .blue
        case .sevenDayOpus: return .purple
        case .sevenDaySonnet: return .teal
        default: return scopedColor(kind)
        }
    }

    static func isShort(_ kind: LimitKind) -> Bool {
        kind.windowLength < 86_400
    }

    private static func scopedColor(_ kind: LimitKind) -> Color {
        let scope = kind.scopeName.lowercased()
        if scope.hasPrefix("opus") { return .indigo }
        if scope.hasPrefix("sonnet") { return .cyan }
        if scope.hasPrefix("haiku") { return .mint }
        let palette: [Color] = [.pink, .green, .brown, Color(red: 0.56, green: 0.45, blue: 0.86)]
        return palette[Int(FNV1a.hash64(Array(kind.rawValue.utf8)) % UInt64(palette.count))]
    }

    static func name(_ kind: LimitKind, live: ClaudeLimits?) -> String {
        if kind.provider == .claude, !kind.isFixed, let scoped = live?.scoped.first(where: { $0.kind == kind }) {
            return "Weekly \(scoped.displayName)"
        }
        return kind.displayName
    }

    static func title(_ kind: LimitKind, live: ClaudeLimits?) -> String {
        guard !kind.isModelScoped, kind.windowMinutes != 10_080 else { return name(kind, live: live) }
        return "\(kind.windowName) window"
    }

    static func resetLabel(_ kind: LimitKind, name: String) -> String {
        if kind.isModelScoped { return "\(name) reset" }
        return kind.windowMinutes == 10_080 ? "Week reset" : "\(kind.windowName) reset"
    }

    static func paceLabel(_ band: LimitPace.Band) -> String {
        switch band {
        case .ahead: return "Ahead of pace"
        case .onTrack: return "On pace"
        case .under: return "Under pace"
        }
    }

    static func paceColor(_ band: LimitPace.Band) -> Color {
        switch band {
        case .ahead: return .orange
        case .onTrack: return .blue
        case .under: return .teal
        }
    }
}

// MARK: - Windows

struct LimitWindowCard: View {
    let projection: LimitsProjection
    let title: String
    let spend: LedgerTotals?
    let now: Date

    var body: some View {
        let tint = ClaudeLimitsWidget.tint(projection.utilization)
        let outlook = outlook
        let pace = pace
        Card(prominent: true, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: SourceBadge.symbol(for: projection.kind.provider.source))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(LimitsStyle.color(projection.kind))
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let pace {
                        LimitChip(text: LimitsStyle.paceLabel(pace.band), color: LimitsStyle.paceColor(pace.band))
                            .help(paceHelp(pace))
                    }
                    LimitChip(text: outlook.chip, color: outlook.color)
                }
                HStack(alignment: .center, spacing: 18) {
                    RingGauge(fraction: projection.utilization / 100, tint: tint, lineWidth: 9,
                              marker: pace.map { $0.elapsedPercent / 100 }) {
                        VStack(spacing: -1) {
                            Text(ClaudeLimitsWidget.percent(projection.utilization))
                                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            Text("used")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 9) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resetTitle)
                                .font(.system(size: 14, weight: .semibold))
                            Text(resetDetail)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProjectionBar(current: projection.utilization, projected: projectedEnd,
                                      elapsed: pace?.elapsedPercent, tint: tint)
                        Text(outlook.sentence)
                            .font(.system(size: 12))
                            .foregroundStyle(outlook.color == .green ? Color.secondary : outlook.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    Metric(value: burnRate, label: "Burn rate")
                    Metric(value: projectedEnd.map { "\(Int($0.rounded()))%" } ?? "–", label: "At reset")
                    let agent = projection.kind.provider.source.displayName
                    if projection.kind.isModelScoped {
                        Metric(value: spend.map(Format.spend) ?? "–", label: "API equiv, all models")
                            .help("What all of \(agent)'s usage since this window started would cost on the API. The ledger doesn't split it by model per window.")
                    } else {
                        Metric(value: spend.map(Format.spend) ?? "–", label: "API equiv so far")
                            .help("What \(agent)'s usage in this window would cost on the API, from the usage ledger")
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var hasReset: Bool {
        projection.resetsAt.map { $0 <= now } ?? false
    }

    /// Measured at the reading, so a stale reading isn't compared with time that passed after it.
    private var pace: LimitPace? {
        hasReset ? nil : projection.pace(at: projection.current.ts)
    }

    private func paceHelp(_ pace: LimitPace) -> String {
        "\(ClaudeLimitsWidget.percent(projection.utilization)) used with \(ClaudeLimitsWidget.percent(pace.elapsedPercent)) of the window gone. "
            + ClaudeLimitsWidget.paceSentence(pace)
            + " Within 5 points either way counts as on pace; the dark tick on the bar and the ring marks the time gone."
    }

    private var projectedEnd: Double? {
        guard !hasReset else { return nil }
        return projection.limitReachedAt != nil ? 100 : projection.projectedUtilization
    }

    private var resetTitle: String {
        guard let resetsAt = projection.resetsAt else { return "Not started" }
        return hasReset ? "Reset at \(Format.clock(resetsAt, now: now))" : Format.resetTime(resetsAt)
    }

    private var resetDetail: String {
        var parts: [String] = []
        if let resetsAt = projection.resetsAt {
            parts.append(hasReset ? "Waiting for a new reading" : "in \(Format.span(resetsAt.timeIntervalSince(now)))")
            if let pace {
                parts.append("\(ClaudeLimitsWidget.percent(pace.elapsedPercent)) of the window gone")
            }
        } else {
            parts.append("Starts with your next request")
        }
        if now.timeIntervalSince(projection.current.ts) > 600 {
            parts.append("last reading \(Format.when(projection.current.ts, now: now))")
        }
        return parts.joined(separator: " · ")
    }

    private var burnRate: String {
        guard let rate = projection.burnRatePerHour else { return "–" }
        return LimitsStyle.isShort(projection.kind) ? String(format: "%.1f%%/h", rate)
                                                    : String(format: "%.1f%%/day", rate * 24)
    }

    private var outlook: (chip: String, sentence: String, color: Color) {
        if hasReset { return ("Reset", "The window has reset since the last reading.", .secondary) }
        if projection.isAtLimit { return ("At limit", "Limit reached; requests wait for the reset.", .red) }
        if let reached = projection.limitReachedAt, let resetsAt = projection.resetsAt {
            let early = Format.span(resetsAt.timeIntervalSince(reached))
            return ("Hits limit", "At this pace: 100% at \(Format.clock(reached, now: now)), \(early) before reset.", .orange)
        }
        if let projected = projection.projectedUtilization {
            let text = "Projected \(Int(projected.rounded()))% at reset."
            return projected >= 90 ? ("Tight", text, .orange) : ("On track", text, .green)
        }
        if projection.resetsAt == nil { return ("Idle", "No window running.", .secondary) }
        return ("Measuring", "A projection needs a few readings in this window.", .secondary)
    }
}

private struct LimitChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct ProjectionBar: View {
    let current: Double
    let projected: Double?
    var elapsed: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                if let projected, projected > current {
                    Capsule()
                        .fill(ClaudeLimitsWidget.tint(projected).opacity(0.28))
                        .frame(width: width * min(projected, 100) / 100)
                }
                Capsule()
                    .fill(tint)
                    .frame(width: max(5, width * min(max(current, 0), 100) / 100))
                ForEach(NotificationPolicy.limitThresholds, id: \.self) { threshold in
                    Rectangle()
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: 1, height: 11)
                        .offset(x: width * threshold / 100)
                }
                if let elapsed {
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 2, height: 15)
                        .offset(x: width * min(max(elapsed, 0), 100) / 100 - 1)
                }
            }
        }
        .frame(height: 7)
        .help("Solid: used so far. Faint: where the current pace ends at reset. Dark tick: the share of the window gone by. Small ticks: the 80% and 95% alerts.")
    }
}

private struct LimitsConnectCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(prominent: true, padding: 18) {
            HStack(spacing: 14) {
                IconTile(symbol: "asterisk", tint: SourceBadge.color(for: .claudeCode), size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Claude limits aren't connected")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Hoply reads your 5-hour and weekly usage with Claude Code's login every 3 minutes, keeps the history here and warns you at 80% and 95%.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Connect") { model.enableClaudeLimits() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct LimitsLoadingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(prominent: true, padding: 18) {
            HStack(spacing: 12) {
                if let error = model.claudeLimitsError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couldn't read Claude limits")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Try again") { Task { await model.refreshClaudeLimits() } }
                        .buttonStyle(.bordered)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading Claude limits…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }
}

// MARK: - History chart

struct LimitHistoryCard: View {
    @Environment(AppModel.self) private var model
    let data: LimitsData?
    let now: Date
    @State private var picked = LimitProvider.claude

    var body: some View {
        let history = model.history
        let days = data?.days ?? history.limitsDays
        let providers = providers
        let provider = providers.contains(picked) ? picked : providers.first ?? .claude
        let samples = data?.samples.filter { $0.kind.provider == provider } ?? []
        DashboardCard(title: "Utilization history", subtitle: "Last \(days) days · peak per \(days > 7 ? "hour" : "10 minutes")",
                      trailing: {
            HStack(spacing: 8) {
                if providers.count > 1 {
                    Picker("Plan", selection: Binding(get: { provider }, set: { picked = $0 })) {
                        ForEach(providers, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Picker("Range", selection: Binding(get: { history.limitsDays }, set: { history.setLimitsDays($0) })) {
                    ForEach(History.limitDayChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }) {
            if history.unavailableReason != nil {
                EmptyNote(text: "The utilization history lives in the usage ledger, which is off.")
            } else if !samples.isEmpty {
                LimitChart(samples: samples, provider: provider, days: days, now: now) {
                    LimitsStyle.name($0, live: model.claudeLimits)
                }
                .frame(height: 250)
            } else {
                EmptyNote(text: data == nil ? "Loading…" : emptyText(provider))
                    .frame(height: 120)
            }
        }
    }

    private var providers: [LimitProvider] {
        var found = Set(data?.samples.map(\.kind.provider) ?? [])
        if model.settings.claudeLimitsEnabled { found.insert(.claude) }
        return found.sorted()
    }

    private func emptyText(_ provider: LimitProvider) -> String {
        switch provider {
        case .claude: return "No readings yet. Hoply stores one every 3 minutes while it runs."
        case .codex: return "No readings in this range. Codex writes them to its session files as you use it."
        }
    }
}

struct LimitChart: View {
    struct Point: Identifiable {
        let ts: Date
        let utilization: Double
        let window: String
        var id: Date { ts }
    }

    struct Reset: Identifiable {
        let kind: LimitKind
        let at: Date
        let label: String
        var id: String { "\(kind.rawValue)-\(at.timeIntervalSince1970)" }
    }

    let kinds: [LimitKind]
    let names: [LimitKind: String]
    let points: [LimitKind: [Point]]
    let resets: [Reset]
    let domain: ClosedRange<Date>
    let days: Int
    let provider: LimitProvider
    @State private var selection: Date?

    init(samples: [LimitSample], provider: LimitProvider, days: Int, now: Date, name: (LimitKind) -> String) {
        let range = now.addingTimeInterval(-Double(days) * 86_400)...now
        self.days = days
        self.provider = provider
        domain = range
        var points: [LimitKind: [Point]] = [:]
        var resets: [String: Reset] = [:]
        var longResets: [Reset] = []
        for (kind, samples) in Dictionary(grouping: samples.filter { $0.kind.provider == provider }, by: \.kind) {
            var window = 0
            var previous: LimitSample?
            var list: [Point] = []
            for sample in samples.sorted(by: { $0.ts < $1.ts }) {
                // Between 5-hour windows the API reports 0% with no reset time; that isn't a window to draw.
                if sample.resetsAt == nil, sample.utilization == 0 {
                    previous = nil
                    window += 1
                    continue
                }
                if let previous, !sample.isSameWindow(as: previous) { window += 1 }
                list.append(Point(ts: sample.ts, utilization: sample.utilization, window: "\(kind.rawValue)-\(window)"))
                if let resetsAt = sample.resetsAt, range.contains(resetsAt) {
                    let reset = Reset(kind: kind, at: resetsAt, label: "")
                    if LimitsStyle.isShort(kind) {
                        let slot = "\(Int(resetsAt.timeIntervalSince1970 / LimitSample.windowTolerance))"
                        resets[slot] = resets[slot] ?? reset
                    } else {
                        longResets.append(reset)
                    }
                }
                previous = sample
            }
            points[kind] = list
        }
        self.points = points
        self.resets = (Array(resets.values) + Self.mergedLongResets(longResets, name: name)).sorted { $0.at < $1.at }
        kinds = points.keys.filter { !(points[$0]?.isEmpty ?? true) }.sorted()
        names = Dictionary(uniqueKeysWithValues: kinds.map { ($0, name($0)) })
    }

    private static func mergedLongResets(_ resets: [Reset], name: (LimitKind) -> String) -> [Reset] {
        var clusters: [[Reset]] = []
        for reset in resets.sorted(by: { $0.at < $1.at }) {
            if let last = clusters.last?.last, reset.at.timeIntervalSince(last.at) <= LimitSample.windowTolerance {
                clusters[clusters.count - 1].append(reset)
            } else {
                clusters.append([reset])
            }
        }
        return clusters.compactMap { cluster in
            guard let first = cluster.first else { return nil }
            let lead = cluster.first { !$0.kind.isModelScoped } ?? first
            return Reset(kind: lead.kind, at: lead.at, label: LimitsStyle.resetLabel(lead.kind, name: name(lead.kind)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            chart
            legend
        }
    }

    private var chart: some View {
        Chart {
            ForEach(NotificationPolicy.limitThresholds, id: \.self) { threshold in
                RuleMark(y: .value("Alert", threshold))
                    .foregroundStyle((threshold >= 95 ? Color.red : Color.orange).opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(resets) { reset in
                if LimitsStyle.isShort(reset.kind) {
                    RuleMark(x: .value("Reset", reset.at), yStart: .value("Utilization", 0),
                             yEnd: .value("Utilization", 7))
                        .foregroundStyle(LimitsStyle.color(reset.kind))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                } else {
                    RuleMark(x: .value("Reset", reset.at))
                        .foregroundStyle(LimitsStyle.color(reset.kind).opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            Text(reset.label)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(LimitsStyle.color(reset.kind))
                        }
                }
            }
            ForEach(kinds, id: \.self) { kind in
                LimitWindowPlot(points: points[kind] ?? [], color: LimitsStyle.color(kind))
            }
            if let selection {
                RuleMark(x: .value("Time", selection))
                    .foregroundStyle(Color.primary.opacity(0.14))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: selection < midpoint ? .trailing : .leading, alignment: .top, spacing: 8,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        LimitTooltip(time: selection, rows: rows(at: selection))
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...100)
        .chartXSelection(value: $selection)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: days > 7 ? 7 : 1)) { _ in
                AxisGridLine()
                if days > 7 {
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
                } else {
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: false)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) { Text("\(Int(percent))%") }
                }
            }
        }
        .accessibilityLabel("\(provider.displayName) plan utilization over the last \(days) days")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: 5) {
                    Circle().fill(LimitsStyle.color(kind)).frame(width: 7, height: 7)
                    Text(names[kind] ?? kind.displayName)
                }
            }
            Spacer(minLength: 8)
            if let short = kinds.first(where: LimitsStyle.isShort) {
                HStack(spacing: 5) {
                    Capsule().fill(LimitsStyle.color(short)).frame(width: 1.5, height: 9)
                    Text("\(short.windowName) reset")
                }
            }
            HStack(spacing: 5) {
                Rectangle()
                    .stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: 14, height: 0.5)
                Text("Alerts at 80% and 95%")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }

    private var midpoint: Date {
        domain.lowerBound.addingTimeInterval(domain.upperBound.timeIntervalSince(domain.lowerBound) / 2)
    }

    private func rows(at time: Date) -> [LimitTooltip.Row] {
        let reach: TimeInterval = days > 7 ? 2 * 3_600 : 45 * 60
        return kinds.compactMap { kind in
            guard let point = points[kind]?.last(where: { $0.ts <= time }),
                  time.timeIntervalSince(point.ts) <= reach else { return nil }
            return LimitTooltip.Row(kind: kind, name: names[kind] ?? kind.displayName, utilization: point.utilization)
        }
    }
}

private struct LimitWindowPlot: ChartContent {
    let points: [LimitChart.Point]
    let color: Color

    // Not `if #available` in a builder: with the macOS 27 SDK that fails to compile at a macOS 15+ target.
    var body: AnyChartContent {
        if #available(macOS 15, *) { return AnyChartContent(plots) }
        return AnyChartContent(marks)
    }

    @available(macOS 15, *)
    @ChartContentBuilder private var plots: some ChartContent {
        AreaPlot(points, x: .value("Time", \.ts), y: .value("Utilization", \.utilization),
                 series: .value("Window", \.window), stacking: .unstacked)
            .foregroundStyle(fill)
        LinePlot(points, x: .value("Time", \.ts), y: .value("Utilization", \.utilization),
                 series: .value("Window", \.window))
            .foregroundStyle(color)
            .lineStyle(line)
    }

    private var marks: some ChartContent {
        ForEach(points) { point in
            AreaMark(x: .value("Time", point.ts), y: .value("Utilization", point.utilization),
                     series: .value("Window", point.window), stacking: .unstacked)
                .foregroundStyle(fill)
            LineMark(x: .value("Time", point.ts), y: .value("Utilization", point.utilization),
                     series: .value("Window", point.window))
                .foregroundStyle(color)
                .lineStyle(line)
        }
    }

    private var fill: LinearGradient {
        LinearGradient(colors: [color.opacity(0.16), color.opacity(0.01)], startPoint: .top, endPoint: .bottom)
    }

    private var line: StrokeStyle { StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round) }
}

struct LimitTooltip: View {
    struct Row: Identifiable {
        let kind: LimitKind
        let name: String
        let utilization: Double
        var id: LimitKind { kind }
    }

    let time: Date
    let rows: [Row]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Format.when(time))
                .font(.system(size: 11.5, weight: .semibold))
            if rows.isEmpty {
                Text("No window running")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Circle().fill(LimitsStyle.color(row.kind)).frame(width: 7, height: 7)
                    Text(row.name)
                    Spacer(minLength: 12)
                    Text(ClaudeLimitsWidget.percent(row.utilization))
                        .monospacedDigit()
                        .fontWeight(.medium)
                }
                .font(.system(size: 11.5))
            }
        }
        .padding(10)
        .frame(minWidth: 150)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: colorScheme == .dark ? .controlBackgroundColor : .white))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

// MARK: - Extra usage and spend

struct PlanExtrasCard: View {
    let limits: ClaudeLimits
    var stacked = false

    var body: some View {
        Card(prominent: true, padding: 16) {
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                                 : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            layout {
                if let extra = limits.extraUsage {
                    PlanExtraSection(title: "Extra usage", symbol: "plus.circle.fill", enabled: extra.isEnabled,
                                     value: extra.percentUsed.map(ClaudeLimitsWidget.percent) ?? "–",
                                     caption: extraCaption(extra), fraction: extra.percentUsed.map { $0 / 100 })
                        .help("Usage past the plan's limits, billed separately. Anthropic sends these amounts without a unit, so Hoply shows only the share of the monthly limit.")
                }
                if limits.extraUsage != nil, limits.spend != nil {
                    Divider()
                }
                if let spend = limits.spend {
                    PlanExtraSection(title: "Spend limit", symbol: "creditcard.fill", enabled: spend.enabled,
                                     value: spend.used.map(Format.money) ?? "–", caption: spendCaption(spend),
                                     fraction: spend.percentUsed.map { $0 / 100 })
                        .help("Spend against your organization's budget, as Anthropic reports it.")
                }
                if stacked {
                    Spacer(minLength: 0)
                    Hint("From Anthropic's latest reading. Extra usage has no unit in the API, so only its share shows.")
                }
            }
            .frame(maxHeight: stacked ? .infinity : nil, alignment: .top)
        }
    }

    private func extraCaption(_ extra: ClaudeLimits.ExtraUsage) -> String {
        if extra.percentUsed != nil { return "of the monthly limit used" }
        return extra.isEnabled == false ? "Turned off" : "No usage figure yet"
    }

    private func spendCaption(_ spend: ClaudeLimits.Spend) -> String {
        guard let limit = spend.limit else { return spend.used == nil ? "No spend figure yet" : "spent" }
        if let percent = spend.percentUsed {
            return "of \(Format.money(limit)) · \(ClaudeLimitsWidget.percent(percent))"
        }
        return "limit \(Format.money(limit))"
    }
}

private struct PlanExtraSection: View {
    let title: String
    let symbol: String
    let enabled: Bool?
    let value: String
    let caption: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SourceBadge.color(for: .claudeCode))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                if let enabled {
                    LimitChip(text: enabled ? "On" : "Off", color: enabled ? .green : .secondary)
                }
            }
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                Text(caption)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let fraction {
                ShareBar(fraction: fraction, tint: ClaudeLimitsWidget.tint(fraction * 100))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UnrecognizedKeysNote: View {
    let keys: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
            Text("Anthropic also returned: \(keys.joined(separator: ", ")). Hoply doesn't read these fields yet.")
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
        .help("Fields in /api/oauth/usage beyond the known windows, extra usage and spend")
    }
}

// MARK: - Copilot

struct CopilotAllowanceCard: View {
    let data: LimitsData?
    let historyOff: Bool

    var body: some View {
        let allowance = data?.copilot ?? CopilotAllowance(used: 0, allowance: 0, usdPerExtraRequest: 0)
        Card(prominent: true, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    SourceBadge(source: .copilotCLI, size: 24)
                    Text("Copilot premium requests")
                        .font(.system(size: 14, weight: .semibold))
                    Text(Format.utcMonth(allowance.month.start))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("Resets \(Format.utcDay(allowance.nextReset))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .help("GitHub resets premium request counters on the 1st of each month at 00:00 UTC")
                }
                if historyOff {
                    EmptyNote(text: "Premium requests come from the usage ledger, which is off.")
                } else if let data {
                    content(data)
                } else {
                    EmptyNote(text: "Loading…")
                }
            }
        }
    }

    private func content(_ data: LimitsData) -> some View {
        let allowance = data.copilot
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(Format.premiumRequests(allowance.used))
                            .font(.system(size: 28, weight: .semibold).monospacedDigit())
                        Text(allowance.isSet ? "of \(Format.count(allowance.allowance)) this month" : "used this month")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    if let fraction = allowance.fraction {
                        Meter(label: "\(Int((fraction * 100).rounded()))% of your allowance", fraction: fraction,
                              caption: remainingCaption(allowance))
                    } else {
                        Hint("No monthly allowance set. Add your plan's allowance in Settings → Copilot plan to see what's left.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 12) {
                    if allowance.isSet {
                        GridRow {
                            Metric(value: allowance.remaining.map(Format.premiumRequests) ?? "–", label: "Remaining")
                            Metric(value: overage(allowance), label: "Overage")
                        }
                    }
                    GridRow {
                        Metric(value: Format.aiu(data.copilotMonth.aiu), label: "AIU")
                        Metric(value: Format.spend(data.copilotMonth), label: "API equiv")
                    }
                }
                .frame(width: 260)
            }
            Hint("Counts Copilot CLI from its session store. Copilot in the IDE draws on the same allowance, but its telemetry carries no request multiplier, so it isn't counted here.")
        }
    }

    private func remainingCaption(_ allowance: CopilotAllowance) -> String {
        if let over = allowance.overageRequests, over > 0 {
            return "\(Format.premiumRequests(over)) over"
        }
        return "\(Format.premiumRequests(allowance.remaining ?? 0)) left"
    }

    private func overage(_ allowance: CopilotAllowance) -> String {
        guard let requests = allowance.overageRequests, let usd = allowance.overageUSD else { return "–" }
        return requests > 0 ? "\(Format.premiumRequests(requests)) · \(Format.cost(usd))" : "0"
    }
}
