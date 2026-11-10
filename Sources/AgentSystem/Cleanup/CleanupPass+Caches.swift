import AgentKit
import Foundation

extension CleanupPass {
    static let cacheWalkDepth = 3

    func cacheCandidates(for project: CleanupInventory.Project, roots: [String]) -> [CleanupCandidate] {
        let otherRoots = Set(inventory.projects.map(\.ref.root)).subtracting([project.ref.root])
        var found: [String: BuildCache] = [:]
        for root in roots { findCaches(in: root, depth: 1, skipping: otherRoots, into: &found) }
        return found.keys.sorted().compactMap { path in
            found[path].map { cacheCandidate(path, $0, project: project, roots: roots, knownBytes: nil) }
        }
    }

    func refreshedCache(_ candidate: CleanupCandidate) -> CleanupCandidate? {
        guard let path = candidate.path, let project = candidate.project.flatMap({ inventory.project($0.id) }),
              isScannable(project), isReachable(path), files.isDirectory(path),
              let cache = match(path) else { return nil }
        let linked = repository(project).map(linkedWorktrees) ?? []
        return cacheCandidate(path, cache, project: project, roots: [project.ref.root] + linked.map(\.path),
                              knownBytes: candidate.bytes)
    }

    private func match(_ path: String) -> BuildCache? {
        let parent = (path as NSString).deletingLastPathComponent
        return BuildCache.match(directoryName: (path as NSString).lastPathComponent,
                                includeNodeModules: rules.thresholds.includeNodeModules) {
            files.exists(parent + "/" + $0)
        }
    }

    private func findCaches(in directory: String, depth: Int, skipping otherRoots: Set<String>,
                            into found: inout [String: BuildCache]) {
        for name in files.entries(of: directory) {
            let path = directory + "/" + name
            guard files.isDirectory(path) else { continue }
            if let cache = match(path) {
                found[path] = cache
                continue
            }
            // A nested repository, linked worktree or other project answers for its own caches.
            guard depth < Self.cacheWalkDepth, BuildCache.isWalkable(directoryName: name),
                  !files.exists(path + "/.git"), !otherRoots.contains(path) else { continue }
            findCaches(in: path, depth: depth + 1, skipping: otherRoots, into: &found)
        }
    }

    private func cacheCandidate(_ path: String, _ cache: BuildCache, project: CleanupInventory.Project,
                                roots: [String], knownBytes: Int64?) -> CleanupCandidate {
        let bytes = size(of: path, known: knownBytes)
        let facts = CacheFacts(bytes: bytes, ignoreState: ignoreState(of: path, in: project),
                               hasLiveSession: activity.hasSession(inside: roots),
                               hasDevServer: activity.hasDevServer(inside: roots),
                               projectLastActive: project.latestActivity)
        return CleanupCandidate(kind: .buildCache, path: path, title: cache.label, project: project.ref, bytes: bytes,
                                lastActive: project.latestActivity, keepReasons: rules.keepReasons(for: facts, now: now))
    }

    private func ignoreState(of path: String, in project: CleanupInventory.Project) -> CacheFacts.IgnoreState {
        guard project.ref.kind == .repo else { return .notInRepository }
        switch git.isIgnored(path, repository: (path as NSString).deletingLastPathComponent) {
        case true?: return .ignored
        case false?: return .notIgnored
        case nil: return .unknown
        }
    }
}
