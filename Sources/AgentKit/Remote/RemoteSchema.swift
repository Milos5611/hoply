import Foundation

public enum RemoteSchema {
    public static let containerID = "iCloud.com.coolcraftcoders.hoply"
    public static let zoneName = "Hoply"
    public static let transcriptZoneName = "HoplyTranscripts"
    public static let historyZoneName = "HoplyHistory"
    public static let answerSubscriptionID = "hoply-answers"
    public static let version = 1

    public enum RecordType {
        public static let snapshot = "Snapshot"
        public static let request = "Request"
        public static let answer = "Answer"
        public static let transcript = "Transcript"
        public static let historyDay = "HistoryDay"
    }

    // CloudKit never lets a field change between plain and encrypted: a new meaning needs a new field name.
    public enum Field {
        public static let payload = "payload"
        public static let kind = "kind"
        public static let createdAt = "createdAt"
        public static let version = "version"
        public static let encrypted: Set<String> = [payload]
    }

    public static func snapshotRecordName(device: String) -> String { "snapshot-" + device }

    public static func transcriptRecordName(device: String, session: String) -> String {
        "transcript-" + device + "-" + sessionHash(session)
    }

    public static func historyRecordName(device: String, day: String, part: Int) -> String {
        "history-" + device + "-" + day.replacingOccurrences(of: "-", with: "") + "-" + String(part)
    }

    // Parsed from the end: device ids are UUIDs and hold dashes themselves.
    public static func historyPart(fromRecordName name: String) -> RemoteHistoryPartKey? {
        guard name.hasPrefix("history-") else { return nil }
        let fields = name.dropFirst("history-".count).split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count >= 3, let part = Int(fields[fields.count - 1]), part >= 0 else { return nil }
        let digits = fields[fields.count - 2]
        guard digits.count == 8, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        let device = fields[..<(fields.count - 2)].joined(separator: "-")
        guard !device.isEmpty else { return nil }
        let day = "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.suffix(2))"
        return RemoteHistoryPartKey(device: device, day: day, part: part)
    }

    // FNV-1a 64 of the UTF-8 bytes, 16 hex digits: the phone computes the same name, so never a per-launch hash.
    public static func sessionHash(_ session: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in session.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    public static func sessionKey(_ key: SessionKey) -> String { "\(key.source.rawValue):\(key.id)" }

    public static let titleLimit = 200

    static func title(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.count > titleLimit ? String(text.prefix(titleLimit)) + "…" : text
    }

    public static func record(_ snapshot: RemoteSnapshot) throws -> RemoteRecord {
        RemoteRecord(type: RecordType.snapshot, name: snapshotRecordName(device: snapshot.device), kind: nil,
                     createdAt: snapshot.updatedAt, payload: try encode(snapshot))
    }

    public static func record(_ request: RemoteRequest) throws -> RemoteRecord {
        RemoteRecord(type: RecordType.request, name: request.id, kind: request.kind.rawValue,
                     createdAt: request.createdAt, payload: try encode(request))
    }

    public static func record(_ answer: RemoteAnswer) throws -> RemoteRecord {
        RemoteRecord(type: RecordType.answer, name: answer.id, kind: answer.kind.rawValue,
                     createdAt: answer.createdAt, payload: try encode(answer))
    }

    public static func record(_ transcript: RemoteTranscript) throws -> RemoteRecord {
        RemoteRecord(type: RecordType.transcript,
                     name: transcriptRecordName(device: transcript.device, session: transcript.session), kind: nil,
                     createdAt: transcript.updatedAt, payload: try encode(transcript))
    }

    public static func record(_ day: RemoteHistoryDay) throws -> RemoteRecord {
        RemoteRecord(type: RecordType.historyDay,
                     name: historyRecordName(device: day.device, day: day.day, part: day.part), kind: nil,
                     createdAt: day.updatedAt, payload: try encode(day))
    }

    public static func historyDay(from record: RemoteRecord) -> RemoteHistoryDay? {
        guard record.type == RecordType.historyDay,
              let day = try? decode(RemoteHistoryDay.self, from: record.payload),
              historyPart(fromRecordName: record.name) == day.key else { return nil }
        return day
    }

    public static func snapshot(from record: RemoteRecord) -> RemoteSnapshot? {
        guard record.type == RecordType.snapshot else { return nil }
        return try? decode(RemoteSnapshot.self, from: record.payload)
    }

    public static func request(from record: RemoteRecord) -> RemoteRequest? {
        guard record.type == RecordType.request, var request = try? decode(RemoteRequest.self, from: record.payload)
        else { return nil }
        request.id = record.name
        return request
    }

    public static func transcript(from record: RemoteRecord) -> RemoteTranscript? {
        guard record.type == RecordType.transcript else { return nil }
        return try? decode(RemoteTranscript.self, from: record.payload)
    }

    // Never nil for an Answer record: one Hoply can't read is still deleted, so it can't linger in the zone.
    public static func answer(from record: RemoteRecord) -> RemoteAnswer? {
        guard record.type == RecordType.answer else { return nil }
        guard var answer = try? decode(RemoteAnswer.self, from: record.payload) else {
            return RemoteAnswer(id: record.name, kind: .unknown, createdAt: record.createdAt ?? .distantPast)
        }
        answer.id = record.name
        return answer
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}

public struct RemoteRecord: Sendable, Equatable {
    public var type: String
    public var name: String
    public var kind: String?
    public var createdAt: Date?
    public var version: Int
    public var payload: Data

    public init(type: String, name: String, kind: String?, createdAt: Date?, version: Int = RemoteSchema.version,
                payload: Data) {
        self.type = type
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.version = version
        self.payload = payload
    }
}

public enum RemoteAccountStatus: String, Sendable, Equatable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
}
