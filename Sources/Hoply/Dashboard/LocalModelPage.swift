import AgentKit
import Charts
import SwiftUI

struct LocalModelPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        let servers = model.settings.modelServers
        let server = model.modelServers.selected(in: servers)
        let state = server.flatMap { model.modelServers.state(of: $0.id) }
        let data = history.localModel
        let own = data?.serverID == server?.id ? data : nil
        let capabilities = state?.status?.capabilities ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Local model", subtitle: "Your model servers' speed and memory, and what their tokens saved vs the API") {
                    if servers.count > 1, let server {
                        Picker("Server", selection: Binding(get: { server.id }, set: { model.modelServers.select($0) })) {
                            ForEach(servers) { Text($0.displayName).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("The server this page shows")
                    }
                    Picker("Range", selection: Binding(get: { history.localModelRange },
                                                       set: { history.setLocalModelRange($0) })) {
                        ForEach(LocalModelRange.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                HistoryBanner()
                if let server {
                    LiveModelCard(server: server, state: state, lastSeen: state?.lastSeen ?? own?.lastSeen)
                    if let status = state?.status, !status.models.isEmpty {
                        ModelsCard(status: status, live: state?.availability == .online)
                    }
                } else {
                    ModelServerSetupCard()
                }
                if history.unavailableReason != nil {
                    DashboardCard(title: "History") {
                        EmptyNote(text: "Speed, cache and token history live in the usage ledger, which is off.")
                    }
                } else {
                    if server != nil {
                        if capabilities.contains(.generationRate) || own?.generation.isEmpty == false {
                            SampleCard(title: "Generation speed", kind: .rate, tint: .blue, height: 220, data: own,
                                       buckets: own?.generation)
                        }
                        if capabilities.contains(.kvCache) || own?.kvCache.isEmpty == false {
                            SampleCard(title: "KV cache", kind: .percent, tint: .orange, height: 150, data: own,
                                       buckets: own?.kvCache)
                        }
                        if capabilities.contains(.memory) || own?.memory.isEmpty == false {
                            SampleCard(title: "Memory in use", kind: .bytes, tint: .purple, height: 150, data: own,
                                       buckets: own?.memory)
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        if capabilities.contains(.promptRate) || capabilities.contains(.generationRate)
                            || own?.tokenDays.contains(where: \.observed) == true {
                            TokensPerDayCard(data: own)
                        }
                        SavedVsAPICard(data: data)
                    }
                }
                if !servers.isEmpty {
                    DashboardCard(title: "Model servers",
                                  subtitle: servers.count == 1 ? "1 server" : "\(servers.count) servers") {
                        ModelServerList()
                    }
                }
            }
            .padding(24)
        }
    }
}

enum LocalModelStyle {
    static let tint = SourceBadge.color(for: .qwenCode)
    static let promptTint = tint.mix(with: .white, by: 0.5)
}

// MARK: - Live

private struct LiveModelCard: View {
    @Environment(AppModel.self) private var model
    let server: ModelServer
    let state: ModelServers.State?
    let lastSeen: Date?

    var body: some View {
        let health = model.modelServers.health(of: server)
        Card(prominent: true, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    IconTile(symbol: "cpu", tint: LocalModelStyle.tint, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.displayName)
                            .font(.system(size: 15, weight: .semibold))
                        Text(identity)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    StatusChip(text: health.detail, color: health.color)
                    Button { model.beginEditingModelServer(server.id) } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .tooltip("Edit \(server.displayName)")
                }
                Divider()
                if let online = state?.online {
                    figures(online)
                    ForEach(online.snapshot.hints, id: \.self) { hint in
                        Label(hint.text, systemImage: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    trouble(health)
                }
            }
        }
    }

    private var identity: String {
        var parts: [String] = []
        if let snapshot = state?.status?.snapshot {
            if let name = snapshot.primaryModel { parts.append(Format.servedModel(name)) }
            parts.append(snapshot.version.map { "\(snapshot.engine.displayName) \($0)" } ?? snapshot.engine.displayName)
        } else if let engine = server.engine {
            parts.append(engine.displayName)
        }
        parts.append(server.host)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func figures(_ status: ModelServerStatus) -> some View {
        let snapshot = status.snapshot
        let metrics = snapshot.metrics
        let capabilities = status.capabilities
        let series = state?.throughput.values ?? []
        let peak = series.max() ?? 0
        let loaded = snapshot.loadedModels
        let rated = capabilities.contains(.generationRate)
        HStack(alignment: .top, spacing: 16) {
            if rated {
                LiveFigure(label: "Generating", value: Format.rate(status.generationTokensPerSecond), unit: "tok/s",
                           detail: peak > 0 ? "peak \(Format.rate(peak)) in 10 min" : "idle in the last 10 min") {
                    MiniBars(values: series, highlightLast: 1, tint: .blue, maxBars: 20)
                }
            }
            if capabilities.contains(.promptRate) {
                LiveFigure(label: "Prompt", value: status.promptTokensPerSecond.map(Format.compact) ?? "–", unit: "tok/s",
                           detail: "\(Format.tokens(metrics.promptTokensTotal ?? 0)) since server start") {
                    EmptyView()
                }
            }
            if let usage = metrics.kvCacheUsage {
                LiveFigure(label: "KV cache", value: Format.percent(usage), unit: nil, detail: "of the cache in use") {
                    ShareBar(fraction: usage, tint: usage >= 0.9 ? .red : .orange)
                }
            }
            if let running = metrics.running {
                LiveFigure(label: "Requests", value: "\(running)", unit: "running",
                           detail: metrics.waiting.map { $0 == 0 ? "none waiting" : "\($0) waiting" } ?? " ") {
                    EmptyView()
                }
            } else if let waiting = metrics.waiting {
                LiveFigure(label: "Requests", value: "\(waiting)", unit: "waiting", detail: " ") { EmptyView() }
            }
            if !rated, capabilities.contains(.loadedModels) {
                LiveFigure(label: "Loaded", value: "\(loaded.count)", unit: loaded.count == 1 ? "model" : "models",
                           detail: loaded.isEmpty ? "none in memory right now"
                                                  : loaded.map { Format.servedModel($0.id) }.joined(separator: ", ")) {
                    EmptyView()
                }
            }
            if let memory = snapshot.memoryBytes {
                LiveFigure(label: "Memory", value: ModelServerText.memory(memory), unit: nil,
                           detail: metrics.memoryBytes != nil ? "reported by the server" : "held by loaded models") {
                    EmptyView()
                }
            }
            if !rated, capabilities.contains(.models) {
                LiveFigure(label: capabilities.contains(.loadedModels) ? "Installed" : "Served",
                           value: "\(status.models.count)", unit: status.models.count == 1 ? "model" : "models",
                           detail: "\(snapshot.engine.displayName) reports no throughput") {
                    EmptyView()
                }
            }
        }
        if capabilities.isSubset(of: [.version]) {
            Text("The server answers, but reports no models or live figures.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }

    private func trouble(_ health: ModelServerHealth) -> some View {
        let host = server.host.isEmpty ? server.baseURL : server.host
        let blocked = health == .signIn || health == .setup || health == .invalid
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: health.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(health.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline(health, host: host))
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(explanation(health))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if health == .paused {
                Button("Turn on") { model.setModelServerEnabled(server.id, true) }
                    .buttonStyle(.borderedProminent)
            } else if blocked {
                Button("Edit server") { model.beginEditingModelServer(server.id) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func headline(_ health: ModelServerHealth, host: String) -> String {
        switch health {
        case .paused: return "\(server.displayName) is off"
        case .invalid: return "The URL isn't a valid http(s) address"
        case .connecting: return "Waiting for the first answer from \(host)…"
        case .offline: return state?.error?.errorDescription ?? "No answer from \(host)"
        case .signIn, .setup: return state?.error?.errorDescription ?? "\(host) answers, but not with a model server API"
        case .live: return ""
        }
    }

    private func explanation(_ health: ModelServerHealth) -> String {
        switch health {
        case .paused: return "Hoply isn't polling it. \(lastSeenText)"
        case .invalid: return "Edit the server and set its address, for example http://192.168.1.20:8000."
        case .signIn: return "The server is up but refuses Hoply's sign-in, so this isn't counted as an outage. Check the sign-in details and test the connection."
        case .setup: return "The server is reachable but Hoply can't read it, so this isn't counted as an outage. Test the connection to see which endpoints answer."
        case .connecting, .offline, .live:
            return lastSeenText + " Hoply checks again every 5 seconds while this window is open."
        }
    }

    private var lastSeenText: String {
        guard let lastSeen else { return "Not seen yet." }
        let now = Date()
        return "Last seen \(Format.when(lastSeen, now: now)), \(Format.lastActive(lastSeen, now: now))."
    }
}

private struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

private struct LiveFigure<Accessory: View>: View {
    let label: String
    let value: String
    let unit: String?
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            ZStack(alignment: .bottomLeading) {
                Color.clear
                accessory
            }
            .frame(height: 16)
            Text(detail)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ModelServerSetupCard: View {
    var body: some View {
        Card(prominent: true, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    IconTile(symbol: "cpu", tint: LocalModelStyle.tint, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No model server yet")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Add the server your agents talk to: Ollama or LM Studio on this Mac, llama.cpp or vLLM on another machine, or one behind an API key, Cloudflare Access or Tailscale. Hoply shows what it reports (speed, cache, loaded models, memory) and keeps the history in the usage ledger.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ModelServerActions()
                    .font(.system(size: 12.5))
            }
        }
    }
}

private struct ModelsCard: View {
    let status: ModelServerStatus
    let live: Bool

    var body: some View {
        let models = status.models.sorted { ($0.loaded == true ? 0 : 1, $0.id) < ($1.loaded == true ? 0 : 1, $1.id) }
        let loaded = status.snapshot.loadedModels.count
        let count = models.count == 1 ? "1 model" : "\(models.count) models"
        DashboardCard(title: "Models",
                      subtitle: status.capabilities.contains(.loadedModels) ? "\(count) · \(loaded) loaded" : count) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(models) { served in
                    ServedModelRow(served: served)
                }
                Hint("Treat as local: the model costs $0 and its tokens count as saved vs the API. It is never set automatically, because a proxy can list cloud models too."
                     + (live ? "" : " This is the list from the last answer."))
            }
            .font(.system(size: 12.5))
        }
    }
}

private struct SampleCard: View {
    let title: String
    let kind: SampleChart.Kind
    let tint: Color
    let height: CGFloat
    let data: LocalModelData?
    let buckets: [SampleBucket]?

    var body: some View {
        let range = data?.range ?? .day
        DashboardCard(title: title,
                      subtitle: "Last \(range.label) · average\(kind == .rate ? " and peak" : "") per \(range.resolutionLabel)") {
            if let data, let buckets {
                SampleChart(buckets: buckets, domain: data.interval, kind: kind, tint: tint)
                    .frame(height: height)
            } else {
                EmptyNote(text: "Loading…").frame(height: height * 0.55)
            }
        }
    }
}

// MARK: - Speed and cache

struct SampleChart: View {
    enum Kind { case rate, percent, bytes }

    struct Point: Identifiable {
        let start: Date
        let end: Date
        let mean: Double
        let peak: Double
        let segment: Int
        var id: Date { start }
    }

    let points: [Point]
    let singles: Set<Int>
    let domain: ClosedRange<Date>
    let kind: Kind
    let tint: Color
    @State private var selection: Date?

    init(buckets: [SampleBucket], domain: DateInterval, kind: Kind, tint: Color) {
        var points: [Point] = []
        var segment = 0
        var previous: SampleBucket?
        for bucket in buckets {
            guard let mean = bucket.mean else { continue }
            if let previous {
                let step = TimeInterval(max(previous.resolution, bucket.resolution))
                if bucket.startDate.timeIntervalSince(previous.startDate) > 2 * step { segment += 1 }
            }
            points.append(Point(start: bucket.startDate,
                                end: bucket.startDate.addingTimeInterval(TimeInterval(bucket.resolution)),
                                mean: mean, peak: bucket.max ?? mean, segment: segment))
            previous = bucket
        }
        self.points = points
        singles = Set(Dictionary(grouping: points, by: \.segment).filter { $0.value.count == 1 }.keys)
        self.domain = domain.start...domain.end
        self.kind = kind
        self.tint = tint
    }

    var body: some View {
        if points.isEmpty {
            EmptyNote(text: "No readings in this range yet. Hoply stores one with every poll of the server.")
                .frame(maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                chart
                legend
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                if kind == .rate {
                    AreaMark(x: .value("Time", point.start), yStart: .value("Average", point.mean),
                             yEnd: .value("Peak", point.peak), series: .value("Stretch", "peak-\(point.segment)"))
                        .foregroundStyle(tint.opacity(0.11))
                } else {
                    AreaMark(x: .value("Time", point.start), yStart: .value("Zero", 0.0),
                             yEnd: .value("Average", point.mean), series: .value("Stretch", "area-\(point.segment)"))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                }
                LineMark(x: .value("Time", point.start), y: .value("Average", point.mean),
                         series: .value("Stretch", "line-\(point.segment)"))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                if singles.contains(point.segment) {
                    PointMark(x: .value("Time", point.start), y: .value("Average", point.mean))
                        .foregroundStyle(tint)
                        .symbolSize(14)
                }
            }
            if let selected {
                RuleMark(x: .value("Time", selected.start))
                    .foregroundStyle(Color.primary.opacity(0.14))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: selected.start < midpoint ? .trailing : .leading, alignment: .top, spacing: 8,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        SampleTooltip(point: selected, kind: kind, tint: tint)
                    }
                PointMark(x: .value("Time", selected.start), y: .value("Average", selected.mean))
                    .foregroundStyle(tint)
                    .symbolSize(30)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...yTop)
        .chartXSelection(value: $selection)
        .chartXAxis { xAxis }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(axisLabel(number))
                    }
                }
            }
        }
        .accessibilityLabel(kind == .rate ? "Generation tokens per second over time"
                            : kind == .percent ? "KV cache use over time" : "Memory in use over time")
    }

    private func axisLabel(_ number: Double) -> String {
        switch kind {
        case .percent: return "\(Format.whole(number))%"
        case .rate: return Format.compact(number).replacingOccurrences(of: ".0", with: "")
        case .bytes: return number == 0 ? "0" : ModelServerText.memory(number)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Capsule().fill(tint).frame(width: 14, height: 2)
                Text(kind == .rate ? "Average tok/s" : kind == .percent ? "Average KV cache use" : "Average memory in use")
            }
            if kind == .rate {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.16)).frame(width: 14, height: 9)
                    Text("Up to the peak")
                }
            }
            Spacer(minLength: 8)
            Text("Gaps: no readings")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }

    @AxisContentBuilder
    private var xAxis: some AxisContent {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        if span <= 2 * 86_400 {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour(), centered: false)
            }
        } else if span <= 8 * 86_400 {
            AxisMarks(values: dayMarks(every: 1)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: false)
            }
        } else {
            AxisMarks(values: dayMarks(every: 5, backFromToday: 2)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
            }
        }
    }

    /// Midnights counted back from the end, so the last label never starts so close to the right edge that it
    /// gets cut off.
    private func dayMarks(every step: Int, backFromToday offset: Int = 0) -> [Date] {
        let calendar = Calendar.current
        let margin = domain.upperBound.timeIntervalSince(domain.lowerBound) * 0.035
        var day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: domain.upperBound))
        var marks: [Date] = []
        while let current = day, current >= domain.lowerBound {
            if domain.upperBound.timeIntervalSince(current) >= margin { marks.append(current) }
            day = calendar.date(byAdding: .day, value: -step, to: current)
        }
        return marks.reversed()
    }

    private var yTop: Double {
        if kind == .percent { return 100 }
        let top = points.map(\.peak).max() ?? 0
        return max(top * 1.12, 1)
    }

    private var midpoint: Date {
        domain.lowerBound.addingTimeInterval(domain.upperBound.timeIntervalSince(domain.lowerBound) / 2)
    }

    private var selected: Point? {
        guard let selection else { return nil }
        return points.last { $0.start <= selection && selection < $0.end }
    }
}

