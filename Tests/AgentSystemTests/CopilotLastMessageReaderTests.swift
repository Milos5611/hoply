import AgentKit
@testable import AgentSystem
import Foundation
import XCTest

final class CopilotLastMessageReaderTests: XCTestCase {
    private let sessionID = "5e551011-0000-4000-8000-000000000002"

    private func line(_ type: String, _ data: [String: Any], agent: String? = nil) throws -> String {
        var rest: [String: Any] = ["data": data, "id": UUID().uuidString.lowercased(),
                                   "timestamp": "2026-11-16T10:00:00.000Z", "parentId": NSNull()]
        rest["agentId"] = agent
        let json = try JSONSerialization.data(withJSONObject: rest, options: [.sortedKeys, .withoutEscapingSlashes])
        return #"{"type":"\#(type)","# + String(decoding: json.dropFirst(), as: UTF8.self) + "\n"
    }

    private func prompt(agent: String? = nil) throws -> String {
        try line("user.message", ["content": "x", "interactionId": "i1"], agent: agent)
    }

    private func assistant(_ content: String, tools: Bool = false, agent: String? = nil) throws -> String {
        let request: [String: Any] = ["toolCallId": "t1", "name": "bash", "arguments": ["command": "ls"]]
        let requests = tools ? [request] : []
        return try line("assistant.message", ["messageId": "m1", "content": content, "toolRequests": requests,
                                              "reasoningOpaque": String(repeating: "A", count: 12_000)], agent: agent)
    }

    private func other(_ type: String) throws -> String {
        try line(type, ["turnId": "0"])
    }

    private func write(_ lines: [String], in temp: TempDirectory, id: String? = nil) throws -> String {
        try temp.write("copilot/session-state/\(id ?? sessionID)/events.jsonl", lines.joined())
    }

    private func reader(_ temp: TempDirectory) -> CopilotLastMessageReader {
        CopilotLastMessageReader(home: temp.path("copilot"))
    }

    func testNewestAssistantTextOfTheTurnWins() throws {
        let temp = try TempDirectory()
        let path = try write([try prompt(), try assistant("Old answer"), try prompt(), try assistant("Looking"),
                              try assistant("", tools: true), try other("tool.execution_complete"),
                              try assistant("  \nAll tests pass now.\n\n"), try other("assistant.turn_end"),
                              try line("hook.start", ["hookType": "agentStop", "input": ["sessionId": sessionID]])],
                             in: temp)
        XCTAssertEqual(reader(temp).message(transcriptPath: path), "All tests pass now.")
    }

    func testToolOnlyMessagesAreSkipped() throws {
        let temp = try TempDirectory()
        let path = try write([try prompt(), try assistant("Running the tests first."), try assistant("", tools: true),
                              try other("tool.execution_complete"), try assistant(" \n", tools: true),
                              try other("assistant.turn_end")], in: temp)
        XCTAssertEqual(reader(temp).message(transcriptPath: path), "Running the tests first.")
    }

    func testAnOlderTurnsMessageIsNeverShown() throws {
        let temp = try TempDirectory()
        let path = try write([try prompt(), try assistant("Answer to the first prompt"), try prompt(),
                              try assistant("", tools: true), try other("assistant.turn_end")], in: temp)
        XCTAssertNil(reader(temp).message(transcriptPath: path))
    }

    func testSubagentLinesAreSkipped() throws {
        let temp = try TempDirectory()
        let path = try write([try prompt(), try assistant("Delegating the search."),
                              try prompt(agent: "explore-1"), try assistant("Found 3 files", agent: "explore-1"),
                              try other("subagent.completed")], in: temp)
        XCTAssertEqual(reader(temp).message(transcriptPath: path), "Delegating the search.")
    }

    func testMessageIsCappedLikeClaudes() throws {
        let temp = try TempDirectory()
        let whole = try write([try prompt(), try assistant(String(repeating: "x", count: 5000))], in: temp)
        XCTAssertEqual(reader(temp).message(transcriptPath: whole)?.count, 5000)
        let path = try write([try prompt(), try assistant(String(repeating: "y", count: TurnReply.messageLimit + 4000))],
                             in: temp)
        let message = try XCTUnwrap(reader(temp).message(transcriptPath: path))
        XCTAssertEqual(message.count, TurnReply.messageLimit + 1)
        XCTAssertTrue(message.hasSuffix("…"))
    }

    func testHugeLastLineWithinTheBound() throws {
        let temp = try TempDirectory()
        let filler = try (0..<120).map { _ in try assistant("earlier") }
        let huge = try assistant("Done. " + String(repeating: "z", count: 600_000))
        XCTAssertLessThan(huge.utf8.count, CopilotLastMessageReader.tailBytes)
        let path = try write([try prompt()] + filler + [huge, try other("assistant.turn_end")], in: temp)
        XCTAssertGreaterThan(FileTailer.status(of: path)?.size ?? 0, Int64(CopilotLastMessageReader.tailBytes))
        let message = try XCTUnwrap(reader(temp).message(transcriptPath: path))
        XCTAssertTrue(message.hasPrefix("Done. zzz"))
        XCTAssertEqual(message.count, TurnReply.messageLimit + 1)
    }

