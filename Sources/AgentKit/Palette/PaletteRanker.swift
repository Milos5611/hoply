import Foundation

public struct PaletteQuery: Sendable, Equatable {
    public var text: String
    public var actionsOnly: Bool

    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        actionsOnly = trimmed.hasPrefix(">")
        text = actionsOnly ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    public var isEmpty: Bool { text.isEmpty }
}

public struct PaletteResult: Identifiable, Sendable, Equatable {
    public var item: PaletteItem
    public var score: Double
    public var titleRanges: [Range<Int>]

    public init(item: PaletteItem, score: Double, titleRanges: [Range<Int>] = []) {
        self.item = item
        self.score = score
        self.titleRanges = titleRanges
    }

    public var id: String { item.id }

    public var titleStringRanges: [Range<String.Index>] {
        FuzzyMatch(score: 0, ranges: titleRanges).stringRanges(in: item.title)
    }
}

public struct PaletteRanker: Sendable {
    public static let subtitleWeight = 0.6
    public static let keywordWeight = 0.5
    public static let frecencyBoost = 0.3
    public static let recencyBoost = 0.1
    public static let attentionBoost = 0.1
    public static let recencyHalfLife: TimeInterval = 7 * 86_400

    public var frecency: Frecency

    public init(frecency: Frecency = Frecency()) {
        self.frecency = frecency
    }

    public func rank(_ items: [PaletteItem], query raw: String, now: Date, limit: Int = 50) -> [PaletteResult] {
        let query = PaletteQuery(raw)
        let candidates = query.actionsOnly ? items.filter { $0.kind == .action } : items
        guard limit > 0 else { return [] }
        let fuzzy = FuzzyQuery(query.text)
        if fuzzy.isEmpty {
            return Array(candidates.map { Scored(item: $0, score: frecency.score($0.id, at: now), ranges: []) }
                .sorted(by: Self.browsingOrder)
                .prefix(limit)
                .map(\.result))
        }
        return Array(candidates.compactMap { scored($0, fuzzy, now: now) }
            .sorted(by: Self.searchOrder)
            .prefix(limit)
            .map(\.result))
    }

    private struct Scored {
        var item: PaletteItem
        var score: Double
        var ranges: [Range<Int>]

        var result: PaletteResult { PaletteResult(item: item, score: score, titleRanges: ranges) }
    }

    private func scored(_ item: PaletteItem, _ query: FuzzyQuery, now: Date) -> Scored? {
        let title = FuzzyText(item.title)
        let subtitle = item.subtitle.map(FuzzyText.init)
        let keywords = item.keywords.map(FuzzyText.init)
        var total = 0.0
        var positions: [Int] = []
        for term in query.terms {
            var best: Double?
            if let found = FuzzyMatcher.match(term: term, in: title) {
                best = Double(found.score)
                positions.append(contentsOf: found.positions)
            }
            if let subtitle, let found = FuzzyMatcher.match(term: term, in: subtitle) {
                best = max(best ?? -.infinity, Double(found.score) * Self.subtitleWeight)
            }
            for keyword in keywords {
                if let found = FuzzyMatcher.match(term: term, in: keyword) {
                    best = max(best ?? -.infinity, Double(found.score) * Self.keywordWeight)
                }
            }
            guard let best else { return nil }
            total += best
        }
        let used = frecency.score(item.id, at: now)
        var boost = Self.frecencyBoost * used / (used + 2)
        if let lastActive = item.lastActive {
            boost += Self.recencyBoost * pow(0.5, max(now.timeIntervalSince(lastActive), 0) / Self.recencyHalfLife)
        }
        switch item.attention {
        case .needsUser: boost += Self.attentionBoost
        case .live: boost += Self.attentionBoost / 2
        case .none: break
        }
        return Scored(item: item, score: total * (1 + boost), ranges: FuzzyMatcher.ranges(of: positions))
    }

    private static func searchOrder(_ a: Scored, _ b: Scored) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.item.title.count != b.item.title.count { return a.item.title.count < b.item.title.count }
        return stableOrder(a.item, b.item)
    }

    private static func browsingOrder(_ a: Scored, _ b: Scored) -> Bool {
        let (aNeeds, bNeeds) = (a.item.attention == .needsUser, b.item.attention == .needsUser)
        if aNeeds != bNeeds { return aNeeds }
        if a.score != b.score { return a.score > b.score }
        if a.item.attention != b.item.attention { return a.item.attention > b.item.attention }
        let (aActive, bActive) = (a.item.lastActive ?? .distantPast, b.item.lastActive ?? .distantPast)
        if aActive != bActive { return aActive > bActive }
        return stableOrder(a.item, b.item)
    }

    private static func stableOrder(_ a: PaletteItem, _ b: PaletteItem) -> Bool {
        if a.kind != b.kind { return a.kind.order < b.kind.order }
        if a.title != b.title { return a.title < b.title }
        return a.id < b.id
    }
}
