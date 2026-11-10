import AgentKit
import Foundation

public struct LedgerConfiguration: Sendable, Equatable {
    public var databasePath: String
    public var claudeConfigDirectory: String
    public var copilotHome: String
    public var pricingOverridesURL: URL?
    public var localModelPatterns: [String]
    public var referenceModel: String
    public var priceAliases: [String: String]
    public var watchForChanges: Bool
    public var rescanInterval: Duration
    public var copilotPollInterval: Duration

    public init(databasePath: String = Store.defaultDatabaseURL.path,
                claudeConfigDirectory: String = ClaudeTranscriptIngester.defaultConfigDirectory,
                copilotHome: String = CopilotStoreIngester.defaultHome,
                pricingOverridesURL: URL? = PricingOverrides.defaultURL,
                localModelPatterns: [String] = PricingTable.defaultLocalModelPatterns,
                referenceModel: String = PricingTable.defaultReferenceModel,
                watchForChanges: Bool = true, rescanInterval: Duration = .seconds(60),
                copilotPollInterval: Duration = .seconds(10), priceAliases: [String: String] = [:]) {
        self.priceAliases = priceAliases
        self.databasePath = databasePath
        self.claudeConfigDirectory = claudeConfigDirectory
        self.copilotHome = copilotHome
        self.pricingOverridesURL = pricingOverridesURL
        self.localModelPatterns = localModelPatterns
        self.referenceModel = referenceModel
        self.watchForChanges = watchForChanges
        self.rescanInterval = rescanInterval
        self.copilotPollInterval = copilotPollInterval
    }

    public init(settings: AppSettings) {
        func directory(_ setting: String, default fallback: String) -> String {
            let configured = setting.trimmingCharacters(in: .whitespaces)
            return configured.isEmpty ? fallback : (configured as NSString).expandingTildeInPath
        }
        self.init(claudeConfigDirectory: directory(settings.claudeConfigDir,
                                                   default: ClaudeTranscriptIngester.defaultConfigDirectory),
                  copilotHome: directory(settings.copilotHome, default: CopilotStoreIngester.defaultHome),
                  localModelPatterns: settings.localModelPatterns, referenceModel: settings.referenceModel,
                  priceAliases: settings.priceAliases)
    }
}

public struct Ledger: Sendable {
    public let configuration: LedgerConfiguration
    public let store: Store
    public let reader: StoreReader
    public let ingest: IngestCoordinator

    public init(configuration: LedgerConfiguration = LedgerConfiguration()) throws {
        self.configuration = configuration
        let pricing = PricingOverrides.table(overridesURL: configuration.pricingOverridesURL,
                                             localModelPatterns: configuration.localModelPatterns,
                                             referenceModel: configuration.referenceModel,
                                             aliases: configuration.priceAliases)
        store = try Store(path: configuration.databasePath, pricing: pricing)
        reader = try StoreReader(path: configuration.databasePath)
        ingest = IngestCoordinator(store: store,
                                   claude: ClaudeTranscriptIngester(configDirectory: configuration.claudeConfigDirectory),
                                   copilot: CopilotStoreIngester(home: configuration.copilotHome),
                                   watch: configuration.watchForChanges, rescanInterval: configuration.rescanInterval,
                                   copilotPollInterval: configuration.copilotPollInterval)
    }

    public static func open(_ configuration: LedgerConfiguration = LedgerConfiguration()) async throws -> Ledger {
        try await Task.detached(priority: .utility) { try Ledger(configuration: configuration) }.value
    }

    public func record(_ usage: [UsageRecord]) async {
        await ingest.record(usage)
    }

    public func pollCopilot() async {
        await ingest.pollCopilot()
    }

    public func resolveProjects(_ cwds: [String]) async -> [String: ProjectRef] {
        (try? await store.projects(forCwds: cwds)) ?? [:]
    }

    @discardableResult
    public func recordLimits(_ limits: ClaudeLimits, at time: Date) async throws -> [LimitKind: LimitSample] {
        try await store.recordLimitSamples(limits.samples(at: time))
    }

    public func limitHistory(days: Int, now: Date = Date(), bucket: TimeInterval? = nil) async throws -> [LimitSample] {
        let start = now.addingTimeInterval(-Double(max(days, 1)) * 86_400)
        return try await reader.limitSamples(in: DateInterval(start: start, end: .distantFuture), bucket: bucket)
    }

