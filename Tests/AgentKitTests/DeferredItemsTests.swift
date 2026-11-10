@testable import AgentKit
import Foundation
import XCTest

private struct RepoFileSystem: ProjectFileSystem {
    var directories: Set<String> = []
    var files: [String: String] = [:]

    func realPath(_ path: String) -> String? { path }
    func isDirectory(_ path: String) -> Bool { directories.contains(path) }
    func isFile(_ path: String) -> Bool { files[path] != nil }
    func readText(_ path: String) -> String? { files[path] }
}

final class SessionPidTests: XCTestCase {
    private let claudeA = SessionKey(source: .claudeCode, id: "a")
    private let claudeB = SessionKey(source: .claudeCode, id: "b")
    private let reportedAt = Date(timeIntervalSince1970: 5_000)
    private var classifier: DevServerClassifier {
        DevServerClassifier(hubPort: 4318, ownPID: 900, uid: 501, homeDirectory: "/Users/dev")
    }

    private func process(_ pid: Int32, parent: Int32 = 1, group: Int32? = nil, uid: UInt32 = 501, name: String = "node",
                         executable: String? = "/opt/homebrew/bin/node", _ arguments: [String] = ["node"],
                         started: TimeInterval? = nil, ports: [Int] = []) -> ScannedProcess {
        ScannedProcess(
            identity: ProcessIdentity(pid: pid, startedAt: Date(timeIntervalSince1970: started ?? 1_000 + Double(pid))),
            parentPID: parent, groupID: group ?? pid, uid: uid, name: name, executable: executable,
            arguments: arguments, cwd: "/Users/dev/Project/fiba",
            listeners: ports.map { ListeningSocket(port: $0, family: .ipv6, address: "::") })
    }

    private func claude(_ pid: Int32, uid: UInt32 = 501, started: TimeInterval? = nil) -> ScannedProcess {
        process(pid, uid: uid, name: "2.1.322", executable: "/Users/dev/.local/share/claude/versions/2.1.322", ["claude"],
                started: started)
    }

