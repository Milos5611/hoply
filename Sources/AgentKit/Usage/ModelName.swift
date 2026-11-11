import Foundation

public enum ModelName {
    public enum Family: String, Sendable, CaseIterable {
        case fable, mythos, opus, sonnet, haiku, local, other
    }

    public static func display(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Unknown model" }
        guard let parts = claudeParts(trimmed) else {
            return openAIName(trimmed) ?? titledName(trimmed) ?? lastPathComponent(trimmed)
        }
        let name = parts.family.prefix(1).uppercased() + parts.family.dropFirst()
        return parts.version.isEmpty ? name : "\(name) \(parts.version)"
    }

    public static func family(_ id: String, isLocal: Bool = false) -> Family {
        if isLocal { return .local }
        guard let parts = claudeParts(id.trimmingCharacters(in: .whitespaces)) else { return .other }
        return Family(rawValue: parts.family) ?? .other
    }

    private static func claudeParts(_ id: String) -> (family: String, version: String)? {
        var name = lastPathComponent(id).lowercased()
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if let range = name.range(of: "anthropic.") { name = String(name[range.upperBound...]) }
        guard name.hasPrefix("claude-") else { return nil }
        var tokens = name.dropFirst("claude-".count).split(separator: "-").map(String.init)
        if let last = tokens.last, last.count == 8, last.allSatisfy(\.isNumber) { tokens.removeLast() }
        guard let family = tokens.first, family.allSatisfy(\.isLetter) else { return nil }
        let version = tokens.dropFirst().filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return (family, version)
    }

    private static func openAIName(_ id: String) -> String? {
        let name = lastPathComponent(id).lowercased()
        guard name.hasPrefix("gpt-") else { return nil }
        let tokens = name.dropFirst("gpt-".count).split(separator: "-").map(String.init)
        guard let version = tokens.first, version.first?.isNumber == true,
              version.allSatisfy({ $0.isNumber || $0 == "." || $0.isLetter }) else { return nil }
        let rest = tokens.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return (["GPT-" + version] + rest).joined(separator: " ")
    }

    private static let titledFamilies: Set<String> = ["kimi", "gemini", "grok"]

    private static func titledName(_ id: String) -> String? {
        let tokens = lastPathComponent(id).lowercased().split(separator: "-")
        guard tokens.count > 1, let family = tokens.first, titledFamilies.contains(String(family)) else { return nil }
        return tokens.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func claudeVersion(_ id: String) -> (family: String, version: [Int])? {
        guard let parts = claudeParts(id.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (parts.family, parts.version.split(separator: ".").compactMap { Int($0) })
    }

    private static func lastPathComponent(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}
