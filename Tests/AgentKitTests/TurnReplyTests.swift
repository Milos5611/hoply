import Foundation
import XCTest
@testable import AgentKit

final class TurnReplyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let reply = [TurnReply.header: "1"]

    private func payload(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(try Fixture.hookPayloads("claude_hooks.json")[name], name)
    }

    func testOnlyClaudeCodeStopFromTheReplyHookIsHeld() throws {
        let stop = try payload("Stop")
        let request = try XCTUnwrap(TurnReply.request(source: .claudeCode, eventName: nil, json: stop, headers: reply,
                                                      now: now))
        XCTAssertEqual(request.key, SessionKey(source: .claudeCode, id: "abc123"))
        XCTAssertEqual(request.message, "The test raced the token refresh. I added an await.")
        XCTAssertEqual(request.received, now)
        XCTAssertEqual(TurnReply.request(source: .claudeCode, eventName: "Stop", json: stop, headers: reply)?.key,
                       request.key, "the path's event name works too")

        XCTAssertNil(TurnReply.request(source: .claudeCode, eventName: nil, json: stop, headers: [:]),
                     "the generic hook's curl gives up after 2 s")
        XCTAssertNil(TurnReply.request(source: .claudeCode, eventName: nil, json: stop,
                                       headers: [TurnReply.header: "0"]))
        XCTAssertNil(TurnReply.request(source: .claudeCode, eventName: nil, json: stop,
                                       headers: [PermissionApproval.header: "1"]))
        XCTAssertNil(TurnReply.request(source: .codexCLI, eventName: nil, json: stop, headers: reply))
        XCTAssertNil(TurnReply.request(source: .copilotCLI, eventName: nil, json: stop, headers: reply),
                     "Claude's Stop is not Copilot's agentStop")
        XCTAssertNil(request.transcriptPath, "Claude's message comes in the payload")
        for name in ["SubagentStop", "InternalSubagentStop", "StopFailure", "PermissionRequest", "SessionEnd"] {
            XCTAssertNil(TurnReply.request(source: .claudeCode, eventName: nil, json: try payload(name),
                                           headers: reply), name)
        }
        XCTAssertNil(TurnReply.request(source: .claudeCode, eventName: "SubagentStop", json: stop, headers: reply),
                     "the path's event name wins")

        var continued = stop
        continued["stop_hook_active"] = true
        XCTAssertNotNil(TurnReply.request(source: .claudeCode, eventName: nil, json: continued, headers: reply),
                        "a human answers, so a turn Hoply already continued is held again")
    }

    func testOnlyCopilotAgentStopFromTheReplyHookIsHeld() throws {
        let stop = try XCTUnwrap(try Fixture.hookPayloads("copilot_cli_hooks.json")["agentStop"])
        let request = try XCTUnwrap(TurnReply.request(source: .copilotCLI, eventName: "agentStop", json: stop,
                                                      headers: reply, now: now))
        XCTAssertEqual(request.key, SessionKey(source: .copilotCLI, id: "cp-9"))
        XCTAssertNil(request.message, "Copilot's agentStop carries no last message")
        XCTAssertEqual(request.transcriptPath, "/Users/x/.copilot/session-state/cp-9/events.jsonl")
        XCTAssertEqual(request.received, now)

        XCTAssertNil(TurnReply.request(source: .copilotCLI, eventName: "agentStop", json: stop, headers: [:]),
                     "the generic hook's curl gives up after 2 s")
        XCTAssertNil(TurnReply.request(source: .copilotCLI, eventName: "agentStop", json: stop,
                                       headers: [TurnReply.header: "0"]))
        XCTAssertNil(TurnReply.request(source: .copilotCLI, eventName: "agentStop", json: stop,
                                       headers: [PermissionApproval.header: "1"]))
        XCTAssertNil(TurnReply.request(source: .copilotCLI, eventName: nil, json: stop, headers: reply),
                     "Copilot's payload names no event; only the path does")
        for name in ["subagentStop", "sessionEnd", "errorOccurred", "permissionRequest", "notification", "Stop"] {
            XCTAssertNil(TurnReply.request(source: .copilotCLI, eventName: name, json: stop, headers: reply), name)
        }
        for source in [AgentSource.claudeCode, .codexCLI, .copilotIDE, .qwenCode] {
            XCTAssertNil(TurnReply.request(source: source, eventName: "agentStop", json: stop, headers: reply),
                         source.rawValue)
        }

        var continued = stop
        continued["stop_hook_active"] = true
        XCTAssertNotNil(TurnReply.request(source: .copilotCLI, eventName: "agentStop", json: continued,
                                          headers: reply))
        var unnamed = stop
        unnamed["sessionId"] = nil
        XCTAssertEqual(TurnReply.request(source: .copilotCLI, eventName: "agentStop", json: unnamed,
                                         headers: reply)?.key.id, "unknown")
        XCTAssertEqual(TurnReply.sources, [.claudeCode, .copilotCLI])
    }

    func testMessageIsTrimmedAndCapped() throws {
        func message(_ value: Any?) throws -> String? {
            var json = try payload("Stop")
            json["last_assistant_message"] = value
            return try XCTUnwrap(TurnReply.request(source: .claudeCode, eventName: nil, json: json, headers: reply))
                .message
        }
        XCTAssertEqual(try message("\n  Done.\n\nAll tests pass.  \n"), "Done.\n\nAll tests pass.")
        XCTAssertNil(try message(nil))
        XCTAssertNil(try message(""))
        XCTAssertNil(try message(" \n\t"))
        XCTAssertNil(try message(42))
        let long = try XCTUnwrap(try message(String(repeating: "x", count: 1500)))
        XCTAssertEqual(long.count, TurnReply.messageLimit + 1)
        XCTAssertTrue(long.hasSuffix("…"))
        let limit = TurnReply.messageLimit
        XCTAssertEqual(try message(String(repeating: "y", count: limit))?.count, limit)
    }

    func testResponseBodiesFollowClaudeCodesStopHookOutput() throws {
        let text = String(decoding: TurnReply.response("Now add a test for the refresh path").body, as: UTF8.self)
        XCTAssertEqual(text, #"{"decision":"block","reason":"Message from the user, sent from Hoply: Now add a test for the refresh path"}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: TurnReply.response("  run \"make\" in a/b\n").body)
                                     as? [String: Any])
        XCTAssertEqual(json["reason"] as? String, #"Message from the user, sent from Hoply: run "make" in a/b"#)
        XCTAssertEqual(json.count, 2)
        for empty in [nil, "", "  \n "] as [String?] {
            XCTAssertEqual(String(decoding: TurnReply.response(empty).body, as: UTF8.self), "{}",
                           "no text: the turn ends as it would have")
        }
        XCTAssertEqual(TurnReply.response("go").contentType, "application/json")
    }

    func testTimeoutsKeepTheirOrder() {
        XCTAssertEqual(TurnReply.holdLimit, 1770)
        XCTAssertEqual(TurnReply.curlTimeout, 1790)
        XCTAssertEqual(TurnReply.hookTimeout, 1800)
        XCTAssertLessThan(TurnReply.holdLimit, TimeInterval(TurnReply.curlTimeout))
        XCTAssertLessThan(TurnReply.curlTimeout, TurnReply.hookTimeout)
        let hooks = ClaudeCodeHooks(port: 4318)
        XCTAssertTrue(hooks.replyCommand.contains(" -m \(TurnReply.curlTimeout) "))
        XCTAssertTrue(hooks.replyCommand.contains("'X-Hoply-Reply: 1'"))
        XCTAssertFalse(hooks.replyCommand.contains("/dev/null"), "Claude Code reads the decision from stdout")
        XCTAssertEqual(hooks.hook(for: ClaudeCodeHooks.replyEvent)["timeout"] as? Int, TurnReply.hookTimeout)
        XCTAssertEqual(ClaudeCodeHooks.replyEvent, "Stop")

        let copilot = CopilotCLIHooks(port: 4318)
        XCTAssertTrue(copilot.replyCommand.contains(" -m \(TurnReply.curlTimeout) "))
        XCTAssertTrue(copilot.replyCommand.contains("'X-Hoply-Reply: 1'"))
        XCTAssertFalse(copilot.replyCommand.contains("/dev/null"), "Copilot reads the decision from stdout")
        XCTAssertEqual(copilot.hook(for: CopilotCLIHooks.replyEvent)["timeoutSec"] as? Int, TurnReply.hookTimeout)
        XCTAssertEqual(CopilotCLIHooks.replyEvent, "agentStop")
    }

    func testLaterActivityInTheSessionReleasesTheHeldReply() {
        let key = SessionKey(source: .claudeCode, id: "s1")
        let held = TurnReplyRequest(id: "r1", key: key, message: "Done.", received: now)
        func event(_ kind: AgentEvent.Kind, agent: String? = nil, at offset: TimeInterval = 1,
                   session: String = "s1", source: AgentSource = .claudeCode, hook: Bool = true) -> AgentEvent {
            AgentEvent(key: SessionKey(source: source, id: session), kind: kind, time: now + offset, fromHook: hook,
                       agentID: agent)
        }
        func answered(_ event: AgentEvent) -> [String] { TurnReply.answered([held], by: [event]) }

        XCTAssertEqual(answered(event(.turnFinished("Done."), at: 0)), [],
                       "the Stop that carried the request arrives with it")
        XCTAssertEqual(answered(event(.promptSubmitted("go on"))), ["r1"], "the user typed at the terminal")
        XCTAssertEqual(answered(event(.sessionEnded(nil))), ["r1"])
        XCTAssertEqual(answered(event(.sessionStarted)), ["r1"])
        XCTAssertEqual(answered(event(.turnFinished("x"))), ["r1"], "a later turn end: this hold is gone")
        XCTAssertEqual(answered(event(.turnFailed(error: "rate_limit", message: nil))), ["r1"])
        XCTAssertEqual(answered(event(.turnFinished("x"), agent: "a7")), [], "a subagent's turn end")
        XCTAssertEqual(answered(event(.turnFinished("x"), agent: "")), ["r1"])
        XCTAssertEqual(answered(event(.subagentStopped(id: "a7", type: nil))), [])
        XCTAssertEqual(answered(event(.toolFinished("Bash"))), [])
        XCTAssertEqual(answered(event(.waitingForInput("x"))), [])
        XCTAssertEqual(answered(event(.activity)), [])
        XCTAssertEqual(answered(event(.promptSubmitted("go"), at: -1)), [], "an event from before the request")
        XCTAssertEqual(answered(event(.promptSubmitted("go"), session: "s2")), [])
        XCTAssertEqual(answered(event(.promptSubmitted("go"), source: .codexCLI)), [])
        XCTAssertEqual(answered(event(.promptSubmitted("go"), hook: false)), [], "delayed telemetry")
        XCTAssertEqual(TurnReply.answered([held], by: []), [])
    }

    func testRouterMapsTheStopAndFlagsTheReply() throws {
        let body = try JSONSerialization.data(withJSONObject: try payload("Stop"))
        let request = HTTPRequest(method: "POST", path: "/hooks/claude-code",
                                  headers: ["content-type": "application/json", TurnReply.header: "1"], body: body)
        let outcome = HubRouter().handle(request, now: now)
        XCTAssertEqual(outcome.reply?.key, SessionKey(source: .claudeCode, id: "abc123"))
        XCTAssertEqual(outcome.reply?.received, now)
        XCTAssertNil(outcome.approval)
        XCTAssertEqual(outcome.events.map(\.kind),
                       [.turnFinished("The test raced the token refresh. I added an await.")])
        XCTAssertEqual(outcome.events.first?.time, outcome.reply?.received)
        XCTAssertEqual(String(decoding: outcome.response.body, as: UTF8.self), "{}")
        XCTAssertEqual(TurnReply.answered([try XCTUnwrap(outcome.reply)], by: outcome.events), [],
                       "its own events never release it")

        let plain = HubRouter().handle(HTTPRequest(method: "POST", path: "/hooks/claude-code",
                                                   headers: ["content-type": "application/json"], body: body), now: now)
        XCTAssertNil(plain.reply)
        var cursor = try payload("Stop")
        cursor["cursor_version"] = "x"
        let fromCursor = HubRouter().handle(HTTPRequest(method: "POST", path: "/hooks/claude-code",
                                                        headers: [TurnReply.header: "1"],
                                                        body: try JSONSerialization.data(withJSONObject: cursor)))
        XCTAssertNil(fromCursor.reply, "Cursor runs Claude Code's hooks; nothing there to answer")
    }

    func testRouterMapsCopilotsAgentStopAndFlagsTheReply() throws {
        let stop = try XCTUnwrap(try Fixture.hookPayloads("copilot_cli_hooks.json")["agentStop"])
        let body = try JSONSerialization.data(withJSONObject: stop)
        func handle(_ path: String, headers: [String: String] = [TurnReply.header: "1"]) -> HubRouter.Outcome {
            HubRouter().handle(HTTPRequest(method: "POST", path: path,
                                           headers: headers.merging(["content-type": "application/json"]) { $1 },
                                           body: body), now: now)
        }
        let outcome = handle("/hooks/copilot-cli/agentStop")
        XCTAssertEqual(outcome.reply?.key, SessionKey(source: .copilotCLI, id: "cp-9"))
        XCTAssertEqual(outcome.reply?.transcriptPath, "/Users/x/.copilot/session-state/cp-9/events.jsonl")
        XCTAssertEqual(outcome.reply?.received, now)
        XCTAssertNil(outcome.approval)
        XCTAssertEqual(outcome.events.map(\.kind), [.turnFinished(nil)])
        XCTAssertEqual(outcome.events.first?.key, outcome.reply?.key)
        XCTAssertEqual(String(decoding: outcome.response.body, as: UTF8.self), "{}")
        XCTAssertEqual(TurnReply.answered([try XCTUnwrap(outcome.reply)], by: outcome.events), [],
                       "its own events never release it")

        XCTAssertNil(handle("/hooks/copilot-cli/agentStop", headers: [:]).reply)
        XCTAssertNil(handle("/hooks/copilot-cli/subagentStop").reply, "a subagent's stop is never held")
        XCTAssertNil(handle("/hooks/copilot-cli").reply)
        XCTAssertNil(handle("/hooks/codex-cli/agentStop").reply)
    }
}