    private func request(_ path: String, headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, headers: headers,
                    body: Data(#"{"hook_event_name":"SessionStart","session_id":"s1","sessionId":"s1","cwd":"/tmp/x"}"#.utf8))
    }

    func testRouterReadsThePidHeader() {
        let router = HubRouter()
        XCTAssertEqual(router.handle(request("/hooks/claude-code", headers: ["x-hoply-pid": "4242"])).events.first?.agentPID,
                       4242)
        XCTAssertEqual(router.handle(request("/hooks/copilot-cli/sessionStart", headers: ["x-hoply-pid": "77"]))
            .events.first?.agentPID, 77)
        for bad in ["", "0", "1", "-5", "abc", "12 34", "99999999999", "4242; rm"] {
            XCTAssertNil(router.handle(request("/hooks/claude-code", headers: ["x-hoply-pid": bad])).events.first?.agentPID,
                         bad)
        }
        XCTAssertNil(router.handle(request("/hooks/claude-code", headers: [:])).events.first?.agentPID)
    }

    func testHeaderSurvivesTheParser() throws {
        let raw = "POST /hooks/claude-code HTTP/1.1\r\nX-Hoply-Pid: 4242\r\nContent-Length: 2\r\n\r\n{}"
        guard case .complete(let parsed) = HTTPRequestParser.parse(Data(raw.utf8)) else { return XCTFail("incomplete") }
        XCTAssertEqual(HubRouter.agentPID(parsed), 4242)
    }

    func testBoardKeepsTheReportedPidAndWhenItCame() {
        var board = SessionBoard()
        let t0 = Date(timeIntervalSince1970: 1_794_200_000)
        board.apply(AgentEvent(key: claudeA, kind: .sessionStarted, time: t0, fromHook: true, agentPID: 600))
        board.apply(AgentEvent(key: claudeA, kind: .toolStarted("Bash"), time: t0.addingTimeInterval(60), fromHook: true,
                               agentPID: 600))
        XCTAssertEqual(board.sessions[claudeA]?.reportedPID, 600)
        XCTAssertEqual(board.sessions[claudeA]?.pidReportedAt, t0, "the first report dates the pid")
        board.apply(AgentEvent(key: claudeA, kind: .activity, time: t0.addingTimeInterval(90), fromHook: false,
                               agentPID: 999))
        XCTAssertEqual(board.sessions[claudeA]?.reportedPID, 600, "telemetry never sets it")
        board.apply(AgentEvent(key: claudeA, kind: .toolStarted("Bash"), time: t0.addingTimeInterval(120), fromHook: true,
                               agentPID: 650))
        XCTAssertEqual(board.sessions[claudeA]?.reportedPID, 650)
        XCTAssertEqual(board.sessions[claudeA]?.pidReportedAt, t0.addingTimeInterval(120))
        board.apply(AgentEvent(key: claudeB, kind: .sessionStarted, time: t0, fromHook: true))
        XCTAssertNil(board.sessions[claudeB]?.reportedPID)
    }

    func testAReportedPidIsTrustedOnlyWhenItIsTheAgent() {
        let lineage = ProcessLineage(ProcessSnapshot(processes: [
            claude(600),
            process(601, parent: 600, name: "sh", executable: "/bin/sh", ["/bin/sh", "-c", "curl"]),
            process(602, parent: 601, name: "sh", executable: "/bin/sh", ["sh"]),
            process(700, name: "zsh", executable: "/bin/zsh", ["-zsh"]),
            claude(800, uid: 0),
            claude(850, started: 9_000),
            process(860, name: "copilot", executable: "/opt/homebrew/bin/node",
                    ["node", "/opt/homebrew/lib/node_modules/@github/copilot/index.js"]),
        ]))
        func agent(_ pid: Int32, _ source: AgentSource = .claudeCode) -> Int32? {
            SessionProcess.agent(reportedPID: pid, source: source, reportedAt: reportedAt, uid: 501, lineage: lineage)?.pid
        }
        XCTAssertEqual(agent(600), 600)
        XCTAssertEqual(agent(601), 600, "an intermediate shell leads up to the agent")
        XCTAssertEqual(agent(602), 600)
        XCTAssertNil(agent(700), "a shell with no agent above it")
        XCTAssertNil(agent(4_000), "no such process")
        XCTAssertNil(agent(800), "another user's process")
        XCTAssertNil(agent(850), "started after the hook fired: the pid was reused")
        XCTAssertNil(agent(600, .copilotCLI), "not this session's agent")
        XCTAssertEqual(agent(860, .copilotCLI), 860)
    }

    func testTwoSessionsInOneFolderTieToTheirOwnServers() throws {
        let snapshot = ProcessSnapshot(processes: [
            claude(600),
            process(601, parent: 600, name: "zsh", executable: "/bin/zsh", ["/bin/zsh", "-c", "npm run dev"]),
            process(602, parent: 601, group: 601, ["node", "/p/node_modules/.bin/vite"], ports: [5173]),
            claude(610),
            process(611, parent: 610, name: "zsh", executable: "/bin/zsh", ["/bin/zsh", "-c", "npm run dev"]),
            process(612, parent: 611, group: 611, ["node", "/p/node_modules/.bin/vite"], ports: [5174]),
        ])
        let folder = "/Users/dev/Project/fiba"
        let byDirectory = [DevServerClassifier.Session(key: claudeA, cwd: folder),
                           DevServerClassifier.Session(key: claudeB, cwd: folder)]
        XCTAssertEqual(classifier.servers(in: snapshot, sessions: byDirectory).map(\.sessionMatch),
                       [.directory, .directory], "without pids the folder cannot tell them apart")

        let reported = [
            DevServerClassifier.Session(key: claudeA, cwd: folder, reportedPID: 610, reportedAt: reportedAt),
            DevServerClassifier.Session(key: claudeB, cwd: folder, reportedPID: 600, reportedAt: reportedAt),
        ]
        let servers = classifier.servers(in: snapshot, sessions: reported)
        XCTAssertEqual(servers.map(\.port), [5173, 5174])
        XCTAssertEqual(servers.map(\.session), [claudeB, claudeA])
        XCTAssertEqual(servers.map(\.sessionMatch), [.lineage, .lineage])
        XCTAssertEqual(classifier.verified(reported, in: snapshot).map(\.pid), [610, 600])

        let forged = [DevServerClassifier.Session(key: claudeA, cwd: folder, reportedPID: 601, reportedAt: reportedAt),
                      DevServerClassifier.Session(key: claudeB, cwd: folder, reportedPID: 4_000, reportedAt: reportedAt)]
        XCTAssertEqual(classifier.verified(forged, in: snapshot).map(\.pid), [600, nil])
    }
}

final class PathRulesTests: XCTestCase {
    private let rules = PathRules([.init(path: "/Users/dev/work", projectID: 1),
                                   .init(path: "/Users/dev/work/client/", projectID: 2),
                                   .init(path: "/Users/dev", projectID: 9)],
                                  exactOnly: ["/Users/dev"])

