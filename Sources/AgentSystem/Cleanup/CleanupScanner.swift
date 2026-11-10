import AgentKit
import Foundation

public struct CleanupScanner: Sendable {
    public var git: GitClient
    public var sizer: DirectorySizer
    public var files: CleanupFiles
    public var homeDirectory: String

    public init(git: GitClient = GitClient(), sizer: DirectorySizer = DirectorySizer(), files: CleanupFiles = CleanupFiles(),
                homeDirectory: String = NSHomeDirectory()) {
        self.git = git
        self.sizer = sizer
        self.files = files
        self.homeDirectory = homeDirectory
    }

    @concurrent
    public func scan(inventory: CleanupInventory, activity: CleanupActivity, options: CleanupOptions,
                     now: Date = Date()) async -> CleanupScan {
        let started = Date()
        let pass = pass(inventory: inventory, activity: activity, options: options, now: now)
        var candidates: [CleanupCandidate] = []
        for project in inventory.projects where pass.isScannable(project) {
            if Task.isCancelled { break }
            candidates += pass.candidates(for: project)
        }
        if !Task.isCancelled { candidates += pass.transcriptCandidates() }
        return CleanupScan(candidates: candidates, scannedAt: now, duration: Date().timeIntervalSince(started))
    }

    @concurrent
    public func refreshed(_ candidate: CleanupCandidate, inventory: CleanupInventory, activity: CleanupActivity,
                          options: CleanupOptions, now: Date = Date()) async -> CleanupCandidate? {
        let pass = pass(inventory: inventory, activity: activity, options: options, now: now)
        switch candidate.kind {
        case .worktree: return pass.refreshedWorktree(candidate)
        case .buildCache: return pass.refreshedCache(candidate)
        case .transcript: return pass.refreshedTranscript(candidate)
        case .orphanProcess: return nil
        }
    }

    @concurrent
    public func trashGuard(for candidate: CleanupCandidate, inventory: CleanupInventory) async -> TrashGuard {
        let listed = candidate.project.flatMap { inventory.project($0.id) }
            .flatMap { git.worktrees(repository: $0.ref.root) } ?? []
        return TrashGuard(home: files.canonical(homeDirectory), projectRoots: inventory.projects.map(\.ref.root),
                          worktrees: inventory.projects.flatMap(\.worktrees).map(\.path)
                              + listed.dropFirst().map { files.canonical($0.path) },
                          transcriptsDirectory: inventory.transcriptsDirectory)
    }

    public func trashPaths(for candidate: CleanupCandidate) -> [String] {
        guard let path = candidate.path else { return [] }
        guard candidate.kind == .transcript, let folder = CleanupPass.sessionFolder(ofTranscript: path),
              files.isDirectory(folder) else { return [path] }
        return [path, folder]
    }

    private func pass(inventory: CleanupInventory, activity: CleanupActivity, options: CleanupOptions,
                      now: Date) -> CleanupPass {
        CleanupPass(git: git, sizer: sizer, files: files, home: files.canonical(homeDirectory), inventory: inventory,
                    activity: activity.mapped(files.canonical), rules: CleanupRules(thresholds: options.thresholds),
                    includesProtectedFolders: options.includesProtectedFolders, now: now)
    }
}

struct CleanupPass {
    let git: GitClient
    let sizer: DirectorySizer
    let files: CleanupFiles
    let home: String
    let inventory: CleanupInventory
    let activity: CleanupActivity
    let rules: CleanupRules
    let includesProtectedFolders: Bool
    let now: Date

    func isReachable(_ path: String) -> Bool {
        includesProtectedFolders || !CleanupRules.isPrivacyProtected(path, home: home)
    }

    func isScannable(_ project: CleanupInventory.Project) -> Bool {
        let kind = project.ref.kind
        return (kind == .repo || kind == .folder) && isReachable(project.ref.root) && files.isDirectory(project.ref.root)
    }

    func candidates(for project: CleanupInventory.Project) -> [CleanupCandidate] {
        let repository = repository(project)
        let linked = repository.map(linkedWorktrees) ?? []
        let worktrees = repository.map { worktreeCandidates(in: $0, linked: linked) } ?? []
        return worktrees + cacheCandidates(for: project, roots: [project.ref.root] + linked.map(\.path))
    }

    func size(of path: String, known: Int64?) -> Int64 {
        known ?? sizer.allocatedSize(of: path) ?? 0
    }

    func kept(_ candidate: CleanupCandidate, _ reason: CleanupKeepReason) -> CleanupCandidate {
        var candidate = candidate
        candidate.keepReasons = [reason]
        return candidate
    }
}
