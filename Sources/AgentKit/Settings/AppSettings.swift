import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var port = 4318
    public var vllmBaseURL = ""
    public var vllmName = ""
    public var claudeLimitsEnabled = false
    public var notificationsEnabled = true
    public var localModelPatterns = PricingTable.defaultLocalModelPatterns
    public var referenceModel = PricingTable.defaultReferenceModel
    public var claudeConfigDir = ""
    public var copilotHome = ""
    public var quietHoursEnabled = false
    public var quietHoursStart = 22 * 60
    public var quietHoursEnd = 8 * 60
    public var mutedProjectRoots: [String] = []
    public var limitAlertsEnabled = true
    public var localModelAlertsEnabled = true
    public var copilotMonthlyAllowance = 300
    public var copilotUSDPerPremiumRequest = 0.04
    public var sparkDashURL = ""
    public var sparkDashName = ""
    public var energyPricePerKWh = 0.0
    public var priceAliases: [String: String] = [:]
    public var cleanupIncludesNodeModules = false
    public var paletteEnabled = true
    public var paletteHotKey = HotKeyCombo.optionSpace

    public init() {}

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
        priceAliases = container.lenient([String: String].self, .priceAliases) ?? defaults.priceAliases
        cleanupIncludesNodeModules = container.lenient(Bool.self, .cleanupIncludesNodeModules)
            ?? defaults.cleanupIncludesNodeModules
        paletteEnabled = container.lenient(Bool.self, .paletteEnabled) ?? defaults.paletteEnabled
        paletteHotKey = container.lenient(HotKeyCombo.self, .paletteHotKey).flatMap { $0.isValid ? $0 : nil }
            ?? defaults.paletteHotKey
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
