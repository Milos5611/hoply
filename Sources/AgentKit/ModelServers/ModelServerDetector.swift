import Foundation

public enum ModelServerResponses {
    static func object(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        return double.isFinite && double > 0 && double < 1e12 ? Int(double) : nil
    }

    static func bytes(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else { return nil }
        return number.doubleValue
    }

    static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return String(text.prefix(200))
    }

    public static func openAIModels(_ data: Data?) -> [ServedModel]? {
        guard let list = object(data)?["data"] as? [Any] else { return nil }
        return list.compactMap { entry in
            guard let entry = entry as? [String: Any], let id = text(entry["id"]) else { return nil }
            let meta = entry["meta"] as? [String: Any]
            return ServedModel(id: id,
                               contextLength: int(entry["max_model_len"]) ?? int(entry["context_length"])
                                   ?? int(entry["max_context_length"]) ?? int(meta?["n_ctx"]) ?? int(meta?["n_ctx_train"]),
                               ownedBy: text(entry["owned_by"]))
        }
    }

    public static func lmStudioModels(_ data: Data?) -> [ServedModel]? {
        guard let list = object(data)?["data"] as? [Any] else { return nil }
        let models: [ServedModel] = list.compactMap { entry in
            guard let entry = entry as? [String: Any], let id = text(entry["id"]),
                  let state = text(entry["state"]) else { return nil }
            let detail = [text(entry["arch"]), text(entry["quantization"])].compactMap { $0 }.joined(separator: " · ")
            return ServedModel(id: id, loaded: state == "loaded",
                               contextLength: int(entry["loaded_context_length"]) ?? int(entry["max_context_length"]),
                               ownedBy: text(entry["publisher"]), detail: detail.isEmpty ? nil : detail)
        }
        return models.isEmpty && !list.isEmpty ? nil : models
    }

    public static func ollamaVersion(_ data: Data?) -> String? {
        text(object(data)?["version"])
    }

    public static func ollamaModels(tags: Data?, running: Data?) -> [ServedModel]? {
        func entries(_ data: Data?) -> [[String: Any]]? {
            (object(data)?["models"] as? [Any])?.compactMap { $0 as? [String: Any] }
        }
        let installed = entries(tags)
        let loaded = entries(running)
        guard installed != nil || loaded != nil else { return nil }
        func model(_ entry: [String: Any], loaded: Bool?) -> ServedModel? {
            guard let id = text(entry["name"]) ?? text(entry["model"]) else { return nil }
            let details = entry["details"] as? [String: Any]
            let detail = [text(details?["parameter_size"]), text(details?["quantization_level"])].compactMap { $0 }
                .joined(separator: " · ")
            return ServedModel(id: id, loaded: loaded,
                               memoryBytes: loaded == true ? bytes(entry["size_vram"]) ?? bytes(entry["size"]) : nil,
                               contextLength: int(entry["context_length"]) ?? int(details?["context_length"]),
                               detail: detail.isEmpty ? nil : detail)
        }
        var result = (loaded ?? []).compactMap { model($0, loaded: true) }
        let active = Set(result.map(\.id))
        result += (installed ?? []).compactMap { model($0, loaded: loaded == nil ? nil : false) }
            .filter { !active.contains($0.id) }
        return result
    }

    public static func llamaCppProps(_ data: Data?)
        -> (model: String?, contextLength: Int?, build: String?, metricsEnabled: Bool?)? {
        guard let props = object(data),
              props["default_generation_settings"] != nil || props["total_slots"] != nil else { return nil }
        let settings = props["default_generation_settings"] as? [String: Any]
        let path = text(props["model_alias"]) ?? text(props["model_path"]).map { ($0 as NSString).lastPathComponent }
        return (path, int(settings?["n_ctx"]), text(props["build_info"]), props["endpoint_metrics"] as? Bool)
    }

    public static func tgiInfo(_ data: Data?) -> (model: String, contextLength: Int?, version: String?)? {
        guard let info = object(data), let model = text(info["model_id"]) else { return nil }
        return (model, int(info["max_total_tokens"]), text(info["version"]))
    }
}

public enum ModelServerDetector {
    public static func routes(for engine: ModelEngine?) -> [ModelServerRoute] {
        switch engine {
        case nil: return ModelServerRoute.allCases
        case .vllm, .tensorfold, .sglang: return [.metrics, .openAIModels]
        case .llamaCpp: return [.metrics, .openAIModels, .llamaCppProps]
        case .tgi: return [.metrics, .tgiInfo]
        case .ollama: return [.ollamaRunning, .ollamaTags, .ollamaVersion]
        case .lmStudio: return [.lmStudioModels, .openAIModels]
        case .openAICompatible: return [.openAIModels, .metrics]
        }
    }

