import AgentKit
import Darwin
import Foundation

public struct CopilotLastMessageReader: Sendable {
    public static let tailBytes = 1 << 20

    public let events: CopilotEventsIngester

    public init(home: String = CopilotStoreIngester.defaultHome) {
        events = CopilotEventsIngester(home: home)
    }

    public init(settings: AppSettings) {
        self.init(home: LedgerConfiguration(settings: settings).copilotHome)
    }

    public func message(transcriptPath: String) -> String? {
        let path = ClaudeTranscriptIngester.canonical(transcriptPath)
        guard events.isEventsFile(path), let lines = Self.tail(of: path) else { return nil }
        return CopilotEventsParser.lastAssistantMessage(in: lines)
    }

    public func completing(_ reply: TurnReplyRequest) -> TurnReplyRequest {
        guard reply.key.source == .copilotCLI, reply.message == nil, let path = reply.transcriptPath else { return reply }
        var completed = reply
        completed.message = message(transcriptPath: path)
        return completed
    }

    static func tail(of path: String, maxBytes: Int = tailBytes) -> [Data]? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let size = Int64(info.st_size)
        let start = max(0, size - Int64(maxBytes))
        // One byte before the window: a newline there means the window starts on a whole line.
        let from = max(0, start - 1)
        guard var data = try? FileTailer.readBytes(fd, at: from, count: Int(size - from)) else { return nil }
        if start > 0 {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return [] }
            data = data[(newline + 1)...]
        }
        return JSONLines.complete(in: data).lines
    }
}