private struct SampleTooltip: View {
    let point: SampleChart.Point
    let kind: SampleChart.Kind
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Format.when(point.start))
                .font(.system(size: 11.5, weight: .semibold))
            row("Average", value(point.mean), color: tint)
            row("Peak", value(point.peak), color: tint.opacity(0.4))
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

    private func row(_ label: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .fontWeight(.medium)
        }
        .font(.system(size: 11.5))
    }

    private func value(_ number: Double) -> String {
        switch kind {
        case .percent: return "\(Format.whole(number))%"
        case .rate: return "\(Format.rate(number)) tok/s"
        case .bytes: return ModelServerText.memory(number)
        }
    }
}

// MARK: - Days

private struct TokensPerDayCard: View {
    let data: LocalModelData?

    var body: some View {
        let days = data?.tokenDays ?? []
        let observed = days.filter(\.observed)
        DashboardCard(title: "Tokens per day", subtitle: "Last \(data?.range.dailyDays ?? 7) days · the server's own counters") {
            if data == nil {
                EmptyNote(text: "Loading…").frame(height: 120)
            } else if observed.isEmpty {
                EmptyNote(text: "No readings in these days yet.").frame(height: 120)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(Format.tokens(observed.reduce(0) { $0 + $1.prompt + $1.generated }))
                            .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        Text("tokens · \(Format.tokens(observed.reduce(0) { $0 + $1.generated })) generated")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    TokenDaysChart(days: days)
                        .frame(height: 210)
                }
            }
        }
    }
}

