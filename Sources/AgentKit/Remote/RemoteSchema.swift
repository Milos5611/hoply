import Foundation

public enum RemoteSchema {
    public static let containerID = "iCloud.com.coolcraftcoders.hoply"
    public static let zoneName = "Hoply"
    public static let answerSubscriptionID = "hoply-answers"
    public static let version = 1

    public enum RecordType {
        public static let snapshot = "Snapshot"
        public static let request = "Request"
        public static let answer = "Answer"
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
