import AgentKit
import Foundation
import XCTest

final class LaunchScriptTests: XCTestCase {
    private let id = "0b6f6c1e-8a57-4f0e-9d0c-2f6a4a1f3b77"

    func testClaudeStartScript() throws {
        let script = try XCTUnwrap(LaunchScript.script(source: .claudeCode, sessionID: nil, prompt: "Fix the login bug",
                                                       cwd: "/Users/dev/Project/api"))
        XCTAssertEqual(script, """
            #!/bin/zsh
            rm -f -- "$0"
            cd -- '/Users/dev/Project/api' || { print -r -- "Hoply: cannot open" '/Users/dev/Project/api'; exit 1; }
            if command -v 'claude' >/dev/null 2>&1; then
              exec 'claude' '--' 'Fix the login bug'
            fi
            exec /bin/zsh -ilc 'exec "$0" "$@"' 'claude' '--' 'Fix the login bug'

            """)
    }

    func testEachAgentsVerifiedSyntax() {
        let cases: [(AgentSource, [String], [String])] = [
            (.claudeCode, ["claude", "--", "go on"], ["claude", "--resume", id, "--", "go on"]),
            (.codexCLI, ["codex", "--", "go on"], ["codex", "resume", id, "--", "go on"]),
            (.copilotCLI, ["copilot", "--interactive=go on"], ["copilot", "--resume=\(id)", "--interactive=go on"]),
        ]
        for (source, start, resume) in cases {
            XCTAssertTrue(LaunchScript.canStart(source), source.rawValue)
            XCTAssertTrue(LaunchScript.canContinue(source), source.rawValue)
            XCTAssertEqual(LaunchScript.arguments(source: source, sessionID: nil, prompt: "go on"), start)
            XCTAssertEqual(LaunchScript.arguments(source: source, sessionID: id, prompt: "go on"), resume)
        }
        for source in [AgentSource.qwenCode, .copilotIDE] {
            XCTAssertFalse(LaunchScript.canStart(source), "no verified prompt syntax yet")
            XCTAssertFalse(LaunchScript.canContinue(source))
            XCTAssertNil(LaunchScript.script(source: source, sessionID: nil, prompt: "go", cwd: "/tmp"))
            XCTAssertNil(LaunchScript.script(source: source, sessionID: id, prompt: "go", cwd: "/tmp"))
        }
    }

    func testNoPermissionBypassFlags() {
        let banned = ["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--yolo",
                      "--allow-all", "--allow-all-tools", "--allow-all-paths", "--full-auto",
                      "--dangerously-bypass-approvals-and-sandbox", "--autopilot", "danger-full-access"]
        for source in AgentSource.allCases {
            let all = (source.info.startArguments ?? []) + (source.info.continueArguments ?? [])
            for flag in banned {
                XCTAssertFalse(all.contains { $0.contains(flag) }, "\(source.rawValue) \(flag)")
            }
        }
    }

    func testHostilePromptsStayOneQuotedArgument() throws {
        let prompts = [
            "it's \"quoted\" and $HOME",
            "$(touch /tmp/pwned) `id` ${PATH}",
            "line one\nline two; rm -rf ~ && echo done\n'\nexit 0",
            "--dangerously-skip-permissions",
            "-p hi",
            "'; exec /bin/sh; '",
            "\\'\\\"\\",
            "{session} {prompt}",
        ]
        for source in [AgentSource.claudeCode, .codexCLI, .copilotCLI] {
            for prompt in prompts {
                let arguments = try XCTUnwrap(LaunchScript.arguments(source: source, sessionID: id, prompt: prompt))
                let passed = prompt.contains(where: \.isWhitespace) ? prompt : prompt + " "
                let carried = source == .copilotCLI ? "--interactive=" + passed : passed
                XCTAssertEqual(arguments.last, carried, "\(source.rawValue): the prompt is the last argument, intact")
                XCTAssertEqual(arguments.count, source.info.continueArguments?.count)
                let script = try XCTUnwrap(LaunchScript.script(source: source, sessionID: id, prompt: prompt,
                                                               cwd: "/Users/dev/My Project"))
                let quoted = arguments.map(ResumeScript.shellQuoted).joined(separator: " ")
                XCTAssertTrue(script.contains("  exec \(quoted)\nfi\n"), script)
                XCTAssertTrue(script.hasSuffix("exec /bin/zsh -ilc 'exec \"$0\" \"$@\"' \(quoted)\n"), script)
            }
        }
        let start = try XCTUnwrap(LaunchScript.arguments(source: .copilotCLI, sessionID: nil, prompt: "{session} x"))
        XCTAssertEqual(start, ["copilot", "--interactive={session} x"], "placeholders in the prompt stay text")
    }

