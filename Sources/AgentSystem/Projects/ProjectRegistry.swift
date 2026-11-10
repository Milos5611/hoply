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

    private struct Auto {
        var projectID: Int64
        var worktree: String?
        var repoAnchor: String?
    }

    private let resolver: ProjectResolver
    let fileSystem: any ProjectFileSystem & Sendable
    private var cache: [String: Entry] = [:]
    private var rules: PathRules?
    private var merges: [Int64: Int64]?
    private var pins: [SessionKey: Int64]?

    init(resolver: ProjectResolver, fileSystem: any ProjectFileSystem & Sendable) {
        self.resolver = resolver
        self.fileSystem = fileSystem
    }

    func entry(for cwd: String, db: SQLiteConnection) throws -> Entry {
        if let hit = cache[cwd] { return hit }
        let auto = try auto(for: cwd, db: db)
        let rules = try loadedRules(db)
        let assigned = rules.isEmpty ? nil : rules.projectID(forRealPath: realPath(cwd), repoAnchor: auto.repoAnchor)
        let entry = Entry(projectID: try merged(assigned ?? auto.projectID, db: db), worktree: auto.worktree)
        cache[cwd] = entry
        return entry
    }

    func realPath(_ path: String) -> String {
        PathRules.standardized(fileSystem.realPath(path) ?? path)
    }

    func merged(_ projectID: Int64, db: SQLiteConnection) throws -> Int64 {
        if merges == nil {
            let rows = try db.query("SELECT id, merged_into FROM projects WHERE merged_into IS NOT NULL") {
                ($0.int64(0), $0.int64(1))
            }
            merges = Dictionary(rows, uniquingKeysWith: { first, _ in first })
        }
        var current = projectID
        var seen: Set<Int64> = [current]
        while let next = merges?[current], seen.insert(next).inserted { current = next }
        return current
    }

    func pin(for key: SessionKey, db: SQLiteConnection) throws -> Int64? {
        if pins == nil {
            let rows = try db.query("""
                SELECT source, id, project_id FROM sessions WHERE project_origin = 'user' AND project_id IS NOT NULL
                """) { row in (AgentSource(rawValue: row.text(0)), row.text(1), row.int64(2)) }
            var loaded: [SessionKey: Int64] = [:]
            for case let (source?, id, projectID) in rows { loaded[SessionKey(source: source, id: id)] = projectID }
            pins = loaded
        }
        return pins?[key]
    }

    private func loadedRules(_ db: SQLiteConnection) throws -> PathRules {
        if let rules { return rules }
        let rows = try db.query("SELECT cwd, project_id FROM path_map WHERE origin = 'user'") {
            PathRules.Rule(path: $0.text(0), projectID: $0.int64(1))
        }
        let loaded = PathRules(rows, exactOnly: [realPath(resolver.home)])
        rules = loaded
        return loaded
    }

    private func auto(for cwd: String, db: SQLiteConnection) throws -> Auto {
        // The stored row is what the folder resolved to when it was first seen; it may be gone from disk by now.
        if let stored = try db.queryOne("""
            SELECT m.project_id, m.worktree, p.root, p.kind FROM path_map m JOIN projects p ON p.id = m.project_id
            WHERE m.cwd = ? AND m.origin = 'auto'
            """, [cwd], { row in
                Auto(projectID: row.int64(0), worktree: row.optionalText(1),
                     repoAnchor: row.text(3) == ProjectKind.repo.rawValue ? row.optionalText(1) ?? row.text(2) : nil)
            }) {
            return stored
        }
        let resolution = resolver.resolve(cwd: cwd, fileSystem: fileSystem)
        let projectID = try db.queryOne("""
            INSERT INTO projects (root, name, kind) VALUES (?, ?, ?)
            ON CONFLICT(root) DO UPDATE SET root = excluded.root
            RETURNING id
            """, [resolution.root, resolution.name, resolution.kind.rawValue]) { $0.int64(0) } ?? 0
        try db.run("INSERT INTO path_map (cwd, project_id, worktree, origin) VALUES (?, ?, ?, 'auto') ON CONFLICT(cwd) DO NOTHING",
                   [cwd, projectID, resolution.worktree])
        return Auto(projectID: projectID, worktree: resolution.worktree,
                    repoAnchor: resolution.kind == .repo ? resolution.worktree ?? resolution.root : nil)
    }

    func cachedEntry(for cwd: String) -> Entry? {
        cache[cwd]
    }

    func invalidate() {
        cache = [:]
        rules = nil
        merges = nil
        pins = nil
    }
}
