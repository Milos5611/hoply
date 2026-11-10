import Foundation

public enum PricingCalibration {
    public struct Row: Sendable, Equatable {
        public var model: String
        public var reportedUSD: Double
        public var computedUSD: Double?
        public var relativeError: Double?
        public var isOff: Bool
    }

    public static func check(_ state: ClaudeCostState, table: PricingTable, tolerance: Double = 0.02) -> [Row] {
        state.models.keys.sorted().compactMap { name -> Row? in
            guard let model = state.models[name], !table.isLocal(name) else { return nil }
            let reported = model.costUSD
            guard let rates = table.match(name)?.price.rates(promptTokens: 0, fast: false) else {
                return Row(model: name, reportedUSD: reported, computedUSD: nil, relativeError: nil, isOff: reported > 0)
            }
            let searches = Double(model.webSearchRequests) * table.webSearchPerThousand / 1000
            let computed = rates.cost(model.tokens) + searches
            var low = computed
            var high = computed
            if !model.cacheSplitKnown {
                var allHour = model.tokens
                allHour.cacheWrite1h += allHour.cacheWrite5m
                allHour.cacheWrite5m = 0
                high = rates.cost(allHour) + searches
                low = min(low, high)
                high = max(computed, high)
            }
            let nearest = min(max(reported, low), high)
            let error = reported > 0 ? (nearest - reported) / reported : (nearest > 0 ? 1 : 0)
            return Row(model: name, reportedUSD: reported, computedUSD: nearest, relativeError: error,
                       isOff: abs(error) > tolerance && abs(nearest - reported) > 0.0001)
        }
    }
}
