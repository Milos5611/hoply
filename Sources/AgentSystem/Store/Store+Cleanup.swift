import AgentKit
import Foundation

extension Store {
    public func logCleanup(_ entries: [CleanupLogEntry]) throws {
        guard !entries.isEmpty else { return }
        try db.transaction {
            for entry in entries {
                try db.run("INSERT INTO cleanup_log (ts, kind, path, bytes, project_id, detail) VALUES (?, ?, ?, ?, ?, ?)",
                           [entry.timestamp.timeIntervalSince1970, entry.kind.rawValue, entry.path, entry.bytes,
                            entry.project?.id, entry.detail])
            }
        }
    }
}
