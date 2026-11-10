import AgentKit
import Foundation

extension StoreReader {
    public func cleanupProjects() throws -> [CleanupInventory.Project] {
        let worktrees = try db.query("""
            SELECT project_id, worktree, MAX(last_at) FROM (
                SELECT project_id, worktree, last_at FROM sessions
                WHERE worktree IS NOT NULL AND project_id IS NOT NULL
                UNION ALL
                SELECT project_id, worktree, NULL FROM path_map WHERE worktree IS NOT NULL
            ) GROUP BY project_id, worktree ORDER BY worktree
            """) { row in
            (row.int64(0), CleanupInventory.Worktree(path: row.text(1), lastActive: Self.date(row, 2)))
        }
        let byProject = Dictionary(grouping: worktrees, by: \.0).mapValues { $0.map(\.1) }
        return try db.query("""
            SELECT p.id, p.root, p.name, p.display_name, p.kind,
                   max(COALESCE(p.last_active, 0), COALESCE((SELECT MAX(last_at) FROM sessions WHERE project_id = p.id), 0))
            FROM projects p ORDER BY p.root
            """) { row -> CleanupInventory.Project? in
            guard let ref = Self.project(row, from: 0) else { return nil }
            let lastActive = row.double(5)
            return CleanupInventory.Project(ref: ref, lastActive: lastActive > 0 ? Date(timeIntervalSince1970: lastActive) : nil,
                                            worktrees: byProject[ref.id] ?? [])
        }.compactMap { $0 }
    }

    public func transcriptSessions() throws -> [String: CleanupInventory.TranscriptSession] {
        let rows = try db.query("""
            SELECT s.transcript_path, s.title, p.id, p.root, p.name, p.display_name, p.kind
            FROM sessions s LEFT JOIN projects p ON p.id = s.project_id
            WHERE s.source = ? AND s.transcript_path IS NOT NULL
            """, [AgentSource.claudeCode.rawValue]) { row in
            (row.text(0), CleanupInventory.TranscriptSession(title: row.optionalText(1), project: Self.project(row, from: 2)))
        }
        return Dictionary(rows, uniquingKeysWith: { _, last in last })
    }

    public func cleanupLog(limit: Int = 100) throws -> [CleanupLogEntry] {
        try db.query("""
            SELECT l.ts, l.kind, l.path, l.bytes, l.detail, p.id, p.root, p.name, p.display_name, p.kind
            FROM cleanup_log l LEFT JOIN projects p ON p.id = l.project_id
            ORDER BY l.ts DESC, l.id DESC LIMIT ?
            """, [limit]) { row -> CleanupLogEntry? in
            guard let kind = CleanupKind(rawValue: row.text(1)) else { return nil }
            return CleanupLogEntry(timestamp: Date(timeIntervalSince1970: row.double(0)), kind: kind, path: row.text(2),
                                   bytes: row.optionalInt64(3), project: Self.project(row, from: 5),
                                   detail: row.optionalText(4))
        }.compactMap { $0 }
    }

    private static func date(_ row: SQLiteRow, _ column: Int32) -> Date? {
        row.optionalDouble(column).map(Date.init(timeIntervalSince1970:))
    }
}