    public static func slowRoutes(for engine: ModelEngine?) -> Set<ModelServerRoute> {
        switch engine {
        case nil, .lmStudio, .openAICompatible: return []
        case .ollama: return [.ollamaTags, .ollamaVersion]
        case .vllm, .tensorfold, .sglang, .llamaCpp, .tgi: return [.openAIModels, .llamaCppProps, .tgiInfo]
        }
    }

    public static func snapshot(from answers: [ModelServerRoute: Result<Data, RemoteError>], engine wanted: ModelEngine?,
                                at time: Date, endpoint name: String) -> Result<ModelServerSnapshot, RemoteError> {
        func body(_ route: ModelServerRoute) -> Data? { try? answers[route]?.get() }

        var hints: [ModelServerHint] = []
        var dialect: PrometheusDialect?
        var metrics = ModelServerMetrics()
        if let text = body(.metrics) {
            let samples = PrometheusParser.parse(String(decoding: text, as: UTF8.self))
            dialect = PrometheusDialect.detect(samples)
            if let wanted, let known = PrometheusDialect.known.first(where: { $0.engine == wanted }),
               samples.contains(where: { $0.name.hasPrefix(known.prefix) }) {
                dialect = known
            }
            if let dialect { metrics = dialect.metrics(from: samples) }
            if samples.isEmpty { hints.append(.metricsUnreadable) }
        }
        do {
            let openAI = ModelServerResponses.openAIModels(body(.openAIModels))
            let studio = ModelServerResponses.lmStudioModels(body(.lmStudioModels))
            let ollamaVersion = ModelServerResponses.ollamaVersion(body(.ollamaVersion))
            let ollama = ModelServerResponses.ollamaModels(tags: body(.ollamaTags), running: body(.ollamaRunning))
            let props = ModelServerResponses.llamaCppProps(body(.llamaCppProps))
            let info = ModelServerResponses.tgiInfo(body(.tgiInfo))
            let owners = Set((openAI ?? []).compactMap { $0.ownedBy?.lowercased() })

            let found: ModelEngine?
            if let dialect, dialect.engine != .openAICompatible {
                found = dialect.engine
            } else if ollama != nil, wanted == .ollama || ollamaVersion != nil || body(.ollamaTags) != nil {
                found = .ollama
            } else if studio != nil {
                found = .lmStudio
            } else if props != nil || owners.contains("llamacpp") {
                found = .llamaCpp
            } else if info != nil {
                found = .tgi
            } else if owners.contains("vllm") {
                found = .vllm
            } else if owners.contains("sglang") {
                found = .sglang
            } else if openAI != nil || dialect != nil {
                found = .openAICompatible
            } else {
                found = nil
            }
            guard let found else { return .failure(failure(answers, endpoint: name)) }
            let engine = wanted ?? found

            var snapshot = ModelServerSnapshot(engine: engine, metricsPrefix: dialect?.prefix, metrics: metrics,
                                               hints: hints, takenAt: time)
            switch engine {
            case .ollama:
                snapshot.models = ollama ?? []
                snapshot.version = ollamaVersion
            case .lmStudio:
                snapshot.models = studio ?? openAI ?? []
            case .tgi:
                snapshot.models = info.map { [ServedModel(id: $0.model, loaded: true, contextLength: $0.contextLength)] }
                    ?? openAI ?? []
                snapshot.version = info?.version
            default:
                snapshot.models = openAI ?? []
                if engine == .llamaCpp {
                    snapshot.version = props?.build
                    if snapshot.models.isEmpty, let model = props?.model {
                        snapshot.models = [ServedModel(id: model, loaded: true, contextLength: props?.contextLength)]
                    }
                }
            }
            if snapshot.models.isEmpty, let model = metrics.model { snapshot.models = [ServedModel(id: model, loaded: true)] }
            if engine.reportsPrometheus, dialect == nil, hints.isEmpty {
                let switchedOff = engine == .llamaCpp
                    && (props?.metricsEnabled == false || failedStatus(answers[.metrics]) == 501)
                snapshot.hints.append(switchedOff ? .metricsDisabled(engine) : .metricsMissing(engine))
            }
            return .success(snapshot)
        }
    }

    static func failedStatus(_ answer: Result<Data, RemoteError>?) -> Int? {
        if case .failure(let error)? = answer, case .http(let status) = error.kind { return status }
        return nil
    }

    public static func failure(_ answers: [ModelServerRoute: Result<Data, RemoteError>],
                               endpoint name: String) -> RemoteError {
        let errors = ModelServerRoute.allCases.compactMap { route -> RemoteError? in
            if case .failure(let error)? = answers[route] { return error }
            return nil
        }
        func isPage(_ error: RemoteError) -> Bool {
            if case .htmlPage = error.kind { return true }
            return false
        }
        if let auth = errors.first(where: \.isAuthFailure) { return auth }
        if let blocked = errors.first(where: { $0.kind == .insecureHTTPBlocked || $0.kind == .httpsRequired }) {
            return blocked
        }
        for error in errors {
            if case .tlsFailure = error.kind { return error }
        }
        if errors.count == answers.count, errors.allSatisfy(\.isUnreachable), let down = errors.first { return down }
        for error in errors {
            if case .redirected = error.kind { return error }
        }
        if errors.count == answers.count, errors.allSatisfy(isPage), let page = errors.first { return page }
        return RemoteError(.noModelServer, endpoint: name)
    }
}

