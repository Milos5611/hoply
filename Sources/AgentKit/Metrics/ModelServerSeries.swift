import Foundation

public enum ModelServerSeries {
    public static let generationTokensPerSecond = "model.generation_tps"
    public static let promptTokensPerSecond = "model.prompt_tps"
    public static let kvCachePercent = "model.kv_cache_pct"
    public static let running = "model.running"
    public static let waiting = "model.waiting"
    public static let generatedTokens = "model.generation_tokens"
    public static let promptTokens = "model.prompt_tokens"

    public static let gauges = [generationTokensPerSecond, promptTokensPerSecond, kvCachePercent, running, waiting]
    public static let counters = [generatedTokens, promptTokens]
    public static var all: [String] { gauges + counters }

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

public struct ModelTokenDay: Sendable, Equatable, Identifiable {
    public var day: Date
    public var generated: Double
    public var prompt: Double
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
