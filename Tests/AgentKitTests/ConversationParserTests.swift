import AgentKit
import Foundation
import XCTest

final class ConversationParserTests: XCTestCase {
    private typealias Message = RemoteTranscript.Message

    private func lines(_ fixture: String) throws -> [Data] {
        JSONLines.complete(in: try Fixture.data(fixture)).lines
    }

    private func messages(_ source: AgentSource, _ fixture: String, cwd: String? = nil) throws -> [Message] {
        try XCTUnwrap(ConversationParser.messages(source, lines: try lines(fixture), cwd: cwd))
    }

    private func shape(_ messages: [Message]) -> [String] {
        messages.map { "\($0.role.rawValue): \($0.text)" }
    }

    private func date(_ text: String) -> Date? { Timestamps.parse(text) }

    func testClaudeKeepsPromptsRepliesAndOneLinePerTool() throws {
        let result = try messages(.claudeCode, "synthetic_claude_conversation.jsonl")
        XCTAssertEqual(shape(result), [
            "user: Fix the login redirect",
            "assistant: I'll look at the auth flow first.",
            "tool: Read Sources/Auth.swift",
            "tool: Bash swift test --filter AuthTests …",
            "tool: Edit Sources/Auth.swift",
            "tool: Grep redirectURL",
            "tool: WebFetch developer.apple.com",
            "tool: Task Review the change",
            "assistant: Fixed: the redirect now waits for the token.\n\nAll 12 auth tests pass.",
            "user: /compact",
            "user: Also add a test for the expired token.",
            "tool: Todo",
            "user: and keep the old API working",
            "user: What about this screen?",
            "tool: mcp__github__get_issue",
            "tool: Read /etc/hosts",
        ])
        XCTAssertEqual(result.first?.at, date("2026-11-19T10:00:00.000Z"))
        XCTAssertEqual(result[3].at, date("2026-11-19T10:00:06.000Z"))
    }

    func testClaudeDropsEverythingButTheConversation() throws {
        let text = shape(try messages(.claudeCode, "synthetic_claude_conversation.jsonl")).joined(separator: "\n")
        for dropped in ["Looks fine.", "Caveat", "Compacted", "continued from a previous", "No response requested",
                        "Request interrupted", "Report from a helper", "let x = 1", "reasonPrefix", "done</task",
                        "Conversation compacted", "Thinking"] {
            XCTAssertFalse(text.contains(dropped), dropped)
        }
        XCTAssertFalse(text.contains("tool: Review"), "a subagent's own prompt never shows")
    }

    func testClaudeFixtureFromARealCapture() throws {
        XCTAssertEqual(shape(try messages(.claudeCode, "claude_transcript.jsonl")), [
            "user: x",
            "tool: Bash",
            "assistant: x",
            "user: x",
            "user: /model",
            "assistant: x",
        ])
    }

    func testCodexKeepsPromptsAgentMessagesAndToolCalls() throws {
        XCTAssertEqual(shape(try messages(.codexCLI, "synthetic_codex_conversation.jsonl")), [
            "user: Add pagination to the list endpoint",
            #"tool: Bash rg -n "def list" src"#,
            "tool: Edit src/routes.py, src/pagination.py",
            "tool: Bash pytest -q",
            "tool: Todo",
            "tool: Bash ls -la",
            "tool: WebSearch cursor pagination",
            "assistant: Added cursor pagination; the tests pass.",
            "user: Search the issues too",
            "tool: github__search_issues pagination",
        ])
    }

    func testCodexFixturesFromRealCaptures() throws {
        XCTAssertEqual(shape(try messages(.codexCLI, "codex_rollout_cli.jsonl")),
                       ["user: x", "assistant: x", "user: x", "assistant: x", "user: x", "assistant: x"])
        XCTAssertEqual(shape(try messages(.codexCLI, "codex_rollout_exec.jsonl")), [
            "user: x", "assistant: x", "tool: Bash x", "tool: Bash x", "tool: Bash x", "tool: Bash x", "assistant: x",
            "tool: Bash x", "tool: Bash x", "assistant: x",
        ])
    }

    func testCopilotKeepsMainAgentMessagesAndTools() throws {
        XCTAssertEqual(shape(try messages(.copilotCLI, "synthetic_copilot_conversation.jsonl")), [
            "user: Why is the build failing?",
            "tool: Bash npm run build",
            "tool: Read src/app.ts",
            "tool: Edit src/app.ts",
            "assistant: The import path was wrong; I fixed it.",
            "user: Run the tests too",
            "tool: Glob **/*.test.ts",
            "tool: WebFetch nodejs.org",
            "assistant: All tests pass.",
        ])
    }

