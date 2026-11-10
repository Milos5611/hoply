import AgentKit
import Darwin
import Foundation

public actor CleanupService {
    private let scanner: CleanupScanner
    private let processes: ProcessScanner
    private let terminator: ProcessTerminator
    private let trash: any TrashBin
    private var tracker = OrphanTracker()
    public private(set) var orphans: [OrphanProcess] = []

    public init(trash: any TrashBin, scanner: CleanupScanner = CleanupScanner(),
                processes: ProcessScanner = ProcessScanner(), terminator: ProcessTerminator = ProcessTerminator()) {
        self.trash = trash
        self.scanner = scanner
        self.processes = processes
        self.terminator = terminator
    }

    @discardableResult
    public func observe(_ snapshot: ProcessSnapshot) -> [OrphanProcess] {
        // A snapshot the tracker cannot judge (the lsof fallback) leaves the last known orphans in place.
        guard snapshot.source == .libproc else { return orphans }
        orphans = tracker.observe(snapshot, uid: getuid(), ownPID: getpid())
        return orphans
    }

    public func scan(inventory: CleanupInventory, activity: CleanupActivity, options: CleanupOptions,
                     now: Date = Date()) async -> CleanupScan {
        await scanner.scan(inventory: inventory, activity: activity, options: options, now: now)
    }

    public func run(_ selection: [CleanupCandidate], inventory: CleanupInventory?, activity: CleanupActivity,
                    options: CleanupOptions, now: Date = Date()) async -> CleanupReport {
        var items: [CleanupReport.Item] = []
        var trashed: [String] = []
        var repositories: Set<String> = []
        let processSnapshot = await freshSnapshot(neededFor: selection)

        for candidate in selection.sorted(by: { Self.order($0.kind) < Self.order($1.kind) }) {
            let outcome: CleanupReport.Outcome
            if let orphan = candidate.orphan {
                outcome = await terminate(orphan, in: processSnapshot)
            } else if candidate.isInside(anyOf: trashed) {
                outcome = .trashed
            } else if let inventory {
                outcome = await moveToTrash(candidate, inventory: inventory, activity: activity, options: options, now: now)
            } else {
                outcome = .skipped([.historyOff])
            }
            if outcome == .trashed, let path = candidate.path {
                trashed.append(path)
                if candidate.kind == .worktree, let root = candidate.project?.root { repositories.insert(root) }
            }
            items.append(CleanupReport.Item(candidate: candidate, outcome: outcome))
        }
        await prune(repositories)
        return CleanupReport(items: items, finishedAt: now)
    }

    private static func order(_ kind: CleanupKind) -> Int {
        CleanupKind.allCases.firstIndex(of: kind) ?? 0
    }

    private func moveToTrash(_ candidate: CleanupCandidate, inventory: CleanupInventory, activity: CleanupActivity,
                             options: CleanupOptions, now: Date) async -> CleanupReport.Outcome {
        guard let fresh = await scanner.refreshed(candidate, inventory: inventory, activity: activity,
                                                  options: options, now: now), fresh.path == candidate.path else {
            return .skipped([.missing])
        }
        guard fresh.isEligible else { return .skipped(fresh.keepReasons) }
        let paths = scanner.trashPaths(for: fresh)
        let trashGuard = await scanner.trashGuard(for: fresh, inventory: inventory)
        guard !paths.isEmpty, paths.allSatisfy(trashGuard.allows) else { return .skipped([.outsideKnownFolders]) }
        do {
            for path in paths { try await trash.moveToTrash(path) }
            return .trashed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func terminate(_ orphan: OrphanProcess, in snapshot: ProcessSnapshot?) async -> CleanupReport.Outcome {
        guard let snapshot, snapshot.source == .libproc else { return .failed("The process list could not be read") }
        switch OrphanStop.decide(orphan.identity, in: snapshot, ownPID: getpid(), uid: getuid()) {
        case .refused(let refusal): return .skipped([.process(refusal)])
        case .allowed(let members):
            let outcome = await terminator.stop(members)
            if outcome.stopped { orphans.removeAll { $0.identity == orphan.identity } }
            switch outcome {
            case .terminated: return .terminated
            case .killed: return .killed
            case .refused(let refusal): return .skipped([.process(refusal)])
            case .failed(let code): return .failed(String(cString: strerror(code)))
            }
        }
    }

    private func freshSnapshot(neededFor selection: [CleanupCandidate]) async -> ProcessSnapshot? {
        guard selection.contains(where: { $0.orphan != nil }) else { return nil }
        let processes = processes
        return await Task.detached(priority: .userInitiated) { processes.scan() }.value
    }

    private func prune(_ repositories: Set<String>) async {
        let git = scanner.git
        await Task.detached(priority: .utility) {
            for repository in repositories.sorted() { git.pruneWorktrees(repository: repository) }
        }.value
    }
}
