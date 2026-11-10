import Foundation

public enum ModelEngine: String, Codable, Sendable, CaseIterable {
    case vllm
    case tensorfold
    case llamaCpp = "llamacpp"
    case sglang
    case tgi
    case ollama
    case lmStudio = "lmstudio"
    case openAICompatible = "openai"

    public var displayName: String {
        switch self {
        case .vllm: return "vLLM"
        case .tensorfold: return "tensorfold"
        case .llamaCpp: return "llama.cpp"
        case .sglang: return "SGLang"
        case .tgi: return "Text Generation Inference"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    public var reportsPrometheus: Bool {
        switch self {
        case .vllm, .tensorfold, .llamaCpp, .sglang, .tgi: return true
        case .ollama, .lmStudio, .openAICompatible: return false
        }
    }
}

public enum ModelServerAuthKind: String, Codable, Sendable, CaseIterable {
    case none
    case bearer
    case basic
    case cloudflareAccess
    case headers
}

public struct ModelServerAuth: Codable, Equatable, Sendable {
    public var kind: ModelServerAuthKind
    public var username: String
    public var clientID: String
    public var headerNames: [String]

    public init(kind: ModelServerAuthKind = .none, username: String = "", clientID: String = "",
                headerNames: [String] = []) {
        self.kind = kind
        self.username = username
        self.clientID = clientID
        self.headerNames = Self.cleaned(headerNames)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.lenient(String.self, .kind).flatMap(ModelServerAuthKind.init(rawValue:)) ?? .none
        username = container.lenient(String.self, .username) ?? ""
        clientID = container.lenient(String.self, .clientID) ?? ""
        headerNames = Self.cleaned(container.lenient([String].self, .headerNames) ?? [])
    }

    public static let none = ModelServerAuth()

    static func cleaned(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public var needsSecrets: Bool { kind != .none || !headerNames.isEmpty }
}

public struct ModelServerSecrets: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var token: String?
    public var password: String?
    public var clientSecret: String?
    public var headerValues: [String: String]

    public init(token: String? = nil, password: String? = nil, clientSecret: String? = nil,
                headerValues: [String: String] = [:]) {
        self.token = token
        self.password = password
        self.clientSecret = clientSecret
        self.headerValues = headerValues
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = container.lenient(String.self, .token)
        password = container.lenient(String.self, .password)
        clientSecret = container.lenient(String.self, .clientSecret)
        headerValues = container.lenient([String: String].self, .headerValues) ?? [:]
    }

    public var isEmpty: Bool {
        Self.blank(token) && (password ?? "").isEmpty && Self.blank(clientSecret)
            && headerValues.values.allSatisfy { Self.blank($0) }
    }

    public func headerValue(_ name: String) -> String? {
        headerValues.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    public func pruned(for auth: ModelServerAuth) -> ModelServerSecrets {
        let names = Set(auth.headerNames.map { $0.lowercased() })
        var result = ModelServerSecrets()
        if auth.kind == .bearer || auth.kind == .cloudflareAccess { result.token = Self.blank(token) ? nil : token }
        if auth.kind == .basic { result.password = password }
        if auth.kind == .cloudflareAccess { result.clientSecret = Self.blank(clientSecret) ? nil : clientSecret }
        result.headerValues = headerValues.filter { names.contains($0.key.lowercased()) && !Self.blank($0.value) }
        return result
    }

    public var description: String {
        let held = [token.map { _ in "token" }, password.map { _ in "password" }, clientSecret.map { _ in "clientSecret" }]
            .compactMap { $0 }
        return "ModelServerSecrets(\(held.joined(separator: ", ")), headers: \(headerValues.keys.sorted()))"
    }

    public var debugDescription: String { description }

    static func blank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}

extension ModelServerAuth {
    public func credentials(_ secrets: ModelServerSecrets, endpoint name: String) throws -> RemoteCredentials {
        func secret(_ value: String?, _ what: String) throws -> String {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw RemoteError(.missingSecret(what: what), endpoint: name)
            }
            return value
        }
        var credentials = RemoteCredentials()
        switch kind {
        case .none, .headers:
            break
        case .bearer:
            guard !ModelServerSecrets.blank(secrets.token) else { throw RemoteError(.missingToken, endpoint: name) }
            credentials.bearerToken = secrets.token
        case .basic:
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty, !user.contains(":") else { throw RemoteError(.missingSecret(what: "user name"), endpoint: name) }
            guard let password = secrets.password else { throw RemoteError(.missingSecret(what: "password"), endpoint: name) }
            credentials.headers["Authorization"] = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        case .cloudflareAccess:
            let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw RemoteError(.missingSecret(what: "Access client ID"), endpoint: name) }
            credentials.headers["CF-Access-Client-Id"] = id
            credentials.headers["CF-Access-Client-Secret"] = try secret(secrets.clientSecret, "Access client secret")
            if !ModelServerSecrets.blank(secrets.token) { credentials.bearerToken = secrets.token }
        }
        if kind == .headers, headerNames.isEmpty { throw RemoteError(.missingSecret(what: "header"), endpoint: name) }
        for header in headerNames {
            guard RemoteEndpoint.isHeaderName(header) else { throw RemoteError(.invalidHeader(name: header), endpoint: name) }
            credentials.headers[header] = try secret(secrets.headerValue(header), "value for the \(header) header")
        }
        return credentials
    }
}

public struct ModelServer: Codable, Equatable, Sendable, Identifiable {
    public static let legacyID = "default"