    func testOneWordPromptsCanNotNameASubcommand() {
        XCTAssertEqual(LaunchScript.arguments(source: .claudeCode, sessionID: nil, prompt: "purge"),
                       ["claude", "--", "purge "])
        XCTAssertEqual(LaunchScript.arguments(source: .claudeCode, sessionID: id, prompt: " update\n"),
                       ["claude", "--resume", id, "--", "update "])
        XCTAssertEqual(LaunchScript.arguments(source: .codexCLI, sessionID: nil, prompt: "doctor"),
                       ["codex", "--", "doctor "])
        XCTAssertEqual(LaunchScript.arguments(source: .claudeCode, sessionID: nil, prompt: "run purge"),
                       ["claude", "--", "run purge"], "a prompt with a space is passed as it is")
    }

    func testShellModePromptsGiveNoScript() {
        for prompt in ["!rm -rf ~", "  \n\t!ls", "\u{1B}!ls", "!"] {
            XCTAssertTrue(LaunchScript.isShellMode(prompt), prompt)
            for source in [AgentSource.claudeCode, .codexCLI, .copilotCLI] {
                XCTAssertNil(LaunchScript.arguments(source: source, sessionID: nil, prompt: prompt), prompt)
                XCTAssertNil(LaunchScript.script(source: source, sessionID: nil, prompt: prompt, cwd: "/tmp"), prompt)
            }
        }
        for prompt in ["say !hi", "/compact", "¡hola!", "- !x"] {
            XCTAssertFalse(LaunchScript.isShellMode(prompt), prompt)
            XCTAssertNotNil(LaunchScript.arguments(source: .claudeCode, sessionID: nil, prompt: prompt), prompt)
        }
    }

    func testPromptsAreTrimmedAndCleanedOfControlCharacters() {
        XCTAssertEqual(LaunchScript.normalizedPrompt("  fix\r\nit\rnow\t \n"), "fix\nit\nnow")
        XCTAssertEqual(LaunchScript.normalizedPrompt("a\u{1B}[31mred\u{07}\u{0}b\u{7F}"), "a[31mredb")
        XCTAssertEqual(LaunchScript.normalizedPrompt("tab\tkept"), "tab\tkept")
        XCTAssertNil(LaunchScript.normalizedPrompt(nil))
        XCTAssertNil(LaunchScript.normalizedPrompt(" \n\t\r "))
        XCTAssertNil(LaunchScript.normalizedPrompt("\u{0}\u{1B}"))
    }

    func testInvalidInputGivesNoScript() {
        XCTAssertNil(LaunchScript.script(source: .claudeCode, sessionID: nil, prompt: " \n ", cwd: "/tmp"))
        let long = String(repeating: "x", count: LaunchScript.maxPromptLength + 1)
        XCTAssertNil(LaunchScript.script(source: .claudeCode, sessionID: nil, prompt: long, cwd: "/tmp"))
        XCTAssertNotNil(LaunchScript.script(source: .claudeCode, sessionID: nil, prompt: String(long.dropFirst()),
                                            cwd: "/tmp"))
        for bad in ["", "-rf", "--dangerously-skip-permissions", "a b", "$(id)", "a\nb", "../x"] {
            XCTAssertNil(LaunchScript.script(source: .claudeCode, sessionID: bad, prompt: "go", cwd: "/tmp"), bad)
        }
        XCTAssertNil(LaunchScript.script(source: .claudeCode, sessionID: nil, prompt: "go", cwd: "relative"))
        XCTAssertNil(LaunchScript.script(source: .claudeCode, sessionID: nil, prompt: "go", cwd: "/a\nb"))
        XCTAssertNil(LaunchScript.script(source: .claudeCode, sessionID: nil, prompt: "go", cwd: "/a\u{0}b"))
    }

