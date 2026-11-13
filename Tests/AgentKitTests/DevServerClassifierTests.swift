import XCTest
@testable import AgentKit

final class DevServerClassifierTests: XCTestCase {
    private let home = "/Users/dev"
    private let corestory = ProjectRef(id: 7, root: "/Users/dev/Project/corestory", name: "corestory", kind: .repo)
    private let hoplyPID: Int32 = 900
    private var classifier: DevServerClassifier {
        DevServerClassifier(hubPort: 4318, ownPID: hoplyPID, uid: 501, homeDirectory: home)
    }

    private func process(_ pid: Int32, parent: Int32 = 1, group: Int32? = nil, uid: UInt32 = 501, name: String = "node",
                         executable: String? = "/opt/homebrew/bin/node", _ arguments: [String] = ["node"],
                         cwd: String? = "/Users/dev/Project/corestory", memoryMB: UInt64? = nil, started: TimeInterval? = nil,
                         ports: [Int] = [], address: String = "::") -> ScannedProcess {
        ScannedProcess(
            identity: ProcessIdentity(pid: pid, startedAt: Date(timeIntervalSince1970: started ?? 1_000 + Double(pid))),
            parentPID: parent, groupID: group ?? pid, uid: uid, name: name, executable: executable,
            arguments: arguments, cwd: cwd, memoryBytes: memoryMB.map { $0 * 1_048_576 },
            listeners: ports.map { ListeningSocket(port: $0, family: address.contains(":") ? .ipv6 : .ipv4,
                                                   address: address) })
    }

    private func snapshot(_ processes: ScannedProcess...) -> ProcessSnapshot {
        ProcessSnapshot(processes: processes)
    }

    private var nextTree: [ScannedProcess] {
        [
            process(100, name: "zsh", executable: "/bin/zsh", ["-zsh"]),
            process(200, parent: 100, name: "npm", ["npm", "run", "dev"], memoryMB: 60),
            process(201, parent: 200, group: 200, ["node", "/Users/dev/Project/corestory/node_modules/.bin/next", "dev"],
                    memoryMB: 100),
            process(202, parent: 201, group: 200, ["next-server (v15.1.0)"], memoryMB: 252, ports: [3000]),
        ]
    }

    func testNamesAServerUnderItsProject() throws {
        let servers = classifier.servers(in: ProcessSnapshot(processes: nextTree),
                                         projects: ["/Users/dev/Project/corestory": corestory])
        let server = try XCTUnwrap(servers.first)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(server.projectName, "corestory")
        XCTAssertEqual(server.framework, .nextJS)
        XCTAssertEqual(server.frameworkName, "Next.js")
        XCTAssertEqual(server.portLabel, ":3000")
        XCTAssertEqual(server.memoryLabel, "412 MB")
        XCTAssertEqual(server.displayName, "corestory · Next.js :3000 · 412 MB")
        XCTAssertEqual(server.url.absoluteString, "http://localhost:3000")
        XCTAssertEqual(server.groupKey, "project:7")
        XCTAssertEqual(server.process.pid, 202)
        XCTAssertEqual(server.groupID, 200)
        XCTAssertEqual(server.id, "202:1202000000:3000")
        XCTAssertTrue(server.isReachableFromNetwork)
        XCTAssertNil(server.stopRefusal)
    }

    func testWithoutALedgerServersGroupByDirectory() throws {
        let server = try XCTUnwrap(classifier.servers(in: ProcessSnapshot(processes: nextTree)).first)
        XCTAssertNil(server.project)
        XCTAssertEqual(server.groupKey, "/Users/dev/Project/corestory")
        XCTAssertEqual(server.projectName, "corestory")
        XCTAssertNil(server.stopRefusal)
    }

