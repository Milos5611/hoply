import AgentKit
import Charts
import SwiftUI

struct LimitsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        let data = history.limits
        let now = Date()
        let windows = windows(data, now: now)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Limits", subtitle: "Claude plan usage windows and Copilot premium requests")
                HistoryBanner()
                if !model.settings.claudeLimitsEnabled {
                    LimitsConnectCard()
                } else if windows.isEmpty {
                    LimitsLoadingCard()
                } else {
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        ForEach(Array(stride(from: 0, to: windows.count, by: 2)), id: \.self) { start in
                            GridRow {
                                ForEach(windows[start..<min(start + 2, windows.count)], id: \.kind) { projection in
                                    LimitWindowCard(projection: projection, spend: data?.windowSpend[projection.kind],
                                                    now: now)
                                }
                                if start + 1 == windows.count {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                }
                            }
                        }
                    }
                }
                if model.settings.claudeLimitsEnabled || !(data?.samples.isEmpty ?? true) {
                    LimitHistoryCard(data: data, now: now)
                }
                CopilotAllowanceCard(data: data, historyOff: history.unavailableReason != nil)
            }
            .padding(24)
        }
    }

    /// The ledger's projections; with History off (or before its first read) the live fetch alone, which has no
    /// burn rate yet.
    private func windows(_ data: LimitsData?, now: Date) -> [LimitsProjection] {
        guard model.settings.claudeLimitsEnabled else { return [] }
        var projections = data?.projections ?? [:]
        if projections.isEmpty, let live = model.claudeLimits {
            projections = LimitsProjection.projections(live.samples(at: now))
        }
        return LimitKind.allCases.compactMap { projections[$0] }
    }
}

enum LimitsStyle {
    static func color(_ kind: LimitKind) -> Color {
        switch kind {
        case .fiveHour: return SourceBadge.color(for: .claudeCode)
        case .sevenDay: return .blue
        case .sevenDayOpus: return .purple
        case .sevenDaySonnet: return .teal
        }
    }

    static func title(_ kind: LimitKind) -> String {
        kind == .fiveHour ? "5-hour window" : kind.displayName
    }
}

// MARK: - Windows

struct LimitWindowCard: View {
    let projection: LimitsProjection
    let spend: LedgerTotals?
    let now: Date