    func testTheLongestAssignedFolderWins() {
        XCTAssertEqual(rules.projectID(forRealPath: "/Users/dev/work"), 1)
        XCTAssertEqual(rules.projectID(forRealPath: "/Users/dev/work/scripts/x"), 1)
        XCTAssertEqual(rules.projectID(forRealPath: "/Users/dev/work/client"), 2)
        XCTAssertEqual(rules.projectID(forRealPath: "/Users/dev/work/client/app/"), 2)
        XCTAssertNil(rules.projectID(forRealPath: "/Users/dev/workshop"), "a name prefix is not a folder prefix")
        XCTAssertNil(rules.projectID(forRealPath: "/Users/other"))
        XCTAssertNil(PathRules().projectID(forRealPath: "/Users/dev/work"))
    }

    func testHomeIsAssignedAloneNotEverythingBelowIt() {
        XCTAssertEqual(rules.projectID(forRealPath: "/Users/dev"), 9)
        XCTAssertNil(rules.projectID(forRealPath: "/Users/dev/notes"))
    }

    func testARepositoryBelowTheFolderKeepsItsOwnProject() {
        XCTAssertNil(rules.projectID(forRealPath: "/Users/dev/work/api/src", repoAnchor: "/Users/dev/work/api"))
        XCTAssertEqual(rules.projectID(forRealPath: "/Users/dev/work/src", repoAnchor: "/Users/dev/work"), 1,
                       "the assigned folder is the repository itself")
        XCTAssertEqual(rules.projectID(forRealPath: "/Users/dev/work/client/src", repoAnchor: "/Users/dev"), 2,
                       "a folder inside a bigger repository can be assigned away from it")
        XCTAssertEqual(rules.projectID(forRealPath: "/Users/dev/work/client/app", repoAnchor: "/Users/dev/work/client/app"), nil)
    }

    func testAssignablePaths() {
        XCTAssertTrue(PathRules.isAssignable("/Users/dev/work"))
        for bad in ["", "/", "//", "/..", "relative/path", "~/work"] { XCTAssertFalse(PathRules.isAssignable(bad), bad) }
    }
}

final class GitRemoteTests: XCTestCase {
    func testSshAndHttpsFormsOfOneRepositoryAgree() {
        let forms = ["git@github.com:Acme/Fiba.git", "https://github.com/acme/fiba", "https://github.com/acme/fiba.git/",
                     "ssh://git@github.com:22/acme/fiba.git", "https://user:secret@github.com/acme/fiba.git",
                     "git://GitHub.com/acme/fiba", "github.com:acme/fiba", "  https://github.com/acme/fiba\n"]
        for form in forms { XCTAssertEqual(GitRemote.identity(form), "github.com/acme/fiba", form) }
        XCTAssertEqual(GitRemote.identity("https://gitlab.example.com:8443/group/sub/repo.git"),
                       "gitlab.example.com/group/sub/repo")
        XCTAssertNotEqual(GitRemote.identity("git@github.com:acme/fiba.git"), GitRemote.identity("git@github.com:acme/fiba-web.git"))
        XCTAssertNotEqual(GitRemote.identity("git@github.com:acme/fiba.git"), GitRemote.identity("git@gitlab.com:acme/fiba.git"))
        XCTAssertEqual(GitRemote.identity("/srv/git/fiba.git"), "file:/srv/git/fiba")
        XCTAssertEqual(GitRemote.identity("file:///srv/git/fiba.git"), "file:/srv/git/fiba")
        for bad in ["", "../fiba", "fiba", "https://", "ftp://example.com/x", "git@github.com:", "a b:c/d"] {
            XCTAssertNil(GitRemote.identity(bad), bad)
        }
        XCTAssertFalse(GitRemote.identity("https://user:secret@github.com/acme/fiba.git")?.contains("secret") ?? true)
    }

    func testOriginUrlFromConfig() {
        let config = """
            [core]
            \trepositoryformatversion = 0
            [remote "upstream"]
            \turl = git@github.com:other/fiba.git
            # url = git@github.com:commented/out.git
            [Remote "origin"]
            \tURL = "git@github.com:acme/fiba.git"
            \tfetch = +refs/heads/*:refs/remotes/origin/*
            [branch "main"]
            \tremote = origin
            \turl = not-this
            """
        XCTAssertEqual(GitRemote.url(inConfig: config), "git@github.com:acme/fiba.git")
        XCTAssertEqual(GitRemote.url(inConfig: config, remote: "upstream"), "git@github.com:other/fiba.git")
        XCTAssertNil(GitRemote.url(inConfig: "[remote \"Origin\"]\nurl = x\n"), "remote names are case-sensitive")
        XCTAssertNil(GitRemote.url(inConfig: "[core]\nbare = false\n"))
        XCTAssertNil(GitRemote.url(inConfig: ""))
    }