    func testFileNamesArePrunedWithResumeScripts() {
        let name = LaunchScript.fileName(source: .codexCLI, answerID: "C0FFEE00-0000-4000-8000-000000000007")
        XCTAssertTrue(name.hasPrefix("hoply-launch-codex-cli-"))
        XCTAssertTrue(name.hasSuffix(".command"))
        XCTAssertEqual(name, LaunchScript.fileName(source: .codexCLI, answerID: "C0FFEE00-0000-4000-8000-000000000007"))
        XCTAssertEqual(LaunchScript.fileName(source: .codexCLI, answerID: "../../x; rm").count, name.count,
                       "the answer id never reaches the file name")
        XCTAssertTrue(ResumeScript.isScriptName(name))
        for bad in ["hoply-launch-codex-cli-0123.command", "hoply-launch-cursor-0123456789abcdef.command",
                    "hoply-launch-codex-cli-0123456789ABCDEF.command", "hoply-launch-codex-cli-0123456789abcdef.sh"] {
            XCTAssertFalse(ResumeScript.isScriptName(bad), bad)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let files = [(name: name, modified: now.addingTimeInterval(-8 * 86_400)),
                     (name: "notes.command", modified: now.addingTimeInterval(-30 * 86_400))]
        XCTAssertEqual(ResumeScript.staleFileNames(files, now: now), [name])
    }
}

final class LaunchCatalogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let api = ProjectRef(id: 1, root: "/Users/dev/Project/api", name: "api", kind: .repo)
    private let web = ProjectRef(id: 2, root: "/Users/dev/Project/web", name: "web", displayName: "Website", kind: .repo)
    private let scratch = ProjectRef(id: 3, root: "/Users/dev/Library/Application Support/Claude/scratch-workspaces",
                                     name: "Scratch", kind: .scratch)
    private let far = ProjectRef(id: 4, root: "/Users/dev/old", name: "old", kind: .folder)

    private func recent(_ id: String, _ source: AgentSource = .claudeCode, project: ProjectRef?, cwd: String? = nil,
                        title: String? = nil, ago: TimeInterval) -> RecentSession {
        RecentSession(key: SessionKey(source: source, id: id), project: project, title: title,
                      cwd: cwd ?? project?.root ?? "/Users/dev", lastAt: t0.addingTimeInterval(-ago))
    }

    private func board() -> [AgentSession] {
        var board = SessionBoard()
        board.apply(AgentEvent(key: SessionKey(source: .claudeCode, id: "live"), kind: .promptSubmitted("x"), time: t0,
                               cwd: api.root, fromHook: true))
        board.apply(AgentEvent(key: SessionKey(source: .claudeCode, id: "ended"), kind: .sessionStarted, time: t0,
                               cwd: api.root, fromHook: true))
        board.apply(AgentEvent(key: SessionKey(source: .claudeCode, id: "ended"), kind: .sessionEnded(nil),
                               time: t0.addingTimeInterval(1), fromHook: true))
        return board.ordered
    }

    private func catalog() -> LaunchCatalog {
        LaunchCatalog.build(projects: [api, web, scratch, api], sessions: [
            recent("c1", project: api, cwd: api.root + "/server", title: "Fix the login", ago: 600),
            recent("019c0000-0000-7000-8000-000000000001", .codexCLI, project: web, title: "Ship", ago: 300),
            recent("cp-1", .copilotCLI, project: web, ago: 900),
            recent("q1", .qwenCode, project: api, ago: 100),
            recent("ide", .copilotIDE, project: api, ago: 100),
            recent("live", project: api, ago: 50),
            recent("ended", project: api, ago: 40),
            recent("far", project: far, ago: 30),
            recent("nowhere", project: nil, ago: 20),
            recent("bad id", project: api, ago: 10),
            recent("s9", project: scratch, ago: 10),
        ], board: board(), available: Set(AgentSource.allCases))
    }

