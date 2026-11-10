import Foundation

public struct ServedModel: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var loaded: Bool?
    public var memoryBytes: Double?
    public var contextLength: Int?
    public var ownedBy: String?
    public var detail: String?

    public init(id: String, loaded: Bool? = nil, memoryBytes: Double? = nil, contextLength: Int? = nil,
                ownedBy: String? = nil, detail: String? = nil) {
        self.id = id
        self.loaded = loaded
        self.memoryBytes = memoryBytes
        self.contextLength = contextLength
        self.ownedBy = ownedBy
        self.detail = detail
    }
}

public enum ModelServerCapability: String, Sendable, CaseIterable {
    case models
    case loadedModels
    case generationRate
    case promptRate
    case running
    case waiting
    case kvCache
    case memory
    case version
}

public enum ModelServerHint: Sendable, Equatable, Hashable {
    case metricsDisabled(ModelEngine)
    case metricsUnreadable

    public var text: String {
        switch self {
        case .metricsDisabled(.llamaCpp): return "Start llama-server with --metrics to see throughput."
        case .metricsDisabled(let engine): return "\(engine.displayName) isn't serving /metrics, so there is no throughput."
        case .metricsUnreadable: return "The metrics address answered with something that isn't Prometheus text."
        }
    }
}

public struct ModelServerMetrics: Sendable, Equatable {
    public var model: String?
    public var running: Int?
    public var waiting: Int?
    public var kvCacheUsage: Double?
    public var promptTokensTotal: Double?
    public var generationTokensTotal: Double?
    public var generationTokensCounter: Double?
    public var reportedGenerationRate: Double?
    public var memoryBytes: Double?

    public init(model: String? = nil, running: Int? = nil, waiting: Int? = nil, kvCacheUsage: Double? = nil,
                promptTokensTotal: Double? = nil, generationTokensTotal: Double? = nil,
                generationTokensCounter: Double? = nil, reportedGenerationRate: Double? = nil,
                memoryBytes: Double? = nil) {
        self.model = model
        self.running = running
        self.waiting = waiting
        self.kvCacheUsage = kvCacheUsage
        self.promptTokensTotal = promptTokensTotal
        self.generationTokensTotal = generationTokensTotal
        self.generationTokensCounter = generationTokensCounter
        self.reportedGenerationRate = reportedGenerationRate
        self.memoryBytes = memoryBytes
    }

    public var isEmpty: Bool { self == ModelServerMetrics() }
}

public struct ModelServerSnapshot: Sendable, Equatable {
    public var engine: ModelEngine
    public var metricsPrefix: String?
    public var version: String?
    public var models: [ServedModel]
    public var metrics: ModelServerMetrics
    public var hints: [ModelServerHint]
    public var takenAt: Date

    public init(engine: ModelEngine, metricsPrefix: String? = nil, version: String? = nil, models: [ServedModel] = [],
                metrics: ModelServerMetrics = ModelServerMetrics(), hints: [ModelServerHint] = [], takenAt: Date) {
        self.engine = engine
        self.metricsPrefix = metricsPrefix
        self.version = version
        self.models = models
        self.metrics = metrics
        self.hints = hints
        self.takenAt = takenAt
    }

    public var loadedModels: [ServedModel] { models.filter { $0.loaded == true } }

    public var primaryModel: String? {
        if let model = metrics.model { return model }
        if let loaded = loadedModels.first { return loaded.id }
        return models.count == 1 ? models.first?.id : nil
    }

    public var memoryBytes: Double? {
        if let reported = metrics.memoryBytes { return reported }
        let sizes = loadedModels.compactMap(\.memoryBytes)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    public var capabilities: Set<ModelServerCapability> {
        var result: Set<ModelServerCapability> = []
        if !models.isEmpty { result.insert(.models) }
        if models.contains(where: { $0.loaded != nil }) { result.insert(.loadedModels) }
        if metrics.generationTokensTotal != nil || metrics.reportedGenerationRate != nil { result.insert(.generationRate) }
        if metrics.promptTokensTotal != nil { result.insert(.promptRate) }
        if metrics.running != nil { result.insert(.running) }
        if metrics.waiting != nil { result.insert(.waiting) }
        if metrics.kvCacheUsage != nil { result.insert(.kvCache) }
        if memoryBytes != nil { result.insert(.memory) }
        if version != nil { result.insert(.version) }
        return result
    }
}

public struct ModelServerStatus: Sendable, Equatable {
    public var snapshot: ModelServerSnapshot
    public var generationTokensPerSecond: Double?
    public var promptTokensPerSecond: Double?

    public init(snapshot: ModelServerSnapshot, generationTokensPerSecond: Double? = nil,
                promptTokensPerSecond: Double? = nil) {
        self.snapshot = snapshot
        self.generationTokensPerSecond = generationTokensPerSecond
        self.promptTokensPerSecond = promptTokensPerSecond
    }

    public var engine: ModelEngine { snapshot.engine }
    public var models: [ServedModel] { snapshot.models }
    public var capabilities: Set<ModelServerCapability> { snapshot.capabilities }

    public static func compute(previous: ModelServerSnapshot?, current: ModelServerSnapshot) -> ModelServerStatus {
        let seconds = previous.map { current.takenAt.timeIntervalSince($0.takenAt) } ?? 0
        func rate(_ now: Double?, _ before: Double?) -> Double? {
            // A counter that went down is a restart: no rate this round.
            guard let now, let before, seconds > 0.5, now >= before else { return nil }
            return (now - before) / seconds
        }
        let sameEngine = previous?.engine == current.engine
        let counted = sameEngine ? rate(current.metrics.generationTokensTotal, previous?.metrics.generationTokensTotal) : nil
        return ModelServerStatus(
            snapshot: current,
            generationTokensPerSecond: current.metrics.generationTokensTotal == nil
                ? current.metrics.reportedGenerationRate : counted,
            promptTokensPerSecond: sameEngine
                ? rate(current.metrics.promptTokensTotal, previous?.metrics.promptTokensTotal) : nil)
    }
}

public enum ModelServerAvailability: String, Sendable, Equatable {
    case online
    case offline
    case blocked

    public init(_ result: Result<ModelServerStatus, RemoteError>) {
        switch result {
        case .success: self = .online
        case .failure(let error): self = error.isUnreachable ? .offline : .blocked
        }
    }
}