private struct TokenDaysChart: View {
    struct Bar: Identifiable {
        let day: Date
        let series: String
        let value: Double
        var id: String { "\(day.timeIntervalSince1970)-\(series)" }
    }

    let days: [ModelTokenDay]
    @State private var selection: Date?

    private static let prompt = "Prompt"
    private static let generated = "Generated"

    private var bars: [Bar] {
        days.filter(\.observed).flatMap { day in
            [Bar(day: day.day, series: Self.prompt, value: day.prompt),
             Bar(day: day.day, series: Self.generated, value: day.generated)]
        }
    }

    var body: some View {
        let selected = selection.flatMap { selection in
            days.last { $0.day <= selection }.flatMap { day in
                Calendar.current.isDate(day.day, inSameDayAs: selection) ? day : nil
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(days.filter { !$0.observed }) { day in
                    RectangleMark(xStart: .value("Day", day.day), xEnd: .value("Next day", nextDay(day.day)))
                        .foregroundStyle(Color.primary.opacity(0.05))
                }
                ForEach(bars) { bar in
                    BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Tokens", bar.value), width: .ratio(0.8))
                        .foregroundStyle(by: .value("Kind", bar.series))
                        .position(by: .value("Kind", bar.series))
                        .cornerRadius(2)
                        .opacity(selected == nil || selected?.day == bar.day ? 1 : 0.45)
                }
                if let selected {
                    RuleMark(x: .value("Day", selected.day, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.12))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: side(of: selected.day), alignment: .top, spacing: 8,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            TokenDayTooltip(day: selected)
                        }
                }
            }
            .chartForegroundStyleScale(domain: [Self.prompt, Self.generated],
                                       range: [LocalModelStyle.promptTint, LocalModelStyle.tint])
            .chartXScale(domain: (days.first?.day ?? Date())...nextDay(days.last?.day ?? Date()))
            .chartXSelection(value: $selection)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: SpendChart.labelDays(days.map(\.day), every: days.count > 10 ? 7 : 1)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let tokens = value.as(Double.self) { Text(Format.tokens(tokens)) }
                    }
                }
            }
            .accessibilityLabel("Prompt and generated tokens per day")
            HStack(spacing: 14) {
                legend(Self.prompt, LocalModelStyle.promptTint)
                legend(Self.generated, LocalModelStyle.tint)
                Spacer(minLength: 8)
                if days.contains(where: { !$0.observed }) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08)).frame(width: 12, height: 9)
                        Text("Not observed")
                    }
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }

    private func nextDay(_ day: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
    }

    private func side(of day: Date) -> AnnotationPosition {
        let index = days.firstIndex { $0.day == day } ?? 0
        return index < days.count / 2 ? .trailing : .leading
    }
}