    func testProjectsCarryAnOpaqueIDAndTheStartableAgents() throws {
        let catalog = catalog()
        XCTAssertEqual(catalog.projects.map(\.name), ["api", "Website"], "scratch folders and duplicates are left out")
        XCTAssertEqual(catalog.projects.map(\.root), [api.root, web.root])
        let id = try XCTUnwrap(catalog.projects.first?.id)
        XCTAssertEqual(id, LaunchCatalog.projectID(root: api.root))
        XCTAssertEqual(id.count, 16)
        XCTAssertFalse(id.contains("/"))
        XCTAssertNotEqual(id, LaunchCatalog.projectID(root: web.root))
        XCTAssertEqual(catalog.projects.first?.agents, [.claudeCode, .copilotCLI, .codexCLI],
                       "AgentSource order, only agents with a verified prompt syntax")

        XCTAssertEqual(catalog.available, [.claudeCode, .copilotCLI, .codexCLI])

        let some = LaunchCatalog.build(projects: [api], sessions: [], available: [.codexCLI, .qwenCode, .copilotIDE])
        XCTAssertEqual(some.projects.first?.agents, [.codexCLI])
        XCTAssertEqual(some.available, [.codexCLI], "agents without a verified prompt syntax are never offered")
        let none = LaunchCatalog.build(projects: [api], sessions: [recent("c1", project: api, ago: 1)], available: [])
        XCTAssertEqual(none.projects.first?.agents, [])
        XCTAssertEqual(none.sessions, [])
        let many = (0..<30).map { ProjectRef(id: Int64($0), root: "/p/\($0)", name: "p\($0)", kind: .repo) }
        XCTAssertEqual(LaunchCatalog.build(projects: many, sessions: [], available: [.claudeCode]).projects.count,
                       LaunchCatalog.maxProjects)
    }

    func testAvailableAgentsAreTheOnesWithHoplysHooks() {
        let statuses: [ConnectableAgent: ConnectionStatus] = [.claudeCode: .connected, .copilotCLI: .notConnected,
                                                              .codexCLI: .outdated]
        XCTAssertEqual(LaunchCatalog.available(statuses), [.claudeCode, .codexCLI])
        XCTAssertEqual(LaunchCatalog.available([.claudeCode: .notInstalled, .codexCLI: .unreadable("x")]), [])
        XCTAssertEqual(LaunchCatalog.available([:]), [], "statuses not loaded yet: nothing is offered")
    }

    func testResumableSessionsAreEndedOnesThatCanContinue() {
        let catalog = catalog()
        XCTAssertEqual(catalog.sessions.map(\.key.id),
                       ["ended", "019c0000-0000-7000-8000-000000000001", "c1", "cp-1"],
                       "newest first; never a live session, an agent that can't continue, or an unlisted project")
        XCTAssertEqual(catalog.sessions[2], LaunchCatalog.Session(key: SessionKey(source: .claudeCode, id: "c1"),
                                                                  projectID: LaunchCatalog.projectID(root: api.root),
                                                                  title: "Fix the login", cwd: api.root + "/server",
                                                                  endedAt: t0.addingTimeInterval(-600)))
        let codexOnly = LaunchCatalog.build(projects: [api, web], sessions: [
            recent("c1", project: api, ago: 1), recent("cx", .codexCLI, project: web, ago: 2),
        ], available: [.codexCLI])
        XCTAssertEqual(codexOnly.sessions.map(\.key.id), ["cx"])
        let many = (0..<20).map { recent("s\($0)", project: api, ago: TimeInterval($0)) }
        XCTAssertEqual(LaunchCatalog.build(projects: [api], sessions: many, available: [.claudeCode]).sessions.map(\.key.id),
                       (0..<LaunchCatalog.maxSessions).map { "s\($0)" })
    }

