import Foundation

public struct PromptRecord: Sendable, Equatable, Hashable {
    public var dedupeKey: String
    public var source: AgentSource
    public var sessionID: String
    public var timestamp: Date
    public var cwd: String?
    public var processID: Int32?

    public init(dedupeKey: String, source: AgentSource, sessionID: String, timestamp: Date, cwd: String? = nil,
                processID: Int32? = nil) {
        self.dedupeKey = dedupeKey
        self.source = source
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.cwd = cwd
        self.processID = processID
    }

    public var session: SessionKey { SessionKey(source: source, id: sessionID) }
}

extension TelemetryUsage {
    public static func prompts(from records: [TelemetryRecord]) -> [PromptRecord] {
        records.compactMap(prompt)
    }

    public static func prompt(_ record: TelemetryRecord) -> PromptRecord? {
        guard TelemetryMapper.source(of: record) == .qwenCode, record.name.lowercased().hasSuffix("user_prompt"),
              let time = record.time, let nanos = record.timeUnixNano else { return nil }
        let sessionID = TelemetryMapper.sessionID(of: record, source: .qwenCode)
        let place = place(of: record)
        return PromptRecord(dedupeKey: "qwp:\(sessionID):\(record["prompt_id"]?.string ?? ""):\(nanos)",
                            source: .qwenCode, sessionID: sessionID, timestamp: time, cwd: place.cwd,
                            processID: place.processID)
    }

    static func place(of record: TelemetryRecord) -> (cwd: String?, processID: Int32?) {
        let cwd = record.resource[cwdKey]?.string ?? record[cwdKey]?.string
        let pid = record.resource["process.pid"]?.int.flatMap { Int32(exactly: $0) }
        return (cwd.flatMap { $0.isEmpty ? nil : $0 }, pid.flatMap { $0 > 0 ? $0 : nil })
    }
}
