import AgentKit
import Foundation

extension Ledger {
    @discardableResult
    public func recordModelSamples(_ status: ModelServerStatus, server id: String) async throws -> [SampleBucket] {
        try await store.recordSamples(ModelServerSeries.observations(status, server: id))
    }

    public func resetModelCounters(server id: String) async {
        await store.resetCounterBaselines(ModelServerSeries.names(ModelServerSeries.counters, server: id))
    }

    public func modelSamples(_ series: String, server id: String, resolution: Int = SampleAggregator.resolution,
                             in range: DateInterval) async throws -> [SampleBucket] {
        try await reader.samples(ModelServerSeries.name(series, server: id), resolution: resolution, in: range)
    }

    public func recentModelSamples(server id: String, since: Date,
                                   now: Date = Date()) async throws -> [String: [SampleBucket]] {
        var result: [String: [SampleBucket]] = [:]
        let keyed = try await reader.recentSamples(ModelServerSeries.names(ModelServerSeries.all, server: id),
                                                   since: since, now: now)
        for series in ModelServerSeries.all {
            if let buckets = keyed[ModelServerSeries.name(series, server: id)] { result[series] = buckets }
        }
        return result
    }

    public func modelTokensPerDay(server id: String, days: Int, now: Date = Date(),
                                  calendar: Calendar = .current) async throws -> [ModelTokenDay] {
        let generated = try await reader.dailySums(ModelServerSeries.name(ModelServerSeries.generatedTokens, server: id),
                                                   days: days, now: now, calendar: calendar)
        let prompt = try await reader.dailySums(ModelServerSeries.name(ModelServerSeries.promptTokens, server: id),
                                                days: days, now: now, calendar: calendar)
        return ModelTokenDay.days(generated: generated, prompt: prompt)
    }

    public func modelServerLastSeen(server id: String, now: Date = Date()) async throws -> Date? {
        try await reader.lastSampleEnd(ModelServerSeries.names(ModelServerSeries.all, server: id)).map { min($0, now) }
    }

    public func modelServerIDsWithSamples() async throws -> [String] {
        try await reader.modelServerIDsWithSamples()
    }
}
