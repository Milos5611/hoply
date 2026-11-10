import AgentKit
import AgentSystem
import Foundation
import XCTest

struct FolderTrash: TrashBin {
    let directory: String

    init(in container: TempDirectory) throws {
        try container.mkdir("trash")
        directory = container.path("trash")
    }

    func moveToTrash(_ path: String) async throws {
        let name = UUID().uuidString + "-" + (path as NSString).lastPathComponent
        try FileManager.default.moveItem(atPath: path, toPath: directory + "/" + name)
    }

    var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).map { String($0.dropFirst(37)) }.sorted()
    }
}

struct CleanupFixture {
    static let cacheBytes = 16 * 1_024

    let repository: TestRepository
    let project: ProjectRef
    let transcripts: String
    let scanner: CleanupScanner
    let options: CleanupOptions
    // Everything the fixture writes carries today's mtime, so "now" sits past every idle and age threshold.
    let now = Date().addingTimeInterval(120 * 86_400)

    init(includeNodeModules: Bool = false) throws {
        repository = try TestRepository()
        project = ProjectRef(id: 1, root: repository.root, name: "app", kind: .repo)
        try repository.container.mkdir("claude/projects")
        transcripts = CleanupFiles().canonical(repository.container.path("claude/projects"))
        scanner = CleanupScanner(homeDirectory: repository.container.url.path)
        options = CleanupOptions(thresholds: CleanupRules.Thresholds(cacheMinimumBytes: 4 * 1_024,
                                                                     includeNodeModules: includeNodeModules))
    }

    func inventory(worktrees: [String] = [], cursors: [String: FileCursor] = [:],
                   lastActive: Date? = Date()) -> CleanupInventory {
        CleanupInventory(projects: [CleanupInventory.Project(ref: project, lastActive: lastActive,
                                                             worktrees: worktrees.map { .init(path: $0) })],
                         transcriptsDirectory: transcripts, transcriptCursors: cursors)
    }

    func scan(_ inventory: CleanupInventory? = nil, activity: CleanupActivity = CleanupActivity(),
              now: Date? = nil) async -> CleanupScan {
        await scanner.scan(inventory: inventory ?? self.inventory(), activity: activity, options: options,
                           now: now ?? self.now)
    }

    @discardableResult
    func writeCache(_ relative: String, in directory: String? = nil, bytes: Int = CleanupFixture.cacheBytes) throws -> String {
        let base = directory ?? repository.root
        try repository.write(relative + "/chunk.bin", String(repeating: "x", count: bytes), in: base)
        return base + "/" + relative
    }

    func writeTranscript(_ relative: String, _ text: String = "{}\n") throws -> String {
        let path = transcripts + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    func ingested(_ paths: [String], short: Int64 = 0) -> [String: FileCursor] {
        var cursors: [String: FileCursor] = [:]
        for path in paths {
            guard let stat = FileTailer.status(of: path) else { continue }
            cursors[path] = FileCursor(inode: stat.inode, size: stat.size, offset: stat.size - short, headHash: 0)
        }
        return cursors
    }
}

extension CleanupScan {
    func candidate(_ path: String) -> CleanupCandidate? {
        candidates.first { $0.path == path }
    }
}
