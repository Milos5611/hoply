import AgentKit
import Foundation

extension GitClient {
    public func worktrees(repository: String) -> [GitWorktree]? {
        guard isAvailable, let output = run(["worktree", "list", "--porcelain", "-z"], in: repository) else { return nil }
        let worktrees = GitWorktree.parse(porcelainZ: output)
        return worktrees.isEmpty ? nil : worktrees
    }

    public func isClean(worktree: String) -> Bool? {
        guard isAvailable else { return nil }
        return run(["status", "--porcelain", "--untracked-files=normal"], in: worktree).map(\.isEmpty)
    }

    public func gitDirectory(worktree: String) -> String? {
        guard isAvailable, let output = run(["rev-parse", "--absolute-git-dir"], in: worktree) else { return nil }
        let path = Self.text(output).trimmingCharacters(in: .newlines)
        return path.isEmpty ? nil : path
    }

    public func defaultBranch(repository: String) -> String? {
        guard isAvailable else { return nil }
        let remotePrefix = "origin/"
        if let output = run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repository) {
            let name = Self.text(output).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix(remotePrefix), name.count > remotePrefix.count {
                return String(name.dropFirst(remotePrefix.count))
            }
        }
        return ["main", "master"].first { exitStatus(["show-ref", "--verify", "--quiet", "refs/heads/\($0)"], in: repository) == 0 }
    }

    public func isMerged(_ ref: String, into branch: String, repository: String) -> Bool? {
        guard isAvailable, !ref.hasPrefix("-") else { return nil }
        let answers = ["refs/heads/\(branch)", "refs/remotes/origin/\(branch)"].map { target -> Bool? in
            switch exitStatus(["merge-base", "--is-ancestor", ref, target], in: repository) {
            case 0: return true
            case 1: return false
            default: return nil
            }
        }
        if answers.contains(true) { return true }
        return answers.contains(false) ? false : nil
    }

    public func isIgnored(_ path: String, repository: String) -> Bool? {
        guard isAvailable else { return nil }
        // check-ignore looks at patterns only; a directory with tracked files in it must never count as ignored.
        guard let tracked = run(["ls-files", "-z", "--", path], in: repository) else { return nil }
        guard tracked.isEmpty else { return false }
        switch exitStatus(["check-ignore", "-q", "--", path], in: repository) {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    @discardableResult
    public func pruneWorktrees(repository: String) -> Bool {
        guard isAvailable else { return false }
        let output = Self.execute(gitPath, ["-c", "core.fsmonitor=false", "worktree", "prune"], directory: repository,
                                  timeout: timeout)
        return output?.status == 0
    }

    private func exitStatus(_ arguments: [String], in directory: String) -> Int32? {
        Self.execute(gitPath, Self.readOnlyOptions + arguments, directory: directory, timeout: timeout)?.status
    }
}
