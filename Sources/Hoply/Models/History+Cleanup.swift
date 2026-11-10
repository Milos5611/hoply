import AgentKit
import AgentSystem
import Foundation

extension History {
    func cleanupInventory() async -> CleanupInventory? {
        try? await ledger?.cleanupInventory()
    }

    func logCleanup(_ entries: [CleanupLogEntry]) async {
        try? await ledger?.logCleanup(entries)
    }

    func cleanupLog(limit: Int) async -> [CleanupLogEntry] {
        (try? await ledger?.cleanupLog(limit: limit)) ?? []
    }
}
