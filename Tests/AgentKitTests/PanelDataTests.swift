import AgentKit
import Foundation
import XCTest

final class SessionGroupingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func board(_ events: [(String, String?, AgentEvent.Kind, TimeInterval)]) -> SessionBoard {
        var board = SessionBoard()
        for (id, cwd, kind, seconds) in events {
            board.apply(AgentEvent(key: SessionKey(source: .claudeCode, id: id), kind: kind,
                                   time: t0.addingTimeInterval(seconds), cwd: cwd, fromHook: true))
        }
        return board
    }

    func testWaitingFirstThenProjectsWorkingFirst() {
        let board = board([
            ("a", "/r/corestory", .promptSubmitted("one"), 0),
            ("b", "/r/corestory", .promptSubmitted("two"), 10),
            ("b", nil, .turnFinished("done"), 20),
            ("c", "/r/api", .promptSubmitted("three"), 30),
            ("c", nil, .turnFinished(nil), 40),
            ("c", nil, .sessionStarted, 41),
            ("d", "/r/api", .sessionStarted, 50),
            ("e", nil, .promptSubmitted("four"), 5),
        ])
        let grouping = SessionGrouping(sessions: board.ordered)
        XCTAssertEqual(grouping.waiting.map(\.key.id), ["c", "b"])
        XCTAssertEqual(grouping.oldestWaitSince, t0.addingTimeInterval(20))
        XCTAssertEqual(grouping.projects.map(\.name), ["Other", "corestory", "api"])
        XCTAssertEqual(grouping.projects.map(\.id), ["", "/r/corestory", "/r/api"])
        XCTAssertEqual(grouping.projects[1].sessions.map(\.key.id), ["a"])
        XCTAssertEqual(grouping.projects[2].lastActivity, t0.addingTimeInterval(50))
    }

    func testResolvedProjectsGroupWorktreesAndSubfoldersTogether() {
        let board = board([
            ("main", "/r/corestory", .promptSubmitted("one"), 0),
            ("tree", "/r/corestory-feature", .promptSubmitted("two"), 10),
            ("sub", "/r/corestory/src/api", .sessionStarted, 20),
            ("api", "/r/api", .sessionStarted, 30),
            ("none", nil, .sessionStarted, 40),
        ])
        let corestory = ProjectRef(id: 7, root: "/r/corestory", name: "corestory", kind: .repo)
        let resolved = ["/r/corestory": corestory, "/r/corestory-feature": corestory, "/r/corestory/src/api": corestory]
        let grouping = SessionGrouping(sessions: board.ordered, projects: resolved)
        XCTAssertEqual(grouping.projects.map(\.id), ["project:7", "", "/r/api"])
        let group = grouping.projects[0]
        XCTAssertEqual(group.name, "corestory")
        XCTAssertEqual(group.path, "/r/corestory")
        XCTAssertEqual(group.project, corestory)
        XCTAssertEqual(Set(group.sessions.map(\.key.id)), ["main", "tree", "sub"])
        XCTAssertEqual(group.lastActivity, t0.addingTimeInterval(20))
        XCTAssertEqual(grouping.projects[2].name, "api", "an unresolved cwd still groups on its own")
        XCTAssertNil(grouping.projects[2].project)

        let renamed = ProjectRef(id: 7, root: "/r/corestory", name: "corestory", displayName: "CoreStory Engine", kind: .repo)
        XCTAssertEqual(SessionGrouping(sessions: board.ordered, projects: ["/r/corestory": renamed]).projects
            .first { $0.id == "project:7" }?.name, "CoreStory Engine")
        XCTAssertEqual(SessionGrouping(sessions: board.ordered).projects.count, 5, "no lookup: one group per cwd")
    }

    func testEmpty() {
        let grouping = SessionGrouping(sessions: [])
        XCTAssertTrue(grouping.waiting.isEmpty)
        XCTAssertTrue(grouping.projects.isEmpty)
        XCTAssertNil(grouping.oldestWaitSince)
    }
}

final class RollingSeriesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAddAdvanceAndLateSamples() {
        var series = RollingSeries(bucketLength: 10, capacity: 4, now: t0)
        series.add(at: t0.addingTimeInterval(1))
        series.add(at: t0.addingTimeInterval(9))
        XCTAssertEqual(series.values, [0, 0, 0, 2])
        series.add(at: t0.addingTimeInterval(25))
        XCTAssertEqual(series.values, [0, 2, 0, 1])
        series.add(at: t0.addingTimeInterval(12))
        XCTAssertEqual(series.values, [0, 2, 1, 1])
        series.add(at: t0.addingTimeInterval(-100))
        XCTAssertEqual(series.values, [0, 2, 1, 1])
    }

    func testLongGapClearsEverything() {
        var series = RollingSeries(bucketLength: 10, capacity: 3, now: t0)
        series.add(5, at: t0)
        series.advance(to: t0.addingTimeInterval(1_000))
        XCTAssertEqual(series.values, [0, 0, 0])
        series.add(at: t0.addingTimeInterval(1_001))
        XCTAssertEqual(series.values, [0, 0, 1])
    }

    func testRecordMax() {
        var series = RollingSeries(bucketLength: 10, capacity: 2, now: t0)
        series.recordMax(40, at: t0.addingTimeInterval(1))
        series.recordMax(25, at: t0.addingTimeInterval(2))
        series.recordMax(30, at: t0.addingTimeInterval(11))
        XCTAssertEqual(series.values, [40, 30])
    }
}
