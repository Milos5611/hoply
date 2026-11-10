import Foundation

public struct ModelPrice: Codable, Sendable, Equatable {
    public struct LongContext: Codable, Sendable, Equatable {
        public var above: Int
        public var input: Double
        public var output: Double
        public var cacheRead: Double?
        public var cacheWrite5m: Double?
        public var cacheWrite1h: Double?

        public init(above: Int, input: Double, output: Double, cacheRead: Double? = nil,
                    cacheWrite5m: Double? = nil, cacheWrite1h: Double? = nil) {
            self.above = above
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite5m = cacheWrite5m
            self.cacheWrite1h = cacheWrite1h
        }
    }

    public struct Fast: Codable, Sendable, Equatable {
        public var input: Double
        public var output: Double

        public init(input: Double, output: Double) {
            self.input = input
            self.output = output
        }
    }

    public struct Rates: Sendable, Equatable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        public var cacheWrite5m: Double
        public var cacheWrite1h: Double

        public func cost(_ tokens: TokenCounts) -> Double {
            (Double(tokens.input) * input + Double(tokens.output) * output + Double(tokens.cacheRead) * cacheRead
                + Double(tokens.cacheWrite5m) * cacheWrite5m + Double(tokens.cacheWrite1h) * cacheWrite1h) / 1_000_000
        }

        func scaled(toInput newInput: Double, output newOutput: Double) -> Rates {
            let factor = input > 0 ? newInput / input : 1
            return Rates(input: newInput, output: newOutput, cacheRead: cacheRead * factor,
                         cacheWrite5m: cacheWrite5m * factor, cacheWrite1h: cacheWrite1h * factor)
        }
    }

    public var input: Double
    public var output: Double
    public var cacheRead: Double?
    public var cacheWrite5m: Double?
    public var cacheWrite1h: Double?
    public var longContext: LongContext?
    public var fast: Fast?

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite5m: Double? = nil,
                cacheWrite1h: Double? = nil, longContext: LongContext? = nil, fast: Fast? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.longContext = longContext
        self.fast = fast
    }

    public var standardRates: Rates {
        Rates(input: input, output: output, cacheRead: cacheRead ?? input * 0.1,
              cacheWrite5m: cacheWrite5m ?? input * 1.25, cacheWrite1h: cacheWrite1h ?? input * 2)
    }

    public func rates(promptTokens: Int, fast isFast: Bool) -> Rates? {
        let standard = standardRates
        if isFast {
            guard let fast else { return nil }
            return standard.scaled(toInput: fast.input, output: fast.output)
        }
        guard let tier = longContext, promptTokens > tier.above else { return standard }
        let scaled = standard.scaled(toInput: tier.input, output: tier.output)
        return Rates(input: tier.input, output: tier.output, cacheRead: tier.cacheRead ?? scaled.cacheRead,
                     cacheWrite5m: tier.cacheWrite5m ?? scaled.cacheWrite5m,
                     cacheWrite1h: tier.cacheWrite1h ?? scaled.cacheWrite1h)
    }
}

public struct PricedUsage: Sendable, Equatable {
    public var costUSD: Double?
    public var apiEquivUSD: Double?
    public var isLocal: Bool

    public init(costUSD: Double?, apiEquivUSD: Double?, isLocal: Bool) {
        self.costUSD = costUSD
        self.apiEquivUSD = apiEquivUSD
        self.isLocal = isLocal
    }
}

public struct PricingTable: Sendable, Equatable {
    public struct Document: Codable, Sendable, Equatable {
        public var models: [String: ModelPrice]
        public var webSearchPerThousand: Double?

        public init(models: [String: ModelPrice], webSearchPerThousand: Double? = nil) {
            self.models = models
            self.webSearchPerThousand = webSearchPerThousand
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            webSearchPerThousand = AnyKey(stringValue: "webSearchPerThousand")
                .flatMap { try? container.decodeIfPresent(Double.self, forKey: $0) }
            guard let key = AnyKey(stringValue: "models"),
                  let entries = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: key) else {
                models = [:]
                return
            }
            var models: [String: ModelPrice] = [:]
            for entry in entries.allKeys {
                if let price = try? entries.decode(ModelPrice.self, forKey: entry) {
                    models[entry.stringValue.lowercased()] = price
                }
            }
            self.models = models
        }

