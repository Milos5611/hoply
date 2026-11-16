import AgentKit
import CloudKit
import Foundation
import Security
import SystemConfiguration

public enum CloudLinkError: Error, Equatable, Sendable {
    case unavailable
    case noAccount
    case network
    case limited(retryAfter: TimeInterval?)
    case quotaExceeded
    case other(String)

    public init(_ error: any Error) {
        if let link = error as? CloudLinkError {
            self = link
            return
        }
        guard let error = error as? CKError else {
            self = .other(error.localizedDescription)
            return
        }
        switch error.code {
        case .notAuthenticated, .accountTemporarilyUnavailable, .managedAccountRestricted:
            self = .noAccount
        case .networkUnavailable, .networkFailure, .serverResponseLost:
            self = .network
        case .requestRateLimited, .zoneBusy, .serviceUnavailable:
            self = .limited(retryAfter: error.retryAfterSeconds)
        case .quotaExceeded:
            self = .quotaExceeded
        case .missingEntitlement, .badContainer:
            self = .unavailable
        case .partialFailure:
            // `batchRequestFailed` only says another item in the batch failed; that item's error is the cause.
            let causes = (error.partialErrorsByItemID ?? [:]).values
                .filter { ($0 as? CKError)?.code != .batchRequestFailed }
                .map(CloudLinkError.init)
            self = causes.min { $0.rank < $1.rank } ?? .other(error.localizedDescription)
        default:
            self = .other(error.localizedDescription)
        }
    }

    var rank: Int {
        switch self {
        case .unavailable: 0
        case .noAccount: 1
        case .quotaExceeded: 2
        case .limited: 3
        case .network: 4
        case .other: 5
        }
    }
}

struct CloudLinkState: Codable, Equatable {
    var device: String
    var zoneReady: Bool
    var subscriptionReady: Bool
    var changeToken: Data?
    var openRequests: [String]
    var launches: [String: Date]

    init(device: String = UUID().uuidString, zoneReady: Bool = false, subscriptionReady: Bool = false,
         changeToken: Data? = nil, openRequests: [String] = [], launches: [String: Date] = [:]) {
        self.device = device
        self.zoneReady = zoneReady
        self.subscriptionReady = subscriptionReady
        self.changeToken = changeToken
        self.openRequests = openRequests
        self.launches = launches
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = (try? container.decode(String.self, forKey: .device)).flatMap { $0.isEmpty ? nil : $0 }
            ?? UUID().uuidString
        zoneReady = (try? container.decode(Bool.self, forKey: .zoneReady)) ?? false
        subscriptionReady = (try? container.decode(Bool.self, forKey: .subscriptionReady)) ?? false
        changeToken = try? container.decode(Data.self, forKey: .changeToken)
        openRequests = (try? container.decode([String].self, forKey: .openRequests)) ?? []
        launches = (try? container.decode([String: Date].self, forKey: .launches)) ?? [:]
    }

    mutating func claimLaunch(_ answerID: String, createdAt: Date, now: Date) -> Bool {
        launches = launches.filter { now.timeIntervalSince($0.value) <= RemoteAnswers.launchLifetime }
        guard launches[answerID] == nil else { return false }
        launches[answerID] = max(now, createdAt)
        return true
    }

    static func load(from url: URL) -> CloudLinkState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(CloudLinkState.self, from: data) else { return CloudLinkState() }
        return state
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

public actor CloudLink {
    // `CKContainer(identifier:)` traps in a process without the iCloud entitlement (swift run, tests, ad-hoc builds).
    public static var isAvailable: Bool { entitled }

    private static let entitled = isEntitled(
        containers: entitlement("com.apple.developer.icloud-container-identifiers"),
        services: entitlement("com.apple.developer.icloud-services"))

    public static var defaultStateURL: URL {
        URL.applicationSupportDirectory.appending(path: "Hoply/icloud-link.json")
    }

    public static var deviceName: String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }

    public static let accountChanged = Notification.Name.CKAccountChanged