    func testCopilotFixtureFromARealCapture() throws {
        let result = try messages(.copilotCLI, "copilot_events.jsonl")
        XCTAssertEqual(result.filter { $0.role == .user }.count, 3)
        XCTAssertEqual(result.filter { $0.role == .assistant }.count, 5)
        XCTAssertEqual(result.filter { $0.role == .tool }.map(\.text),
                       ["Read", "Glob", "Glob", "Read", "Read", "Read", "Read", "Read"])
    }

    func testAMidFileTailStillReadsAndUsesTheGivenCwd() throws {
        let tail = Array(try lines("synthetic_copilot_conversation.jsonl").dropFirst())
        let result = try XCTUnwrap(ConversationParser.messages(.copilotCLI, lines: tail, cwd: "/Users/x/Project/web"))
        XCTAssertTrue(shape(result).contains("tool: Read src/app.ts"), "the workspace's cwd stands in for session.start")
        let bare = try XCTUnwrap(ConversationParser.messages(.copilotCLI, lines: tail))
        XCTAssertTrue(shape(bare).contains("tool: Read /Users/x/Project/web/src/app.ts"))
    }

    func testOnlyAgentsWithTranscriptsAreSupported() throws {
        XCTAssertEqual(ConversationParser.agents, [.claudeCode, .codexCLI, .copilotCLI])
        XCTAssertNil(ConversationParser.messages(.qwenCode, lines: [Data("{}".utf8)]))
        XCTAssertNil(ConversationParser.messages(.copilotIDE, lines: []))
        XCTAssertEqual(ConversationParser.messages(.claudeCode, lines: [Data("not json".utf8)]), [])
    }

    func testHoplyRepliesAreFoundOnlyWhereAnAgentPutThem() {
        let prefix = TurnReply.reasonPrefix
        XCTAssertEqual(TurnReply.sentText(in: prefix + " Run the tests "), "Run the tests")
        XCTAssertEqual(TurnReply.sentText(in: "Stop hook feedback:\n[curl … # hoply]: " + prefix + "go on"), "go on")
        XCTAssertEqual(TurnReply.sentText(in: "Stop hook feedback:\n" + prefix + "go on"), "go on")
        XCTAssertNil(TurnReply.sentText(in: #"let reasonPrefix = ""# + prefix + #"""#), "quoted in code")
        XCTAssertNil(TurnReply.sentText(in: #"{"reason":""# + prefix + #"x"}"#))
        XCTAssertNil(TurnReply.sentText(in: prefix + "   "))
        XCTAssertNil(TurnReply.sentText(in: "Run the tests"))
    }

    func testToolLinesNameTheMainArgument() {
        let cwd = "/Users/x/p"
        func line(_ name: String, _ values: [String: String]) -> String? {
            let data = try? JSONSerialization.data(withJSONObject: ["type": "tool_use", "id": UUID().uuidString,
                                                                    "name": name, "input": values])
            let json = #"{"type":"assistant","uuid":"\#(UUID().uuidString)","cwd":"\#(cwd)","message":{"id":"m","model":"m","content":["#
                + String(decoding: data ?? Data(), as: UTF8.self) + "]}}"
            return ConversationParser.messages(.claudeCode, lines: [Data(json.utf8)])?.first?.text
        }
        XCTAssertEqual(line("Bash", ["command": "  git status  "]), "Bash git status")
        XCTAssertEqual(line("Read", ["file_path": cwd]), "Read .")
        XCTAssertEqual(line("Write", ["file_path": "/Users/x/pkg/a.swift"]), "Write /Users/x/pkg/a.swift",
                       "a sibling folder sharing the prefix stays absolute")
        XCTAssertEqual(line("Glob", ["pattern": "**/*.swift"]), "Glob **/*.swift")
        XCTAssertEqual(line("WebSearch", ["query": "swift testing"]), "WebSearch swift testing")
        XCTAssertEqual(line("Skill", ["skill": "release"]), "Skill release")
        XCTAssertEqual(line("NotebookEdit", ["notebook_path": cwd + "/a.ipynb"]), "Edit a.ipynb")
        XCTAssertEqual(line("WebFetch", ["url": "not a url"]), "WebFetch not a url")
        XCTAssertEqual(line("ExitPlanMode", [:]), "ExitPlanMode")
    }
}
