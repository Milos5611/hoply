import AgentKit
import XCTest

final class OrphanTrackerTests: XCTestCase {
    private let uid: UInt32 = 501
    private let hoplyPID: Int32 = 900

    private func process(_ pid: Int32, parent: Int32 = 1, uid: UInt32 = 501, name: String = "node",
                         _ arguments: [String] = ["node", "server.js"], memoryMB: UInt64? = nil,
                         started: TimeInterval? = nil) -> ScannedProcess {
        ScannedProcess(identity: ProcessIdentity(pid: pid, startedAt: Date(timeIntervalSince1970: started ?? 1_000 + Double(pid))),
                       parentPID: parent, groupID: pid, uid: uid, name: name, executable: "/usr/bin/\(name)",
                       arguments: arguments, cwd: "/r/app", memoryBytes: memoryMB.map { $0 * 1_048_576 })
    }

    private func claude(_ pid: Int32, parent: Int32 = 100) -> ScannedProcess {
        process(pid, parent: parent, name: "claude", ["claude"])
    }

    private var shell: ScannedProcess { process(100, name: "zsh", ["-zsh"]) }
    private var hoply: ScannedProcess { process(hoplyPID, name: "Hoply", ["Hoply"]) }

    private func snapshot(_ processes: [ScannedProcess], source: ProcessSnapshot.Source = .libproc) -> ProcessSnapshot {
        ProcessSnapshot(source: source, processes: processes + [hoply])
    }

    private func observe(_ tracker: inout OrphanTracker, _ processes: [ScannedProcess]) -> [OrphanProcess] {
        tracker.observe(snapshot(processes), uid: uid, ownPID: hoplyPID)
    }

    private var session: [ScannedProcess] {
        [shell, claude(200), process(300, parent: 200, name: "bash", ["bash", "-c", "npm run dev"], memoryMB: 4),
         process(301, parent: 300, memoryMB: 250), process(302, parent: 301, memoryMB: 46)]
    }

    private var orphaned: [ScannedProcess] {
        [shell, process(300, parent: 1, name: "bash", ["bash", "-c", "npm run dev"], memoryMB: 4),
         process(301, parent: 300, memoryMB: 250), process(302, parent: 301, memoryMB: 46)]
    }

    func testNothingWhileTheAgentIsAlive() {
        var tracker = OrphanTracker()
        XCTAssertEqual(observe(&tracker, session), [])
        var reparented = session
        reparented[3].parentPID = 1
        XCTAssertEqual(observe(&tracker, reparented), [], "a daemonised child of a running agent is the agent's business")
    }

    func testFlagsTheTopOfTheTreeOnceTheAgentIsGone() throws {
        var tracker = OrphanTracker()
        _ = observe(&tracker, session)
        let orphans = observe(&tracker, orphaned)
        XCTAssertEqual(orphans.count, 1)
        let orphan = try XCTUnwrap(orphans.first)
        XCTAssertEqual(orphan.identity, orphaned[1].identity)
        XCTAssertEqual(orphan.name, "bash")
        XCTAssertEqual(orphan.cwd, "/r/app")
        XCTAssertEqual(orphan.agent, .claudeCode)
        XCTAssertEqual(orphan.memoryBytes, 300 * 1_048_576)
        XCTAssertEqual(Set(orphan.members), Set(orphaned.dropFirst().map(\.identity)))
        XCTAssertEqual(observe(&tracker, orphaned), orphans, "still reported while it lives")
    }

    func testNeverSeenUnderAnAgentIsNeverFlagged() {
        var tracker = OrphanTracker()
        XCTAssertEqual(observe(&tracker, orphaned), [])
    }

    func testForgetsProcessesThatExitAndIgnoresReusedPids() {
        var tracker = OrphanTracker()
        _ = observe(&tracker, session)
        XCTAssertEqual(observe(&tracker, [shell]), [])
        let reused = process(300, parent: 1, name: "postgres", ["postgres"], started: 9_000)
        XCTAssertEqual(observe(&tracker, [shell, reused]), [], "pid 300 now belongs to an unrelated process")
    }

    func testAReusedAgentPidDoesNotHideOrphans() {
        var tracker = OrphanTracker()
        _ = observe(&tracker, session)
        let newcomer = process(200, parent: 100, name: "vim", ["vim"], started: 9_000)
        XCTAssertEqual(observe(&tracker, orphaned + [newcomer]).map(\.identity.pid), [300])
    }

    func testNeverHoplyAnAgentOrAnotherUsersProcess() {
        var tracker = OrphanTracker()
        let hoplyUnderAgent = process(hoplyPID, parent: 250, name: "Hoply", ["Hoply"])
        let launcher = process(250, parent: 200, name: "swift-run", ["swift-run", "Hoply"])
        let before = ProcessSnapshot(processes: [shell, claude(200), launcher, hoplyUnderAgent,
                                                 process(400, parent: 200, name: "bash", ["bash"]), claude(401, parent: 400),
                                                 process(500, parent: 200, uid: 0)])
        XCTAssertEqual(tracker.observe(before, uid: uid, ownPID: hoplyPID), [])
        var orphanedLauncher = launcher
        orphanedLauncher.parentPID = 1
        let after = ProcessSnapshot(processes: [shell, orphanedLauncher, hoplyUnderAgent,
                                                process(400, parent: 1, name: "bash", ["bash"]), claude(401, parent: 400),
                                                process(500, parent: 1, uid: 0)])
        XCTAssertEqual(tracker.observe(after, uid: uid, ownPID: hoplyPID), [])
    }

    func testAPartialSnapshotChangesNothing() {
        var tracker = OrphanTracker()
        _ = observe(&tracker, session)
        XCTAssertEqual(tracker.observe(snapshot([orphaned[2]], source: .lsof), uid: uid, ownPID: hoplyPID), [])
        XCTAssertEqual(observe(&tracker, orphaned).map(\.identity.pid), [300], "still remembered afterwards")
    }

    func testStopDecision() {
        let top = orphaned[1].identity
        func decide(_ processes: [ScannedProcess], _ identity: ProcessIdentity? = nil) -> OrphanStop.Decision {
            OrphanStop.decide(identity ?? top, in: snapshot(processes), ownPID: hoplyPID, uid: uid)
        }
        XCTAssertEqual(decide(orphaned), .allowed(orphaned.dropFirst().map(\.identity)))
        XCTAssertEqual(decide([shell]), .refused(.processGone))
        XCTAssertEqual(decide(orphaned, ProcessIdentity(pid: 300, startedAt: Date(timeIntervalSince1970: 5))),
                       .refused(.identityChanged))
        XCTAssertEqual(decide(orphaned + [process(303, parent: 302, uid: 0)]), .refused(.notOurUser))
        XCTAssertEqual(decide(orphaned + [claude(303, parent: 302)]), .refused(.includesAgent))
        let hoplyInside = process(hoplyPID, parent: 302, name: "Hoply", ["Hoply"])
        XCTAssertEqual(OrphanStop.decide(top, in: ProcessSnapshot(processes: orphaned + [hoplyInside]), ownPID: hoplyPID,
                                         uid: uid), .refused(.includesHoply))
    }
}
