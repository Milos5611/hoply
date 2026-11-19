import AgentKit
import Foundation
import XCTest
@testable import AgentSystem

final class ConversationReaderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let claudeID = "22222222-2222-4222-8222-222222222222"
    private let codexThread = "019c0000-0000-7000-8000-00000000000a"
    private let copilotID = "33333333-3333-4333-8333-333333333333"

    private func configuration(_ temp: TempDirectory,
                               folders: Set<AgentFolder> = Set(AgentFolder.allCases)) -> LedgerConfiguration {
        LedgerConfiguration(databasePath: temp.path("hoply.sqlite"), claudeConfigDirectory: temp.path(".claude"),
                            copilotHome: temp.path(".copilot"), codexHome: temp.path(".codex"), folders: folders)
    }

    private func claudeLine(_ uuid: String, user text: String) -> String {
        #"{"type":"user","uuid":"\#(uuid)","timestamp":"2026-11-19T10:00:00.000Z","cwd":"/Users/x/demo","origin":{"kind":"human"},"message":{"role":"user","content":"\#(text)"}}"#
    }

    private func claudeTool(_ uuid: String, command: String) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","cwd":"/Users/x/demo","message":{"id":"m-\#(uuid)","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t-\#(uuid)","name":"Bash","input":{"command":"\#(command)"}}]}}"#
    }

    @discardableResult
    private func writeClaude(_ temp: TempDirectory, _ lines: [String], id: String? = nil) throws -> String {
        try temp.write(".claude/projects/-Users-x-demo/\(id ?? claudeID).jsonl", lines.joined(separator: "\n") + "\n")
    }

    private func transcript(_ reader: ConversationReader, _ session: String) async -> RemoteTranscript {
        await reader.transcript(for: session, device: "mac-1", answerID: "a-1", now: t0)
    }

    func testClaudeConversationComesFromTheMacsOwnFolder() async throws {
        let temp = try TempDirectory()
        try writeClaude(temp, [claudeLine("u1", user: "Fix the login"), claudeTool("a1", command: "swift test"),
                               #"{"type":"assistant","uuid":"a2","message":{"id":"m2","model":"claude-opus-5-5","content":[{"type":"text","text":"Fixed."}]}}"#])
        let reader = ConversationReader(configuration: configuration(temp))
        XCTAssertEqual(reader.agents, [.claudeCode, .codexCLI, .copilotCLI])
        let result = await transcript(reader, "claude-code:" + claudeID)
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.messages.map(\.text), ["Fix the login", "Bash swift test", "Fixed."])
        XCTAssertEqual(result.messages.map(\.role), [.user, .tool, .assistant])
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.device, "mac-1")
        XCTAssertEqual(result.session, "claude-code:" + claudeID)
        XCTAssertEqual(result.agent, "claude-code")
        XCTAssertEqual(result.answerID, "a-1")
        XCTAssertEqual(result.updatedAt, t0)
    }

    func testKeysThatNameNoSessionOfThisMacReachNoFile() async throws {
        let temp = try TempDirectory()
        try writeClaude(temp, [claudeLine("u1", user: "hi")])
        try temp.write(".claude/projects/-Users-x-demo/\(claudeID)/subagents/agent-\(claudeID).jsonl",
                       claudeLine("s1", user: "sub") + "\n")
        try temp.write(".claude/projects/-Users-x-demo/other.jsonl", claudeLine("o1", user: "other") + "\n")
        try temp.write("secret.jsonl", claudeLine("x1", user: "secret") + "\n")
        let reader = ConversationReader(configuration: configuration(temp))
        let cases: [(String, RemoteTranscript.Problem, String)] = [
            ("claude-code:44444444-4444-4444-8444-444444444444", .unknownSession, "claude-code"),
            ("claude-code:../../../secret", .unknownSession, "claude-code"),
            ("claude-code:-Users-x-demo/other", .unknownSession, "claude-code"),
            ("claude-code:", .unknownSession, "claude-code"),
            ("copilot-cli:../../secret", .unknownSession, "copilot-cli"),
            ("copilot-cli:.hidden", .unknownSession, "copilot-cli"),
            ("codex-cli:" + codexThread, .unknownSession, "codex-cli"),
            ("qwen-code:abc", .unsupportedAgent, "qwen-code"),
            ("copilot-ide:abc", .unsupportedAgent, "copilot-ide"),
            ("cursor:abc", .unknownSession, "cursor"),
            ("", .unknownSession, ""),
        ]
        for (session, problem, agent) in cases {
            let result = await transcript(reader, session)
            XCTAssertEqual(result.problem, problem, session)
            XCTAssertEqual(result.agent, agent, session)
            XCTAssertEqual(result.messages, [], session)
            XCTAssertEqual(result.answerID, "a-1", session)
        }
    }

    func testALinkedTranscriptIsNeverFollowed() async throws {
        let temp = try TempDirectory()
        let outside = try temp.write("outside.jsonl", claudeLine("x1", user: "not a transcript") + "\n")
        try temp.mkdir(".claude/projects/-Users-x-demo")
        try FileManager.default.createSymbolicLink(atPath: temp.path(".claude/projects/-Users-x-demo/\(claudeID).jsonl"),
                                                   withDestinationPath: outside)
        let reader = ConversationReader(configuration: configuration(temp))
        let result = await transcript(reader, "claude-code:" + claudeID)
        XCTAssertEqual(result.problem, .unreadable)
        XCTAssertEqual(result.messages, [])
    }

    func testFoldersWithoutAccessAreNeitherOfferedNorRead() async throws {
        let temp = try TempDirectory()
        try writeClaude(temp, [claudeLine("u1", user: "hi")])
        let reader = ConversationReader(configuration: configuration(temp, folders: [.copilot]))
        XCTAssertEqual(reader.agents, [.copilotCLI])
        let result = await transcript(reader, "claude-code:" + claudeID)
        XCTAssertEqual(result.problem, .unreadable)
        let none = ConversationReader(configuration: configuration(temp, folders: []))
        XCTAssertEqual(none.agents, [])
    }

    func testOnlyTheTailOfABigFileIsRead() async throws {
        let temp = try TempDirectory()
        let lines = (0..<40).map { claudeLine("u\($0)", user: "prompt \($0)") }
        try writeClaude(temp, lines)
        let reader = ConversationReader(configuration: configuration(temp), maxBytes: 1_000)
        let result = await transcript(reader, "claude-code:" + claudeID)
        XCTAssertNil(result.problem)
        XCTAssertTrue(result.truncated, "earlier messages are on the Mac but not in the record")
        XCTAssertEqual(result.messages.last?.text, "prompt 39")
        XCTAssertGreaterThan(result.messages.count, 2)
        XCTAssertLessThan(result.messages.count, 40)
        let first = try XCTUnwrap(result.messages.first?.text)
        XCTAssertTrue(first.hasPrefix("prompt "), "a cut first line is skipped, never half-read")
    }

    func testTheSignalFollowsTheFile() async throws {
        let temp = try TempDirectory()
        let path = try writeClaude(temp, [claudeLine("u1", user: "hi")])
        let reader = ConversationReader(configuration: configuration(temp))
        let session = "claude-code:" + claudeID
        let signal = await reader.signal(for: session)
        let before = try XCTUnwrap(signal)
        XCTAssertEqual(before.path, ClaudeTranscriptIngester.canonical(path))
        try temp.append(".claude/projects/-Users-x-demo/\(claudeID).jsonl", claudeLine("u2", user: "more") + "\n")
        let signals = await reader.signals(for: [session, "claude-code:44444444-4444-4444-8444-444444444444"])
        XCTAssertEqual(Array(signals.keys), [session])
        XCTAssertNotEqual(signals[session], before)
        XCTAssertGreaterThan(signals[session]?.size ?? 0, before.size)
    }

    func testCodexRolloutsComeFromTheLedgerOrTheirThreadID() async throws {
        let temp = try TempDirectory()
        let rollout = [
            #"{"timestamp":"2026-11-19T11:00:00.000Z","type":"session_meta","payload":{"id":"\#(codexThread)","cwd":"/Users/x/api"}}"#,
            #"{"timestamp":"2026-11-19T11:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"Add paging"}}"#,
            #"{"timestamp":"2026-11-19T11:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"pytest -q\"}"}}"#,
        ].joined(separator: "\n") + "\n"
        let path = try temp.write(".codex/sessions/2026/11/19/rollout-2026-11-19T11-00-00-\(codexThread).jsonl", rollout)
        let outside = try temp.write("rollout-2026-11-19T11-00-00-\(codexThread).jsonl", rollout)
        let store = try Store(path: temp.path("hoply.sqlite"), resolver: ProjectResolver(home: "/Users/x"))
        try await store.apply(LedgerBatch(sessions: [
            SessionUpdate(key: SessionKey(source: .codexCLI, id: "sess-1"), cwd: "/Users/x/api",
                          transcriptPath: ClaudeTranscriptIngester.canonical(path)),
            SessionUpdate(key: SessionKey(source: .codexCLI, id: "sess-2"), cwd: "/Users/x/api",
                          transcriptPath: outside),
        ]))
        let reader = ConversationReader(configuration: configuration(temp),
                                        store: try StoreReader(path: temp.path("hoply.sqlite")))
        let scanned = await transcript(reader, "codex-cli:" + codexThread.uppercased())
        XCTAssertEqual(scanned.messages.map(\.text), ["Add paging", "Bash pytest -q"])
        let ledger = await transcript(reader, "codex-cli:sess-1")
        XCTAssertEqual(ledger.messages.map(\.text), ["Add paging", "Bash pytest -q"])
        let refused = await transcript(reader, "codex-cli:sess-2")
        XCTAssertEqual(refused.problem, .unknownSession, "a ledger path outside Codex's folder is never read")
    }

    func testCopilotPathsAreShownFromItsWorkspaceFolder() async throws {
        let temp = try TempDirectory()
        let events = [
            #"{"type":"user.message","data":{"content":"Why does it fail?"},"timestamp":"2026-11-19T12:00:01.000Z"}"#,
            #"{"type":"tool.execution_start","data":{"toolName":"view","arguments":{"path":"/Users/x/web/src/app.ts"}},"timestamp":"2026-11-19T12:00:02.000Z"}"#,
            #"{"type":"user.message","data":{"content":"\#(TurnReply.reasonPrefix)Run the tests"},"timestamp":"2026-11-19T12:05:00.000Z"}"#,
        ].joined(separator: "\n") + "\n"
        try temp.write(".copilot/session-state/\(copilotID)/events.jsonl", events)
        try temp.write(".copilot/session-state/\(copilotID)/workspace.yaml", "id: \(copilotID)\ncwd: /Users/x/web\n")
        let reader = ConversationReader(configuration: configuration(temp))
        let result = await transcript(reader, "copilot-cli:" + copilotID)
        XCTAssertEqual(result.messages.map(\.text), ["Why does it fail?", "Read src/app.ts", "Run the tests"])
        XCTAssertEqual(result.messages.last?.role, .user, "an Away reply shows as what the user said")
    }

    func testAFileThatAppearsLaterIsFoundAfterTheRetryWindow() async throws {
        let temp = try TempDirectory()
        let reader = ConversationReader(configuration: configuration(temp))
        let session = "claude-code:" + claudeID
        let missing = await transcript(reader, session)
        XCTAssertEqual(missing.problem, .unknownSession)
        try writeClaude(temp, [claudeLine("u1", user: "hi")])
        let soon = await transcript(reader, session)
        XCTAssertEqual(soon.problem, .unknownSession, "a miss isn't rescanned on every loop")
        XCTAssertGreaterThan(ConversationReader.missRetry, 0)
    }
}

