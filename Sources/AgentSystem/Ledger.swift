import AgentKit
import Foundation

public struct LedgerConfiguration: Sendable, Equatable {
    public var databasePath: String
    public var claudeConfigDirectory: String
    /// Copilot CLI's home, holding `session-store.db`.
    public var copilotHome: String
    public var pricingOverridesURL: URL?
    public var localModelPatterns: [String]
    public var referenceModel: String
    /// FSEvents, the 60 s transcript rescan and the 10 s Copilot poll. Without it, `start()` reads everything
    /// once and later reads happen only on request.
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
                copilotPollInterval: Duration = .seconds(10)) {
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
                  localModelPatterns: settings.localModelPatterns, referenceModel: settings.referenceModel)
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
                                             referenceModel: configuration.referenceModel)
        store = try Store(path: configuration.databasePath, pricing: pricing)
        reader = try StoreReader(path: configuration.databasePath)
        ingest = IngestCoordinator(store: store,
                                   claude: ClaudeTranscriptIngester(configDirectory: configuration.claudeConfigDirectory),
                                   copilot: CopilotStoreIngester(home: configuration.copilotHome),
                                   watch: configuration.watchForChanges, rescanInterval: configuration.rescanInterval,
                                   copilotPollInterval: configuration.copilotPollInterval)
    }

    /// Opening runs migrations, a weekly backup and possibly a full re-price, so keep it off the main actor.
    public static func open(_ configuration: LedgerConfiguration = LedgerConfiguration()) async throws -> Ledger {
        try await Task.detached(priority: .utility) { try Ledger(configuration: configuration) }.value
    }

    /// Persists telemetry usage (`HubServer.onUsage`): Copilot IDE and Qwen Code rows; others are dropped.
    /// Re-sent OTLP batches map to the same dedupe keys, so they never count twice.
    public func record(_ usage: [UsageRecord]) async {
        await ingest.record(usage)
    }

    /// Reads Copilot CLI's session store now if it changed (call when a Copilot CLI hook arrives).
    public func pollCopilot() async {
        await ingest.pollCopilot()
    }

    /// The ledger project for each cwd (worktrees and subfolders of a repo resolve to the repo), for grouping
    /// live sessions. Cwds that cannot be resolved are absent; group those by cwd meanwhile.
    public func resolveProjects(_ cwds: [String]) async -> [String: ProjectRef] {
        (try? await store.projects(forCwds: cwds)) ?? [:]
    }

    /// Stores one Claude limits fetch and returns each window's last stored sample from before it. Pass that to
    /// `NotificationPolicy.limitsUpdated(_:previous:now:)` with `limits.samples(at:)`, so limit alerts survive
    /// restarts without being repeated.
    @discardableResult
    public func recordLimits(_ limits: ClaudeLimits, at time: Date) async throws -> [LimitKind: LimitSample] {
        try await store.recordLimitSamples(limits.samples(at: time))
    }

    /// Limits page history: samples from the last `days` days (rolling, not local midnights), oldest first.
    /// `bucket` (seconds) keeps each window's peak per bucket, e.g. 3600 for a 30-day chart.
    public func limitHistory(days: Int, now: Date = Date(), bucket: TimeInterval? = nil) async throws -> [LimitSample] {
        let start = now.addingTimeInterval(-Double(max(days, 1)) * 86_400)
        return try await reader.limitSamples(in: DateInterval(start: start, end: .distantFuture), bucket: bucket)
    }

    /// Each window's current state, burn rate and projection, from the last 7 days of samples.
    public func limitProjections(now: Date = Date()) async throws -> [LimitKind: LimitsProjection] {
        let start = now.addingTimeInterval(-LimitKind.sevenDay.windowLength - 3600)
        return LimitsProjection.projections(try await reader.limitSamples(in: DateInterval(start: start,
                                                                                           end: .distantFuture)))
    }

    public func latestLimitSamples() async throws -> [LimitKind: LimitSample] {
        try await reader.latestLimitSamples()
    }

    /// Copilot CLI premium requests this UTC month against the allowance in `settings`. Copilot IDE requests
    /// draw on the same allowance but never reach the ledger with a multiplier, so they are not counted.
    public func copilotAllowance(settings: AppSettings, now: Date = Date()) async throws -> CopilotAllowance {
        let month = CopilotAllowance.month(containing: now)
        let used = try await reader.totalsBySource(in: month)[.copilotCLI]?.premiumRequests ?? 0
        return CopilotAllowance(used: used, settings: settings, now: now)
    }

    /// Reloads `pricing.json` and applies new local-model settings; re-prices affected rows. Returns how many.
    @discardableResult
    public func updatePricing(localModelPatterns: [String], referenceModel: String) async throws -> Int {
        try await store.setPricing(PricingOverrides.table(overridesURL: configuration.pricingOverridesURL,
                                                          localModelPatterns: localModelPatterns,
                                                          referenceModel: referenceModel))
    }
}