    func testWorkersOnTheSamePortCollapseIntoTheTopmostListener() throws {
        let snapshot = snapshot(
            process(300, name: "python3.13", executable: "/opt/homebrew/bin/python3.13",
                    ["python3.13", "-m", "uvicorn", "app:app", "--workers", "2"], memoryMB: 40, ports: [8000],
                    address: "127.0.0.1"),
            process(301, parent: 300, group: 300, name: "python3.13", executable: "/opt/homebrew/bin/python3.13",
                    ["python3.13", "-c", "from multiprocessing.spawn import spawn_main"], memoryMB: 80, ports: [8000],
                    address: "127.0.0.1"),
            process(302, parent: 300, group: 300, name: "python3.13", executable: "/opt/homebrew/bin/python3.13",
                    ["python3.13", "-c", "from multiprocessing.spawn import spawn_main"], memoryMB: 80, ports: [8000],
                    address: "127.0.0.1"),
            process(400, name: "python3.13", executable: "/opt/homebrew/bin/python3.13",
                    ["python3.13", "-m", "http.server", "8000"], cwd: "/Users/dev/notes", ports: [8000]))
        let servers = classifier.servers(in: snapshot)
        XCTAssertEqual(servers.map(\.process.pid), [300, 400])
        XCTAssertEqual(servers[0].members.map(\.pid), [300, 301, 302])
        XCTAssertEqual(servers[0].framework, .uvicorn)
        XCTAssertEqual(servers[0].memoryLabel, "200 MB")
        XCTAssertFalse(servers[0].isReachableFromNetwork)
        XCTAssertEqual(servers[1].displayName, "notes · http.server :8000")
    }

    func testAProcessOnTwoPortsIsTwoServersWithStableIDs() {
        let snapshot = snapshot(process(500, ["node", "node_modules/vite/bin/vite.js"], ports: [5173, 5174]))
        let servers = classifier.servers(in: snapshot)
        XCTAssertEqual(servers.map(\.id), ["500:1500000000:5173", "500:1500000000:5174"])
        XCTAssertEqual(classifier.servers(in: snapshot), servers)
    }

    func testExcludesSystemPortsOurListenerAndProcessesWithoutADirectory() {
        let snapshot = snapshot(
            process(10, ports: [80, 443, 1023]),
            process(11, ports: [4318]),
            process(12, ports: [5432, 6379, 9229]),
            process(13, cwd: nil, ports: [3000]),
            process(14, cwd: "/", ports: [3001]),
            process(15, cwd: "/Users/dev/Library/Containers/app/Data", ports: [3002]),
            process(16, name: "ControlCenter", executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
                    ["ControlCenter"], cwd: "/Users/dev", ports: [5000, 7000]),
            process(hoplyPID, name: "Hoply", executable: "/Users/dev/Applications/Hoply.app/Contents/MacOS/Hoply",
                    ["Hoply"], cwd: "/Users/dev", ports: [4400]),
            process(18, ports: [1024]))
        XCTAssertEqual(classifier.servers(in: snapshot).map(\.port), [1024])
        XCTAssertEqual(classifier.candidateDirectories(in: snapshot), ["/Users/dev/Project/corestory"])
    }

    func testInstalledAppsCountOnlyInsideARepoOrWithAKnownRuntime() {
        let editor = process(20, name: "Editor Helper",
                             executable: "/Applications/Editor.app/Contents/Frameworks/Editor Helper.app/Contents/MacOS/Editor Helper",
                             ["Editor Helper", "--type=utility"], ports: [8123])
        let python = process(21, name: "Python",
                             executable: "/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python",
                             ["Python", "-m", "http.server"], cwd: "/Users/dev/notes", ports: [8000])
        XCTAssertEqual(classifier.servers(in: snapshot(editor, python)).map(\.process.pid), [21])
        let inRepo = classifier.servers(in: snapshot(editor), projects: ["/Users/dev/Project/corestory": corestory])
        XCTAssertEqual(inRepo.map(\.displayName), ["corestory · Editor Helper :8123"])
        let home = ProjectRef(id: 1, root: "/Users/dev/Project/corestory", name: "Home", kind: .home)
        XCTAssertEqual(classifier.servers(in: snapshot(editor), projects: ["/Users/dev/Project/corestory": home]), [])
    }

    func testEphemeralPortsNeedARecognisedFramework() {
        let snapshot = snapshot(
            process(30, ["node", "/Users/dev/.vscode/extensions/ts/server.js"], ports: [51234]),
            process(31, ["node", "/Users/dev/Project/corestory/node_modules/vite/bin/vite.js", "--port", "0"],
                    ports: [60001]))
        XCTAssertEqual(classifier.servers(in: snapshot).map(\.port), [60001])
    }

