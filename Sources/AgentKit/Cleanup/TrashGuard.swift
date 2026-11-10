import Foundation

public struct TrashGuard: Sendable, Equatable {
    public var home: String
    public var projectRoots: [String]
    public var worktrees: [String]
    public var transcriptsDirectory: String?

    public init(home: String, projectRoots: [String], worktrees: [String], transcriptsDirectory: String?) {
        self.home = home
        self.projectRoots = projectRoots
        self.worktrees = worktrees
        self.transcriptsDirectory = transcriptsDirectory
    }

    public func allows(_ path: String) -> Bool {
        let path = PathScope.normalized(path)
        let components = path.split(separator: "/")
        guard path.hasPrefix("/"), !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            return false
        }
        let neverTrashed = [home] + projectRoots + [transcriptsDirectory].compactMap { $0 }
        if neverTrashed.contains(where: { PathScope.contains(path, $0) }) { return false }
        if let transcriptsDirectory, PathScope.contains(transcriptsDirectory, path) {
            // <projects>/<project folder>/<session>: the project folders themselves also hold Claude's memory.
            return components.count >= PathScope.normalized(transcriptsDirectory).split(separator: "/").count + 2
        }
        return (projectRoots + worktrees).contains { PathScope.contains($0, path) }
    }
}
