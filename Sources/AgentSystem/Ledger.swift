import AgentKit
import Foundation

public struct LedgerConfiguration: Sendable, Equatable {
    public var databasePath: String
    public var claudeConfigDirectory: String
    public var copilotHome: String
    public var codexHome: String?
    public var pricingOverridesURL: URL?
    public var localModelPatterns: [String]
    public var referenceModel: String
    public var priceAliases: [String: String]
    public var customPrices: [String: CustomModelPrice]
    public var watchForChanges: Bool
    public var rescanInterval: Duration
    public var copilotPollInterval: Duration
    public var folders: Set<AgentFolder>

    public init(databasePath: String = Store.defaultDatabaseURL.path,
                claudeConfigDirectory: String = ClaudeTranscriptIngester.defaultConfigDirectory,
                copilotHome: String = CopilotStoreIngester.defaultHome,
                pricingOverridesURL: URL? = PricingOverrides.defaultURL,
                localModelPatterns: [String] = PricingTable.defaultLocalModelPatterns,
                referenceModel: String = PricingTable.defaultReferenceModel,
                watchForChanges: Bool = true, rescanInterval: Duration = .seconds(60),
                copilotPollInterval: Duration = .seconds(10), priceAliases: [String: String] = [:],
                codexHome: String? = nil, folders: Set<AgentFolder> = Set(AgentFolder.allCases),
                customPrices: [String: CustomModelPrice] = [:]) {
        self.priceAliases = priceAliases
        self.customPrices = customPrices
        self.folders = folders
        self.codexHome = codexHome
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

    public init(settings: AppSettings, environment: [String: String] = ProcessInfo.processInfo.environment,
                home: String = UserHome.path, edition: Edition = .current, grants: FolderGrants = .shared) {
        func path(_ folder: AgentFolder) -> String {
            folder.path(settings: settings, environment: environment, home: home)
        }
        let readable = AgentFolder.allCases.filter {
            !edition.needsFolderGrants || grants.access(for: $0, at: path($0)).allowsReading
        }
        self.init(claudeConfigDirectory: path(.claude), copilotHome: path(.copilot),
                  localModelPatterns: settings.localModelPatterns, referenceModel: settings.referenceModel,
                  priceAliases: settings.priceAliases, codexHome: path(.codex), folders: Set(readable),
                  customPrices: settings.customPrices)
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
                                             aliases: configuration.priceAliases,
                                             customPrices: configuration.customPrices)
        store = try Store(path: configuration.databasePath, pricing: pricing)
        reader = try StoreReader(path: configuration.databasePath)
        let folders = configuration.folders
        let copilot = folders.contains(.copilot)
        ingest = IngestCoordinator(store: store,
                                   claude: folders.contains(.claude)
                                       ? ClaudeTranscriptIngester(configDirectory: configuration.claudeConfigDirectory)
                                       : nil,
                                   copilot: copilot ? CopilotStoreIngester(home: configuration.copilotHome) : nil,
                                   codex: folders.contains(.codex)
                                       ? configuration.codexHome.map { CodexRolloutIngester(home: $0) } : nil,
                                   copilotEvents: copilot ? CopilotEventsIngester(home: configuration.copilotHome) : nil,
                                   watch: configuration.watchForChanges, rescanInterval: configuration.rescanInterval,
                                   copilotPollInterval: configuration.copilotPollInterval)
    }

    public static func open(_ configuration: LedgerConfiguration = LedgerConfiguration()) async throws -> Ledger {
        try await Task.detached(priority: .utility) { try Ledger(configuration: configuration) }.value
    }

    public func record(_ usage: [UsageRecord], prompts: [PromptRecord] = []) async {
        await ingest.record(usage, prompts: prompts)
    }

    public func pollCopilot(sessions: [String] = []) async {
        await ingest.tailCopilotSessions(sessions)
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
        let longest = try await reader.latestLimitSamples().keys.map(\.windowLength).max() ?? 0
        let start = now.addingTimeInterval(-max(longest, LimitKind.sevenDay.windowLength) - 3600)
        return LimitsProjection.projections(try await reader.limitSamples(in: DateInterval(start: start,
                                                                                           end: .distantFuture)),
                                            now: now)
    }

    public func latestLimitSamples() async throws -> [LimitKind: LimitSample] {
        try await reader.latestLimitSamples()
    }

    public func currentLimitSamples(provider: LimitProvider? = nil) async throws -> [LimitKind: LimitSample] {
        let current = LimitSample.current(try await reader.latestLimitSamples())
        guard let provider else { return current }
        return current.filter { $0.key.provider == provider }
    }

    public func copilotAllowance(settings: AppSettings, now: Date = Date()) async throws -> CopilotAllowance {
        let month = CopilotAllowance.month(containing: now)
        let used = try await reader.totalsBySource(in: month)[.copilotCLI]?.premiumRequests ?? 0
        return CopilotAllowance(used: used, settings: settings, now: now)
    }

    // MARK: - Local model and pricing

    public func localModelSpend(days: Int, split: SpendSeriesSplit = .source, now: Date = Date(),
                                calendar: Calendar = .current) async throws -> DailySpendSeries {
        try await reader.dailySpend(days: days, split: split, localOnly: true, now: now, calendar: calendar)
    }

    @discardableResult
    public func updatePricing(localModelPatterns: [String], referenceModel: String,
                              priceAliases: [String: String]? = nil,
                              customPrices: [String: CustomModelPrice]? = nil) async throws -> Int {
        let current = await store.pricing
        return try await store.setPricing(PricingOverrides.table(overridesURL: configuration.pricingOverridesURL,
                                                                 localModelPatterns: localModelPatterns,
                                                                 referenceModel: referenceModel,
                                                                 aliases: priceAliases ?? current.aliases,
                                                                 customPrices: customPrices ?? current.customPrices))
    }

    // MARK: - Session insight

    public func lastMainCalls(for keys: [SessionKey]) async throws -> [SessionKey: SessionLastCall] {
        try await reader.lastMainCalls(for: keys)
    }

    public func contextWindows(for sessions: [AgentSession]) async throws -> [SessionKey: ContextWindow] {
        let known = sessions.filter { $0.key.source == .claudeCode || $0.key.source == .codexCLI }
        let calls = try await reader.lastMainCalls(for: known.map(\.key))
        var result: [SessionKey: ContextWindow] = [:]
        for session in known {
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

    public func modelEfficiency(in range: DateInterval, project: ProjectFilter? = nil,
                                scope: MacScope = .thisMac) async throws -> [ModelEfficiency] {
        try await reader.modelEfficiency(in: range, project: project, pricing: await store.pricing, scope: scope)
    }

    public func unpricedModels() async throws -> [UnpricedModel] {
        try await reader.unpricedModels()
    }

    public func referenceModelHasPrice() async -> Bool {
        await store.pricing.referenceModelHasPrice
    }

    public func priceAliasesInTable() async -> Set<String> {
        await store.pricing.priceAliasesInTable
    }

    public func customPricesInTable() async -> Set<String> {
        await store.pricing.customPricesInTable
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
