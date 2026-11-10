import AgentKit
import AgentSystem
import Foundation
import XCTest

final class StateSpansStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_000)
    private let key = SessionKey(source: .claudeCode, id: "s1")
    private let other = SessionKey(source: .qwenCode, id: "q1")

    private func open(_ directory: TempDirectory) throws -> (Store, StoreReader) {
        let path = directory.path("hoply.sqlite")
        return (try Store(path: path, resolver: ProjectResolver(home: "/Users/dev")), try StoreReader(path: path))
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func span(_ state: SessionState, _ start: TimeInterval, _ end: TimeInterval?) -> StateSpan {
        StateSpan(state: state, start: at(start), end: end.map(at))
    }

    private func play(_ board: inout SessionBoard, _ key: SessionKey, _ steps: [(AgentEvent.Kind, TimeInterval)]) -> [StateChange] {
        steps.compactMap { kind, seconds in
            board.apply(AgentEvent(key: key, kind: kind, time: at(seconds), fromHook: true))
        }
    }

    func testEachStateBecomesASpanAndEndingClosesTheLast() async throws {
        let (store, reader) = try open(try TempDirectory())
        var board = SessionBoard()
        let changes = play(&board, key, [
            (.sessionStarted, 0), (.promptSubmitted("x"), 10), (.toolStarted("Bash"), 20), (.toolFinished("Bash"), 25),
            (.needsPermission("Allow Bash?"), 40), (.toolStarted("Bash"), 70), (.turnFinished(nil), 100),
        ])
        XCTAssertEqual(changes.count, 5, "tool events inside a working stretch change nothing")
        try await store.recordStateChanges(Array(changes.prefix(2)), now: at(10))
        try await store.recordStateChanges(Array(changes.dropFirst(2)), now: at(100))
        var spans = try await reader.stateSpans(of: key)
        XCTAssertEqual(spans, [span(.idle, 0, 10), span(.working, 10, 40), span(.needsPermission, 40, 70),
                               span(.working, 70, 100), span(.yourTurn, 100, nil)])
        XCTAssertEqual(StateSpan.timeInState(spans, now: at(130)),
                       [.idle: 10, .working: 60, .needsPermission: 30, .yourTurn: 30])

        try await store.recordStateChanges(play(&board, key, [(.sessionEnded("exit"), 160)]), now: at(160))
        spans = try await reader.stateSpans(of: key)
        XCTAssertEqual(spans.last, span(.yourTurn, 100, 160))
        XCTAssertEqual(spans.count, 5, "ended is the close of the last span, not a span of its own")
        let nothing = try await reader.stateSpans(of: other)
        XCTAssertEqual(nothing, [])
    }

    func testABlipShorterThanASecondIsAbsorbed() async throws {
        let (store, reader) = try open(try TempDirectory())
        var board = SessionBoard()
        let changes = play(&board, key, [
            (.promptSubmitted("x"), 0), (.needsPermission("Allow?"), 30), (.toolStarted("Bash"), 30.4),
            (.turnFinished(nil), 60),
        ])
        XCTAssertEqual(changes.count, 4)
        try await store.recordStateChanges(changes, now: at(60))
        let raw = try await reader.stateSpans(of: key, coalesced: false)
        XCTAssertEqual(raw, [span(.working, 0, 30), span(.working, 30, 60), span(.yourTurn, 60, nil)])
        let joined = try await reader.stateSpans(of: key)
        XCTAssertEqual(joined, [span(.working, 0, 60), span(.yourTurn, 60, nil)])
    }

    func testDroppedSessionsAndQuitCloseTheirSpans() async throws {
        let (store, reader) = try open(try TempDirectory())
        var board = SessionBoard()
        try await store.recordStateChanges(play(&board, key, [(.promptSubmitted("x"), 0)])
                                           + play(&board, other, [(.promptSubmitted("y"), 5)]), now: at(5))
        try await store.closeStateSpans(for: [key], at: at(50))
        try await store.closeStateSpans(for: [key], at: at(90))
        let dropped = try await reader.stateSpans(of: key)
        XCTAssertEqual(dropped, [span(.working, 0, 50)])
        let stillOpen = try await reader.stateSpans(of: other)
        XCTAssertEqual(stillOpen, [span(.working, 5, nil)])

        try await store.closeAllStateSpans(at: at(120))
        let closed = try await reader.stateSpans(of: other)
        XCTAssertEqual(closed, [span(.working, 5, 120)])
    }

    func testAnOpenSpanFromAnEarlierRunIsClosedAtTheLastSignOfLife() async throws {
        let directory = try TempDirectory()
        var (store, reader) = try open(directory)
        var board = SessionBoard()
        try await store.recordStateChanges(play(&board, key, [(.promptSubmitted("x"), 0), (.turnFinished(nil), 40)]),
                                           now: at(40))
        try await store.recordStateChanges(play(&board, other, [(.promptSubmitted("y"), 90)]), now: at(90))
        try await store.recordLimitSamples([LimitSample(kind: .fiveHour, ts: at(300), utilization: 10, resetsAt: nil)])

        (store, reader) = try open(directory)
        var spans = try await reader.stateSpans(of: key)
        XCTAssertEqual(spans, [span(.working, 0, 40), span(.yourTurn, 40, 300)],
                       "closed where the ledger last shows Hoply running, not left to grow")
        let orphan = try await reader.stateSpans(of: other)
        XCTAssertEqual(orphan, [span(.working, 90, 300)])

        // The session is still on the board after a ledger reopen: its span carries on as one row.
        try await store.trackStateSpans(of: Array(board.sessions.values))
        try await store.trackStateSpans(of: Array(board.sessions.values))
        spans = try await reader.stateSpans(of: key, coalesced: false)
        XCTAssertEqual(spans, [span(.working, 0, 40), span(.yourTurn, 40, nil)])
        try await store.recordStateChanges(play(&board, key, [(.promptSubmitted("again"), 400)]), now: at(400))
        spans = try await reader.stateSpans(of: key)
        XCTAssertEqual(spans, [span(.working, 0, 40), span(.yourTurn, 40, 400), span(.working, 400, nil)])
    }

    func testAChangeForASessionTheStoreNeverSawClosesWhatWasLeftOpen() async throws {
        let directory = try TempDirectory()
        var (store, reader) = try open(directory)
        var board = SessionBoard()
        try await store.recordStateChanges(play(&board, key, [(.promptSubmitted("x"), 0)]), now: at(0))
        (store, reader) = try open(directory)
        try await store.recordStateChanges(play(&board, key, [(.turnFinished(nil), 70)]), now: at(70))
        let spans = try await reader.stateSpans(of: key)
        XCTAssertEqual(spans, [span(.working, 0, 0), span(.yourTurn, 70, nil)])
    }

    func testOldSpansRollOffAfterThirtyDays() async throws {
        let (store, reader) = try open(try TempDirectory())
        var board = SessionBoard()
        try await store.recordStateChanges(play(&board, key, [(.promptSubmitted("x"), 0), (.turnFinished(nil), 60),
                                                              (.sessionEnded(nil), 120)]), now: at(120))
        try await store.recordStateChanges(play(&board, other, [(.promptSubmitted("y"), 0)]), now: at(120))
        let day: TimeInterval = 86_400
        let early = try await store.pruneStateSpans(now: at(29 * day))
        XCTAssertEqual(early, 0)
        let removed = try await store.pruneStateSpans(now: at(30 * day + 100))
        XCTAssertEqual(removed, 1, "only the span that ended more than 30 days ago")
        let kept = try await reader.stateSpans(of: key)
        XCTAssertEqual(kept, [span(.yourTurn, 60, 120)])
        let open = try await reader.stateSpans(of: other)
        XCTAssertEqual(open, [span(.working, 0, nil)], "an open span is never pruned")

        // A day after the last prune, recording prunes on its own.
        try await store.recordStateChanges(play(&board, other, [(.turnFinished(nil), 31 * day + 200)]),
                                           now: at(31 * day + 200))
        let gone = try await reader.stateSpans(of: key)
        XCTAssertEqual(gone, [])
    }
}