    func testTailReadsOnlyWholeLinesInTheWindow() throws {
        let temp = try TempDirectory()
        let path = try temp.write("tail.jsonl", "aaaaaaaa\nbbbb\ncccc\npartial")
        func tail(_ maxBytes: Int) -> [String]? {
            CopilotLastMessageReader.tail(of: path, maxBytes: maxBytes)?.map { String(decoding: $0, as: UTF8.self) }
        }
        XCTAssertEqual(tail(100), ["aaaaaaaa", "bbbb", "cccc"], "a line still being written is left out")
        XCTAssertEqual(tail(17), ["bbbb", "cccc"], "the window starts right on a line")
        XCTAssertEqual(tail(19), ["bbbb", "cccc"], "a cut line is dropped")
        XCTAssertEqual(tail(3), [], "a line longer than the window")
        XCTAssertNil(CopilotLastMessageReader.tail(of: temp.path("missing.jsonl")))
        try temp.mkdir("folder.jsonl")
        XCTAssertNil(CopilotLastMessageReader.tail(of: temp.path("folder.jsonl")))
    }

    func testOnlyEventsFilesInsideSessionStateAreRead() throws {
        let temp = try TempDirectory()
        let lines = [try prompt(), try assistant("secret")]
        let inside = try write(lines, in: temp)
        let reader = reader(temp)
        XCTAssertEqual(reader.message(transcriptPath: inside), "secret")

        let outside = try temp.write("outside/events.jsonl", lines.joined())
        let otherHome = try temp.write("other/session-state/\(sessionID)/events.jsonl", lines.joined())
        let notEvents = try temp.write("copilot/session-state/\(sessionID)/notes.jsonl", lines.joined())
        let nested = try temp.write("copilot/session-state/\(sessionID)/sub/events.jsonl", lines.joined())
        let loose = try temp.write("copilot/session-state/events.jsonl", lines.joined())
        let hidden = try temp.write("copilot/session-state/.tmp/events.jsonl", lines.joined())
        for path in [outside, otherHome, notEvents, nested, loose, hidden,
                     temp.path("copilot/session-state/\(sessionID)/../../../outside/events.jsonl"),
                     "copilot/session-state/\(sessionID)/events.jsonl", ""] {
            XCTAssertNil(reader.message(transcriptPath: path), path)
        }

        try temp.mkdir("copilot/session-state/linked")
        try FileManager.default.createSymbolicLink(atPath: temp.path("copilot/session-state/linked/events.jsonl"),
                                                   withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: temp.path("copilot/session-state/folder-link"),
                                                   withDestinationPath: temp.path("outside"))
        XCTAssertNil(reader.message(transcriptPath: temp.path("copilot/session-state/linked/events.jsonl")))
        XCTAssertNil(reader.message(transcriptPath: temp.path("copilot/session-state/folder-link/events.jsonl")))
    }

    func testHomeThroughASymlinkStillReads() throws {
        let temp = try TempDirectory()
        let path = try write([try prompt(), try assistant("via link")], in: temp)
        try FileManager.default.createSymbolicLink(atPath: temp.path("copilot-link"),
                                                   withDestinationPath: temp.path("copilot"))
        let linked = CopilotLastMessageReader(home: temp.path("copilot-link"))
        XCTAssertEqual(linked.message(transcriptPath: path), "via link")
        let throughLink = temp.path("copilot-link/session-state/\(sessionID)/events.jsonl")
        XCTAssertEqual(linked.message(transcriptPath: throughLink), "via link")
    }

    func testMissingFileOrNoAssistantText() throws {
        let temp = try TempDirectory()
        XCTAssertNil(reader(temp).message(transcriptPath: temp.path("copilot/session-state/\(sessionID)/events.jsonl")))
        let empty = try write([], in: temp, id: "empty")
        XCTAssertNil(reader(temp).message(transcriptPath: empty))
        let noText = try write([try prompt(), try other("assistant.turn_start"), "not json\n", "{\"type\":\n"],
                               in: temp, id: "no-text")
        XCTAssertNil(reader(temp).message(transcriptPath: noText))
    }

    func testCompletingFillsOnlyCopilotRepliesWithoutAMessage() throws {
        let temp = try TempDirectory()
        let path = try write([try prompt(), try assistant("Pushed the branch.")], in: temp)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let copilot = TurnReplyRequest(id: "r1", key: SessionKey(source: .copilotCLI, id: sessionID), message: nil,
                                       received: now, transcriptPath: path)
        let completed = reader(temp).completing(copilot)
        XCTAssertEqual(completed.message, "Pushed the branch.")
        XCTAssertEqual(completed.id, "r1")
        XCTAssertEqual(completed.transcriptPath, path)

        let claude = TurnReplyRequest(id: "r2", key: SessionKey(source: .claudeCode, id: "abc"), message: nil,
                                      received: now, transcriptPath: path)
        XCTAssertNil(reader(temp).completing(claude).message)
        let noPath = TurnReplyRequest(key: copilot.key, message: nil, received: now)
        XCTAssertNil(reader(temp).completing(noPath).message)
    }
}
