import AgentKit
import Charts
import SwiftUI

struct LocalModelPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        let data = history.localModel
        let configured = !model.settings.vllmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSamples = !(data?.generation.isEmpty ?? true) || !(data?.kvCache.isEmpty ?? true)
        let observedDays = data?.tokenDays.contains(where: \.observed) ?? false
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Local model", subtitle: "Your model server's speed and cache, and what its tokens saved vs the API") {
                    Picker("Range", selection: Binding(get: { history.localModelRange },
                                                       set: { history.setLocalModelRange($0) })) {
                        ForEach(LocalModelRange.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                HistoryBanner()
                if configured {
                    LiveModelCard(lastSeen: model.vllmLastSeen ?? data?.lastSeen)
                } else {
                    ModelServerSetupCard()
                }
                if history.unavailableReason != nil {
                    DashboardCard(title: "History") {
                        EmptyNote(text: "Speed, cache and token history live in the usage ledger, which is off.")
                    }
                } else {
                    if configured || hasSamples {
                        GenerationCard(data: data)
                        KVCacheCard(data: data)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        if configured || observedDays {
                            TokensPerDayCard(data: data)
                        }
                        SavedVsAPICard(data: data)
                    }
                }
            }
            .padding(24)
        }
    }
}

enum LocalModelStyle {
    static let tint = SourceBadge.color(for: .qwenCode)
    /// Lighter rather than translucent, so prompt bars stay visible on a dark card.
    static let promptTint = tint.mix(with: .white, by: 0.5)

    /// "zgx.local:8000" from the configured base URL.
    static func host(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host() else { return trimmed }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

// MARK: - Live

private struct LiveModelCard: View {
    @Environment(AppModel.self) private var model
    let lastSeen: Date?

    var body: some View {
        let online = model.vllmOnline ? model.vllm : nil
        Card(prominent: true, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    IconTile(symbol: "cpu", tint: LocalModelStyle.tint, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.settings.vllmName.isEmpty ? "Local model" : model.settings.vllmName)
                            .font(.system(size: 15, weight: .semibold))
                        Text(identity)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    StatusChip(text: status.text, color: status.color)
                }
                Divider()
                if let online {
                    figures(online)
                } else {
                    offline
                }
            }
        }
    }

    private var identity: String {
        var parts: [String] = []
        if let snapshot = model.vllm?.snapshot {
            if let name = snapshot.model { parts.append(Format.servedModel(name)) }
            parts.append(Format.engine(snapshot.engine))
        }
        parts.append(LocalModelStyle.host(model.settings.vllmBaseURL))
        return parts.joined(separator: " · ")
    }

    private var status: (text: String, color: Color) {
        if model.vllmOnline { return ("Live", .green) }
        if model.vllmError == nil { return ("Connecting…", .secondary) }
        return model.vllmError == "Offline" ? ("Offline", .red) : ("Error", .red)
    }

    private func figures(_ status: VLLMStatus) -> some View {
        let snapshot = status.snapshot
        let peak = model.throughput.values.max() ?? 0
        return HStack(alignment: .top, spacing: 16) {
            LiveFigure(label: "Generating", value: Format.rate(status.generationTokensPerSecond), unit: "tok/s",
                       detail: peak > 0 ? "peak \(Format.rate(peak)) in 10 min" : "idle in the last 10 min") {
                MiniBars(values: model.throughput.values, highlightLast: 1, tint: .blue, maxBars: 20)
            }
            LiveFigure(label: "Prompt", value: status.promptTokensPerSecond.map(Format.compact) ?? "–", unit: "tok/s",
                       detail: "\(Format.tokens(Int(snapshot.promptTokensTotal))) since the server started") {
                EmptyView()
            }
            LiveFigure(label: "KV cache", value: snapshot.kvCacheUsage.map { Format.percent($0) } ?? "–", unit: nil,
                       detail: "of the cache in use") {
                if let usage = snapshot.kvCacheUsage {
                    ShareBar(fraction: usage, tint: usage >= 0.9 ? .red : .orange)
                }
            }
            LiveFigure(label: "Requests", value: "\(snapshot.running)", unit: "running",
                       detail: snapshot.waiting == 0 ? "none waiting" : "\(snapshot.waiting) waiting") {
                EmptyView()
            }
        }
    }

