import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var port = 4318
    public var vllmBaseURL = ""
    public var vllmName = ""
    public var claudeLimitsEnabled = false
    public var notificationsEnabled = true
    /// Models whose name contains one of these (case-insensitive) run locally: $0 cost, API-equivalent at `referenceModel`.
    public var localModelPatterns = PricingTable.defaultLocalModelPatterns
    public var referenceModel = PricingTable.defaultReferenceModel
    /// Claude Code's config directory; empty means `~/.claude`.
    public var claudeConfigDir = ""
    /// Copilot CLI's home (holds `session-store.db`); empty means `$COPILOT_HOME`, else `~/.copilot`.
    public var copilotHome = ""
    /// Quiet hours silence every notification. Start and end are minutes after local midnight; the range may
    /// wrap midnight (the default is 22:00–08:00).
    public var quietHoursEnabled = false
    public var quietHoursStart = 22 * 60
    public var quietHoursEnd = 8 * 60
    /// Session notifications from these project roots (or cwds, while unresolved) stay silent.
    public var mutedProjectRoots: [String] = []
    public var limitAlertsEnabled = true
    public var localModelAlertsEnabled = true
    /// Copilot premium requests included per month (300 = Copilot Pro); 0 = not set.
    public var copilotMonthlyAllowance = 300
    public var copilotUSDPerPremiumRequest = 0.04
    /// sparkDash on the GPU box (GPU, energy, memory); empty = off. Its token lives in the Keychain only.
    public var sparkDashURL = ""
    /// The spark id in sparkDash's paths, e.g. `zgx-ff24`.
    public var sparkDashName = ""
    /// Price of a kWh for the GPU's energy cost; 0 = off.
    public var energyPricePerKWh = 0.0

    public init() {}

    /// Every key is optional and a wrongly typed value falls back to its default, so settings saved by an
    /// older or newer build keep the rest of their values instead of resetting wholesale.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        port = container.lenient(Int.self, .port) ?? defaults.port
        vllmBaseURL = container.lenient(String.self, .vllmBaseURL) ?? defaults.vllmBaseURL
        vllmName = container.lenient(String.self, .vllmName) ?? defaults.vllmName
        claudeLimitsEnabled = container.lenient(Bool.self, .claudeLimitsEnabled) ?? defaults.claudeLimitsEnabled
        notificationsEnabled = container.lenient(Bool.self, .notificationsEnabled) ?? defaults.notificationsEnabled
        localModelPatterns = container.lenient([String].self, .localModelPatterns) ?? defaults.localModelPatterns
        referenceModel = container.lenient(String.self, .referenceModel) ?? defaults.referenceModel
        claudeConfigDir = container.lenient(String.self, .claudeConfigDir) ?? defaults.claudeConfigDir
        copilotHome = container.lenient(String.self, .copilotHome) ?? defaults.copilotHome
        quietHoursEnabled = container.lenient(Bool.self, .quietHoursEnabled) ?? defaults.quietHoursEnabled
        quietHoursStart = container.lenient(Int.self, .quietHoursStart) ?? defaults.quietHoursStart
        quietHoursEnd = container.lenient(Int.self, .quietHoursEnd) ?? defaults.quietHoursEnd
        mutedProjectRoots = container.lenient([String].self, .mutedProjectRoots) ?? defaults.mutedProjectRoots
        limitAlertsEnabled = container.lenient(Bool.self, .limitAlertsEnabled) ?? defaults.limitAlertsEnabled
        localModelAlertsEnabled = container.lenient(Bool.self, .localModelAlertsEnabled) ?? defaults.localModelAlertsEnabled
        copilotMonthlyAllowance = container.lenient(Int.self, .copilotMonthlyAllowance) ?? defaults.copilotMonthlyAllowance
        copilotUSDPerPremiumRequest = container.lenient(Double.self, .copilotUSDPerPremiumRequest)
            ?? defaults.copilotUSDPerPremiumRequest
        sparkDashURL = container.lenient(String.self, .sparkDashURL) ?? defaults.sparkDashURL
        sparkDashName = container.lenient(String.self, .sparkDashName) ?? defaults.sparkDashName
        energyPricePerKWh = container.lenient(Double.self, .energyPricePerKWh) ?? defaults.energyPricePerKWh
    }

    public static func decode(_ data: Data?) -> AppSettings {
        guard let data, let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
