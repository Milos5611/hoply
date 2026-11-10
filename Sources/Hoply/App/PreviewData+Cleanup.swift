import AgentKit
import Foundation

extension PreviewData {
    private static let megabyte: Int64 = 1_048_576

    static func cleanupScan(now: Date) -> CleanupScan {
        let home = NSHomeDirectory()
        let fiba = projectRefs[0], backend = projectRefs[1]
        func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        func worktree(_ name: String, branch: String, megabytes: Int64, idle: Double,
                      kept: [CleanupKeepReason] = []) -> CleanupCandidate {
            CleanupCandidate(kind: .worktree, path: "\(home)/Project/fiba.worktrees/\(name)", title: name, project: fiba,
                             branch: branch, bytes: megabytes * megabyte, lastActive: daysAgo(idle), keepReasons: kept)
        }
        func cache(_ label: String, _ path: String, project: ProjectRef, megabytes: Int64, idle: Double,
                   kept: [CleanupKeepReason] = []) -> CleanupCandidate {
            CleanupCandidate(kind: .buildCache, path: "\(project.root)/\(path)", title: label, project: project,
                             bytes: megabytes * megabyte, lastActive: daysAgo(idle), keepReasons: kept)
        }
        func transcript(_ title: String, id: String, megabytes: Int64, age: Double,
                        kept: [CleanupKeepReason] = []) -> CleanupCandidate {
            CleanupCandidate(kind: .transcript, path: "\(home)/.claude/projects/-Users-dev-Project-fiba/\(id).jsonl",
                             title: title, project: fiba, bytes: megabytes * megabyte, lastActive: daysAgo(age),
                             keepReasons: kept)
        }
        return CleanupScan(candidates: [
            worktree("pricing-table", branch: "feature/pricing-table", megabytes: 412, idle: 19),
            worktree("auth-refresh", branch: "fix/auth-refresh", megabytes: 388, idle: 11),
            worktree("landing-hero", branch: "feature/landing-hero", megabytes: 431, idle: 0,
                     kept: [.uncommittedChanges, .sessionRunning]),
            worktree("standings-api", branch: "feature/standings-api", megabytes: 402, idle: 23,
                     kept: [.notMerged(branch: "feature/standings-api", into: "main")]),
            cache("Next.js build", "apps/web/.next", project: backend, megabytes: 1_240, idle: 31),
            cache("Turborepo cache", ".turbo", project: backend, megabytes: 318, idle: 31),
            cache("Next.js build", ".next", project: fiba, megabytes: 986, idle: 0,
                  kept: [.devServerRunning, .recentlyActive(idleDays: 0, requiredDays: 14)]),
            cache("pytest cache", ".pytest_cache", project: backend, megabytes: 3, idle: 31,
                  kept: [.tooSmall(bytes: 3 * megabyte, minimumBytes: 50 * megabyte)]),
            transcript("Migrate standings to the new rule engine", id: "5f1c", megabytes: 14, age: 118),
            transcript("Fix flaky bracket seeding test", id: "a0d2", megabytes: 6, age: 97),
            transcript("Pricing page redesign", id: "pricing", megabytes: 21, age: 2,
                       kept: [.recentlyWritten(ageDays: 2, requiredDays: 90)]),
        ], scannedAt: now.addingTimeInterval(-40), duration: 1.8)
    }

    static func cleanupOrphans(now: Date) -> [OrphanProcess] {
        let identity = ProcessIdentity(pid: 48_211, startedAt: now.addingTimeInterval(-26 * 3_600))
        return [OrphanProcess(identity: identity, name: "node", cwd: "\(NSHomeDirectory())/Project/yasm-backend",
                              memoryBytes: 212 * 1_048_576, agent: .claudeCode, members: [identity])]
    }

    static func cleanupReport(now: Date) -> CleanupReport {
        let candidates = cleanupScan(now: now).candidates
        var changed = candidates[1]
        changed.keepReasons = [.uncommittedChanges]
        return CleanupReport(items: [
            CleanupReport.Item(candidate: candidates[0], outcome: .trashed),
            CleanupReport.Item(candidate: candidates[4], outcome: .trashed),
            CleanupReport.Item(candidate: changed, outcome: .skipped(changed.keepReasons)),
        ], finishedAt: now)
    }

    static func cleanupLog(now: Date) -> [CleanupLogEntry] {
        let fiba = projectRefs[0]
        return [
            CleanupLogEntry(timestamp: now.addingTimeInterval(-6 * 86_400), kind: .worktree,
                            path: "\(NSHomeDirectory())/Project/fiba.worktrees/bracket-view", bytes: 397 * megabyte,
                            project: fiba, detail: "feature/bracket-view"),
            CleanupLogEntry(timestamp: now.addingTimeInterval(-6 * 86_400), kind: .buildCache,
                            path: "\(fiba.root)/apps/admin/.vite", bytes: 84 * megabyte, project: fiba,
                            detail: "Vite cache"),
        ]
    }
}
