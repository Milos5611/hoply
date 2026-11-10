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
        if let servers = container.lenient([LenientElement<ModelServer>].self, .modelServers) {
            var seen: Set<String> = []
            modelServers = servers.compactMap(\.value).filter { seen.insert($0.id).inserted }
        } else {
            // Settings saved before several servers existed: the one server keeps a fixed id, so its
            // un-keyed `model.*` sample series stay attached to it.
            let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
            vllmBaseURL = legacy?.lenient(String.self, .vllmBaseURL) ?? ""
            vllmName = legacy?.lenient(String.self, .vllmName) ?? ""
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

    private enum LegacyKeys: String, CodingKey {
        case vllmBaseURL, vllmName
    }

    public var legacyModelServer: ModelServer? { modelServers.first { $0.isLegacy } }
    public var activeModelServers: [ModelServer] { modelServers.filter(\.isActive) }

    public func modelServer(id: String) -> ModelServer? { modelServers.first { $0.id == id } }

    public var vllmBaseURL: String {
        get { legacyModelServer?.baseURL ?? "" }
        set { updateLegacyServer { $0.baseURL = newValue } }
    }

    public var vllmName: String {
        get { legacyModelServer?.name ?? "" }
        set { updateLegacyServer { $0.name = newValue } }
    }

    private mutating func updateLegacyServer(_ change: (inout ModelServer) -> Void) {
        var server = legacyModelServer ?? ModelServer(id: ModelServer.legacyID)
        change(&server)
        let index = modelServers.firstIndex { $0.isLegacy }
        if server.baseURL.isEmpty, server.name.isEmpty {
            if let index { modelServers.remove(at: index) }
        } else if let index {
            modelServers[index] = server
        } else {
            modelServers.insert(server, at: 0)
        }
    }

    public func applying(_ edited: AppSettings, since base: AppSettings) -> AppSettings {
        guard let current = jsonObject, let changed = edited.jsonObject, let origin = base.jsonObject else {
            return edited
        }
        var merged = current
        for (key, value) in changed where !Self.same(value, origin[key]) {
            merged[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return edited }
        var result = AppSettings.decode(data)
        // Lists both sides can edit: the draft's removals, additions and changes are applied to the current list.
        let removed = Set(base.mutedProjectRoots).subtracting(edited.mutedProjectRoots)
        let added = edited.mutedProjectRoots.filter { !base.mutedProjectRoots.contains($0) }
        result.mutedProjectRoots = mutedProjectRoots.filter { !removed.contains($0) }
            + added.filter { !mutedProjectRoots.contains($0) }
        result.modelServers = ModelServer.merge(current: modelServers, edited: edited.modelServers,
                                                base: base.modelServers)
        return result
    }

    private var jsonObject: [String: Any]? {
        encoded().flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }

    private static func same(_ value: Any, _ other: Any?) -> Bool {
        guard let other else { return false }
        return (value as? NSObject)?.isEqual(other) ?? false
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

struct LenientElement<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