    func testRemoteBlockHasNoPaths() throws {
        let long = String(repeating: "t", count: RemoteSchema.titleLimit + 20)
        let catalog = LaunchCatalog.build(projects: [web], sessions: [recent("c1", project: web, title: long, ago: 5)],
                                          available: Set(AgentSource.allCases))
        let last = RemoteLaunch.Result(answerID: "a-1", outcome: .started, at: t0)
        let block = catalog.remote(last: last)
        XCTAssertEqual(block.projects, [RemoteLaunch.Project(id: LaunchCatalog.projectID(root: web.root), name: "Website",
                                                             agents: ["claude-code", "copilot-cli", "codex-cli"])])
        XCTAssertEqual(block.projects.first?.sources, [.claudeCode, .copilotCLI, .codexCLI])
        XCTAssertEqual(block.resumable.map(\.key), ["claude-code:c1"])
        XCTAssertEqual(block.resumable.first?.source, .claudeCode)
        XCTAssertEqual(block.resumable.first?.title?.count, RemoteSchema.titleLimit + 1)
        XCTAssertEqual(block.resumable.first?.endedAt, t0.addingTimeInterval(-5))
        XCTAssertEqual(block.promptLimit, LaunchScript.maxPromptLength)
        XCTAssertEqual(block.last, last)
        let snapshot = RemoteSnapshot(device: "mac-1", away: false, updatedAt: t0, launch: block)
        let json = String(decoding: try RemoteSchema.encode(snapshot), as: UTF8.self)
        XCTAssertFalse(json.contains("/Users"), json)
        XCTAssertFalse(json.contains("Project"), json)
    }
}