    public var id: String
    public var name: String
    public var baseURL: String
    public var enabled: Bool
    public var engine: ModelEngine?
    public var metricsPath: String
    public var auth: ModelServerAuth
    public var offlineAlerts: Bool

    public init(id: String = ModelServer.newID(), name: String = "", baseURL: String = "", enabled: Bool = true,
                engine: ModelEngine? = nil, metricsPath: String = "", auth: ModelServerAuth = .none,
                offlineAlerts: Bool = true) {
        self.id = Self.cleanID(id) ?? Self.newID()
        self.name = name
        self.baseURL = baseURL
        self.enabled = enabled
        self.engine = engine
        self.metricsPath = metricsPath
        self.auth = auth
        self.offlineAlerts = offlineAlerts
    }

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, enabled, engine, metricsPath, auth, offlineAlerts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.lenient(String.self, .id).flatMap(Self.cleanID) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "a server needs an id")
        }
        self.id = id
        name = container.lenient(String.self, .name) ?? ""
        baseURL = container.lenient(String.self, .baseURL) ?? ""
        enabled = container.lenient(Bool.self, .enabled) ?? true
        engine = container.lenient(String.self, .engine).flatMap(ModelEngine.init(rawValue:))
        metricsPath = container.lenient(String.self, .metricsPath) ?? ""
        auth = container.lenient(ModelServerAuth.self, .auth) ?? .none
        offlineAlerts = container.lenient(Bool.self, .offlineAlerts) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(engine?.rawValue ?? Self.autoEngine, forKey: .engine)
        try container.encode(metricsPath, forKey: .metricsPath)
        try container.encode(auth, forKey: .auth)
        try container.encode(offlineAlerts, forKey: .offlineAlerts)
    }

    static let autoEngine = "auto"

    public static func newID() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
    }

    // The id is part of sample series names and the Keychain account, so it stays within [A-Za-z0-9_-].
    static func cleanID(_ raw: String) -> String? {
        let id = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).map { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
                ? character : "-"
        }.prefix(64))
        return id.isEmpty ? nil : id
    }

    public var isLegacy: Bool { id == Self.legacyID }

    public var endpoint: RemoteEndpoint? {
        guard var base = RemoteEndpoint.sanitizedBaseURL(baseURL) else { return nil }
        // People paste the OpenAI base URL; the API root is one level up.
        if base.lowercased().hasSuffix("/v1") { base.removeLast(3) }
        return RemoteEndpoint(baseURL: base, name: displayName)
    }

    public var isConfigured: Bool { endpoint != nil }
    public var isActive: Bool { enabled && isConfigured }

    public var host: String {
        guard let url = URL(string: RemoteEndpoint.sanitizedBaseURL(baseURL) ?? ""), let host = url.host() else { return "" }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return host.isEmpty ? "Local model" : host
    }

    public var isLoopback: Bool {
        guard let host = endpoint?.host else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    public func hasSameConnection(as other: ModelServer) -> Bool {
        id == other.id && endpoint?.baseURL == other.endpoint?.baseURL && engine == other.engine
            && metricsPath.trimmingCharacters(in: .whitespaces) == other.metricsPath.trimmingCharacters(in: .whitespaces)
            && auth == other.auth
    }

    public struct Target: Sendable, Equatable {
        public var endpoint: RemoteEndpoint
        public var path: String
        public var sendsCredentials: Bool
    }

    public func target(for route: ModelServerRoute) -> Target? {
        guard let endpoint else { return nil }
        let override = metricsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard route == .metrics, !override.isEmpty else {
            return Target(endpoint: endpoint, path: route.path, sendsCredentials: true)
        }
        guard override.contains("://") else {
            return Target(endpoint: endpoint, path: override.hasPrefix("/") ? override : "/" + override,
                          sendsCredentials: true)
        }
        guard let url = URLComponents(string: override), let host = url.host?.lowercased(),
              var base = URLComponents(string: override) else { return nil }
        base.path = ""
        base.query = nil
        base.fragment = nil
        guard let root = base.string, let other = RemoteEndpoint(baseURL: root, name: displayName) else { return nil }
        let path = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath)
            + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        // Credentials belong to the server's own host; a metrics URL elsewhere gets none of them.
        return Target(endpoint: other, path: path, sendsCredentials: host == endpoint.host)
    }

}

public enum ModelServerRoute: String, Sendable, CaseIterable, Codable {
    case metrics
    case openAIModels
    case ollamaVersion
    case ollamaTags
    case ollamaRunning
    case lmStudioModels
    case llamaCppProps
    case tgiInfo

    public var path: String {
        switch self {
        case .metrics: return "/metrics"
        case .openAIModels: return "/v1/models"
        case .ollamaVersion: return "/api/version"
        case .ollamaTags: return "/api/tags"
        case .ollamaRunning: return "/api/ps"
        case .lmStudioModels: return "/api/v0/models"
        case .llamaCppProps: return "/props"
        case .tgiInfo: return "/info"
        }
    }

    public var accept: String {
        self == .metrics ? "text/plain, */*;q=0.5" : "application/json"
    }
}
