import AgentKit
import Foundation

public struct ClaudeTranscriptIngester: Sendable {
    public struct TranscriptFile: Sendable, Equatable {
        public var path: String
        public var stat: FileStat
    }

    public let configDirectory: String

    public static var defaultConfigDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude").path
    }

    public init(configDirectory: String = ClaudeTranscriptIngester.defaultConfigDirectory) {
        self.configDirectory = Self.canonical(configDirectory)
    }

    public var projectsDirectory: String { configDirectory + "/projects" }

    public func discover() -> [TranscriptFile] {
        let fileManager = FileManager.default
        var files: [TranscriptFile] = []
        func add(_ path: String) {
            if let stat = FileTailer.status(of: path) { files.append(TranscriptFile(path: path, stat: stat)) }
        }
        for project in (try? fileManager.contentsOfDirectory(atPath: projectsDirectory)) ?? [] {
            let projectPath = projectsDirectory + "/" + project
            for entry in (try? fileManager.contentsOfDirectory(atPath: projectPath)) ?? [] {
                let entryPath = projectPath + "/" + entry
                if entry.hasSuffix(".jsonl") {
                    add(entryPath)
                } else {
                    let subagents = entryPath + "/subagents"
                    for name in (try? fileManager.contentsOfDirectory(atPath: subagents)) ?? [] where name.hasSuffix(".jsonl") {
                        add(subagents + "/" + name)
                    }
                }
            }
        }
        return files.sorted { $0.stat.modified > $1.stat.modified }
    }

    public func isTranscript(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl"), path.hasPrefix(projectsDirectory + "/") else { return false }
        let parts = path.dropFirst(projectsDirectory.count + 1).split(separator: "/")
        return parts.count == 2 || (parts.count == 4 && parts[2] == "subagents")
    }

    public static func batch(lines: [Data], path: String, startOffset: Int64) -> LedgerBatch {
        ClaudeTranscriptParser.batch(from: lines).ledgerBatch(transcriptPath: path, startsAtFileStart: startOffset == 0)
    }

    public static func subagentInfo(forTranscript path: String) -> SubagentInfo? {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        guard stem.hasPrefix("agent-"), folder.lastPathComponent == "subagents",
              let meta = try? Data(contentsOf: folder.appendingPathComponent(stem + ".meta.json")) else { return nil }
        return SubagentInfo(meta: meta, session: SessionKey(source: .claudeCode,
                                                            id: folder.deletingLastPathComponent().lastPathComponent),
                            agentID: String(stem.dropFirst("agent-".count)))
    }

    public static func canonical(_ path: String) -> String {
        LocalProjectFileSystem().realPath(path) ?? URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
