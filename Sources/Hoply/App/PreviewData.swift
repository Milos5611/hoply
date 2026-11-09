import AgentKit
import Foundation

/// Sample state for `Hoply --snapshot`, shaped like a busy afternoon.
enum PreviewData {
    static var settings: AppSettings {
        var settings = AppSettings()
        settings.vllmBaseURL = "http://zgx.local:8000"
        settings.vllmName = "ZGX"
        settings.claudeLimitsEnabled = true
        return settings
    }

    static func events(now: Date) -> [AgentEvent] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        func key(_ source: AgentSource, _ id: String) -> SessionKey { SessionKey(source: source, id: id) }
        let auth = key(.claudeCode, "auth")
        let orders = key(.copilotCLI, "orders")
        let tests = key(.qwenCode, "tests")
        let pricing = key(.claudeCode, "pricing")
        let docs = key(.claudeCode, "docs")
        let home = NSHomeDirectory()
        return [
            AgentEvent(key: auth, kind: .promptSubmitted("Refactor the auth middleware to use refresh tokens"),
                       time: at(46), cwd: "\(home)/Project/fiba", model: "claude-opus-5", fromHook: true),
            AgentEvent(key: auth, kind: .usage(.init(inputTokens: 21_000, outputTokens: 9_000, cacheTokens: 24_000, costUSD: 0.21)),
                       time: at(5), fromHook: false),
            AgentEvent(key: auth, kind: .turnFinished("Middleware now refreshes tokens; all 214 tests pass."),
                       time: at(4), fromHook: true),
            AgentEvent(key: orders, kind: .promptSubmitted("Add pagination to the orders endpoint"),
                       time: at(12), cwd: "\(home)/Project/yasm-backend", fromHook: true),
            AgentEvent(key: orders, kind: .needsPermission("Run `dotnet test` in yasm-backend?"),
                       time: at(1), fromHook: true),
            AgentEvent(key: pricing, kind: .promptSubmitted("Build the pricing section"),
                       time: at(42), cwd: "\(home)/Project/fiba", model: "claude-sonnet-5", fromHook: true),
            AgentEvent(key: pricing, kind: .toolStarted("Edit"), time: at(0.2), fromHook: true),
            AgentEvent(key: pricing, kind: .usage(.init(inputTokens: 80_000, outputTokens: 30_000, cacheTokens: 300_000, costUSD: 0.64)),
                       time: at(0.5), fromHook: false),
            AgentEvent(key: tests, kind: .promptSubmitted("Write unit tests for the Prometheus parser"),
                       time: at(6), cwd: "\(home)/Project/hoply", model: "qwen3-coder", fromHook: false),
            AgentEvent(key: tests, kind: .usage(.init(inputTokens: 2_100, outputTokens: 900)), time: at(0.3), fromHook: false),
            AgentEvent(key: docs, kind: .promptSubmitted("Update the README for v2"),
                       time: at(30), cwd: "\(home)/Project/hoply", model: "claude-opus-5", fromHook: true),
            AgentEvent(key: docs, kind: .sessionEnded(nil), time: at(8), fromHook: true),
        ]
    }

    static func activity(now: Date) -> RollingSeries {
        series(now: now, values: [1, 0, 2, 3, 1, 4, 6, 3, 2, 5, 7, 4, 3, 6, 8, 5, 9, 7, 11, 8], max: false)
    }

    static func throughput(now: Date) -> RollingSeries {
        series(now: now, values: [0, 0, 12, 38, 41, 40, 22, 0, 0, 35, 44, 43, 39, 30, 41, 45, 44, 38, 42, 43], max: true)
    }

    static func vllm(now: Date) -> VLLMStatus {
        func snapshot(generated: Double, at time: Date) -> VLLMSnapshot {
            let text = """
            vllm:num_requests_running{model_name="Qwen/Qwen3-Coder-30B-A3B-Instruct"} 2
            vllm:num_requests_waiting{model_name="Qwen/Qwen3-Coder-30B-A3B-Instruct"} 1
            vllm:kv_cache_usage_perc{model_name="Qwen/Qwen3-Coder-30B-A3B-Instruct"} 0.44
            vllm:prompt_tokens_total{model_name="Qwen/Qwen3-Coder-30B-A3B-Instruct"} 120000
            vllm:generation_tokens_total{model_name="Qwen/Qwen3-Coder-30B-A3B-Instruct"} \(generated)
            """
            return VLLMSnapshot.from(samples: PrometheusParser.parse(text), at: time)
        }
        return VLLMStatus.compute(previous: snapshot(generated: 45_000, at: now.addingTimeInterval(-5)),
                                  current: snapshot(generated: 45_215, at: now))
    }

    static func claudeLimits(now: Date) -> ClaudeLimits? {
        let fiveHour = Int(now.addingTimeInterval(2.6 * 3_600).timeIntervalSince1970)
        let week = Int(now.addingTimeInterval(3.7 * 86_400).timeIntervalSince1970)
        let json = #"{"five_hour":{"utilization":62,"resets_at":\#(fiveHour)},"seven_day":{"utilization":25,"resets_at":\#(week)}}"#
        return try? ClaudeLimits.decode(Data(json.utf8))
    }

    private static func series(now: Date, values: [Double], max: Bool) -> RollingSeries {
        var series = RollingSeries(bucketLength: 30, capacity: values.count, now: now)
        for (index, value) in values.enumerated() {
            let time = now.addingTimeInterval(-Double(values.count - 1 - index) * 30)
            if max { series.recordMax(value, at: time) } else { series.add(value, at: time) }
        }
        return series
    }

    // MARK: - Ledger

    static let backfilling = IngestProgress(filesDone: 51, filesTotal: 122, bytesDone: 112_000_000,
                                            bytesTotal: 261_000_000, isBackfilling: true)

    /// Ninety days of ledger rows shaped like a heavy Claude Code subscriber who also runs Qwen locally.
    static func history(now: Date) -> HistoryPreview {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let days = (0..<90).compactMap { calendar.date(byAdding: .day, value: $0 - 89, to: today) }
        let models: [(id: String, source: AgentSource, scale: Double, local: Bool)] = [
            ("claude-opus-5", .claudeCode, 16, false),
            ("claude-sonnet-5", .claudeCode, 7, false),
            ("claude-haiku-4-5", .claudeCode, 0.9, false),
            ("Qwen3.8-Flash-Next", .qwenCode, 2.4, true),
        ]

        var byModel: [DailySpendPoint] = []
        for (index, day) in days.enumerated() {
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7 ? 0.25 : 1
            let ramp = 0.55 + 0.45 * Double(index) / Double(days.count)
            for (offset, model) in models.enumerated() {
                let wave = 0.55 + 0.45 * sin(Double(index) * 0.9 + Double(offset) * 1.7)
                let usd = model.scale * weekend * ramp * wave
                guard usd > 0.05 else { continue }
                byModel.append(DailySpendPoint(day: day, series: model.id,
                                               totals: totals(usd: usd, local: model.local)))
            }
        }
        let sourceOf = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.source) })
        var bySourceTotals: [Date: [AgentSource: LedgerTotals]] = [:]
        for point in byModel {
            bySourceTotals[point.day, default: [:]][sourceOf[point.series] ?? .claudeCode, default: .zero] += point.totals
        }
        let bySource = bySourceTotals.flatMap { day, sources in
            sources.map { DailySpendPoint(day: day, series: $0.key.rawValue, totals: $0.value) }
        }.sorted { ($0.day, $0.series) < ($1.day, $1.series) }

        func sum(_ points: [DailySpendPoint], lastDays count: Int) -> LedgerTotals {
            let start = days[days.count - count]
            return points.filter { $0.day >= start }.reduce(.zero) { $0 + $1.totals }
        }
        func series(_ points: [DailySpendPoint], lastDays count: Int) -> DailySpendSeries {
            let window = Array(days.suffix(count))
            return DailySpendSeries(days: window, points: points.filter { $0.day >= window[0] })
        }

        let month = sum(byModel, lastDays: 30)
        let unpriced = SpendSlice(id: "claude-nova-preview", label: "claude-nova-preview", totals: unpricedTotals,
                                  sessionCount: 1)
        let modelSlices = models.map { model in
            let totals = byModel.filter { $0.series == model.id && $0.day >= days[days.count - 30] }
                .reduce(.zero) { $0 + $1.totals }
            return SpendSlice(id: model.id, label: model.id, totals: totals, sessionCount: Int(totals.apiEquivUSD / 9) + 2)
        }.sorted { $0.totals.apiEquivUSD > $1.totals.apiEquivUSD } + [unpriced]

        let home = NSHomeDirectory()
        let projectShares: [(name: String, share: Double, sessions: Int)] = [
            ("fiba", 0.38, 41), ("yasm-backend", 0.24, 26), ("hoply", 0.19, 33), ("FIBA3x3", 0.11, 12), ("", 0.08, 7),
        ]
        let projectSlices = projectShares.enumerated().map { index, entry in
            let project = entry.name.isEmpty ? nil
                : ProjectRef(id: Int64(index + 1), root: "\(home)/Project/\(entry.name)", name: entry.name, kind: .repo)
            return SpendSlice(id: project.map { String($0.id) } ?? "", label: project?.title ?? "Unassigned",
                              project: project, totals: scaled(month, by: entry.share), sessionCount: entry.sessions)
        }

        let overview = OverviewData(
            totals: SpendOverview(today: sum(byModel, lastDays: 1), last7Days: sum(byModel, lastDays: 7),
                                  last30Days: month, allTime: scaled(sum(byModel, lastDays: 90), by: 1.42)),
            daily: series(bySource, lastDays: 30),
            projects: Array(projectSlices.prefix(5)),
            models: Array(modelSlices.prefix(5)))
        let spending = SpendingData(range: .month, split: .model, daily: series(byModel, lastDays: 30),
                                    projects: projectSlices, models: modelSlices)

        let sessions = sessionSummaries(now: now, projects: projectSlices.compactMap(\.project))
        let todayBySource = bySourceTotals[today] ?? [:]
        return HistoryPreview(
            progress: IngestProgress(filesDone: 122, filesTotal: 122, bytesDone: 261_000_000, bytesTotal: 261_000_000),
            sessionTotals: [
                SessionKey(source: .claudeCode, id: "auth"): totals(usd: 4.12, local: false),
                SessionKey(source: .claudeCode, id: "pricing"): totals(usd: 11.80, local: false),
                SessionKey(source: .claudeCode, id: "docs"): totals(usd: 0.86, local: false),
            ],
            today: todayBySource, overview: overview, spending: spending,
            sessions: SessionPage(sessions: sessions, totalCount: 86), selectedSession: sessions.first)
    }

    private static func sessionSummaries(now: Date, projects: [ProjectRef]) -> [SessionSummary] {
        let home = NSHomeDirectory()
        let rows: [(title: String, project: Int?, branch: String?, minutesAgo: Double, hours: Double, turns: Int,
                    usd: Double, mix: [(String, Double)])] = [
            ("Build the pricing section", 0, "feature/pricing", 0.5, 0.7, 14, 11.80,
             [("claude-sonnet-5", 0.82), ("claude-haiku-4-5", 0.18)]),
            ("Refactor the auth middleware to use refresh tokens", 0, "auth-refresh", 4, 0.8, 9, 4.12,
             [("claude-opus-5", 1)]),
            ("Update the README for v2", 2, "main", 8, 0.4, 3, 0.86, [("claude-opus-5", 1)]),
            ("Store and Claude history", 2, "v2-ledger", 95, 3.1, 41, 38.40,
             [("claude-opus-5", 0.91), ("claude-haiku-4-5", 0.09)]),
            ("Pagination for the orders endpoint", 1, "orders-paging", 180, 1.2, 12, 6.25,
             [("claude-sonnet-5", 1)]),
            ("Write unit tests for the Prometheus parser", 2, "main", 260, 0.6, 7, 1.94,
             [("Qwen3.8-Flash-Next", 0.7), ("claude-sonnet-5", 0.3)]),
            ("Investigate the flaky referee assignment test", 3, "fix/flaky-ref", 1_400, 2.2, 18, 9.71,
             [("claude-opus-5", 0.64), ("claude-sonnet-5", 0.36)]),
            ("Explain the bracket seeding rules", 3, nil, 1_700, 0.3, 2, 0.42, [("claude-haiku-4-5", 1)]),
            ("Migrate the API client to async/await", 1, "async-client", 2_900, 4.5, 33, 27.15,
             [("claude-opus-5", 0.77), ("claude-sonnet-5", 0.23)]),
            ("Quick shell question", nil, nil, 3_100, 0.1, 1, 0.08, [("claude-haiku-4-5", 1)]),
            ("Try the nova preview model", 2, "main", 3_300, 0.2, 2, 0, [("claude-nova-preview", 1)]),
            ("Landing page hero animation", 0, "landing-hero", 4_300, 1.7, 15, 7.02, [("claude-sonnet-5", 1)]),
            ("Profile the ingest coordinator", 2, "v2-ledger", 5_800, 0.9, 6, 3.30,
             [("Qwen3.8-Flash-Next", 1)]),
        ]
        return rows.enumerated().map { index, row in
            let project = row.project.flatMap { projects.indices.contains($0) ? projects[$0] : nil }
            let last = now.addingTimeInterval(-row.minutesAgo * 60)
            let models = row.mix.map { model, share in
                ModelShare(model: model, totals: row.usd == 0 ? unpricedTotals
                                                               : totals(usd: row.usd * share, local: model.hasPrefix("Qwen")))
            }
            let total = models.reduce(LedgerTotals.zero) { $0 + $1.totals }
            let id = String(format: "%08x-preview-%02d", 0x5e55_1000 + index * 7_919, index)
            let cwd = project?.root ?? home
            return SessionSummary(
                key: SessionKey(source: .claudeCode, id: id), project: project, title: row.title, cwd: cwd,
                branch: row.branch, firstAt: last.addingTimeInterval(-row.hours * 3_600), lastAt: last,
                turns: row.turns, totals: total, models: models,
                nativeCostUSD: index == 0 ? row.usd * 0.987 : nil,
                linesAdded: row.turns * 23, linesRemoved: row.turns * 7,
                prURL: index == 0 ? "https://github.com/fiba/fiba-web/pull/482" : nil,
                transcriptPath: "\(home)/.claude/projects/-preview/\(id).jsonl")
        }
    }

    private static let unpricedTotals = LedgerTotals(tokens: TokenCounts(input: 4_100, output: 2_300, cacheRead: 61_000),
                                                     calls: 9, hasUnpriced: true)

    private static func totals(usd: Double, local: Bool) -> LedgerTotals {
        let tokens = Int(usd * 420_000)
        return LedgerTotals(costUSD: local ? 0 : usd, apiEquivUSD: usd,
                            tokens: TokenCounts(input: tokens / 60, output: tokens / 45, reasoning: tokens / 200,
                                                cacheRead: tokens * 84 / 100, cacheWrite5m: tokens * 9 / 100),
                            calls: max(1, Int(usd * 11)))
    }

    private static func scaled(_ totals: LedgerTotals, by factor: Double) -> LedgerTotals {
        let t = totals.tokens
        func s(_ value: Int) -> Int { Int(Double(value) * factor) }
        return LedgerTotals(costUSD: totals.costUSD * factor, apiEquivUSD: totals.apiEquivUSD * factor,
                            tokens: TokenCounts(input: s(t.input), output: s(t.output), reasoning: s(t.reasoning),
                                                cacheRead: s(t.cacheRead), cacheWrite5m: s(t.cacheWrite5m),
                                                cacheWrite1h: s(t.cacheWrite1h)),
                            calls: s(totals.calls), hasUnpriced: totals.hasUnpriced)
    }
}

private extension LedgerTotals {
    static func += (lhs: inout LedgerTotals, rhs: LedgerTotals) { lhs = lhs + rhs }
}