public struct ModelServerRouteReport: Sendable, Equatable, Identifiable {
    public var route: ModelServerRoute
    public var url: String
    public var status: Int?
    public var error: RemoteError?
    public var latency: TimeInterval?

    public init(route: ModelServerRoute, url: String, status: Int?, error: RemoteError?, latency: TimeInterval?) {
        self.route = route
        self.url = url
        self.status = status
        self.error = error
        self.latency = latency
    }

    public var id: ModelServerRoute { route }
    public var answered: Bool { error == nil }
}

public struct ModelServerProbe: Sendable, Equatable {
    public var server: ModelServer
    public var result: Result<ModelServerStatus, RemoteError>
    public var endpoints: [ModelServerRouteReport]
    public var plainHTTPAllowed: Bool
    public var at: Date

    public init(server: ModelServer, result: Result<ModelServerStatus, RemoteError>, endpoints: [ModelServerRouteReport],
                plainHTTPAllowed: Bool = true, at: Date) {
        self.server = server
        self.result = result
        self.endpoints = endpoints
        self.plainHTTPAllowed = plainHTTPAllowed
        self.at = at
    }

    public var status: ModelServerStatus? { try? result.get() }
    public var error: RemoteError? {
        if case .failure(let error) = result { return error }
        return nil
    }
    public var isReachable: Bool { status != nil }
    public var availability: ModelServerAvailability { ModelServerAvailability(result) }
    public var engine: ModelEngine? { status?.engine }
    public var models: [ServedModel] { status?.models ?? [] }
    public var hints: [ModelServerHint] { status?.snapshot.hints ?? [] }
    public var latency: TimeInterval? { endpoints.filter(\.answered).compactMap(\.latency).min() }
}

public struct ModelServerPoll: Sendable, Equatable {
    public var server: ModelServer
    public var result: Result<ModelServerStatus, RemoteError>
    public var at: Date

    public init(server: ModelServer, result: Result<ModelServerStatus, RemoteError>, at: Date) {
        self.server = server
        self.result = result
        self.at = at
    }

    public var status: ModelServerStatus? { try? result.get() }
    public var error: RemoteError? {
        if case .failure(let error) = result { return error }
        return nil
    }
    public var availability: ModelServerAvailability { ModelServerAvailability(result) }

    public func isCurrent(for server: ModelServer?) -> Bool {
        guard let server else { return false }
        return server.isActive && self.server.hasSameConnection(as: server)
    }
}

public struct ModelServerCandidate: Sendable, Equatable, Identifiable {
    public var server: ModelServer
    public var probe: ModelServerProbe

    public init(server: ModelServer, probe: ModelServerProbe) {
        self.server = server
        self.probe = probe
    }

    public var id: String { server.id }
}

public enum ModelServerDiscovery {
    public struct Port: Sendable, Equatable {
        public var port: Int
        public var usualEngine: String
    }

    public static let wellKnownPorts: [Port] = [
        Port(port: 11434, usualEngine: "Ollama"),
        Port(port: 1234, usualEngine: "LM Studio"),
        Port(port: 8080, usualEngine: "llama.cpp, MLX, LocalAI, TGI"),
        Port(port: 8000, usualEngine: "vLLM"),
        Port(port: 30000, usualEngine: "SGLang"),
        Port(port: 1337, usualEngine: "Jan"),
        Port(port: 5001, usualEngine: "KoboldCpp"),
        Port(port: 5000, usualEngine: "text-generation-webui, TabbyAPI"),
        Port(port: 4000, usualEngine: "LiteLLM"),
        Port(port: 8888, usualEngine: "tensorfold"),
    ]

    public static func ports(_ candidates: [Int] = wellKnownPorts.map(\.port), hubPort: Int,
                             configured: [ModelServer]) -> [Int] {
        var taken: Set<Int> = [hubPort]
        for server in configured where server.isLoopback {
            guard let url = server.endpoint?.baseURL else { continue }
            taken.insert(url.port ?? (url.scheme == "https" ? 443 : 80))
        }
        var seen: Set<Int> = []
        return candidates.filter { (1...65_535).contains($0) && !taken.contains($0) && seen.insert($0).inserted }
    }

    public static func server(port: Int) -> ModelServer {
        ModelServer(baseURL: "http://localhost:\(port)")
    }

    public static func candidate(_ probe: ModelServerProbe) -> ModelServerCandidate? {
        guard let status = probe.status else { return nil }
        var server = probe.server
        if server.name.trimmingCharacters(in: .whitespaces).isEmpty { server.name = status.engine.displayName }
        return ModelServerCandidate(server: server, probe: probe)
    }
}