    var body: some View {
        let tint = ClaudeLimitsWidget.tint(projection.utilization)
        let outlook = outlook
        Card(prominent: true, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "asterisk")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(LimitsStyle.color(projection.kind))
                    Text(LimitsStyle.title(projection.kind))
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 8)
                    LimitChip(text: outlook.chip, color: outlook.color)
                }
                HStack(alignment: .center, spacing: 18) {
                    RingGauge(fraction: projection.utilization / 100, tint: tint, lineWidth: 9) {
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
                        ProjectionBar(current: projection.utilization, projected: projectedEnd, tint: tint)
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
                    Metric(value: spend.map(Format.spend) ?? "–", label: "API equiv so far")
                        .help("What Claude Code's usage in this window would cost on the API, from the usage ledger")
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var hasReset: Bool {
        projection.resetsAt.map { $0 <= now } ?? false
    }

    /// Where the bar's projected part ends: 100 when the pace runs into the limit before the reset.
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
        return projection.kind == .fiveHour ? String(format: "%.1f%%/h", rate) : String(format: "%.1f%%/day", rate * 24)
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

/// Used so far (solid), where the current pace ends at reset (faint), and ticks at the 80% and 95% alerts.
struct ProjectionBar: View {
    let current: Double
    let projected: Double?
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
            }
        }
        .frame(height: 7)
        .help("Solid: used so far. Faint: where the current pace ends at reset. Ticks: the 80% and 95% alerts.")
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

    var body: some View {
        let history = model.history
        let days = data?.days ?? history.limitsDays
        DashboardCard(title: "Utilization history", subtitle: "Last \(days) days · peak per \(days > 7 ? "hour" : "10 minutes")",
                      trailing: {
            Picker("Range", selection: Binding(get: { history.limitsDays }, set: { history.setLimitsDays($0) })) {
                ForEach(History.limitDayChoices, id: \.self) { Text("\($0) days").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }) {
            if history.unavailableReason != nil {
                EmptyNote(text: "The utilization history lives in the usage ledger, which is off.")
            } else if let data, !data.samples.isEmpty {
                LimitChart(samples: data.samples, days: data.days, now: now)
                    .frame(height: 250)
            } else {
                EmptyNote(text: data == nil ? "Loading…" : "No readings yet. Hoply stores one every 3 minutes while it runs.")
                    .frame(height: 120)
            }
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
        var id: String { "\(kind.rawValue)-\(at.timeIntervalSince1970)" }
    }

    let kinds: [LimitKind]
    let points: [LimitKind: [Point]]
    let resets: [Reset]
    let domain: ClosedRange<Date>
    let days: Int
    @State private var selection: Date?

    init(samples: [LimitSample], days: Int, now: Date) {
        let range = now.addingTimeInterval(-Double(days) * 86_400)...now
        self.days = days
        domain = range
        var points: [LimitKind: [Point]] = [:]
        var resets: [String: Reset] = [:]
        for (kind, samples) in Dictionary(grouping: samples, by: \.kind) {
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
                    let reset = Reset(kind: kind, at: resetsAt)
                    let slot = "\(kind.rawValue)-\(Int(resetsAt.timeIntervalSince1970 / LimitSample.windowTolerance))"
                    resets[slot] = resets[slot] ?? reset
                }
                previous = sample
            }
            points[kind] = list
        }
        self.points = points
        self.resets = resets.values.sorted { $0.at < $1.at }
        kinds = LimitKind.allCases.filter { !(points[$0]?.isEmpty ?? true) }
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
                if reset.kind == .fiveHour {
                    RuleMark(x: .value("Reset", reset.at), yStart: .value("Utilization", 0),
                             yEnd: .value("Utilization", 7))
                        .foregroundStyle(LimitsStyle.color(reset.kind))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                } else {
                    RuleMark(x: .value("Reset", reset.at))
                        .foregroundStyle(LimitsStyle.color(reset.kind).opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            Text("\(reset.kind == .sevenDay ? "Week" : reset.kind.displayName) reset")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(LimitsStyle.color(reset.kind))
                        }
                }
            }
            ForEach(kinds, id: \.self) { kind in
                let color = LimitsStyle.color(kind)
                let list = points[kind] ?? []
                AreaPlot(list, x: .value("Time", \.ts), y: .value("Utilization", \.utilization),
                         series: .value("Window", \.window), stacking: .unstacked)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.16), color.opacity(0.01)],
                                                    startPoint: .top, endPoint: .bottom))
                LinePlot(list, x: .value("Time", \.ts), y: .value("Utilization", \.utilization),
                         series: .value("Window", \.window))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
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
        .accessibilityLabel("Claude plan utilization over the last \(days) days")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: 5) {
                    Circle().fill(LimitsStyle.color(kind)).frame(width: 7, height: 7)
                    Text(kind.displayName)
                }
            }
            Spacer(minLength: 8)
            if kinds.contains(.fiveHour) {
                HStack(spacing: 5) {
                    Capsule().fill(LimitsStyle.color(.fiveHour)).frame(width: 1.5, height: 9)
                    Text("5-hour reset")
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

    /// Each window's latest reading at or before `time`, if it was running then.
    private func rows(at time: Date) -> [LimitTooltip.Row] {
        let reach: TimeInterval = days > 7 ? 2 * 3_600 : 45 * 60
        return kinds.compactMap { kind in
            guard let point = points[kind]?.last(where: { $0.ts <= time }),
                  time.timeIntervalSince(point.ts) <= reach else { return nil }
            return LimitTooltip.Row(kind: kind, utilization: point.utilization)
        }
    }
}

struct LimitTooltip: View {
    struct Row: Identifiable {
        let kind: LimitKind
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
                    Text(row.kind.displayName)
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
