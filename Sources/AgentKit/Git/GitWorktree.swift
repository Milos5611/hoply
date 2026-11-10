import Foundation

public struct GitWorktree: Sendable, Equatable {
    public var path: String
    public var head: String?
    public var branch: String?
    public var isBare: Bool
    public var isDetached: Bool
    public var isLocked: Bool
    public var isPrunable: Bool

    public init(path: String, head: String? = nil, branch: String? = nil, isBare: Bool = false,
                isDetached: Bool = false, isLocked: Bool = false, isPrunable: Bool = false) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }

    public static func parse(porcelainZ output: Data) -> [GitWorktree] {
        var worktrees: [GitWorktree] = []
        var current: GitWorktree?
        // With -z every attribute ends in NUL and an empty attribute ends the record.
        for field in output.split(separator: 0, omittingEmptySubsequences: false) {
            let line = String(decoding: field, as: UTF8.self)
            guard !line.isEmpty else {
                if let finished = current { worktrees.append(finished) }
                current = nil
                continue
            }
            let (key, value) = Self.attribute(line)
            if key == "worktree" {
                if let finished = current { worktrees.append(finished) }
                current = GitWorktree(path: value)
                continue
            }
            switch key {
            case "HEAD": current?.head = value
            case "branch": current?.branch = value.hasPrefix(branchPrefix) ? String(value.dropFirst(branchPrefix.count)) : value
            case "bare": current?.isBare = true
            case "detached": current?.isDetached = true
            case "locked": current?.isLocked = true
            case "prunable": current?.isPrunable = true
            default: break
            }
        }
        if let finished = current { worktrees.append(finished) }
        return worktrees
    }

    private static let branchPrefix = "refs/heads/"

    private static func attribute(_ line: String) -> (key: String, value: String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }
}
