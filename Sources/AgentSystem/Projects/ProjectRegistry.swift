import AgentKit
import Darwin
import Foundation

public struct LocalProjectFileSystem: ProjectFileSystem, Sendable {
    public init() {}

    public func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func isDirectory(_ path: String) -> Bool { mode(path).map { $0 & S_IFMT == S_IFDIR } ?? false }
    public func isFile(_ path: String) -> Bool { mode(path).map { $0 & S_IFMT == S_IFREG } ?? false }

    public func readText(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), data.count < 64 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func mode(_ path: String) -> mode_t? {
        var info = stat()
        return stat(path, &info) == 0 ? info.st_mode : nil
    }
}

final class ProjectRegistry {
    struct Entry: Equatable {
        var projectID: Int64
        var worktree: String?
    }

    private let resolver: ProjectResolver
    private let fileSystem: any ProjectFileSystem & Sendable
    private var cache: [String: Entry] = [:]

    init(resolver: ProjectResolver, fileSystem: any ProjectFileSystem & Sendable) {
        self.resolver = resolver
        self.fileSystem = fileSystem
    }

    func entry(for cwd: String, db: SQLiteConnection) throws -> Entry {
        if let hit = cache[cwd] { return hit }
        if let mapped = try db.queryOne("SELECT project_id, worktree FROM path_map WHERE cwd = ?", [cwd], {
            Entry(projectID: $0.int64(0), worktree: $0.optionalText(1))
        }) {
            cache[cwd] = mapped
            return mapped
        }
        let resolution = resolver.resolve(cwd: cwd, fileSystem: fileSystem)
        let projectID = try db.queryOne("""
            INSERT INTO projects (root, name, kind) VALUES (?, ?, ?)
            ON CONFLICT(root) DO UPDATE SET root = excluded.root
            RETURNING id
            """, [resolution.root, resolution.name, resolution.kind.rawValue]) { $0.int64(0) } ?? 0
        try db.run("INSERT INTO path_map (cwd, project_id, worktree, origin) VALUES (?, ?, ?, 'auto') ON CONFLICT(cwd) DO NOTHING",
                   [cwd, projectID, resolution.worktree])
        let entry = Entry(projectID: projectID, worktree: resolution.worktree)
        cache[cwd] = entry
        return entry
    }

    func cachedEntry(for cwd: String) -> Entry? {
        cache[cwd]
    }

    func invalidate() {
        cache = [:]
    }
}
