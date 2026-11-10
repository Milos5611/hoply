import Foundation

public struct Frecency: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var uses: Int
        public var weight: Double
        public var lastUsed: Date

        public init(uses: Int, weight: Double, lastUsed: Date) {
            self.uses = uses
            self.weight = weight
            self.lastUsed = lastUsed
        }

        private enum CodingKeys: String, CodingKey {
            case uses, weight, lastUsed
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uses = try container.decode(Int.self, forKey: .uses)
            weight = try container.decode(Double.self, forKey: .weight)
            lastUsed = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .lastUsed))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(uses, forKey: .uses)
            try container.encode(weight, forKey: .weight)
            try container.encode(lastUsed.timeIntervalSince1970, forKey: .lastUsed)
        }

        var isSane: Bool {
            uses > 0 && weight.isFinite && weight > 0 && lastUsed.timeIntervalSince1970.isFinite
        }
    }

    public static let defaultHalfLife: TimeInterval = 14 * 86_400
    public static let defaultMaxEntries = 200

    public private(set) var entries: [String: Entry]
    public var halfLife: TimeInterval
    public var maxEntries: Int

    public init(entries: [String: Entry] = [:], halfLife: TimeInterval = Frecency.defaultHalfLife,
                maxEntries: Int = Frecency.defaultMaxEntries) {
        self.entries = entries.filter { $0.value.isSane }
        self.halfLife = halfLife > 0 ? halfLife : Frecency.defaultHalfLife
        self.maxEntries = max(maxEntries, 1)
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func record(_ id: String, at time: Date) {
        let earlier = entries[id]
        entries[id] = Entry(uses: (earlier?.uses ?? 0) + 1, weight: score(id, at: time) + 1,
                            lastUsed: max(time, earlier?.lastUsed ?? time))
        prune(at: time)
    }

    public func score(_ id: String, at time: Date) -> Double {
        guard let entry = entries[id] else { return 0 }
        // A clock that moved back must not turn decay into growth.
        let elapsed = max(time.timeIntervalSince(entry.lastUsed), 0)
        return entry.weight * pow(0.5, elapsed / halfLife)
    }

    public mutating func forget(_ id: String) {
        entries[id] = nil
    }

    public mutating func prune(at time: Date) {
        guard entries.count > maxEntries else { return }
        let kept = entries.keys
            .map { (id: $0, score: score($0, at: time)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
            .prefix(maxEntries)
        entries = Dictionary(uniqueKeysWithValues: kept.compactMap { item in entries[item.id].map { (item.id, $0) } })
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    private struct Tolerant: Decodable {
        var entry: Entry?

        init(from decoder: any Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = container.lenient([String: Tolerant].self, .entries) ?? [:]
        self.init(entries: decoded.compactMapValues(\.entry))
        prune(at: entries.values.map(\.lastUsed).max() ?? Date(timeIntervalSince1970: 0))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }

    public static func decode(_ data: Data?) -> Frecency {
        guard let data, let frecency = try? JSONDecoder().decode(Frecency.self, from: data) else { return Frecency() }
        return frecency
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
