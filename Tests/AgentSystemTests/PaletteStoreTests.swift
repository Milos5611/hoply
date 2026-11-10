import AgentKit
import AgentSystem
import Foundation
import XCTest

final class PaletteStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_000)
    private let resolver = ProjectResolver(home: "/Users/dev")

    private func session(_ id: String, source: AgentSource = .claudeCode, at seconds: TimeInterval, cwd: String?,
                         title: String? = nil) -> SessionUpdate {
        SessionUpdate(key: SessionKey(source: source, id: id), firstAt: t0.addingTimeInterval(seconds - 60),
                      lastAt: t0.addingTimeInterval(seconds), cwd: cwd, branch: "main", title: title, titleRank: 2)
    }

    func testRecentSessionsAndProjects() async throws {
        let directory = try TempDirectory()
        let path = directory.path("hoply.sqlite")
        let store = try Store(path: path, pricing: .bundled(), resolver: resolver)
        let reader = try StoreReader(path: path)
        let empty = try await reader.recentSessions(limit: 10)
        XCTAssertEqual(empty, [])

        try await store.apply(LedgerBatch(sessions: [
            session("old", at: -30 * 86_400, cwd: "/Users/dev/Project/demo", title: "Old work"),
            session("mid", at: -3_600, cwd: "/Users/dev/Project/demo", title: "Web"),
            session("new", at: -60, cwd: "/Users/dev/Project/api"),
            session("nowhere", at: -10, cwd: nil, title: "No folder"),
            session("cp", source: .copilotCLI, at: -30, cwd: "/Users/dev/Project/api", title: "Copilot"),
        ]))

        let all = try await reader.recentSessions(limit: 10)
        XCTAssertEqual(all.map(\.key.id), ["cp", "new", "mid", "old"], "newest first; a session without a folder is left out")
        XCTAssertEqual(all.map(\.project?.name), ["api", "api", "demo", "demo"])
        XCTAssertEqual(all[2], RecentSession(key: SessionKey(source: .claudeCode, id: "mid"), project: all[3].project,
                                             title: "Web", cwd: "/Users/dev/Project/demo", branch: "main",
                                             lastAt: t0.addingTimeInterval(-3_600)))
        XCTAssertNil(all[1].title)

        let claude = try await reader.recentSessions(limit: 2, sources: [.claudeCode])
        XCTAssertEqual(claude.map(\.key.id), ["new", "mid"])
        let none = try await reader.recentSessions(limit: 5, sources: [])
        XCTAssertEqual(none, [])

        let projects = try await reader.recentProjects(limit: 10)
        XCTAssertEqual(projects.map(\.project.name), ["api", "demo"])
        XCTAssertEqual(projects.map(\.sessionCount), [2, 2])
        XCTAssertEqual(projects.map(\.lastActive), [t0.addingTimeInterval(-30), t0.addingTimeInterval(-3_600)])
        let one = try await reader.recentProjects(limit: 1)
        XCTAssertEqual(one.map(\.project.name), ["api"])
    }

    func testResumeScriptRunsTheAgentInTheFolderWithIntactArguments() throws {
        let directory = try TempDirectory()
        let folder = "My Project's $HOME `x`; \"y\""
        try directory.mkdir(folder)
        try directory.write("bin/claude", """
            #!/bin/sh
            { pwd -P; printf '%s\\n' "$@"; } > "$HOPLY_TEST_OUT"

            """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path("bin/claude"))
        let cwd = try XCTUnwrap(realpath(directory.path(folder), nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let id = "0b6f6c1e-8a57-4f0e-9d0c-2f6a4a1f3b77"
        let script = try XCTUnwrap(ResumeScript.script(source: .claudeCode, sessionID: id, cwd: cwd))
        let name = try XCTUnwrap(ResumeScript.fileName(source: .claudeCode, sessionID: id))
        let scriptPath = try directory.write(name, script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        func run(_ path: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.environment = ["PATH": "\(directory.path("bin")):/usr/bin:/bin", "HOME": directory.path("home"),
                                   "HOPLY_TEST_OUT": directory.path("out.txt")]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        XCTAssertEqual(try run(scriptPath), 0)
        let output = try String(contentsOfFile: directory.path("out.txt"), encoding: .utf8)
        XCTAssertEqual(output, "\(cwd)\n--resume\n\(id)\n")

        let gone = try XCTUnwrap(ResumeScript.script(source: .claudeCode, sessionID: id, cwd: cwd + "/missing"))
        let gonePath = try directory.write("gone.command", gone)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gonePath)
        XCTAssertEqual(try run(gonePath), 1, "a folder that is gone stops the script before the agent starts")
    }
}
