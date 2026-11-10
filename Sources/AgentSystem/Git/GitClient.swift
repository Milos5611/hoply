import AgentKit
import Foundation

public struct GitClient: Sendable {
    public static let defaultGitPath = "/usr/bin/git"

    public var gitPath: String
    public var timeout: TimeInterval

    public init(gitPath: String = GitClient.defaultGitPath, timeout: TimeInterval = 5) {
        self.gitPath = gitPath
        self.timeout = timeout
    }

    public func diffStat(worktree directory: String) -> GitDiffStat? {
        guard isAvailable, let top = run(["rev-parse", "--show-toplevel"], in: directory),
              let root = Self.text(top).split(separator: "\n").first.map(String.init), !root.isEmpty else { return nil }
        var stat = GitDiffStat()
        // A repository without commits has no HEAD to diff against; everything in it is untracked or staged.
        if let diff = run(["diff", "--shortstat", "--no-ext-diff", "--no-textconv", "HEAD"], in: root) {
            guard let parsed = GitDiffStat(shortstat: Self.text(diff)) else { return nil }
            stat = parsed
        }
        guard let untracked = run(["ls-files", "--others", "--exclude-standard", "-z"], in: root) else { return nil }
        stat.untracked = GitDiffStat.entryCount(nulSeparated: untracked)
        return stat
    }

    // `/usr/bin/git` is a shim that opens the "install developer tools" dialog when none are installed.
    private var isAvailable: Bool {
        guard FileManager.default.isExecutableFile(atPath: gitPath) else { return false }
        return gitPath != Self.defaultGitPath || Self.developerToolsInstalled
    }

    private static let developerToolsInstalled: Bool = {
        Self.execute("/usr/bin/xcode-select", ["-p"], directory: nil, timeout: 5) != nil
    }()

    // No optional locks: git never writes to the repo. fsmonitor, ext-diff, textconv off: it runs nothing the repo configures.
    private func run(_ arguments: [String], in directory: String) -> Data? {
        Self.execute(gitPath, ["--no-optional-locks", "-c", "core.fsmonitor=false"] + arguments,
                     directory: directory, timeout: timeout)
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private static func execute(_ path: String, _ arguments: [String], directory: String?,
                                timeout: TimeInterval) -> Data? {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        guard let output = Subprocess.run(path, arguments, directory: directory, environment: environment,
                                          timeout: timeout), output.status == 0 else { return nil }
        return output.data
    }
}

public actor GitStatCache {
    private let client: GitClient
    private var stats: [String: GitDiffStat] = [:]
    private var running: [String: Task<GitDiffStat?, Never>] = [:]

    public init(client: GitClient = GitClient()) {
        self.client = client
    }

    public func cached(_ directory: String) -> GitDiffStat? {
        stats[directory]
    }

    public func all() -> [String: GitDiffStat] {
        stats
    }

    @discardableResult
    public func refresh(_ directory: String) async -> GitDiffStat? {
        if let task = running[directory] { return await task.value }
        let client = client
        let task = Task.detached(priority: .utility) { client.diffStat(worktree: directory) }
        running[directory] = task
        let stat = await task.value
        running[directory] = nil
        stats[directory] = stat
        return stat
    }

    public func stat(for directory: String) async -> GitDiffStat? {
        if let stat = stats[directory] { return stat }
        return await refresh(directory)
    }

    public func forget(_ directory: String) {
        stats[directory] = nil
    }
}