#if canImport(Network)
final class TurnReplyServerTests: XCTestCase {
    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [TurnReplyRequest] = []
        private var closed: [String] = []
        private var approvalsClosed: [String] = []

        func add(_ reply: TurnReplyRequest) { lock.withLock { replies.append(reply) } }
        func close(_ id: String) { lock.withLock { closed.append(id) } }
        func closeApproval(_ id: String) { lock.withLock { approvalsClosed.append(id) } }
        var latest: TurnReplyRequest? { lock.withLock { replies.last } }
        var closedIDs: [String] { lock.withLock { closed } }
        var closedApprovalIDs: [String] { lock.withLock { approvalsClosed } }
    }

    private var server: HubServer!
    private var port: UInt16 = 0
    private let captured = Captured()
    private var held: XCTestExpectation!

    override func setUp() async throws {
        server = HubServer()
        port = UInt16.random(in: 45_000...46_999)
        let listening = expectation(description: "listening")
        let captured = captured
        let held = expectation(description: "held")
        self.held = held
        server.onStatus = { status in if case .listening = status { listening.fulfill() } }
        server.onReply = { reply, events in
            XCTAssertEqual(events.map(\.kind), [.turnFinished("The test raced the token refresh. I added an await.")])
            captured.add(reply)
            held.fulfill()
        }
        server.onApprovalClosed = { id in captured.closeApproval(id) }
        server.start(port: port)
        await fulfillment(of: [listening], timeout: 5)
    }

    override func tearDown() async throws {
        server.stop()
    }

    private static func body() throws -> Data {
        let stop = try XCTUnwrap(try Fixture.hookPayloads("claude_hooks.json")["Stop"])
        return try JSONSerialization.data(withJSONObject: stop)
    }

    private static func post(port: UInt16, reply: Bool = true) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hooks/claude-code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if reply { request.setValue("1", forHTTPHeaderField: "X-Hoply-Reply") }
        request.httpBody = try Self.body()
        request.timeoutInterval = 10
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    private func closedExpectation() -> XCTestExpectation {
        let captured = captured
        let closed = expectation(description: "closed")
        server.onReplyClosed = { id in
            captured.close(id)
            closed.fulfill()
        }
        return closed
    }

    func testHeldUntilTheUserAnswers() async throws {
        server.setHoldsReplies(true)
        let port = port
        async let answer = Self.post(port: port)
        await fulfillment(of: [held], timeout: 5)
        let reply = try XCTUnwrap(captured.latest)
        XCTAssertEqual(reply.message, "The test raced the token refresh. I added an await.")
        server.resolve(reply.id, .deny)
        server.answer(reply.id, text: "Also update the changelog")
        let text = try await answer
        XCTAssertEqual(text, #"{"decision":"block","reason":"Message from the user, sent from Hoply: Also update the changelog"}"#,
                       "resolve only answers approvals")
        XCTAssertEqual(captured.closedIDs, [], "an answer is not a close")
    }

    func testDoneAnswersWithNoDecision() async throws {
        server.setHoldsReplies(true)
        let port = port
        async let first = Self.post(port: port)
        await fulfillment(of: [held], timeout: 5)
        server.answer(try XCTUnwrap(captured.latest).id, text: nil)
        let done = try await first
        XCTAssertEqual(done, "{}")
    }

    func testReleaseAnswersWithNoDecision() async throws {
        server.setHoldsReplies(true)
        let port = port
        async let answer = Self.post(port: port)
        await fulfillment(of: [held], timeout: 5)
        server.release([try XCTUnwrap(captured.latest).id])
        let text = try await answer
        XCTAssertEqual(text, "{}")
    }

    func testLeavingAwayModeReleasesRepliesButTurningApprovalsOffDoesNot() async throws {
        let closed = closedExpectation()
        server.setHoldsReplies(true)
        server.setHoldsApprovals(true)
        let port = port
        async let answer = Self.post(port: port)
        await fulfillment(of: [held], timeout: 5)
        server.setHoldsApprovals(false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(captured.closedIDs, [], "approvals off leaves a held reply alone")
        server.setHoldsReplies(false)
        let text = try await answer
        XCTAssertEqual(text, "{}")
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(captured.closedIDs, [captured.latest?.id].compactMap { $0 })
        XCTAssertEqual(captured.closedApprovalIDs, [], "a reply's close is not an approval's")
    }

    func testStoppingTheServerReleasesReplies() async throws {
        let closed = closedExpectation()
        server.setHoldsReplies(true)
        let port = port
        async let answer = Self.post(port: port)
        await fulfillment(of: [held], timeout: 5)
        server.stop()
        let text = try await answer
        XCTAssertEqual(text, "{}")
        await fulfillment(of: [closed], timeout: 5)
    }

    func testNotHeldWhenOffOrWithoutTheHeader() async throws {
        held.isInverted = true
        let first = try await Self.post(port: port)
        XCTAssertEqual(first, "{}", "Away mode off")
        server.setHoldsReplies(true)
        let second = try await Self.post(port: port, reply: false)
        XCTAssertEqual(second, "{}", "older Stop hook without the header")
        await fulfillment(of: [held], timeout: 0.2)
    }

    private static func run(_ command: String, input body: Data) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(body)
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testInstalledHookCommandPrintsTheAnswer() async throws {
        server.setHoldsReplies(true)
        let command = ClaudeCodeHooks(port: Int(port)).replyCommand
        let body = try Self.body()
        let hook = Task.detached { try Self.run(command, input: body) }
        await fulfillment(of: [held], timeout: 5)
        server.answer(try XCTUnwrap(captured.latest).id, text: "Ship it")
        let printed = try await hook.value
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any])
        XCTAssertEqual(json["decision"] as? String, "block", printed)
        XCTAssertEqual(json["reason"] as? String, "Message from the user, sent from Hoply: Ship it")
    }

    func testInstalledCopilotHookCommandPrintsTheAnswer() async throws {
        let captured = captured
        let held = try XCTUnwrap(held)
        server.onReply = { reply, events in
            XCTAssertEqual(events.map(\.kind), [.turnFinished(nil)])
            captured.add(reply)
            held.fulfill()
        }
        let command = CopilotCLIHooks(port: Int(port)).replyCommand
        let stop = try XCTUnwrap(try Fixture.hookPayloads("copilot_cli_hooks.json")["agentStop"])
        let body = try JSONSerialization.data(withJSONObject: stop)
        let notHeld = try await Task.detached { try Self.run(command, input: body) }.value
        XCTAssertEqual(notHeld, "{}", "Away mode off: Copilot stops as it would have")

        server.setHoldsReplies(true)
        let hook = Task.detached { try Self.run(command, input: body) }
        await fulfillment(of: [held], timeout: 5)
        let reply = try XCTUnwrap(captured.latest)
        XCTAssertEqual(reply.key, SessionKey(source: .copilotCLI, id: "cp-9"))
        XCTAssertEqual(reply.transcriptPath, "/Users/x/.copilot/session-state/cp-9/events.jsonl")
        server.answer(reply.id, text: "Ship it")
        let printed = try await hook.value
        XCTAssertEqual(printed, #"{"decision":"block","reason":"Message from the user, sent from Hoply: Ship it"}"#)
    }

    func testClosedConnectionDropsTheReply() async throws {
        let closed = closedExpectation()
        server.setHoldsReplies(true)
        let port = port
        let task = Task { try await Self.post(port: port) }
        await fulfillment(of: [held], timeout: 5)
        task.cancel()
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(captured.closedIDs, [captured.latest?.id].compactMap { $0 })
    }
}
#endif
