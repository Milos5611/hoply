import AgentKit
import Foundation

public struct LedgerConfiguration: Sendable, Equatable {
    public var databasePath: String
    public var claudeConfigDirectory: String
    public var pricingOverridesURL: URL?
    public var localModelPatterns: [String]
    public var referenceModel: String
    public var watchForChanges: Bool
    public var rescanInterval: Duration

    public init(databasePath: String = Store.defaultDatabaseURL.path,
                claudeConfigDirectory: String = ClaudeTranscriptIngester.defaultConfigDirectory,
                pricingOverridesURL: URL? = PricingOverrides.defaultURL,
                localModelPatterns: [String] = PricingTable.defaultLocalModelPatterns,
                referenceModel: String = PricingTable.defaultReferenceModel,
                watchForChanges: Bool = true, rescanInterval: Duration = .seconds(60)) {
        self.databasePath = databasePath
        self.claudeConfigDirectory = claudeConfigDirectory
        self.pricingOverridesURL = pricingOverridesURL
        self.localModelPatterns = localModelPatterns
        self.referenceModel = referenceModel
        self.watchForChanges = watchForChanges
        self.rescanInterval = rescanInterval
    }

    public init(settings: AppSettings) {
        let configured = settings.claudeConfigDir.trimmingCharacters(in: .whitespaces)
        self.init(claudeConfigDirectory: configured.isEmpty
                    ? ClaudeTranscriptIngester.defaultConfigDirectory
                    : (configured as NSString).expandingTildeInPath,
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
                                   watch: configuration.watchForChanges, rescanInterval: configuration.rescanInterval)
    }

    /// Opening runs migrations, a weekly backup and possibly a full re-price, so keep it off the main actor.
    public static func open(_ configuration: LedgerConfiguration = LedgerConfiguration()) async throws -> Ledger {
        try await Task.detached(priority: .utility) { try Ledger(configuration: configuration) }.value
    }

    /// Reloads `pricing.json` and applies new local-model settings; re-prices affected rows. Returns how many.
    @discardableResult
    public func updatePricing(localModelPatterns: [String], referenceModel: String) async throws -> Int {
        try await store.setPricing(PricingOverrides.table(overridesURL: configuration.pricingOverridesURL,
                                                          localModelPatterns: localModelPatterns,
                                                          referenceModel: referenceModel))
    }
}
