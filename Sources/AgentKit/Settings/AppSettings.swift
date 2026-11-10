import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var port = 4318
    public var modelServers: [ModelServer] = []
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
    public var priceAliases: [String: String] = [:]
    public var cleanupIncludesNodeModules = false
    public var paletteEnabled = true
    public var paletteHotKey = HotKeyCombo.optionSpace
    public var approveFromHoply = false

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        port = container.lenient(Int.self, .port) ?? defaults.port
        if let servers = container.lenient([LenientElement<ModelServer>].self, .modelServers) {
            var seen: Set<String> = []
            modelServers = servers.compactMap(\.value).filter { seen.insert($0.id).inserted }
        } else {
            // Settings saved before several servers existed: the one server keeps a fixed id, so its
            // un-keyed `model.*` sample series stay attached to it.
            let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
            let url = legacy?.lenient(String.self, .vllmBaseURL) ?? ""
            let name = legacy?.lenient(String.self, .vllmName) ?? ""
            if !url.isEmpty || !name.isEmpty {
                modelServers = [ModelServer(id: ModelServer.legacyID, name: name, baseURL: url)]
            }
        }
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
        priceAliases = container.lenient([String: String].self, .priceAliases) ?? defaults.priceAliases
        cleanupIncludesNodeModules = container.lenient(Bool.self, .cleanupIncludesNodeModules)
            ?? defaults.cleanupIncludesNodeModules
        paletteEnabled = container.lenient(Bool.self, .paletteEnabled) ?? defaults.paletteEnabled
        paletteHotKey = container.lenient(HotKeyCombo.self, .paletteHotKey).flatMap { $0.isValid ? $0 : nil }
            ?? defaults.paletteHotKey
        approveFromHoply = container.lenient(Bool.self, .approveFromHoply) ?? defaults.approveFromHoply
    }

    private enum LegacyKeys: String, CodingKey {
        case vllmBaseURL, vllmName
    }

    public var legacyModelServer: ModelServer? { modelServers.first { $0.isLegacy } }
    public var activeModelServers: [ModelServer] { modelServers.filter(\.isActive) }

    public func modelServer(id: String) -> ModelServer? { modelServers.first { $0.id == id } }

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

struct LenientElement<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