private struct TokenDayTooltip: View {
    let day: ModelTokenDay

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Format.day(day.day))
                .font(.system(size: 11.5, weight: .semibold))
            if day.observed {
                row("Prompt", day.prompt, LocalModelStyle.promptTint)
                row("Generated", day.generated, LocalModelStyle.tint)
            } else {
                Text("Not observed: the server was off\nor Hoply wasn't running.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(minWidth: 160)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: colorScheme == .dark ? .controlBackgroundColor : .white))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private func row(_ label: String, _ tokens: Double, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
            Spacer(minLength: 12)
            Text(Format.tokens(tokens))
                .monospacedDigit()
                .fontWeight(.medium)
        }
        .font(.system(size: 11.5))
    }
}

private struct SavedVsAPICard: View {
    @Environment(AppModel.self) private var model
    let data: LocalModelData?

    var body: some View {
        let reference = Format.model(model.settings.referenceModel)
        let total = data?.savedTotal ?? .zero
        // Local rows have no API-equivalent while the reference model has no price; that must not read as $0.
        let unpriced = total.calls > 0 && total.apiEquivUSD <= 0
        let usage = "\(Format.tokens(total.tokens.total)) tokens · \(Format.count(total.calls)) calls"
        DashboardCard(title: "Saved vs API", subtitle: "Last \(data?.range.dailyDays ?? 7) days · priced at \(reference)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(unpriced ? "unpriced" : Format.spend(total))
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    Text(total.calls == 0 ? "no local model usage in these days"
                         : unpriced ? "no price for \(reference) · \(usage)" : "saved · \(usage)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                SpendChart(series: data?.saved ?? DailySpendSeries(days: [], points: []), split: .source)
                    .frame(height: 214)
            }
        }
        .help(unpriced
              ? "Hoply has no price for \(reference), so it can't say what these calls would cost at the API. Set a priced reference model in Settings → History (\"Priced as\")."
              : "Your agents' calls to local models cost $0. This is what the same tokens would cost at \(reference)'s API prices; change the reference model in Settings → History.")
    }
}
