import AgentKit
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
        FileTailer.lastLines(of: path, maxBytes: maxBytes)?.lines
    }
}
