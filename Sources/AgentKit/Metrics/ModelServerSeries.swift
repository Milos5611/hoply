import Foundation

/// The `samples` series kept for the local model server (vLLM or tensorfold), from each `/metrics` poll.
public enum ModelServerSeries {
    public static let generationTokensPerSecond = "model.generation_tps"
    public static let promptTokensPerSecond = "model.prompt_tps"
    /// Percent 0…100.
    public static let kvCachePercent = "model.kv_cache_pct"
    public static let running = "model.running"
    public static let waiting = "model.waiting"
    /// Counters: their buckets' sums are tokens per bucket, so a day's sum is tokens per day.
    public static let generatedTokens = "model.generation_tokens"
    public static let promptTokens = "model.prompt_tokens"

    public static let gauges = [generationTokensPerSecond, promptTokensPerSecond, kvCachePercent, running, waiting]
    public static let counters = [generatedTokens, promptTokens]
    public static var all: [String] { gauges + counters }

    /// Rates are missing on the first poll and after a counter reset, so those polls carry no tok/s reading.
    /// The generated-token counter is the engine's own (`generationTokensCounter`), not the live total that
    /// includes running streams, because a cancelled stream would make that dip and look like a restart.
    public static func observations(_ status: VLLMStatus) -> [SampleObservation] {
        let snapshot = status.snapshot
        let time = snapshot.takenAt
        var result: [SampleObservation] = []
        func add(_ series: String, _ value: Double?, _ kind: SampleKind = .gauge) {
            guard let value, value.isFinite, value >= 0 else { return }
            result.append(SampleObservation(series: series, ts: time, value: value, kind: kind))
        }
        add(generationTokensPerSecond, status.generationTokensPerSecond)
        add(promptTokensPerSecond, status.promptTokensPerSecond)
        add(kvCachePercent, snapshot.kvCacheUsage.map { $0 * 100 })
        add(running, Double(snapshot.running))
        add(waiting, Double(snapshot.waiting))
        add(generatedTokens, snapshot.generationTokensCounter, .counter)
        add(promptTokens, snapshot.promptTokensTotal, .counter)
        return result
    }

    public static func observations(current: VLLMSnapshot, previous: VLLMSnapshot?) -> [SampleObservation] {
        observations(VLLMStatus.compute(previous: previous, current: current))
    }
}

/// Tokens the model server processed on one local day, from its counter series.
public struct ModelTokenDay: Sendable, Equatable, Identifiable {
    /// Local midnight.
    public var day: Date
    public var generated: Double
    public var prompt: Double
    /// False when no poll reached the server that day (server off, or Hoply not running).
    public var observed: Bool

    public init(day: Date, generated: Double, prompt: Double, observed: Bool) {
        self.day = day
        self.generated = generated
        self.prompt = prompt
        self.observed = observed
    }

    public var id: Date { day }

    public static func days(generated: [DailySampleSum], prompt: [DailySampleSum]) -> [ModelTokenDay] {
        let prompts = Dictionary(prompt.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        return generated.map { day in
            let other = prompts[day.day]
            return ModelTokenDay(day: day.day, generated: day.sum, prompt: other?.sum ?? 0,
                                 observed: day.readings > 0 || (other?.readings ?? 0) > 0)
        }
    }
}
