import Foundation

public struct FuzzyMatch: Sendable, Equatable {
    public var score: Int
    public var ranges: [Range<Int>]

    public init(score: Int, ranges: [Range<Int>]) {
        self.score = score
        self.ranges = ranges
    }

    public func stringRanges(in text: String) -> [Range<String.Index>] {
        ranges.compactMap { range in
            guard let lower = text.index(text.startIndex, offsetBy: range.lowerBound, limitedBy: text.endIndex),
                  let upper = text.index(lower, offsetBy: range.count, limitedBy: text.endIndex) else { return nil }
            return lower..<upper
        }
    }
}

public struct FuzzyQuery: Sendable, Equatable {
    public let terms: [[Character]]

    public init(_ text: String) {
        terms = text.split(whereSeparator: \.isWhitespace).map { $0.map(FuzzyText.fold) }
    }

    public var isEmpty: Bool { terms.isEmpty }
}

public struct FuzzyText: Sendable, Equatable {
    public static let maxLength = 256

    let folded: [Character]
    let startsWord: [Bool]

    public init(_ text: String) {
        var folded: [Character] = []
        var startsWord: [Bool] = []
        folded.reserveCapacity(min(text.utf8.count, Self.maxLength))
        startsWord.reserveCapacity(folded.capacity)
        var previous: Character?
        for character in text.prefix(Self.maxLength) {
            let isBoundary: Bool
            if let previous {
                isBoundary = Self.isSeparator(previous) && !Self.isSeparator(character)
                    || previous.isLowercase && character.isUppercase
            } else {
                isBoundary = true
            }
            folded.append(Self.fold(character))
            startsWord.append(isBoundary)
            previous = character
        }
        self.folded = folded
        self.startsWord = startsWord
    }

    // One folded Character per input Character, so match offsets index the original string.
    static func fold(_ character: Character) -> Character {
        if let ascii = character.asciiValue {
            return ascii >= 65 && ascii <= 90 ? Character(UnicodeScalar(ascii + 32)) : character
        }
        return String(character).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).first ?? character
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character == "/" || character == "-" || character == "_" || character == "."
            || character == ":"
    }
}

public enum FuzzyMatcher {
    static let matchScore = 16
    static let wordStartBonus = 12
    static let consecutiveBonus = 14
    static let prefixBonus = 8
    static let gapPenalty = 2
    static let maxGapPenalty = 12
    static let maxLateStartPenalty = 8

    public static func match(_ query: String, in text: String) -> FuzzyMatch? {
        match(FuzzyQuery(query), in: FuzzyText(text))
    }

    public static func match(_ query: FuzzyQuery, in text: FuzzyText) -> FuzzyMatch? {
        var score = 0
        var positions: [Int] = []
        for term in query.terms {
            guard let found = match(term: term, in: text) else { return nil }
            score += found.score
            positions.append(contentsOf: found.positions)
        }
        return FuzzyMatch(score: score, ranges: ranges(of: positions))
    }

    static func ranges(of positions: [Int]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for position in Set(positions).sorted() {
            if let last = ranges.last, last.upperBound == position {
                ranges[ranges.count - 1] = last.lowerBound..<(position + 1)
            } else {
                ranges.append(position..<(position + 1))
            }
        }
        return ranges
    }

    static func match(term: [Character], in text: FuzzyText) -> (score: Int, positions: [Int])? {
        let (m, n) = (term.count, text.folded.count)
        guard m > 0, m <= n, isSubsequence(term, of: text.folded) else { return nil }
        let unreachable = Int.min / 2
        var scores = [Int](repeating: unreachable, count: m * n)
        var sources = [Int](repeating: -1, count: m * n)

        for i in 0..<m {
            // Best earlier row-(i-1) match for a gap ending before j: one with a per-character penalty,
            // one with the capped penalty, so a far-away word start still beats a close mid-word hit.
            var decayed = unreachable, decayedAt = -1
            var best = unreachable, bestAt = -1
            for j in i..<n {
                if i > 0, j > 0 {
                    let previous = scores[(i - 1) * n + j - 1]
                    decayed = decayed == unreachable ? unreachable : decayed - gapPenalty
                    if previous > unreachable {
                        if previous >= decayed { (decayed, decayedAt) = (previous, j - 1) }
                        if previous > best { (best, bestAt) = (previous, j - 1) }
                    }
                }
                guard text.folded[j] == term[i] else { continue }
                var own = matchScore + (text.startsWord[j] ? wordStartBonus : 0)
                if i == 0 {
                    scores[j] = own + (j == 0 ? prefixBonus : -min(j, maxLateStartPenalty))
                    continue
                }
                let adjacent = scores[(i - 1) * n + j - 1]
                var from = unreachable, fromAt = -1
                if adjacent > unreachable { (from, fromAt) = (adjacent + consecutiveBonus, j - 1) }
                if decayed > unreachable, decayedAt != j - 1, decayed > from { (from, fromAt) = (decayed, decayedAt) }
                if best > unreachable, bestAt != j - 1, best - maxGapPenalty > from {
                    (from, fromAt) = (best - maxGapPenalty, bestAt)
                }
                guard from > unreachable else { continue }
                own += from
                scores[i * n + j] = own
                sources[i * n + j] = fromAt
            }
        }

        var end = -1, total = unreachable
        for j in (m - 1)..<n where scores[(m - 1) * n + j] > total {
            (total, end) = (scores[(m - 1) * n + j], j)
        }
        guard end >= 0 else { return nil }
        var positions = [Int](repeating: 0, count: m)
        var j = end
        for i in stride(from: m - 1, through: 0, by: -1) {
            positions[i] = j
            j = sources[i * n + j]
        }
        return (total, positions)
    }

    private static func isSubsequence(_ term: [Character], of text: [Character]) -> Bool {
        var index = 0
        for character in text where character == term[index] {
            index += 1
            if index == term.count { return true }
        }
        return false
    }
}
