import AgentKit
import Foundation

extension Ledger {
    public func cleanupInventory() async throws -> CleanupInventory {
        let transcripts = ClaudeTranscriptIngester(configDirectory: configuration.claudeConfigDirectory)
        return CleanupInventory(projects: try await reader.cleanupProjects(),
                                transcriptsDirectory: transcripts.projectsDirectory,
                                transcriptCursors: try await store.cursors(source: .claudeCode),
                                transcriptSessions: try await reader.transcriptSessions())
    }

    public func logCleanup(_ entries: [CleanupLogEntry]) async throws {
        try await store.logCleanup(entries)
    }

    public func cleanupLog(limit: Int = 100) async throws -> [CleanupLogEntry] {
        try await reader.cleanupLog(limit: limit)
    }
}
