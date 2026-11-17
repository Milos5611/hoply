import AgentKit
import AgentSystem
import Foundation
import XCTest

/// A fresh directory under the system temp dir. Left in place afterwards (tests never delete files);
/// the OS clears its temp directory.
struct TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("hoply-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ relative: String) -> String { url.appendingPathComponent(relative).path }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> String {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        return target.path
    }

    func append(_ relative: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url.appendingPathComponent(relative))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(relative), withIntermediateDirectories: true)
    }
}

// The backfill's own updates name the session too; only one after its last proves the later change was reported.
func firstUpdateAfterBackfill(in updates: AsyncStream<IngestUpdate>, touching key: SessionKey,
                              timeout: Duration = .seconds(10)) -> Task<IngestUpdate?, Never> {
    let watcher = Task { () -> IngestUpdate? in
        var backfilled = false
        for await update in updates {
            if !backfilled {
                backfilled = !update.progress.isBackfilling
                continue
            }
            if update.changedSessions.contains(key) { return update }
        }
        return nil
    }
    Task {
        try? await Task.sleep(for: timeout)
        watcher.cancel()
    }
    return watcher
}