    func testOriginOfARepoAndOfALinkedWorktree() {
        let fs = RepoFileSystem(directories: ["/p/fiba/.git"], files: [
            "/p/fiba/.git/config": "[remote \"origin\"]\n\turl = git@github.com:acme/fiba.git\n",
            "/p/fiba-wt/.git": "gitdir: /p/fiba/.git/worktrees/wt\n",
            "/p/fiba/.git/worktrees/wt/commondir": "../..\n",
            "/p/plain/readme": "x",
        ])
        XCTAssertEqual(GitRemote.originURL(ofRepoAt: "/p/fiba", fileSystem: fs), "git@github.com:acme/fiba.git")
        XCTAssertEqual(GitRemote.originURL(ofRepoAt: "/p/fiba-wt", fileSystem: fs), "git@github.com:acme/fiba.git")
        XCTAssertNil(GitRemote.originURL(ofRepoAt: "/p/plain", fileSystem: fs))
        XCTAssertNil(GitRemote.originURL(ofRepoAt: "/p/gone", fileSystem: fs))
    }

    func testCloneSuggestions() {
        func project(_ id: Int64, _ name: String) -> ProjectRef {
            ProjectRef(id: id, root: "/p/\(name)", name: name, kind: .repo)
        }
        let projects = [(project: project(1, "fiba"), originURL: "git@github.com:acme/fiba.git"),
                        (project: project(2, "fiba-copy"), originURL: "https://github.com/acme/fiba"),
                        (project: project(3, "other"), originURL: "git@github.com:acme/other.git"),
                        (project: project(4, "odd"), originURL: "../relative")]
        let suggestions = MergeSuggestion.clones(projects)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.id, "clone:github.com/acme/fiba:1,2")
        XCTAssertEqual(suggestions.first?.projects.map(\.id), [1, 2])
        XCTAssertEqual(suggestions.first?.summary, "fiba and fiba-copy share origin github.com/acme/fiba")
        XCTAssertEqual(MergeSuggestion.clones(projects, dismissed: ["clone:github.com/acme/fiba:1,2"]), [])

        let third = projects + [(project: project(5, "fiba-3"), originURL: "ssh://git@github.com/acme/fiba.git")]
        let again = MergeSuggestion.clones(third, dismissed: ["clone:github.com/acme/fiba:1,2"])
        XCTAssertEqual(again.map(\.id), ["clone:github.com/acme/fiba:1,2,5"], "a new clone brings the suggestion back")
        XCTAssertEqual(again.first?.summary, "fiba, fiba-copy and fiba-3 share origin github.com/acme/fiba")
    }
}

final class StateSpanTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_000)

    func testAdjacentSpansOfOneStateJoin() {
        let spans = [StateSpan(state: .working, start: t0, end: t0.addingTimeInterval(60)),
                     StateSpan(state: .working, start: t0.addingTimeInterval(60.4), end: t0.addingTimeInterval(90)),
                     StateSpan(state: .yourTurn, start: t0.addingTimeInterval(90), end: t0.addingTimeInterval(100)),
                     StateSpan(state: .working, start: t0.addingTimeInterval(200), end: t0.addingTimeInterval(210)),
                     StateSpan(state: .working, start: t0.addingTimeInterval(210), end: nil)]
        XCTAssertEqual(StateSpan.coalesced(spans.reversed()), [
            StateSpan(state: .working, start: t0, end: t0.addingTimeInterval(90)),
            StateSpan(state: .yourTurn, start: t0.addingTimeInterval(90), end: t0.addingTimeInterval(100)),
            StateSpan(state: .working, start: t0.addingTimeInterval(200), end: nil),
        ])
        let totals = StateSpan.timeInState(spans, now: t0.addingTimeInterval(240))
        XCTAssertEqual(totals[.working] ?? 0, 60 + 29.6 + 10 + 30, accuracy: 0.001)
        XCTAssertEqual(totals[.yourTurn], 10)
        XCTAssertNil(totals[.idle])
    }
}