    public static func isAnswerNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == RemoteSchema.answerSubscriptionID
    }

    static func isEntitled(containers: Any?, services: Any?) -> Bool {
        guard let containers = containers as? [String], let services = services as? [String] else { return false }
        return containers.contains(RemoteSchema.containerID) && services.contains("CloudKit")
    }

    private static func entitlement(_ name: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    }

    public nonisolated let device: String
    private let stateURL: URL
    private var state: CloudLinkState
    private var leftovers: [String]
    private var fetchedToken: Data?
    private var container: CKContainer?

    public init(stateURL: URL = CloudLink.defaultStateURL) {
        let state = CloudLinkState.load(from: stateURL)
        self.stateURL = stateURL
        self.state = state
        device = state.device
        leftovers = state.openRequests
    }

    public var openRequestIDs: [String] { state.openRequests }

    public func claimLaunch(_ answerID: String, createdAt: Date, now: Date = Date()) -> Bool {
        let before = state
        let claimed = state.claimLaunch(answerID, createdAt: createdAt, now: now)
        if state != before { saveState() }
        return claimed
    }

    public func accountStatus() async throws -> RemoteAccountStatus {
        let container = try cloudContainer()
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .couldNotDetermine
            @unknown default: return .couldNotDetermine
            }
        } catch {
            throw CloudLinkError(error)
        }
    }

    public func prepare() async throws {
        guard try await accountStatus() == .available else { throw CloudLinkError.noAccount }
        try await run { link, database in
            try await link.ensureZone(database)
            let stale = link.leftovers
            guard !stale.isEmpty else { return }
            // Held requests die with the process that held them; the phone must not keep offering them.
            try await Self.delete(stale.map { link.recordID($0) }, in: database)
            link.state.openRequests.removeAll { stale.contains($0) }
            link.leftovers = []
            link.saveState()
        }
    }

    public func publish(_ snapshot: RemoteSnapshot) async throws {
        try await save { try RemoteSchema.record(snapshot) }
    }

    public func open(_ request: RemoteRequest) async throws {
        try await save { try RemoteSchema.record(request) }
        guard !state.openRequests.contains(request.id) else { return }
        state.openRequests.append(request.id)
        saveState()
    }

    public func close(requestID: String) async throws {
        try await run { link, database in
            try await Self.delete([link.recordID(requestID)], in: database)
        }
        state.openRequests.removeAll { $0 == requestID }
        saveState()
    }

    public func fetchAnswers() async throws -> [RemoteAnswer] {
        try await run { link, database in
            var token = link.state.changeToken.flatMap(Self.token(from:))
            var restarted = false
            var answers: [RemoteAnswer] = []
            while true {
                let changes: ZoneChanges
                do {
                    changes = try await Self.zoneChanges(database, zone: link.zoneID, since: token)
                } catch let error as CKError where error.code == .changeTokenExpired && !restarted {
                    token = nil
                    restarted = true
                    answers = []
                    continue
                }
                answers += changes.records.compactMap { RemoteSchema.answer(from: Self.image(of: $0)) }
                token = changes.token
                if !changes.more { break }
            }
            link.fetchedToken = token.flatMap(Self.data(from:))
            return answers
        }
    }

    // The fetch's change token is kept only now, so answers fetched but never acknowledged come back next time.
    public func acknowledge(_ answerIDs: [String]) async throws {
        try await run { link, database in
            try await Self.delete(answerIDs.map { link.recordID($0) }, in: database)
        }
        guard let fetchedToken else { return }
        state.changeToken = fetchedToken
        self.fetchedToken = nil
        saveState()
    }

    public func withdraw() async throws {
        let database = try cloudContainer().privateCloudDatabase
        let names = [RemoteSchema.snapshotRecordName(device: device)] + state.openRequests + leftovers
        do {
            try await Self.delete(names.map { recordID($0) }, in: database)
        } catch where Self.zoneMissing(error) {
        } catch {
            throw CloudLinkError(error)
        }
        state.openRequests = []
        leftovers = []
        saveState()
    }

    private nonisolated var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: RemoteSchema.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private nonisolated func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private func cloudContainer() throws -> CKContainer {
        guard Self.isAvailable else { throw CloudLinkError.unavailable }
        if let container { return container }
        let made = CKContainer(identifier: RemoteSchema.containerID)
        container = made
        return made
    }

    private func saveState() {
        try? state.save(to: stateURL)
    }

    private func save(_ make: () throws -> RemoteRecord) async throws {
        _ = try cloudContainer()
        let image: RemoteRecord
        do {
            image = try make()
        } catch {
            throw CloudLinkError(error)
        }
        try await run { link, database in
            let record = Self.record(from: image, zone: link.zoneID)
            let saved = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys,
                                                         atomically: true).saveResults
            _ = try saved[record.recordID]?.get()
        }
    }

    private func run<T: Sendable>(_ body: (isolated CloudLink, CKDatabase) async throws -> T) async throws -> T {
        let database = try cloudContainer().privateCloudDatabase
        do {
            return try await body(self, database)
        } catch where Self.zoneMissing(error) {
            state.zoneReady = false
            state.subscriptionReady = false
            state.changeToken = nil
            fetchedToken = nil
            saveState()
            do {
                try await ensureZone(database)
                return try await body(self, database)
            } catch {
                throw CloudLinkError(error)
            }
        } catch {
            throw CloudLinkError(error)
        }
    }

    private func ensureZone(_ database: CKDatabase) async throws {
        if !state.zoneReady {
            let zone = CKRecordZone(zoneID: zoneID)
            let saved = try await database.modifyRecordZones(saving: [zone], deleting: []).saveResults
            _ = try saved[zone.zoneID]?.get()
            state.zoneReady = true
            saveState()
        }
        if !state.subscriptionReady {
            let subscription = CKRecordZoneSubscription(zoneID: zoneID,
                                                        subscriptionID: RemoteSchema.answerSubscriptionID)
            subscription.recordType = RemoteSchema.RecordType.answer
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            let saved = try await database.modifySubscriptions(saving: [subscription], deleting: []).saveResults
            _ = try saved[subscription.subscriptionID]?.get()
            state.subscriptionReady = true
            saveState()
        }
    }

    private struct ZoneChanges: Sendable {
        var records: [CKRecord]
        var token: CKServerChangeToken
        var more: Bool
    }

    private static func zoneChanges(_ database: CKDatabase, zone: CKRecordZone.ID,
                                    since token: CKServerChangeToken?) async throws -> ZoneChanges {
        let changes = try await database.recordZoneChanges(inZoneWith: zone, since: token)
        return ZoneChanges(records: changes.modificationResultsByID.values.compactMap { try? $0.get().record },
                           token: changes.changeToken, more: changes.moreComing)
    }

    private static func delete(_ ids: [CKRecord.ID], in database: CKDatabase) async throws {
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            let deleted = try await database.modifyRecords(saving: [], deleting: chunk, atomically: false).deleteResults
            for result in deleted.values {
                do {
                    try result.get()
                } catch let error as CKError where error.code == .unknownItem {
                    continue
                }
            }
        }
    }

    static func zoneMissing(_ error: any Error) -> Bool {
        guard let error = error as? CKError else { return false }
        switch error.code {
        case .zoneNotFound, .userDeletedZone:
            return true
        case .partialFailure:
            return (error.partialErrorsByItemID ?? [:]).values.contains { zoneMissing($0) }
        default:
            return false
        }
    }

    static func record(from image: RemoteRecord, zone: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: image.type, recordID: CKRecord.ID(recordName: image.name, zoneID: zone))
        record.encryptedValues[RemoteSchema.Field.payload] = image.payload
        record[RemoteSchema.Field.kind] = image.kind
        record[RemoteSchema.Field.createdAt] = image.createdAt
        record[RemoteSchema.Field.version] = image.version
        return record
    }

    static func image(of record: CKRecord) -> RemoteRecord {
        let kind: String? = record[RemoteSchema.Field.kind]
        let createdAt: Date? = record[RemoteSchema.Field.createdAt]
        let version: Int? = record[RemoteSchema.Field.version]
        let payload: Data? = record.encryptedValues[RemoteSchema.Field.payload]
        return RemoteRecord(type: record.recordType, name: record.recordID.recordName, kind: kind,
                            createdAt: createdAt ?? record.creationDate, version: version ?? 0,
                            payload: payload ?? Data())
    }

    private static func token(from data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private static func data(from token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }
}