    func testDetectsFrameworksFromTheCommandLine() {
        let cases: [([String], String?, DevServerFramework)] = [
            (["node", "/p/node_modules/.bin/next", "dev"], "/usr/local/bin/node", .nextJS),
            (["next-server (v15.1.0)"], "/usr/local/bin/node", .nextJS),
            (["node", "/p/node_modules/.bin/vite", "--host"], nil, .vite),
            (["node", "/p/node_modules/astro/astro.js", "dev"], nil, .astro),
            (["node", "/p/node_modules/nuxi/bin/nuxi.mjs", "dev"], nil, .nuxt),
            (["node", "/p/node_modules/@sveltejs/kit/svelte-kit.js", "dev"], nil, .svelteKit),
            (["node", "/p/node_modules/.bin/remix", "vite:dev"], nil, .remix),
            (["node", "/p/node_modules/.bin/webpack", "serve"], nil, .webpackDevServer),
            (["node", "/p/node_modules/webpack-dev-server/bin/webpack-dev-server.js"], nil, .webpackDevServer),
            (["/p/.venv/bin/python", "/p/.venv/bin/uvicorn", "main:app", "--reload"], nil, .uvicorn),
            (["gunicorn: master [app]"], "/p/.venv/bin/python3.12", .gunicorn),
            (["python", "-m", "flask", "run"], nil, .flask),
            (["python", "manage.py", "runserver"], nil, .django),
            (["python3", "-m", "http.server", "8080"], "/usr/bin/python3", .pythonHTTPServer),
            (["ruby", "bin/rails", "server"], nil, .rails),
            (["puma 6.4.2 (tcp://localhost:3000) [corestory]"], "/opt/homebrew/bin/ruby", .puma),
            (["dotnet", "run"], "/usr/local/share/dotnet/dotnet", .dotnet),
            (["bun", "run", "dev"], "/Users/dev/.bun/bin/bun", .bun),
            (["deno", "run", "-A", "main.ts"], "/opt/homebrew/bin/deno", .deno),
            (["node", "server.js"], "/usr/local/bin/node", .node),
            (["npm", "run", "dev"], "/usr/local/bin/node", .node),
            (["/var/folders/x/go-build123/b001/exe/main"], "/private/var/folders/x/go-build123/b001/exe/main", .go),
            (["target/debug/api"], "/Users/dev/Project/api/target/debug/api", .rust),
            (["php", "-S", "localhost:8000"], "/opt/homebrew/bin/php", .php),
            (["python3", "serve.py"], "/usr/bin/python3", .python),
            (["java", "-jar", "app.jar"], "/usr/bin/java", .java),
            (["./server"], "/Users/dev/Project/api/server", .other),
            (["node", "server.js", "--port", "3000", "--name", "x", "next"], "/usr/local/bin/node", .node),
        ]
        for (arguments, executable, expected) in cases {
            XCTAssertEqual(DevServerFramework.detect(executable: executable, arguments: arguments), expected,
                           arguments.joined(separator: " "))
        }
    }

    func testAnUnknownServerIsNamedAfterItsProcess() throws {
        let server = try XCTUnwrap(classifier.servers(in: snapshot(
            process(40, name: "caddy", executable: "/opt/homebrew/bin/caddy", ["caddy", "run"], memoryMB: 1536,
                    ports: [2019]))).first)
        XCTAssertEqual(server.framework, .other)
        XCTAssertEqual(server.displayName, "corestory · caddy :2019 · 1.5 GB")
    }

    func testTheLauncherNamesTheFrameworkWhenTheListenerDoesNot() throws {
        let snapshot = snapshot(
            process(50, ["node", "/p/node_modules/.bin/astro", "dev"]),
            process(51, parent: 50, group: 50, ["node", "worker.js"], ports: [4321]))
        XCTAssertEqual(try XCTUnwrap(classifier.servers(in: snapshot).first).framework, .astro)
    }

    // MARK: - Sessions

    private let claude = SessionKey(source: .claudeCode, id: "s1")
    private let qwen = SessionKey(source: .qwenCode, id: "q1")

    private var agentTree: [ScannedProcess] {
        [
            process(600, name: "2.1.322", executable: "/Users/dev/.local/share/claude/versions/2.1.322", ["claude"]),
            process(601, parent: 600, name: "zsh", executable: "/bin/zsh", ["/bin/zsh", "-c", "npm run dev"]),
            process(602, parent: 601, group: 601, ["node", "/p/node_modules/.bin/vite"], ports: [5173]),
        ]
    }