final class QwenPromptTests: XCTestCase {
    private func log(_ name: String, session: String? = "q1", promptID: String? = "p7",
                     nanos: UInt64? = 1_794_228_000_123_456_789, resource: [String: AttributeValue] = [:],
                     service: String = "qwen-code") -> TelemetryRecord {
        var attributes: [String: AttributeValue] = ["prompt_length": .int(42)]
        if let session { attributes["session.id"] = .string(session) }
        if let promptID { attributes["prompt_id"] = .string(promptID) }
        return TelemetryRecord(signal: .log, name: name, attributes: attributes,
                               resource: ["service.name": .string(service)].merging(resource) { _, new in new },
                               time: nanos.map { Date(timeIntervalSince1970: Double($0) / 1e9) }, timeUnixNano: nanos)
    }

    func testAUserPromptBecomesOnePromptRecord() throws {
        let prompt = try XCTUnwrap(TelemetryUsage.prompt(log("qwen-code.user_prompt", resource: [
            "hoply.cwd": .string("/Users/dev/Project/fiba"), "process.pid": .int(4242),
        ])))
        XCTAssertEqual(prompt.dedupeKey, "qwp:q1:p7:1794228000123456789")
        XCTAssertEqual(prompt.session, SessionKey(source: .qwenCode, id: "q1"))
        XCTAssertEqual(prompt.cwd, "/Users/dev/Project/fiba")
        XCTAssertEqual(prompt.processID, 4242)
        XCTAssertEqual(TelemetryUsage.prompt(log("qwen-code.user_prompt")), TelemetryUsage.prompt(log("qwen-code.user_prompt")))
        XCTAssertNotEqual(TelemetryUsage.prompt(log("qwen-code.user_prompt"))?.dedupeKey,
                          TelemetryUsage.prompt(log("qwen-code.user_prompt", promptID: "p8"))?.dedupeKey)
    }

    func testOnlyQwenUserPromptsWithATimestampCount() {
        XCTAssertNil(TelemetryUsage.prompt(log("qwen-code.api_response")))
        XCTAssertNil(TelemetryUsage.prompt(log("qwen-code.user_prompt", nanos: nil)), "no stable identity")
        XCTAssertNil(TelemetryUsage.prompt(log("claude_code.user_prompt", service: "claude-code")),
                     "Claude Code turns come from its transcripts")
        XCTAssertNotNil(TelemetryUsage.prompt(log("qwen-code.user_prompt", promptID: nil)))
    }

    func testTheRouterHandsPromptsOutAndTheFixtureHasNone() throws {
        let outcome = HubRouter().handle(HTTPRequest(method: "POST", path: "/v1/logs",
                                                     headers: ["content-type": "application/json"],
                                                     body: try Fixture.data("qwen_logs.json")))
        XCTAssertEqual(outcome.usage.count, 1)
        XCTAssertEqual(outcome.prompts, [])

        let body = """
            {"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"qwen-code"}}]},
            "scopeLogs":[{"logRecords":[{"timeUnixNano":"1794228000123456789","attributes":[
            {"key":"event.name","value":{"stringValue":"qwen-code.user_prompt"}},
            {"key":"session.id","value":{"stringValue":"q1"}},{"key":"prompt_id","value":{"stringValue":"p7"}},
            {"key":"prompt_length","value":{"intValue":"42"}}]}]}]}]}
            """
        let prompted = HubRouter().handle(HTTPRequest(method: "POST", path: "/v1/logs",
                                                      headers: ["content-type": "application/json"],
                                                      body: Data(body.utf8)))
        XCTAssertEqual(prompted.prompts.map(\.dedupeKey), ["qwp:q1:p7:1794228000123456789"])
        XCTAssertEqual(prompted.usage, [])
        XCTAssertEqual(prompted.events.map(\.kind), [.promptSubmitted(nil)])
    }

    func testPromptsAloneStillMakeASessionUpdate() {
        let t0 = Date(timeIntervalSince1970: 1_794_200_000)
        let batch = TelemetryUsage.ledgerBatch([], prompts: [
            PromptRecord(dedupeKey: "a", source: .qwenCode, sessionID: "q1", timestamp: t0, cwd: "/p/fiba"),
            PromptRecord(dedupeKey: "b", source: .qwenCode, sessionID: "q1", timestamp: t0.addingTimeInterval(60)),
        ])
        XCTAssertEqual(batch.sessions, [SessionUpdate(key: SessionKey(source: .qwenCode, id: "q1"), firstAt: t0,
                                                      lastAt: t0.addingTimeInterval(60), cwd: "/p/fiba")])
        XCTAssertEqual(batch.prompts.count, 2)
        XCTAssertFalse(batch.isEmpty)
        XCTAssertFalse(LedgerBatch(prompts: batch.prompts).isEmpty)
    }
}
