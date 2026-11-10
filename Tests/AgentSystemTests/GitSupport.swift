import AgentSystem
import Foundation
import XCTest

struct TestRepository {
    let container: TempDirectory
    let root: String

    init(defaultBranch: String = "main", ignoring patterns: [String] = [".next/", ".turbo/", "node_modules/"]) throws {
        container = try TempDirectory()
        try container.mkdir("app")
        root = CleanupFiles().canonical(container.path("app"))
        try git("init", "-q", "-b", defaultBranch)
        try write(".gitignore", patterns.map { $0 + "\n" }.joined())
        try write("a.txt", "one\n")
        try commit("first")
    }

    static func git(_ arguments: [String], in directory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                             "-c", "init.defaultBranch=main"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    func git(_ arguments: String..., in directory: String? = nil) throws {
        try Self.git(arguments, in: directory ?? root)
    }

    @discardableResult
    func write(_ relative: String, _ text: String, in directory: String? = nil) throws -> String {
        let target = URL(fileURLWithPath: directory ?? root).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        return target.path
    }

    func commit(_ message: String, in directory: String? = nil) throws {
        try git("add", "-A", in: directory)
        try git("commit", "-q", "-m", message, in: directory)
    }

    func addWorktree(_ name: String, branch: String? = nil) throws -> String {
        let path = (root as NSString).deletingLastPathComponent + "/" + name
        if let branch {
            try git("worktree", "add", "-q", "-b", branch, path)
        } else {
            try git("worktree", "add", "-q", "--detach", path)
        }
        return path
    }

    func moveAside(_ path: String) throws {
        try container.mkdir("moved")
        try FileManager.default.moveItem(atPath: path, toPath: container.path("moved/" + UUID().uuidString))
    }
}