    func testTiesAServerToTheSessionWhoseProcessStartedIt() throws {
        let sessions = [DevServerClassifier.Session(key: qwen, pid: 999, cwd: "/Users/dev/Project/corestory"),
                        DevServerClassifier.Session(key: claude, pid: 600, cwd: "/Users/dev/Project/other")]
        let server = try XCTUnwrap(classifier.servers(in: ProcessSnapshot(processes: agentTree), sessions: sessions).first)
        XCTAssertEqual(server.session, claude)
        XCTAssertEqual(server.sessionMatch, .lineage)
        XCTAssertNil(server.stopRefusal)
    }

    func testFindsTheAgentAmongTheAncestorsWhenNoPidIsKnown() throws {
        let sessions = [DevServerClassifier.Session(key: qwen, cwd: "/Users/dev/Project/corestory"),
                        DevServerClassifier.Session(key: claude, cwd: "/Users/dev/Project/corestory")]
        let server = try XCTUnwrap(classifier.servers(in: ProcessSnapshot(processes: agentTree), sessions: sessions).first)
        XCTAssertEqual(server.session, claude)
        XCTAssertEqual(server.sessionMatch, .lineage)
    }

    func testFallsBackToTheSessionDirectory() throws {
        let sessions = [DevServerClassifier.Session(key: qwen, cwd: "/Users/dev/Project"),
                        DevServerClassifier.Session(key: claude, cwd: "/Users/dev/Project/corestory"),
                        DevServerClassifier.Session(key: SessionKey(source: .copilotCLI, id: "c"),
                                                    cwd: "/Users/dev/Project/corestory/web")]
        let server = try XCTUnwrap(classifier.servers(in: ProcessSnapshot(processes: nextTree), sessions: sessions).first)
        XCTAssertEqual(server.session, claude)
        XCTAssertEqual(server.sessionMatch, .directory)

        let elsewhere = [DevServerClassifier.Session(key: claude, cwd: "/Users/dev/Project/fib")]
        XCTAssertNil(classifier.servers(in: ProcessSnapshot(processes: nextTree), sessions: elsewhere).first?.session)
    }

    func testLineageIgnoresAParentThatStartedAfterItsChild() {
        let snapshot = snapshot(process(700, started: 5_000), process(701, parent: 700, started: 2_000))
        XCTAssertEqual(ProcessLineage(snapshot).ancestors(of: 701), [])
        XCTAssertEqual(ProcessLineage(snapshot).descendants(of: 700), [])

        let lineage = ProcessLineage(ProcessSnapshot(processes: nextTree))
        XCTAssertEqual(lineage.ancestors(of: 202).map(\.pid), [201, 200, 100])
        XCTAssertEqual(Set(lineage.descendants(of: 200).map(\.pid)), [201, 202])
        XCTAssertTrue(lineage.isAncestor(100, of: 202))
    }

    // MARK: - Stop

    private func decide(_ pid: Int32, in processes: [ScannedProcess], root: String = "/Users/dev/Project/corestory",
                        started: TimeInterval? = nil, protected: Set<Int32> = []) -> DevServerStop.Decision {
        DevServerStop.decide(
            process: ProcessIdentity(pid: pid, startedAt: Date(timeIntervalSince1970: started ?? 1_000 + Double(pid))),
            root: root, in: ProcessSnapshot(processes: processes), ownPID: hoplyPID, uid: 501, protectedPIDs: protected)
    }

    func testStopTargetsTheWholeProcessGroup() throws {
        let target = try XCTUnwrap(decide(202, in: nextTree).target)
        XCTAssertEqual(target.groupID, 200)
        XCTAssertEqual(target.leader.pid, 200)
        XCTAssertEqual(target.members.map(\.pid), [200, 201, 202])
    }

    func testStopIsRefusedWhenTheProcessIsGoneOrItsPidWasReused() {
        XCTAssertEqual(decide(999, in: nextTree).refusal, .processGone)
        XCTAssertEqual(decide(202, in: nextTree, started: 9_999).refusal, .identityChanged)
    }

