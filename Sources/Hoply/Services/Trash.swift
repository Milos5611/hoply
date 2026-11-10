import AgentSystem
import AppKit

struct WorkspaceTrash: TrashBin {
    func moveToTrash(_ path: String) async throws {
        // Recycling goes through Finder, which is what records the original place for "Put Back".
        try await NSWorkspace.shared.recycle([URL(fileURLWithPath: path)])
    }
}
