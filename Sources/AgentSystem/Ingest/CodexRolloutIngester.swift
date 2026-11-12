import AgentKit
import Foundation

public struct CodexRolloutIngester: Sendable {
    public let home: String

    public static var defaultHome: String {
        AgentConnector.defaultCodexHome(environment: ProcessInfo.processInfo.environment,
                                        home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    public init(home: String = CodexRolloutIngester.defaultHome) {
        self.home = ClaudeTranscriptIngester.canonical(home)
    }

    public var sessionsDirectory: String { home + "/sessions" }
    // `codex archive` moves a rollout here under the same name.
    public var archivedDirectory: String { home + "/archived_sessions" }
    public var watchedDirectories: [String] { [sessionsDirectory, archivedDirectory] }
    public var sessionIndexPath: String { home + "/session_index.jsonl" }

    public func discover() -> [ClaudeTranscriptIngester.TranscriptFile] {
        let fileManager = FileManager.default
        var files: [ClaudeTranscriptIngester.TranscriptFile] = []
        func add(_ folder: String) {
            for name in (try? fileManager.contentsOfDirectory(atPath: folder)) ?? [] where Self.isRolloutName(name) {
                let path = folder + "/" + name
                if let stat = FileTailer.status(of: path) {
                    files.append(ClaudeTranscriptIngester.TranscriptFile(path: path, stat: stat))
                }
            }
        }
        func children(_ folder: String) -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.allSatisfy(\.isNumber) }
                .map { folder + "/" + $0 }
        }
        for year in children(sessionsDirectory) {
            for month in children(year) {
                for day in children(month) { add(day) }
            }
        }
        add(archivedDirectory)
        return files.sorted { $0.stat.modified > $1.stat.modified }
    }

    public func isRollout(_ path: String) -> Bool {
        guard Self.isRolloutName((path as NSString).lastPathComponent) else { return false }
        if path.hasPrefix(sessionsDirectory + "/") {
            return path.dropFirst(sessionsDirectory.count + 1).split(separator: "/").count == 4
        }
        if path.hasPrefix(archivedDirectory + "/") {
            return path.dropFirst(archivedDirectory.count + 1).split(separator: "/").count == 1
        }
        return false
    }

    static func isRolloutName(_ name: String) -> Bool {
        name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }
}