    private var offline: some View {
        let host = LocalModelStyle.host(model.settings.vllmBaseURL)
        let error = model.vllmError
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: error == nil ? "antenna.radiowaves.left.and.right" : "wifi.slash")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(error == nil ? Color.secondary : Color.red)
            VStack(alignment: .leading, spacing: 3) {
                Text(error == nil ? "Waiting for the first answer from \(host)…"
                                  : error == "Offline" ? "No answer from \(host)" : "\(host): \(error ?? "")")
                    .font(.system(size: 13, weight: .medium))
                Text(lastSeenText + " Hoply checks again every 5 seconds while this window is open.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
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
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(prominent: true, padding: 18) {
            HStack(spacing: 14) {
                IconTile(symbol: "cpu", tint: LocalModelStyle.tint, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("No model server set")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Add your vLLM or tensorfold server's URL in Settings to see its speed, KV cache and tokens per day here. Hoply keeps the history in the usage ledger.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Open Settings") { model.openSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Speed and cache

private struct GenerationCard: View {
    let data: LocalModelData?

    var body: some View {
        let range = data?.range ?? .day
        DashboardCard(title: "Generation speed",
                      subtitle: "Last \(range.label) · average and peak per \(range.resolutionLabel)") {
            if let data {
                SampleChart(buckets: data.generation, domain: data.interval, kind: .rate, tint: .blue)
                    .frame(height: 220)
            } else {
                EmptyNote(text: "Loading…").frame(height: 120)
            }
        }
    }
}

private struct KVCacheCard: View {
    let data: LocalModelData?

    var body: some View {
        let range = data?.range ?? .day
        DashboardCard(title: "KV cache", subtitle: "Last \(range.label) · average per \(range.resolutionLabel)") {
            if let data {
                SampleChart(buckets: data.kvCache, domain: data.interval, kind: .percent, tint: .orange)
                    .frame(height: 150)
            } else {
                EmptyNote(text: "Loading…").frame(height: 80)
            }
        }
    }
}

/// A gauge series over time: the average as a line, for rates the band up to each bucket's peak. Gaps without
/// readings (server off, Hoply not running) break the line instead of being drawn as zero.
struct SampleChart: View {
    enum Kind { case rate, percent }

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
                        Text(kind == .percent ? "\(Int(number))%" : Format.compact(number).replacingOccurrences(of: ".0", with: ""))
                    }
                }
            }
        }
        .accessibilityLabel(kind == .rate ? "Generation tokens per second over time" : "KV cache use over time")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Capsule().fill(tint).frame(width: 14, height: 2)
                Text(kind == .rate ? "Average tok/s" : "Average KV cache use")
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

    /// The bucket under the pointer; none in a gap.
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
        kind == .percent ? "\(Int(number.rounded()))%" : "\(Format.rate(number)) tok/s"
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
                        Text(Format.tokens(Int(observed.reduce(0) { $0 + $1.prompt + $1.generated })))
                            .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        Text("tokens · \(Format.tokens(Int(observed.reduce(0) { $0 + $1.generated }))) generated")
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
                        if let tokens = value.as(Double.self) { Text(Format.tokens(Int(tokens))) }
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
            Text(Format.tokens(Int(tokens)))
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
        DashboardCard(title: "Saved vs API", subtitle: "Last \(data?.range.dailyDays ?? 7) days · priced at \(reference)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(Format.cost(total.apiEquivUSD))
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    Text(total.calls > 0 ? "saved · \(Format.tokens(total.tokens.total)) tokens · \(Format.count(total.calls)) calls"
                                         : "no local model usage in these days")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                SpendChart(series: data?.saved ?? DailySpendSeries(days: [], points: []), split: .source)
                    .frame(height: 214)
            }
        }
        .help("Your agents' calls to local models cost $0. This is what the same tokens would cost at \(reference)'s API prices; change the reference model in Settings → History.")
    }
}
