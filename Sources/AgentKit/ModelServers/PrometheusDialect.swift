import Foundation

public struct PrometheusDialect: Sendable, Equatable {
    public var engine: ModelEngine
    public var prefix: String
    var running: [String]
    var waiting: [String]
    var kvCache: [String]
    var promptTokens: [String]
    var generationTokens: [String]
    var generationTokensLive: [String] = []
    var generationRate: [String] = []
    var memoryBytes: [String] = []

    static let vllmNames = PrometheusDialect(
        engine: .vllm, prefix: "vllm:",
        running: ["num_requests_running"], waiting: ["num_requests_waiting"],
        kvCache: ["kv_cache_usage_perc", "gpu_cache_usage_perc"],
        promptTokens: ["prompt_tokens_total", "prompt_tokens"],
        generationTokens: ["generation_tokens_total", "generation_tokens"],
        generationTokensLive: ["generation_tokens_running"], memoryBytes: ["device_memory_bytes"])

    public static let known: [PrometheusDialect] = {
        var tensorfold = vllmNames
        tensorfold.engine = .tensorfold
        tensorfold.prefix = "tensorfold:"
        return [
            vllmNames,
            tensorfold,
            PrometheusDialect(engine: .llamaCpp, prefix: "llamacpp:",
                              running: ["requests_processing"], waiting: ["requests_deferred"],
                              kvCache: ["kv_cache_usage_ratio"],
                              promptTokens: ["prompt_tokens_total"], generationTokens: ["tokens_predicted_total"]),
            PrometheusDialect(engine: .sglang, prefix: "sglang:",
                              running: ["num_running_reqs"], waiting: ["num_queue_reqs", "num_waiting_reqs"],
                              kvCache: ["token_usage"],
                              promptTokens: ["prompt_tokens_total"], generationTokens: ["generation_tokens_total"],
                              generationRate: ["gen_throughput"]),
            PrometheusDialect(engine: .tgi, prefix: "tgi_",
                              running: ["batch_current_size"], waiting: ["queue_size"], kvCache: [],
                              promptTokens: ["request_input_length_sum"],
                              generationTokens: ["request_generated_tokens_sum"]),
        ]
    }()

    public static func detect(_ samples: [PromSample]) -> PrometheusDialect? {
        if let dialect = known.first(where: { dialect in samples.contains { $0.name.hasPrefix(dialect.prefix) } }) {
            return dialect
        }
        // An engine nobody listed that still uses vLLM's metric names under its own prefix, as tensorfold does.
        for sample in samples {
            for suffix in vllmNames.generationTokens + vllmNames.running where sample.name.hasSuffix(":" + suffix) {
                var dialect = vllmNames
                dialect.engine = .openAICompatible
                dialect.prefix = String(sample.name.dropLast(suffix.count))
                return dialect
            }
        }
        return nil
    }

    public func metrics(from samples: [PromSample]) -> ModelServerMetrics {
        func values(_ names: [String]) -> [Double]? {
            for name in names.map({ prefix + $0 }) {
                let matching = samples.filter { $0.name == name && $0.value.isFinite }.map(\.value)
                if !matching.isEmpty { return matching }
            }
            return nil
        }
        func sum(_ names: [String]) -> Double? { values(names).map { $0.reduce(0, +) } }
        func count(_ value: Double?) -> Int? {
            guard let value, value >= 0, value < 1e9 else { return nil }
            return Int(value)
        }
        let counter = sum(generationTokens)
        // tensorfold counts generated tokens only when a request finishes; adding the tokens held by live
        // streams turns that into a counter that moves while decoding, so tok/s isn't zero until the end.
        let live = counter.map { $0 + (sum(generationTokensLive) ?? 0) }
        let model = samples.first { $0.name.hasPrefix(prefix) && $0.labels["model_name"] != nil }?.labels["model_name"]
        return ModelServerMetrics(
            model: model,
            running: count(sum(running)),
            waiting: count(sum(waiting)),
            kvCacheUsage: values(kvCache)?.max().map { Swift.min(Swift.max($0, 0), 1) },
            promptTokensTotal: sum(promptTokens),
            generationTokensTotal: live,
            generationTokensCounter: counter,
            reportedGenerationRate: sum(generationRate),
            memoryBytes: sum(memoryBytes))
    }
}
