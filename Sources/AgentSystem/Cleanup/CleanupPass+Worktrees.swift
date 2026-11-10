import AgentKit
import Foundation

extension CleanupPass {
    struct Repository {
        var project: CleanupInventory.Project
        var worktrees: [GitWorktree]
        var defaultBranch: String?
    }

    func repository(_ project: CleanupInventory.Project) -> Repository? {
        guard project.ref.kind == .repo, var listed = git.worktrees(repository: project.ref.root) else { return nil }
        for index in listed.indices { listed[index].path = files.canonical(listed[index].path) }
        return Repository(project: project, worktrees: listed, defaultBranch: git.defaultBranch(repository: project.ref.root))
    }

    func isMain(_ worktree: GitWorktree, in repository: Repository) -> Bool {
        worktree.path == repository.worktrees.first?.path || worktree.path == repository.project.ref.root
    }

    func linkedWorktrees(_ repository: Repository) -> [GitWorktree] {
        repository.worktrees.filter {
            !isMain($0, in: repository) && !$0.isBare && !$0.isPrunable && isReachable($0.path) && files.isDirectory($0.path)
        }
    }

    func worktreeCandidates(in repository: Repository, linked: [GitWorktree]) -> [CleanupCandidate] {
        let listed = Set(repository.worktrees.map(\.path))
        let untracked = repository.project.worktrees.map { files.canonical($0.path) }.filter {
            !listed.contains($0) && $0 != repository.project.ref.root && isReachable($0) && files.isDirectory($0)
        }
        return linked.map { worktreeCandidate($0, in: repository, knownBytes: nil) }
            + Set(untracked).sorted().map { untrackedCandidate($0, in: repository, knownBytes: nil) }
    }

    func refreshedWorktree(_ candidate: CleanupCandidate) -> CleanupCandidate? {
        guard let path = candidate.path, let project = candidate.project.flatMap({ inventory.project($0.id) }),
              isScannable(project), files.isDirectory(path) else { return nil }
        guard let repository = repository(project) else { return kept(candidate, .gitStateUnknown) }
        guard let worktree = repository.worktrees.first(where: { $0.path == path }) else {
            return untrackedCandidate(path, in: repository, knownBytes: candidate.bytes)
        }
        return worktreeCandidate(worktree, in: repository, knownBytes: candidate.bytes)
    }

    private func worktreeCandidate(_ worktree: GitWorktree, in repository: Repository,
                                   knownBytes: Int64?) -> CleanupCandidate {
        let root = repository.project.ref.root
        let adminDirectory = git.gitDirectory(worktree: worktree.path)
        let isMerged = worktree.head.flatMap { head in
            repository.defaultBranch.flatMap { git.isMerged(head, into: $0, repository: root) }
        }
        let activity = [ledgerActivity(worktree.path, in: repository)]
            + (adminDirectory.map { [files.modified($0 + "/index"), files.modified($0 + "/HEAD")] } ?? [])
        let facts = WorktreeFacts(
            isMain: isMain(worktree, in: repository), isLocked: worktree.isLocked,
            isClean: git.isClean(worktree: worktree.path), branch: worktree.branch,
            defaultBranch: repository.defaultBranch, isMerged: isMerged,
            hasLiveSession: self.activity.hasSession(inside: [worktree.path]),
            hasDevServer: self.activity.hasDevServer(inside: [worktree.path]),
            // Without the admin directory the idle time cannot be trusted, whatever the ledger says.
            lastActive: adminDirectory == nil ? nil : activity.compactMap { $0 }.max())
        return CleanupCandidate(kind: .worktree, path: worktree.path, title: (worktree.path as NSString).lastPathComponent,
                                project: repository.project.ref, branch: worktree.branch,
                                bytes: size(of: worktree.path, known: knownBytes), lastActive: facts.lastActive,
                                keepReasons: rules.keepReasons(for: facts, now: now))
    }

    private func untrackedCandidate(_ path: String, in repository: Repository, knownBytes: Int64?) -> CleanupCandidate {
        CleanupCandidate(kind: .worktree, path: path, title: (path as NSString).lastPathComponent,
                         project: repository.project.ref, bytes: size(of: path, known: knownBytes),
                         lastActive: ledgerActivity(path, in: repository),
                         keepReasons: rules.keepReasons(for: WorktreeFacts(isTracked: false), now: now))
    }

    private func ledgerActivity(_ path: String, in repository: Repository) -> Date? {
        repository.project.worktrees.filter { files.canonical($0.path) == path }.compactMap(\.lastActive).max()
    }
}
