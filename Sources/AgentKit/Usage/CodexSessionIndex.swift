import Foundation

public enum CodexSessionIndex {
    public static let titleRank = ClaudeTitleKind.custom.rawValue

    // The last line for an id wins, and an empty name clears it, so it is kept rather than skipped.
    @discardableResult
    public static func apply<Lines: Sequence>(lines: Lines, to names: inout [String: String]) -> Set<String>
    where Lines.Element == Data {
        var touched = Set<String>()
        for line in lines {
            guard let entry = try? decoder.decode(Entry.self, from: line), !entry.id.isEmpty else { continue }
            let name = entry.threadName.trimmingCharacters(in: .whitespacesAndNewlines)
            if names[entry.id] != name { touched.insert(entry.id) }
            names[entry.id] = name
        }
        return touched
    }

    public static func titles(_ names: [String: String], ids: Set<String>? = nil) -> [String: String] {
        names.filter { !$0.value.isEmpty && (ids?.contains($0.key) ?? true) }
    }

    private static let decoder = JSONDecoder()

    struct Entry: Decodable {
        var id: String
        var threadName: String

        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
        }
    }
}
