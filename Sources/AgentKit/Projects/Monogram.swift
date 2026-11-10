import Foundation

public enum Monogram {
    public static let placeholder = "?"

    public static func letters(for title: String) -> String {
        let words = words(in: title)
        guard let first = words.first, let initial = first.first else { return placeholder }
        if initial.isEmojiLike { return String(initial) }
        if words.count == 1 { return (first.count <= 2 ? first : String(initial)).uppercased() }
        let second = words[1].first.flatMap { $0.isEmojiLike ? nil : $0 }
        return (String(initial) + (second.map { String($0) } ?? "")).uppercased()
    }

    public static func paletteIndex(for key: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(FNV1a.hash64(key.utf8) % UInt64(count))
    }

    static func words(in title: String) -> [String] {
        var words: [String] = []
        var current: [Character] = []
        func flush() {
            if !current.isEmpty { words.append(String(current)) }
            current = []
        }
        let characters = Array(title)
        for (index, character) in characters.enumerated() {
            if character.isEmojiLike {
                flush()
                words.append(String(character))
                continue
            }
            guard character.isLetter || character.isNumber else {
                flush()
                continue
            }
            if let previous = current.last {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let camel = previous.isLowercase && character.isUppercase
                // "HTTPServer" splits before the S, not between every capital.
                let acronymEnd = previous.isUppercase && character.isUppercase && (next?.isLowercase ?? false)
                if camel || acronymEnd || previous.isDigit != character.isDigit { flush() }
            }
            current.append(character)
        }
        flush()
        return words
    }
}

private extension Character {
    // `isNumber` is also true for CJK numerals such as 京.
    var isDigit: Bool { isASCII && isNumber }

    var isEmojiLike: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        // Digits, # and * are "emoji" to Unicode but only render as one with a variation selector.
        return scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && unicodeScalars.count > 1
                                                         && !scalar.isASCII)
    }
}