final class RemoteLaunchAnswerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let device = "mac-1"
    private let api = ProjectRef(id: 1, root: "/Users/dev/Project/api", name: "api", kind: .repo)
    private let web = ProjectRef(id: 2, root: "/Users/dev/Project/web", name: "web", kind: .repo)
    private lazy var apiID = LaunchCatalog.projectID(root: api.root)
    private lazy var webID = LaunchCatalog.projectID(root: web.root)
    private lazy var sessions = [
        RecentSession(key: SessionKey(source: .claudeCode, id: "c1"), project: api, cwd: api.root + "/server",
                      lastAt: t0.addingTimeInterval(-600)),
        RecentSession(key: SessionKey(source: .codexCLI, id: "cx-1"), project: web, cwd: web.root,
                      lastAt: t0.addingTimeInterval(-300)),
    ]
    private lazy var catalog = LaunchCatalog.build(projects: [api, web], sessions: sessions,
                                                   available: Set(AgentSource.allCases))

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func resolve(_ answers: [RemoteAnswer], catalog: LaunchCatalog?? = .none, handled: Set<String> = [],
                         now: Date? = nil) -> RemoteResolution {
        RemoteAnswers.resolve(answers, approvals: [], replies: [], device: device, handled: handled,
                              launch: catalog ?? self.catalog, now: now ?? at(30))
    }

    private func launch(_ agent: String = "claude-code", project: String? = nil, session: String? = nil,
                        prompt: String = "Fix the flaky test", at seconds: TimeInterval = 0) -> RemoteAnswer {
        RemoteAnswer.launch(agent, projectID: project ?? apiID, session: session, prompt: prompt, device: device,
                            at: at(seconds))
    }

    private func refusal(_ answer: RemoteAnswer, catalog: LaunchCatalog?? = .none,
                         now: Date? = nil) -> RemoteLaunch.Reason? {
        let result = resolve([answer], catalog: catalog, now: now)
        XCTAssertEqual(result.acknowledged, [answer.id], "a refused launch is deleted too")
        XCTAssertEqual(result.actions, [])
        guard case .refuse(let refused)? = result.launches.first, result.launches.count == 1 else { return nil }
        XCTAssertEqual(refused.answerID, answer.id)
        XCTAssertEqual(refused.outcome, .refused)
        XCTAssertEqual(refused.at, now ?? at(30))
        return refused.reason
    }

    func testANewSessionStartsInTheProjectRoot() throws {
        let answer = launch(prompt: "  Fix the flaky test\n")
        let result = resolve([answer])
        XCTAssertEqual(result.acknowledged, [answer.id])
        XCTAssertEqual(result.actions, [], "launches never reach the approval and reply actions")
        guard case .start(let order)? = result.launches.first else { return XCTFail("\(result.launches)") }
        XCTAssertEqual(order.answerID, answer.id)
        XCTAssertEqual(order.source, .claudeCode)
        XCTAssertNil(order.sessionID)
        XCTAssertEqual(order.projectID, apiID)
        XCTAssertEqual(order.directory, api.root)
        XCTAssertEqual(order.script, LaunchScript.script(source: .claudeCode, sessionID: nil,
                                                         prompt: "Fix the flaky test", cwd: api.root))
        XCTAssertEqual(order.fileName, LaunchScript.fileName(source: .claudeCode, answerID: answer.id))
        XCTAssertEqual(order.started(at: at(40)), RemoteLaunch.Result(answerID: answer.id, outcome: .started, at: at(40)))
        XCTAssertEqual(order.failed(at: at(40)), .refused(answer.id, .launchFailed, at: at(40)))

        let copilot = resolve([launch("copilot-cli", project: webID)])
        guard case .start(let other)? = copilot.launches.first else { return XCTFail("\(copilot.launches)") }
        XCTAssertEqual(other.directory, web.root)
        XCTAssertTrue(other.script.contains("exec 'copilot' '--interactive=Fix the flaky test'"), other.script)
    }

    func testContinueResumesInTheSessionsOwnFolder() throws {
        let answer = launch(session: "claude-code:c1", prompt: "now run the tests")
        guard case .start(let order)? = resolve([answer]).launches.first else { return XCTFail() }
        XCTAssertEqual(order.sessionID, "c1")
        XCTAssertEqual(order.directory, api.root + "/server")
        XCTAssertTrue(order.script.contains("exec 'claude' '--resume' 'c1' '--' 'now run the tests'"), order.script)
        let codex = resolve([launch("codex-cli", project: webID, session: "codex-cli:cx-1", prompt: "go on")])
        guard case .start(let resumed)? = codex.launches.first else { return XCTFail("\(codex.launches)") }
        XCTAssertTrue(resumed.script.contains("exec 'codex' 'resume' 'cx-1' '--' 'go on'"), resumed.script)
    }

    func testEveryRefusalReason() {
        XCTAssertEqual(refusal(launch(), catalog: .some(nil)), .disabled)
        var anonymous = launch()
        anonymous.device = nil
        XCTAssertEqual(refusal(anonymous), .noDevice, "a launch must name its Mac")
        XCTAssertEqual(refusal(launch(at: -RemoteAnswers.launchLifetime - 1), now: t0), .expired)
        XCTAssertEqual(refusal(launch(prompt: " \n\t")), .emptyPrompt)
        XCTAssertEqual(refusal(launch(prompt: " !rm -rf ~")), .shellMode, "shell mode skips the approval flow")
        XCTAssertEqual(refusal(launch(session: "claude-code:c1", prompt: "!git push -f")), .shellMode)
        var silent = launch()
        silent.text = nil
        XCTAssertEqual(refusal(silent), .emptyPrompt)
        let long = String(repeating: "x", count: LaunchScript.maxPromptLength + 1)
        XCTAssertEqual(refusal(launch(prompt: long)), .promptTooLong)
        XCTAssertEqual(refusal(launch("cursor")), .unsupportedAgent, "an agent this Mac doesn't know")
        XCTAssertEqual(refusal(launch("qwen-code")), .unsupportedAgent, "no verified prompt syntax")
        XCTAssertEqual(refusal(launch("copilot-ide")), .unsupportedAgent)
        var agentless = launch()
        agentless.agent = nil
        XCTAssertEqual(refusal(agentless), .unsupportedAgent)
        XCTAssertEqual(refusal(launch(project: "0123456789abcdef")), .unknownProject)
        XCTAssertEqual(refusal(launch(project: api.root)), .unknownProject, "a path is never a project id")
        var projectless = launch()
        projectless.projectID = nil
        XCTAssertEqual(refusal(projectless), .unknownProject)
        XCTAssertEqual(refusal(launch(session: "claude-code:gone")), .unknownSession)
        XCTAssertEqual(refusal(launch(session: "claude-code:c1 --dangerously-skip-permissions")), .unknownSession)
        XCTAssertEqual(refusal(launch(session: "c1")), .unknownSession)
        XCTAssertEqual(refusal(launch("codex-cli", session: "claude-code:c1")), .unknownSession,
                       "the session belongs to another agent")
        XCTAssertEqual(refusal(launch(project: webID, session: "claude-code:c1")), .unknownSession,
                       "the session belongs to another project")
        let claudeOnly = LaunchCatalog.build(projects: [api, web], sessions: sessions, available: [.claudeCode])
        XCTAssertEqual(refusal(launch("codex-cli", project: webID), catalog: .some(claudeOnly)), .unsupportedAgent,
                       "an agent without Hoply's hooks on this Mac")
        XCTAssertEqual(refusal(launch("codex-cli", project: webID, session: "codex-cli:cx-1"),
                               catalog: .some(claudeOnly)), .unsupportedAgent)
        let limited = LaunchCatalog(projects: [LaunchCatalog.Project(id: apiID, name: "api", root: api.root,
                                                                     agents: [.codexCLI])],
                                    available: [.claudeCode, .codexCLI])
        XCTAssertEqual(refusal(launch(), catalog: .some(limited)), .unsupportedAgent,
                       "an agent the project doesn't offer")
        let broken = LaunchCatalog(projects: [LaunchCatalog.Project(id: apiID, name: "api", root: "relative/api",
                                                                    agents: [.claudeCode])], available: [.claudeCode])
        XCTAssertEqual(refusal(launch(), catalog: .some(broken)), .launchFailed)
    }

    func testFreshnessWindow() {
        let edge = launch(at: -RemoteAnswers.launchLifetime)
        guard case .start? = resolve([edge], now: t0).launches.first else { return XCTFail("still fresh at the limit") }
        let ahead = launch(at: 300)
        guard case .start? = resolve([ahead], now: t0).launches.first else {
            return XCTFail("a phone clock ahead of the Mac still counts")
        }
        XCTAssertEqual(refusal(launch(at: -RemoteAnswers.launchLifetime - 0.5), now: t0), .expired)
    }

    func testAnotherMacsLaunchIsLeftForIt() {
        var foreign = launch()
        foreign.device = "mac-2"
        let result = resolve([foreign])
        XCTAssertEqual(result.launches, [])
        XCTAssertEqual(result.acknowledged, [])
        let old = resolve([foreign], now: at(RemoteAnswers.foreignLifetime + 1))
        XCTAssertEqual(old.launches, [], "nobody launches it a day later")
        XCTAssertEqual(old.acknowledged, [foreign.id])
    }

    func testALaunchIsAppliedOnce() {
        let answer = launch()
        let twice = resolve([answer, answer])
        XCTAssertEqual(twice.launches.count, 1)
        XCTAssertEqual(twice.acknowledged, [answer.id])
        let refetched = resolve([answer], handled: [answer.id])
        XCTAssertEqual(refetched.launches, [])
        XCTAssertEqual(refetched.acknowledged, [answer.id])

        let first = launch(session: "claude-code:c1", prompt: "one", at: 1)
        let second = launch(session: "claude-code:c1", prompt: "two", at: 2)
        let both = resolve([second, first])
        XCTAssertEqual(both.acknowledged, [first.id, second.id])
        guard both.launches.count == 2, case .start(let order) = both.launches[0],
              case .refuse(let refused) = both.launches[1] else { return XCTFail("\(both.launches)") }
        XCTAssertEqual(order.answerID, first.id)
        XCTAssertEqual(refused, .refused(second.id, .unknownSession, at: at(30)), "one session resumes once")
    }

    func testLaunchesMixWithOtherAnswers() {
        let away = RemoteAnswer.away(true, device: device, at: at(1))
        let start = launch(at: 2)
        let unknown = RemoteAnswer(device: device, kind: .unknown, createdAt: at(3))
        let result = resolve([unknown, start, away])
        XCTAssertEqual(result.actions, [.setAway(true)])
        XCTAssertEqual(result.acknowledged, [away.id, start.id, unknown.id])
        XCTAssertEqual(result.launches.count, 1)
    }
}

final class RemoteLaunchSchemaTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000.5)

    func testLaunchAnswersRoundTrip() throws {
        for answer in [RemoteAnswer.launch("claude-code", projectID: "0123456789abcdef", prompt: "it's `x` $(y)\nz",
                                           device: "mac-1", at: t0),
                       RemoteAnswer.launch("codex-cli", projectID: "0123456789abcdef", session: "codex-cli:cx-1",
                                           prompt: "go on", device: "mac-1", at: t0)] {
            let record = try RemoteSchema.record(answer)
            XCTAssertEqual(record.kind, "launch")
            XCTAssertEqual(record.createdAt, t0)
            XCTAssertEqual(RemoteSchema.answer(from: record), answer)
        }
        let older = #"{"id":"a","kind":"away","on":true,"createdAt":1800000000}"#
        let decoded = try RemoteSchema.decode(RemoteAnswer.self, from: Data(older.utf8))
        XCTAssertNil(decoded.agent)
        XCTAssertNil(decoded.projectID)
        XCTAssertNil(decoded.session)
        let away = String(decoding: try RemoteSchema.encode(RemoteAnswer.away(true, device: nil, at: t0)), as: UTF8.self)
        XCTAssertFalse(away.contains("agent"), "unset launch fields stay out of other answers")
    }

    func testSnapshotsWithAndWithoutALaunchBlock() throws {
        let block = RemoteLaunch(projects: [RemoteLaunch.Project(id: "p1", name: "api", agents: ["claude-code"])],
                                 resumable: [RemoteLaunch.Resumable(key: "claude-code:c1", agent: "claude-code",
                                                                    projectID: "p1", title: "Fix", endedAt: t0)],
                                 last: .refused("a-1", .shellMode, at: t0))
        let snapshot = RemoteSnapshot(device: "mac-1", away: false, updatedAt: t0, launch: block)
        XCTAssertEqual(RemoteSchema.snapshot(from: try RemoteSchema.record(snapshot)), snapshot)

        let off = RemoteSnapshot(device: "mac-1", away: false, updatedAt: t0)
        let json = String(decoding: try RemoteSchema.encode(off), as: UTF8.self)
        XCTAssertFalse(json.contains("launch"), "no block while the setting is off")
        XCTAssertNil(try RemoteSchema.decode(RemoteSnapshot.self, from: Data(json.utf8)).launch)
    }

    func testNewerLaunchValuesDecodeAsUnknown() throws {
        let result = #"{"answerID":"a","outcome":"queued","reason":"busy","at":1800000000}"#
        let decoded = try RemoteSchema.decode(RemoteLaunch.Result.self, from: Data(result.utf8))
        XCTAssertEqual(decoded.outcome, .unknown)
        XCTAssertEqual(decoded.reason, .unknown)
        let resumable = #"{"key":"cursor:1","agent":"cursor","projectID":"p","endedAt":1800000000,"branch":"x"}"#
        XCTAssertNil(try RemoteSchema.decode(RemoteLaunch.Resumable.self, from: Data(resumable.utf8)).source)
        let project = #"{"id":"p","name":"n","agents":["claude-code","cursor"]}"#
        XCTAssertEqual(try RemoteSchema.decode(RemoteLaunch.Project.self, from: Data(project.utf8)).sources,
                       [.claudeCode])
    }

    func testLaunchChangesPublishAtOnce() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let block = RemoteLaunch(projects: [RemoteLaunch.Project(id: "p1", name: "api", agents: ["claude-code"])])
        let base = RemoteSnapshot(device: "mac-1", away: false, updatedAt: start, launch: block)
        func publishes(_ change: (inout RemoteSnapshot) -> Void) -> Bool {
            var next = base
            change(&next)
            return RemoteLinkPolicy.shouldPublish(next, last: base, at: start, now: start.addingTimeInterval(1))
        }
        XCTAssertTrue(publishes { $0.launch?.last = RemoteLaunch.Result(answerID: "a", outcome: .started, at: start) },
                      "the phone waits for its launch result")
        XCTAssertTrue(publishes { $0.launch = nil }, "the setting was turned off")
        XCTAssertFalse(publishes { $0.launch?.projects = [] }, "a changed project list can wait")
        var off = base
        off.launch = nil
        XCTAssertTrue(RemoteLinkPolicy.shouldPublish(base, last: off, at: start, now: start.addingTimeInterval(1)))
    }
}