    func testStopIsRefusedWhenTheGroupLeaderIsOutsideTheProject() {
        var tree = nextTree
        tree[1].cwd = "/Users/dev/Project"
        XCTAssertEqual(decide(202, in: tree).refusal, .leaderOutsideProject)
        tree[1].cwd = "/Users/dev/Project/corestory-old"
        XCTAssertEqual(decide(202, in: tree).refusal, .leaderOutsideProject)
        tree[1].cwd = nil
        XCTAssertEqual(decide(202, in: tree).refusal, .leaderOutsideProject)
        tree[1].cwd = "/Users/dev/Project/corestory/web"
        XCTAssertNotNil(decide(202, in: tree).target)
    }

    func testStopIsRefusedWithoutAGroupLeaderOrForAnotherUser() {
        XCTAssertEqual(decide(202, in: Array(nextTree.dropFirst(2))).refusal, .leaderGone)
        var tree = nextTree
        tree[3].uid = 0
        XCTAssertEqual(decide(202, in: tree).refusal, .notOurUser)
        tree = nextTree
        tree[1].uid = 0
        XCTAssertEqual(decide(202, in: tree).refusal, .notOurUser)
        XCTAssertEqual(decide(5, in: [process(5, group: 1, ports: [3000])]).refusal, .noProcessGroup)
    }

    func testStopNeverReachesHoplyItsAncestorsOrAnAgent() {
        let hoply = process(hoplyPID, parent: 800, group: 800, name: "Hoply", ["Hoply"])
        let launcher = process(800, name: "zsh", executable: "/bin/zsh", ["zsh"])
        let server = process(801, parent: 800, group: 800, ports: [3000])
        XCTAssertEqual(decide(801, in: [launcher, hoply, server]).refusal, .includesHoply)
        XCTAssertEqual(decide(hoplyPID, in: [process(hoplyPID, ports: [3000])]).refusal, .includesHoply)
        XCTAssertEqual(decide(800, in: [launcher, process(hoplyPID, parent: 800)]).refusal, .includesHoply)

        let agent = process(810, name: "claude", executable: "/Users/dev/.local/bin/claude", ["claude"])
        let child = process(811, parent: 810, group: 810, ports: [3000])
        XCTAssertEqual(decide(811, in: [agent, child]).refusal, .includesAgent)
        XCTAssertEqual(decide(202, in: nextTree, protected: [200]).refusal, .includesAgent)
    }

    func testAHomeProjectNarrowsStopToTheServerDirectory() throws {
        var tree = nextTree
        tree[1].cwd = "/Users/dev"
        let home = ProjectRef(id: 1, root: "/Users/dev", name: "Home", kind: .home)
        let server = try XCTUnwrap(classifier.servers(in: ProcessSnapshot(processes: tree),
                                                      projects: ["/Users/dev/Project/corestory": home]).first)
        XCTAssertEqual(server.stopRefusal, .leaderOutsideProject)
        XCTAssertFalse(server.canStop)
    }

    func testAServerInALinkedWorktreeOutsideTheRepoRootCanBeStopped() throws {
        let worktree = "/Users/dev/Project/corestory.worktrees/landing-hero"
        var tree = nextTree
        for index in tree.indices { tree[index].cwd = worktree }
        let corestory = ProjectRef(id: 1, root: "/Users/dev/Project/corestory", name: "corestory", kind: .repo)
        let server = try XCTUnwrap(classifier.servers(in: ProcessSnapshot(processes: tree),
                                                      projects: [worktree: corestory]).first)
        XCTAssertEqual(server.project, corestory)
        XCTAssertNil(server.stopRefusal)
    }

    // MARK: - Arguments

    func testParsesKernelProcessArguments() throws {
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += Array("/usr/local/bin/node".utf8) + [0, 0, 0, 0, 0]
        for argument in ["node", "", "server.js"] { bytes += Array(argument.utf8) + [0] }
        bytes += Array("SECRET=1".utf8) + [0]
        let parsed = try XCTUnwrap(ProcessArguments.parse(procargs2: bytes))
        XCTAssertEqual(parsed.executable, "/usr/local/bin/node")
        XCTAssertEqual(parsed.arguments, ["node", "", "server.js"])
        XCTAssertNil(ProcessArguments.parse(procargs2: [1, 0]))
        XCTAssertEqual(ProcessArguments.parse(procargs2: [5, 0, 0, 0] + Array("/bin/x".utf8) + [0, 120, 0])?.arguments, ["x"])
    }
}
