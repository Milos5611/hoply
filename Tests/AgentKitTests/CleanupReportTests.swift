import XCTest
@testable import AgentKit

final class CleanupReportTests: XCTestCase {
    private let project = ProjectRef(id: 3, root: "/r/app", name: "app", kind: .repo)
    private let megabyte: Int64 = 1_048_576

    private func item(_ kind: CleanupKind, _ path: String, megabytes: Int64, branch: String? = nil,
                      keep: [CleanupKeepReason] = []) -> CleanupCandidate {
        CleanupCandidate(kind: kind, path: path, title: "Next.js build", project: project, branch: branch,
                         bytes: megabytes * megabyte, keepReasons: keep)
    }

    private var orphan: CleanupCandidate {
        let identity = ProcessIdentity(pid: 42, startedAt: Date(timeIntervalSince1970: 1_000))
        return CleanupCandidate(orphan: OrphanProcess(identity: identity, name: "node", cwd: "/r/app",
                                                      memoryBytes: 300 * 1_048_576, agent: .claudeCode, members: [identity]))
    }

    func testCandidateIdentityAndEligibility() {
        let cache = item(.buildCache, "/r/app/.next", megabytes: 80)
        XCTAssertEqual(cache.id, "build-cache:/r/app/.next")
        XCTAssertTrue(cache.isEligible)
        XCTAssertFalse(item(.worktree, "/r/app-x", megabytes: 1, keep: [.locked]).isEligible)
        XCTAssertEqual(orphan.id, "orphan-process:42:1000000000")
        XCTAssertNil(orphan.path)
        XCTAssertEqual(orphan.title, "node")
    }

    func testReclaimableBytesCountEligiblePathsOnce() {
        let scan = CleanupScan(candidates: [
            item(.worktree, "/r/app-x", megabytes: 500),
            item(.buildCache, "/r/app-x/.next", megabytes: 200),
            item(.buildCache, "/r/app/.next", megabytes: 80),
            item(.buildCache, "/r/app/.turbo", megabytes: 900, keep: [.sessionRunning]),
            orphan,
        ])
        XCTAssertEqual(scan.reclaimableBytes, 580 * megabyte)
        XCTAssertEqual(scan.eligible.count, 4)
    }

    func testReportSummarisesOutcomesAndLogsWhatLeft() {
        let finished = Date(timeIntervalSince1970: 1_800_000_000)
        let report = CleanupReport(items: [
            .init(candidate: item(.worktree, "/r/app-x", megabytes: 500, branch: "feature/x"), outcome: .trashed),
            .init(candidate: item(.buildCache, "/r/app-x/.next", megabytes: 200), outcome: .trashed),
            .init(candidate: item(.buildCache, "/r/app/.next", megabytes: 80), outcome: .skipped([.devServerRunning])),
            .init(candidate: item(.transcript, "/c/projects/p/s.jsonl", megabytes: 3), outcome: .failed("Disk full")),
            .init(candidate: orphan, outcome: .killed),
        ], finishedAt: finished)

        XCTAssertEqual(report.removed.count, 3)
        XCTAssertEqual(report.skipped.map(\.id), ["build-cache:/r/app/.next"])
        XCTAssertEqual(report.failed.map(\.id), ["transcript:/c/projects/p/s.jsonl"])
        XCTAssertEqual(report.bytesFreed, 500 * megabyte)
        XCTAssertEqual(report.logEntries, [
            CleanupLogEntry(timestamp: finished, kind: .worktree, path: "/r/app-x", bytes: 500 * megabyte, project: project,
                            detail: "feature/x"),
            CleanupLogEntry(timestamp: finished, kind: .orphanProcess, path: "/r/app", detail: "node · pid 42 · killed"),
        ])
    }
}
