import Foundation
import XCTest
@testable import AgentKit

final class ApprovalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let approve = [PermissionApproval.header: "1"]

    private func payload(tool: String = "Bash", input: [String: Any] = ["command": "npm run lint"],
                         agent: String? = nil) -> [String: Any] {
        var json: [String: Any] = ["session_id": "s1", "hook_event_name": "PermissionRequest", "cwd": "/r/app",
                                   "tool_name": tool, "tool_input": input]
        if let agent { json["agent_id"] = agent }
        return json
    }

    func testOnlyClaudeCodePermissionRequestsFromTheNewHookAreHeld() throws {
        let request = try XCTUnwrap(PermissionApproval.request(source: .claudeCode, eventName: nil, json: payload(),
                                                               headers: approve, now: now))
        XCTAssertEqual(request.key, SessionKey(source: .claudeCode, id: "s1"))
        XCTAssertEqual(request.tool, "Bash")
        XCTAssertEqual(request.summary, "Bash: npm run lint")
        XCTAssertNil(request.agentID)
        XCTAssertEqual(request.received, now)

        XCTAssertNil(PermissionApproval.request(source: .claudeCode, eventName: nil, json: payload(), headers: [:]),
                     "a hook without the header (older install.sh) has a 2 s curl timeout")
        XCTAssertNil(PermissionApproval.request(source: .copilotCLI, eventName: "permissionRequest", json: payload(),
                                                headers: approve), "Copilot waits for the hook before its own rules")
        XCTAssertNil(PermissionApproval.request(source: .claudeCode, eventName: "PreToolUse", json: payload(),
                                                headers: approve))
        for tool in ["AskUserQuestion", "ExitPlanMode"] {
            XCTAssertNil(PermissionApproval.request(source: .claudeCode, eventName: nil, json: payload(tool: tool),
                                                    headers: approve), tool)
        }
        var noTool = payload()
        noTool["tool_name"] = nil
        XCTAssertNil(PermissionApproval.request(source: .claudeCode, eventName: nil, json: noTool, headers: approve))
        let subagent = PermissionApproval.request(source: .claudeCode, eventName: nil, json: payload(agent: "a7"),
                                                  headers: approve)
        XCTAssertEqual(subagent?.agentID, "a7")
    }

    func testDetailNamesWhatIsBeingApproved() {
        XCTAssertEqual(PermissionApproval.detail(tool: "Edit", input: ["file_path": "/r/app/main.swift",
                                                                       "old_string": "a"]), "/r/app/main.swift")
        XCTAssertEqual(PermissionApproval.detail(tool: "WebFetch", input: ["url": "https://example.com", "prompt": "x"]),
                       "https://example.com")
        XCTAssertEqual(PermissionApproval.detail(tool: "Bash", input: ["command": "set -e\n\n  make test\n"]),
                       "set -e ⏎ make test")
        let long = PermissionApproval.detail(tool: "Bash", input: ["command": String(repeating: "x", count: 400)])
        XCTAssertEqual(long?.count, 301)
        XCTAssertTrue(long?.hasSuffix("…") == true)
        XCTAssertNil(PermissionApproval.detail(tool: "mcp__db__query", input: ["limit": 5]))
        XCTAssertNil(PermissionApproval.detail(tool: "Bash", input: nil))
    }

    func testDecisionBodiesFollowClaudeCodesHookOutput() throws {
        func decision(_ response: HTTPResponse) throws -> [String: Any] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            let output = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
            XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
            return try XCTUnwrap(output["decision"] as? [String: Any])
        }
        let allow = try decision(PermissionApproval.response(.allow))
        XCTAssertEqual(allow["behavior"] as? String, "allow")
        XCTAssertEqual(allow.count, 1, "allow once: no updatedInput, no permanent rules")
        let deny = try decision(PermissionApproval.response(.deny))
        XCTAssertEqual(deny["behavior"] as? String, "deny")
        XCTAssertEqual(deny["message"] as? String, PermissionApproval.denyMessage)
        XCTAssertEqual(deny["interrupt"] as? Bool, false)
        XCTAssertEqual(String(decoding: PermissionApproval.response(nil).body, as: UTF8.self), "{}",
                       "no decision: Claude Code keeps its own dialog")
    }

    func testAnswerElsewhereReleasesTheHeldRequest() {
        let key = SessionKey(source: .claudeCode, id: "s1")
        let main = ApprovalRequest(id: "main", key: key, tool: "Bash", detail: "make", received: now)
        let sub = ApprovalRequest(id: "sub", key: key, tool: "Write", detail: "/r/a", agentID: "a7", received: now)
        let pending = [main, sub]
        func event(_ kind: AgentEvent.Kind, agent: String? = nil, at offset: TimeInterval = 1,
                   session: String = "s1", hook: Bool = true) -> AgentEvent {
            AgentEvent(key: SessionKey(source: .claudeCode, id: session), kind: kind, time: now + offset,
                       fromHook: hook, agentID: agent)
        }
        XCTAssertEqual(PermissionApproval.answered(pending, by: [event(.toolFinished("Bash"))]), ["main"])
        XCTAssertEqual(PermissionApproval.answered(pending, by: [event(.toolFinished("Read"))]), [],
                       "a parallel auto-allowed tool says nothing about this prompt")
        XCTAssertEqual(PermissionApproval.answered(pending, by: [event(.toolStarted("Bash"))]), [])
        XCTAssertEqual(PermissionApproval.answered(pending, by: [event(.turnFinished(nil))]), ["main"])
        XCTAssertEqual(PermissionApproval.answered(pending, by: [event(.promptSubmitted("go"))]), ["main"])
        XCTAssertEqual(PermissionApproval.answered(pending, by: [event(.toolFinished("Write"), agent: "a7")]), ["sub"])
        XCTAssertEqual(PermissionApproval.answered(pending, by: [event(.toolFinished("Write"))]), [],
                       "the main agent's Write is not the subagent's")
        XCTAssertEqual(PermissionApproval.answered(pending, by: [event(.subagentStopped(id: "a7", type: nil))]), ["sub"])
        XCTAssertEqual(PermissionApproval.answered(pending, by: [event(.sessionEnded(nil), agent: "a7")]), ["main", "sub"])
        XCTAssertEqual(PermissionApproval.answered(pending, by: [event(.turnFinished(nil), at: -1)]), [],
                       "an event from before the request")
        XCTAssertEqual(PermissionApproval.answered(pending, by: [event(.turnFinished(nil), session: "s2")]), [])
        XCTAssertEqual(PermissionApproval.answered(pending, by: [event(.turnFinished(nil), hook: false)]), [],
                       "delayed telemetry")
        XCTAssertEqual(PermissionApproval.answered(pending, by: [event(.needsPermission("Allow Bash?"))]), [])
    }

    func testSettingIsOffByDefaultAndDecodesLeniently() throws {
        XCTAssertFalse(AppSettings().approveFromHoply)
        XCTAssertFalse(AppSettings.decode(Data(#"{"port":4400}"#.utf8)).approveFromHoply)
        let wrong = AppSettings.decode(Data(#"{"approveFromHoply":"yes","port":4400}"#.utf8))
        XCTAssertFalse(wrong.approveFromHoply)
        XCTAssertEqual(wrong.port, 4400)
        var on = AppSettings()
        on.approveFromHoply = true
        XCTAssertTrue(AppSettings.decode(try XCTUnwrap(on.encoded())).approveFromHoply)
    }

    func testRouterMapsTheEventAndFlagsTheApproval() throws {
        let body = try JSONSerialization.data(withJSONObject: payload())
        let request = HTTPRequest(method: "POST", path: "/hooks/claude-code",
                                  headers: ["content-type": "application/json", PermissionApproval.header: "1"],
                                  body: body)
        let outcome = HubRouter().handle(request, now: now)
        XCTAssertEqual(outcome.approval?.tool, "Bash")
        XCTAssertEqual(outcome.events.map(\.kind), [.needsPermission("Allow Bash?")])
        XCTAssertEqual(String(decoding: outcome.response.body, as: UTF8.self), "{}")
    }
}

#if canImport(Network)
final class ApprovalServerTests: XCTestCase {
    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var approvals: [ApprovalRequest] = []
        private var closed: [String] = []

        func add(_ approval: ApprovalRequest) { lock.withLock { approvals.append(approval) } }
        func close(_ id: String) { lock.withLock { closed.append(id) } }
        var latest: ApprovalRequest? { lock.withLock { approvals.last } }
        var closedIDs: [String] { lock.withLock { closed } }
    }

    private var server: HubServer!
    private var port: UInt16 = 0
    private let captured = Captured()
    private var held: XCTestExpectation!
    private var closed: XCTestExpectation?

    override func setUp() async throws {
        server = HubServer()
        port = UInt16.random(in: 47_000...48_999)
        let listening = expectation(description: "listening")
        let captured = captured
        let held = expectation(description: "held")
        self.held = held
        server.onStatus = { status in if case .listening = status { listening.fulfill() } }
        server.onApproval = { approval, events in
            XCTAssertEqual(events.count, 1)
            captured.add(approval)
            held.fulfill()
        }
        server.start(port: port)
        await fulfillment(of: [listening], timeout: 5)
    }

    override func tearDown() async throws {
        server.stop()
    }

    private static func body() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["session_id": "s1", "hook_event_name": "PermissionRequest",
                                                    "tool_name": "Bash", "tool_input": ["command": "make"]])
    }

    private static func post(port: UInt16, approve: Bool = true) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hooks/claude-code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if approve { request.setValue("1", forHTTPHeaderField: "X-Hoply-Approve") }
        request.httpBody = try Self.body()
        request.timeoutInterval = 10
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    func testHeldUntilTheUserDecides() async throws {
        server.setHoldsApprovals(true)
        let port = port
        async let reply = Self.post(port: port)
        await fulfillment(of: [held], timeout: 5)
        let approval = try XCTUnwrap(captured.latest)
        server.resolve(approval.id, .deny)
        let text = try await reply
        XCTAssertTrue(text.contains(#""behavior":"deny""#), text)
        XCTAssertEqual(captured.closedIDs, [], "a decision is not a close")
    }

    func testReleaseAnswersWithNoDecision() async throws {
        server.setHoldsApprovals(true)
        let port = port
        async let reply = Self.post(port: port)
        await fulfillment(of: [held], timeout: 5)
        server.release([try XCTUnwrap(captured.latest).id])
        let text = try await reply
        XCTAssertEqual(text, "{}")
    }

    func testTurningApprovalsOffReleasesWhatIsHeld() async throws {
        let captured = captured
        let closed = expectation(description: "closed")
        server.onApprovalClosed = { id in
            captured.close(id)
            closed.fulfill()
        }
        server.setHoldsApprovals(true)
        let port = port
        async let reply = Self.post(port: port)
        await fulfillment(of: [held], timeout: 5)
        server.setHoldsApprovals(false)
        let text = try await reply
        XCTAssertEqual(text, "{}")
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(captured.closedIDs, [captured.latest?.id].compactMap { $0 })
    }

    func testNotHeldWhenOffOrWithoutTheHeader() async throws {
        held.isInverted = true
        let first = try await Self.post(port: port)
        XCTAssertEqual(first, "{}", "approvals off")
        server.setHoldsApprovals(true)
        let second = try await Self.post(port: port, approve: false)
        XCTAssertEqual(second, "{}", "older hook without the header")
        await fulfillment(of: [held], timeout: 0.2)
    }

    // Same flags as CLAUDE_APPROVE_HOOK in scripts/install.sh; its stdout is what Claude Code reads.
    private static func curlHook(port: UInt16) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-sf", "-m", "10", "-H", "Expect:", "-H", "Content-Type: application/json",
                             "-H", "X-Hoply-Approve: 1", "-H", "X-Hoply-Pid: \(ProcessInfo.processInfo.processIdentifier)",
                             "--data-binary", "@-", "http://127.0.0.1:\(port)/hooks/claude-code"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(try body())
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testInstalledHookCommandPrintsTheDecision() async throws {
        server.setHoldsApprovals(true)
        let port = port
        let hook = Task.detached { try Self.curlHook(port: port) }
        await fulfillment(of: [held], timeout: 5)
        server.resolve(try XCTUnwrap(captured.latest).id, .allow)
        let printed = try await hook.value
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any])
        let decision = (json["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow", printed)
    }

    func testClosedConnectionDropsTheApproval() async throws {
        let captured = captured
        let closed = expectation(description: "closed")
        server.onApprovalClosed = { id in
            captured.close(id)
            closed.fulfill()
        }
        server.setHoldsApprovals(true)
        let port = port
        let task = Task { try await Self.post(port: port) }
        await fulfillment(of: [held], timeout: 5)
        task.cancel()
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(captured.closedIDs, [captured.latest?.id].compactMap { $0 })
    }
}
#endif
