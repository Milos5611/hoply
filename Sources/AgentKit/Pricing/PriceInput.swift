import Foundation

public enum PriceInput {
    public static func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite, value > 0 else { return nil }
        return value
    }

    public static func format(_ value: Double) -> String {
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

public struct ReferenceModelOption: Sendable, Equatable, Identifiable {
    public var id: String
    public var isSavedButUnlisted: Bool
    public var hasNoPrice: Bool

    public init(id: String, isSavedButUnlisted: Bool = false, hasNoPrice: Bool = false) {
        self.id = id
        self.isSavedButUnlisted = isSavedButUnlisted
        self.hasNoPrice = hasNoPrice
    }

    public static func options(priced: [String], saved: String, savedHasPrice: Bool) -> [ReferenceModelOption] {
        var options = priced.map { ReferenceModelOption(id: $0) }
        if !saved.isEmpty, !priced.contains(saved) {
            options.append(ReferenceModelOption(id: saved, isSavedButUnlisted: true, hasNoPrice: !savedHasPrice))
        }
        return options
    }
}