        public static func decode(_ data: Data) throws -> Document {
            try JSONDecoder().decode(Document.self, from: data)
        }
    }

    public static let defaultLocalModelPatterns = ["qwen"]
    public static let defaultReferenceModel = "claude-sonnet-5-5"

    public let models: [String: ModelPrice]
    public let webSearchPerThousand: Double
    public let localModelPatterns: [String]
    public let referenceModel: String
    public let aliases: [String: String]
    public let revision: String

    public init(models: [String: ModelPrice], webSearchPerThousand: Double = 10,
                localModelPatterns: [String] = PricingTable.defaultLocalModelPatterns,
                referenceModel: String = PricingTable.defaultReferenceModel, aliases: [String: String] = [:]) {
        var lowered: [String: ModelPrice] = [:]
        for (key, value) in models { lowered[key.lowercased()] = value }
        self.models = lowered
        self.webSearchPerThousand = webSearchPerThousand
        self.localModelPatterns = localModelPatterns
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        self.referenceModel = referenceModel.trimmingCharacters(in: .whitespaces).lowercased()
        var cleaned: [String: String] = [:]
        for (model, target) in aliases {
            let from = model.trimmingCharacters(in: .whitespaces).lowercased()
            let to = target.trimmingCharacters(in: .whitespaces).lowercased()
            if !from.isEmpty, !to.isEmpty, from != to { cleaned[from] = to }
        }
        self.aliases = cleaned
        revision = Self.hash(Document(models: lowered, webSearchPerThousand: webSearchPerThousand),
                             patterns: self.localModelPatterns, reference: self.referenceModel, aliases: cleaned)
    }

    public var pricedModelIDs: [String] { models.keys.sorted() }

    public static func bundled(overrides: Document? = nil,
                               localModelPatterns: [String] = defaultLocalModelPatterns,
                               referenceModel: String = defaultReferenceModel,
                               aliases: [String: String] = [:]) -> PricingTable {
        let bundled = BundledPricing.document
        var models = bundled.models
        for (key, value) in overrides?.models ?? [:] { models[key] = value }
        return PricingTable(models: models,
                            webSearchPerThousand: overrides?.webSearchPerThousand ?? bundled.webSearchPerThousand ?? 10,
                            localModelPatterns: localModelPatterns, referenceModel: referenceModel, aliases: aliases)
    }

    public func isLocal(_ model: String?) -> Bool {
        guard let model = model?.lowercased() else { return false }
        return localModelPatterns.contains { model.contains($0) }
    }

    public func match(_ model: String) -> (id: String, price: ModelPrice)? {
        let lowered = model.lowercased()
        if let target = aliases[lowered] ?? aliases[Self.normalize(lowered)], let hit = direct(target) { return hit }
        return direct(lowered)
    }

    private func direct(_ lowered: String) -> (id: String, price: ModelPrice)? {
        if let price = models[lowered] { return (lowered, price) }
        let normalized = Self.normalize(lowered)
        if let price = models[normalized] { return (normalized, price) }
        var best: (id: String, price: ModelPrice)?
        for (id, price) in models where normalized.hasPrefix(id + "-") {
            let next = normalized[normalized.index(normalized.startIndex, offsetBy: id.count + 1)...].first
            guard let next, !next.isNumber else { continue }
            if id.count > (best?.id.count ?? 0) { best = (id, price) }
        }
        return best
    }

    public func price(model: String?, tokens: TokenCounts, speed: String?) -> PricedUsage {
        let isFast = speed?.lowercased() == "fast"
        if isLocal(model) {
            let reference = models[referenceModel].flatMap { $0.rates(promptTokens: tokens.promptTokens, fast: false) }
            return PricedUsage(costUSD: 0, apiEquivUSD: reference?.cost(tokens), isLocal: true)
        }
        guard let model, let rates = match(model)?.price.rates(promptTokens: tokens.promptTokens, fast: isFast) else {
            return PricedUsage(costUSD: nil, apiEquivUSD: nil, isLocal: false)
        }
        let cost = rates.cost(tokens)
        return PricedUsage(costUSD: cost, apiEquivUSD: cost, isLocal: false)
    }

    static func normalize(_ model: String) -> String {
        var id = model
        if let range = id.range(of: "anthropic.") { id = String(id[range.upperBound...]) }
        if id.hasSuffix("[1m]") { id.removeLast(4) }
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        if let range = id.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) { id.removeSubrange(range) }
        if let range = id.range(of: #"-\d{8}$"#, options: .regularExpression) { id.removeSubrange(range) }
        // Copilot spells Claude versions with dots (`claude-haiku-4.5`).
        if id.hasPrefix("claude-") { id = id.replacingOccurrences(of: ".", with: "-") }
        return id
    }

    private static func hash(_ document: Document, patterns: [String], reference: String,
                             aliases: [String: String]) -> String {
        struct Canonical: Encodable {
            var document: Document
            var localModelPatterns: [String]
            var referenceModel: String
            // Nil (left out of the JSON) without aliases, so adding the field re-priced nobody's ledger.
            var aliases: [String: String]?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Canonical(document: document, localModelPatterns: patterns.sorted(),
                                                  referenceModel: reference,
                                                  aliases: aliases.isEmpty ? nil : aliases))) ?? Data()
        return FNV1a.hex64(data)
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
