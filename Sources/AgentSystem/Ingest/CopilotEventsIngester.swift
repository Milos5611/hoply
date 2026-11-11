import AgentKit
import Foundation

public struct CopilotEventsIngester: Sendable {
    public static let eventsName = "events.jsonl"
    public static let workspaceName = "workspace.yaml"

    public let home: String

    public init(home: String = CopilotStoreIngester.defaultHome) {
        self.home = ClaudeTranscriptIngester.canonical(home)
    }

    public var sessionStateDirectory: String { home + "/session-state" }
    public var watchedDirectories: [String] { [sessionStateDirectory] }

    public func eventsPath(sessionID: String) -> String? {
        guard Self.isSessionFolderName(sessionID) else { return nil }
        return sessionStateDirectory + "/" + sessionID + "/" + Self.eventsName
    }

    public func discover() -> [ClaudeTranscriptIngester.TranscriptFile] {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: sessionStateDirectory)) ?? []
        return folders.filter(Self.isSessionFolderName).compactMap { name in
            let path = sessionStateDirectory + "/" + name + "/" + Self.eventsName
            return FileTailer.status(of: path).map { ClaudeTranscriptIngester.TranscriptFile(path: path, stat: $0) }
        }
        .sorted { $0.stat.modified > $1.stat.modified }
    }

    public func isEventsFile(_ path: String) -> Bool {
        guard path.hasPrefix(sessionStateDirectory + "/") else { return false }
        let parts = path.dropFirst(sessionStateDirectory.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[1] == Self.eventsName && Self.isSessionFolderName(String(parts[0]))
    }

    public func workspace(forEventsFile path: String) -> CopilotWorkspace? {
        let url = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(Self.workspaceName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return CopilotWorkspace(yaml: String(decoding: data, as: UTF8.self))
    }

    static func isSessionFolderName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
    }
}
