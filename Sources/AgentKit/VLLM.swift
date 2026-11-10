import Foundation

public struct PromSample: Sendable, Equatable {
    public var name: String
    public var labels: [String: String]
    public var value: Double
}

/// Parser for the Prometheus text exposition format (what vLLM serves at /metrics).
public enum PrometheusParser {
    public static func parse(_ text: String) -> [PromSample] {
        var samples: [PromSample] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let sample = parseLine(line) { samples.append(sample) }
        }
        return samples
    }

    static func parseLine(_ line: String) -> PromSample? {
        let chars = Array(line)
        var index = 0
        var name = ""
        while index < chars.count, chars[index] != "{", chars[index] != " ", chars[index] != "\t" {
            name.append(chars[index])
            index += 1
        }
        guard !name.isEmpty else { return nil }

        var labels: [String: String] = [:]
        if index < chars.count, chars[index] == "{" {
            index += 1
            while index < chars.count, chars[index] != "}" {
                while index < chars.count, chars[index] == "," || chars[index] == " " { index += 1 }
                if index < chars.count, chars[index] == "}" { break }
                var key = ""
                while index < chars.count, chars[index] != "=" {
                    key.append(chars[index])
                    index += 1
                }
                guard index + 1 < chars.count, chars[index + 1] == "\"" else { return nil }
                index += 2
                var value = ""
                while index < chars.count, chars[index] != "\"" {
                    if chars[index] == "\\", index + 1 < chars.count {
                        let escaped = chars[index + 1]
                        value.append(escaped == "n" ? "\n" : escaped)
                        index += 2
                    } else {
                        value.append(chars[index])
                        index += 1
                    }
                }
                guard index < chars.count else { return nil }
                index += 1
                labels[key.trimmingCharacters(in: .whitespaces)] = value
            }
            guard index < chars.count else { return nil }
            index += 1
        }

        let rest = String(chars[index...]).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = rest.first, let value = Double(first) else { return nil }
        return PromSample(name: name, labels: labels, value: value)
    }
}

/// One scrape of a vLLM server's /metrics.
public struct VLLMSnapshot: Sendable, Equatable {
    /// "vllm" or "tensorfold": both publish vLLM's metric names, each under its own prefix.
    public var engine: String
    public var model: String?
    public var running: Int
    public var waiting: Int
    /// Fraction 0…1 of KV cache in use.
    public var kvCacheUsage: Double?
    public var promptTokensTotal: Double
    /// The engine's counter plus tokens held by live streams; moves while decoding, so rates use it. It can dip
    /// when a stream is cancelled, so it is not a counter.
    public var generationTokensTotal: Double
    /// The engine's own monotonic counter (tensorfold: finished requests only); a drop means a restart.
    public var generationTokensCounter: Double
    public var takenAt: Date

    public static let engines = ["vllm", "tensorfold"]

    public static func engine(of samples: [PromSample]) -> String? {
        engines.first { engine in samples.contains { $0.name.hasPrefix(engine + ":") } }
    }

    public static func from(samples: [PromSample], at time: Date) -> VLLMSnapshot {
        let engine = Self.engine(of: samples) ?? "vllm"
        func sum(_ suffixes: [String]) -> Double? {
            for name in suffixes.map({ "\(engine):\($0)" }) {
                let matching = samples.filter { $0.name == name }
                if !matching.isEmpty { return matching.reduce(0) { $0 + $1.value } }
            }
            return nil
        }
        func maximum(_ suffixes: [String]) -> Double? {
            for name in suffixes.map({ "\(engine):\($0)" }) {
                let values = samples.filter { $0.name == name }.map(\.value)
                if let top = values.max() { return top }
            }
            return nil
        }
        func count(_ value: Double?) -> Int {
            guard let value, value.isFinite, value >= 0, value < 1e9 else { return 0 }
            return Int(value)
        }
        let model = samples.first { $0.name.hasPrefix(engine + ":") && $0.labels["model_name"] != nil }?.labels["model_name"]
        // tensorfold counts generated tokens only when a request finishes; adding the tokens held by live
        // streams turns that into a counter that moves while decoding, so tok/s isn't zero until the end.
        let counter = sum(["generation_tokens_total", "generation_tokens"]) ?? 0
        let generated = counter + (sum(["generation_tokens_running"]) ?? 0)
        return VLLMSnapshot(
            engine: engine,
            model: model,
            running: count(sum(["num_requests_running"])),
            waiting: count(sum(["num_requests_waiting"])),
            kvCacheUsage: maximum(["kv_cache_usage_perc", "gpu_cache_usage_perc"]),
            promptTokensTotal: sum(["prompt_tokens_total", "prompt_tokens"]) ?? 0,
            generationTokensTotal: generated,
            generationTokensCounter: counter,
            takenAt: time
        )
    }
}

/// What the panel shows for the local model server: the latest snapshot plus rates.
public struct VLLMStatus: Sendable, Equatable {
    public var snapshot: VLLMSnapshot
    public var generationTokensPerSecond: Double?
    public var promptTokensPerSecond: Double?

    public static func compute(previous: VLLMSnapshot?, current: VLLMSnapshot) -> VLLMStatus {
        guard let previous else {
            return VLLMStatus(snapshot: current, generationTokensPerSecond: nil, promptTokensPerSecond: nil)
        }
        let seconds = current.takenAt.timeIntervalSince(previous.takenAt)
        func rate(_ now: Double, _ before: Double) -> Double? {
            guard seconds > 0.5, now >= before else { return nil }  // counter reset → no rate this round
            return (now - before) / seconds
        }
        return VLLMStatus(
            snapshot: current,
            generationTokensPerSecond: rate(current.generationTokensTotal, previous.generationTokensTotal),
            promptTokensPerSecond: rate(current.promptTokensTotal, previous.promptTokensTotal)
        )
    }
}
