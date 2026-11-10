import Foundation

public struct GitDiffStat: Sendable, Equatable, Hashable {
    public var filesChanged: Int
    public var added: Int
    public var removed: Int
    public var untracked: Int

    public init(filesChanged: Int = 0, added: Int = 0, removed: Int = 0, untracked: Int = 0) {
        self.filesChanged = filesChanged
        self.added = added
        self.removed = removed
        self.untracked = untracked
    }

    public var isClean: Bool { filesChanged == 0 && added == 0 && removed == 0 && untracked == 0 }

    public init?(shortstat: String) {
        self.init()
        let line = shortstat.trimmingCharacters(in: .whitespacesAndNewlines)
        // git prints nothing for a clean tree and leaves out the parts that are zero.
        guard !line.isEmpty else { return }
        var matched = false
        for part in line.split(separator: ",") {
            let fields = part.split(separator: " ")
            guard fields.count >= 2, let count = Int(fields[0]) else { return nil }
            if fields[1].hasPrefix("file") {
                filesChanged = count
            } else if fields[1].hasPrefix("insertion") {
                added = count
            } else if fields[1].hasPrefix("deletion") {
                removed = count
            } else {
                return nil
            }
            matched = true
        }
        guard matched else { return nil }
    }

    public static func entryCount(nulSeparated output: Data) -> Int {
        output.split(separator: 0, omittingEmptySubsequences: true).count
    }
}