    public func limitProjections(now: Date = Date()) async throws -> [LimitKind: LimitsProjection] {
        let start = now.addingTimeInterval(-LimitKind.sevenDay.windowLength - 3600)
        return LimitsProjection.projections(try await reader.limitSamples(in: DateInterval(start: start,
                                                                                           end: .distantFuture)))
    }

    public func latestLimitSamples() async throws -> [LimitKind: LimitSample] {
        try await reader.latestLimitSamples()
    }

    public func copilotAllowance(settings: AppSettings, now: Date = Date()) async throws -> CopilotAllowance {
        let month = CopilotAllowance.month(containing: now)
        let used = try await reader.totalsBySource(in: month)[.copilotCLI]?.premiumRequests ?? 0
        return CopilotAllowance(used: used, settings: settings, now: now)
    }

    // MARK: - Samples (local model, later GPU)

    @discardableResult
    public func recordModelSamples(_ status: VLLMStatus) async throws -> [SampleBucket] {
        try await store.recordSamples(ModelServerSeries.observations(status))
    }

    public func resetModelCounters() async {
        await store.resetCounterBaselines(ModelServerSeries.counters)
    }

    @discardableResult
    public func recordSamples(_ observations: [SampleObservation]) async throws -> [SampleBucket] {
        try await store.recordSamples(observations)
    }

    public func samples(_ series: String, resolution: Int = SampleAggregator.resolution,
                        in range: DateInterval) async throws -> [SampleBucket] {
        try await reader.samples(series, resolution: resolution, in: range)
    }

    public func recentModelSamples(since: Date, now: Date = Date()) async throws -> [String: [SampleBucket]] {
        try await reader.recentSamples(ModelServerSeries.all, since: since, now: now)
    }

    public func modelTokensPerDay(days: Int, now: Date = Date(),
                                  calendar: Calendar = .current) async throws -> [ModelTokenDay] {
        let generated = try await reader.dailySums(ModelServerSeries.generatedTokens, days: days, now: now,
                                                   calendar: calendar)
        let prompt = try await reader.dailySums(ModelServerSeries.promptTokens, days: days, now: now, calendar: calendar)
        return ModelTokenDay.days(generated: generated, prompt: prompt)
    }

    public func localModelSpend(days: Int, split: SpendSeriesSplit = .source, now: Date = Date(),
                                calendar: Calendar = .current) async throws -> DailySpendSeries {
        try await reader.dailySpend(days: days, split: split, localOnly: true, now: now, calendar: calendar)
    }

    @discardableResult
    public func updatePricing(localModelPatterns: [String], referenceModel: String,
                              priceAliases: [String: String]? = nil) async throws -> Int {
        let aliases: [String: String]
        if let priceAliases { aliases = priceAliases } else { aliases = await store.pricing.aliases }
        return try await store.setPricing(PricingOverrides.table(overridesURL: configuration.pricingOverridesURL,
                                                                 localModelPatterns: localModelPatterns,
                                                                 referenceModel: referenceModel, aliases: aliases))
    }

    // MARK: - Session insight

    public func lastMainCalls(for keys: [SessionKey]) async throws -> [SessionKey: SessionLastCall] {
        try await reader.lastMainCalls(for: keys)
    }

    public func contextWindows(for sessions: [AgentSession]) async throws -> [SessionKey: ContextWindow] {
        let claude = sessions.filter { $0.key.source == .claudeCode }
        let calls = try await reader.lastMainCalls(for: claude.map(\.key))
        var result: [SessionKey: ContextWindow] = [:]
        for session in claude {
            if let call = calls[session.key] { result[session.key] = ContextWindow(lastCall: call, liveModel: session.model) }
        }
        return result
    }

    public func subagents(of key: SessionKey) async throws -> [SubagentSummary] {
        try await reader.subagents(of: key)
    }

    public func subagentCounts(for keys: [SessionKey]) async throws -> [SessionKey: Int] {
        try await reader.subagentCounts(for: keys)
    }

    public func modelEfficiency(in range: DateInterval, project: ProjectFilter? = nil) async throws -> [ModelEfficiency] {
        try await reader.modelEfficiency(in: range, project: project, pricing: await store.pricing)
    }

    public func unpricedModels() async throws -> [UnpricedModel] {
        try await reader.unpricedModels()
    }

    public func pricedModels() async -> [String] {
        await store.pricing.pricedModelIDs
    }

    public func recentSessions(limit: Int, sources: Set<AgentSource>? = nil) async throws -> [RecentSession] {
        try await reader.recentSessions(limit: limit, sources: sources)
    }

    public func recentProjects(limit: Int) async throws -> [RecentProject] {
        try await reader.recentProjects(limit: limit)
    }
}
