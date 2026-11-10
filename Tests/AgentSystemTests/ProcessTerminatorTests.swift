import AgentKit
import AgentSystem
import Foundation
import XCTest

final class ProcessTerminatorTests: XCTestCase {
    private func target(_ child: SpawnedProcess) throws -> DevServerStop.Target {
        XCTAssertEqual(getpgid(child.pid), child.pid)
        XCTAssertNotEqual(getpgid(child.pid), getpgrp())
        let identity = try XCTUnwrap(ProcessScanner.identity(of: child.pid))
        return DevServerStop.Target(groupID: child.pid, leader: identity, members: [identity])
    }

    private func signal(of status: Int32?) -> Int32? {
        status.map { $0 & 0x7f }
    }

    func testTerminatesTheGroupGracefully() async throws {
        let child = try SpawnedProcess("/bin/sleep", ["60"])
        defer { child.cleanUp() }
        let outcome = await ProcessTerminator(grace: 3).stop(try target(child))
        XCTAssertEqual(outcome, .terminated)
        XCTAssertEqual(signal(of: child.waitForExit()), SIGTERM)
    }

    func testKillsAGroupThatIgnoresTheFirstSignal() async throws {
        let child = try SpawnedProcess("/bin/sh", ["-c", "trap '' TERM; while :; do /bin/sleep 1; done"])
        defer { child.cleanUp() }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        let outcome = await ProcessTerminator(grace: 0.5).stop(try target(child))
        XCTAssertEqual(outcome, .killed)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(signal(of: child.waitForExit()), SIGKILL)
    }

    func testRefusesWhenTheIdentityNoLongerMatches() async throws {
        let child = try SpawnedProcess("/bin/sleep", ["60"])
        defer { child.cleanUp() }
        var stale = try target(child)
        stale.leader.startedAt = stale.leader.startedAt.addingTimeInterval(-5)
        let outcome = await ProcessTerminator(grace: 0.2).stop(stale)
        XCTAssertEqual(outcome, .refused(.identityChanged))
        XCTAssertTrue(child.isRunning)
    }

    func testRefusesAnExitedProcess() async throws {
        let child = try SpawnedProcess("/bin/sleep", ["60"])
        let target = try target(child)
        child.cleanUp()
        let outcome = await ProcessTerminator(grace: 0.2).stop(target)
        XCTAssertEqual(outcome, .refused(.processGone))
    }

    func testRefusesItsOwnGroupAndTargetsWithoutALeader() async throws {
        let own = try XCTUnwrap(ProcessScanner.identity(of: getpgrp()))
        let ownGroup = DevServerStop.Target(groupID: getpgrp(), leader: own, members: [own])
        let first = await ProcessTerminator(grace: 0.2).stop(ownGroup)
        XCTAssertEqual(first, .refused(.noProcessGroup))

        let child = try SpawnedProcess("/bin/sleep", ["60"])
        defer { child.cleanUp() }
        var wrongLeader = try target(child)
        wrongLeader.leader = try XCTUnwrap(ProcessScanner.identity(of: getpid()))
        let second = await ProcessTerminator(grace: 0.2).stop(wrongLeader)
        XCTAssertEqual(second, .refused(.noProcessGroup))
        XCTAssertTrue(child.isRunning)
    }
}
