import AgentKit
import CloudKit
import Foundation
import os
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
        if let failure = error as? CloudLinkFailure {
            self = failure.link
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

    var name: String {
        switch self {
        case .unavailable: "unavailable"
        case .noAccount: "noAccount"
        case .network: "network"
        case .limited: "limited"
        case .quotaExceeded: "quotaExceeded"
        case .other: "other"
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

// Keeps the CloudKit error behind an `.other`, so history health can tell a rejected request from the rest;
// `CloudLinkError(_:)` unwraps it, so callers see the same cases as before.
struct CloudLinkFailure: Error, LocalizedError {
    let link: CloudLinkError
    let cause: NSError

    var errorDescription: String? { cause.localizedDescription }

    static func wrapping(_ error: any Error) -> any Error {
        if error is CloudLinkError || error is CloudLinkFailure { return error }
        let link = CloudLinkError(error)
        guard case .other = link else { return link }
        return CloudLinkFailure(link: link, cause: error as NSError)
    }
}

public protocol HistoryCloud: Sendable {
    var device: String { get }
    var machine: String? { get }
    var historyDays: [String: RemoteHistoryPublished] { get async }
    func publishHistory(_ parts: [RemoteHistoryDay]) async throws
    func deleteHistory(days: [String]) async throws
    func fetchHistory() async throws -> RemoteHistoryPage
    func acknowledgeHistory() async
    func restartHistoryFetch() async
}

struct CloudLinkState: Codable, Equatable {
    var device: String
    var machine: String?
    var zoneReady: Bool
    var subscriptionReady: Bool
    var changeToken: Data?
    var openRequests: [String]
    var launches: [String: Date]
    var transcriptZoneReady: Bool
    var transcripts: [String: Date]
    var historyZoneReady: Bool
    var historyToken: Data?
    var history: [String: RemoteHistoryPublished]

    init(device: String = UUID().uuidString, machine: String? = nil, zoneReady: Bool = false,
         subscriptionReady: Bool = false,
         changeToken: Data? = nil, openRequests: [String] = [], launches: [String: Date] = [:],
         transcriptZoneReady: Bool = false, transcripts: [String: Date] = [:], historyZoneReady: Bool = false,
         historyToken: Data? = nil, history: [String: RemoteHistoryPublished] = [:]) {
        self.device = device
        self.machine = machine
        self.zoneReady = zoneReady
        self.subscriptionReady = subscriptionReady
        self.changeToken = changeToken
        self.openRequests = openRequests
        self.launches = launches
        self.transcriptZoneReady = transcriptZoneReady
        self.transcripts = transcripts
        self.historyZoneReady = historyZoneReady
        self.historyToken = historyToken
        self.history = history
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = (try? container.decode(String.self, forKey: .device)).flatMap { $0.isEmpty ? nil : $0 }
            ?? UUID().uuidString
        machine = try? container.decode(String.self, forKey: .machine)
        zoneReady = (try? container.decode(Bool.self, forKey: .zoneReady)) ?? false
        subscriptionReady = (try? container.decode(Bool.self, forKey: .subscriptionReady)) ?? false
        changeToken = try? container.decode(Data.self, forKey: .changeToken)
        openRequests = (try? container.decode([String].self, forKey: .openRequests)) ?? []
        launches = (try? container.decode([String: Date].self, forKey: .launches)) ?? [:]
        transcriptZoneReady = (try? container.decode(Bool.self, forKey: .transcriptZoneReady)) ?? false
        transcripts = (try? container.decode([String: Date].self, forKey: .transcripts)) ?? [:]
        historyZoneReady = (try? container.decode(Bool.self, forKey: .historyZoneReady)) ?? false
        historyToken = try? container.decode(Data.self, forKey: .historyToken)
        history = (try? container.decode([String: RemoteHistoryPublished].self, forKey: .history)) ?? [:]
    }

    mutating func claimLaunch(_ answerID: String, createdAt: Date, now: Date) -> Bool {
        launches = launches.filter { now.timeIntervalSince($0.value) <= RemoteAnswers.launchLifetime }
        guard launches[answerID] == nil else { return false }
        launches[answerID] = max(now, createdAt)
        return true
    }

    // A state file from another Mac (Migration Assistant copies it) must not let this Mac delete, overwrite or claim
    // that Mac's records: a new device id, and nothing it wrote is remembered. Zones belong to the account, so they stay.
    @discardableResult
    mutating func adopt(machine: String?) -> Bool {
        guard let machine, self.machine != machine else { return false }
        guard self.machine != nil else {
            self.machine = machine
            return true
        }
        self = CloudLinkState(machine: machine, zoneReady: zoneReady, subscriptionReady: subscriptionReady,
                              transcriptZoneReady: transcriptZoneReady, historyZoneReady: historyZoneReady)
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
    public nonisolated let machine: String?
    private let stateURL: URL
    private var state: CloudLinkState
    private var leftovers: [String]
    private var fetchedToken: Data?
    private var historyCursor: Data?
    private var container: CKContainer?

    public init(stateURL: URL = CloudLink.defaultStateURL, machine: String? = MachineID.current) {
        var state = CloudLinkState.load(from: stateURL)
        if state.adopt(machine: machine), FileManager.default.fileExists(atPath: stateURL.path) {
            try? state.save(to: stateURL)
        }
        self.machine = machine
        self.stateURL = stateURL
        self.state = state
        device = state.device
        leftovers = state.openRequests
    }

    public var openRequestIDs: [String] { state.openRequests }
    public var transcriptRecords: [String: Date] { state.transcripts }
    public var historyDays: [String: RemoteHistoryPublished] { state.history }

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
            throw failed(error, "accountStatus", RemoteSchema.containerID)
        }
    }

    public func prepare() async throws {
        guard try await accountStatus() == .available else { throw CloudLinkError.noAccount }
        try await run("prepare", RemoteSchema.zoneName) { link, database in
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

    public func publish(_ transcript: RemoteTranscript) async throws {
        _ = try cloudContainer()
        let image: RemoteRecord
        do {
            image = try RemoteSchema.record(transcript)
        } catch {
            throw failed(error, "encode", RemoteSchema.RecordType.transcript)
        }
        // Remembered before the save, so a withdraw after a crash mid-save still deletes it.
        if state.transcripts[image.name] == nil {
            state.transcripts[image.name] = transcript.updatedAt
            saveState()
        }
        try await runTranscripts("save", "\(RemoteSchema.RecordType.transcript) in \(RemoteSchema.transcriptZoneName)") {
            link, database in
            let record = Self.record(from: image, zone: link.transcriptZoneID)
            let saved = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys,
                                                         atomically: true).saveResults
            _ = try saved[record.recordID]?.get()
        }
        state.transcripts[image.name] = max(state.transcripts[image.name] ?? transcript.updatedAt, transcript.updatedAt)
        saveState()
    }

    public func deleteTranscripts(_ names: [String]) async throws {
        let database = try cloudContainer().privateCloudDatabase
        guard !names.isEmpty else { return }
        do {
            try await Self.delete(names.map { transcriptRecordID($0) }, in: database)
        } catch where Self.zoneMissing(error) {
        } catch {
            throw failed(error, "delete", RemoteSchema.transcriptZoneName)
        }
        for name in names { state.transcripts[name] = nil }
        saveState()
    }

    public func publishHistory(_ parts: [RemoteHistoryDay]) async throws {
        _ = try cloudContainer()
        guard let first = parts.first else { return }
        let day = first.day
        let images: [RemoteRecord]
        do {
            images = try parts.map { try RemoteSchema.record($0) }
        } catch {
            throw failed(error, "encode", RemoteSchema.RecordType.historyDay)
        }
        let previous = state.history[day]
        let extra = RemoteHistoryOutbox.extraParts(device: device, day: day, previous: previous, parts: parts.count)
        // Remembered before the save without a fingerprint: a crash mid-save republishes, a withdraw finds every part.
        state.history[day] = RemoteHistoryPublished(fingerprint: nil, parts: max(previous?.parts ?? 0, parts.count),
                                                    at: first.updatedAt)
        saveState()
        try await runHistory("save", "\(RemoteSchema.RecordType.historyDay) in \(RemoteSchema.historyZoneName)") {
            link, database in
            for image in images {
                let record = Self.record(from: image, zone: link.historyZoneID)
                let saved = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys,
                                                             atomically: true).saveResults
                _ = try saved[record.recordID]?.get()
            }
            try await Self.delete(extra.map { link.historyRecordID($0) }, in: database)
        }
        state.history[day] = RemoteHistoryPublished(fingerprint: RemoteHistoryDay.fingerprint(parts),
                                                    parts: parts.count, at: first.updatedAt)
        saveState()
    }

    public func deleteHistory(days: [String]) async throws {
        let database = try cloudContainer().privateCloudDatabase
        let known = days.filter { state.history[$0] != nil }
        guard !known.isEmpty else { return }
        let names = known.flatMap { day in
            state.history[day].map { RemoteHistoryOutbox.recordNames(device: device, day: day, published: $0) } ?? []
        }
        do {
            try await Self.delete(names.map { historyRecordID($0) }, in: database)
        } catch where Self.zoneMissing(error) {
        } catch {
            throw failed(error, "delete", RemoteSchema.historyZoneName)
        }
        for day in known { state.history[day] = nil }
        saveState()
    }

    // The page's token is kept only by `acknowledgeHistory`, once the caller has applied the page.
    public func fetchHistory() async throws -> RemoteHistoryPage {
        try await runHistory("fetch", RemoteSchema.historyZoneName) { link, database in
            var token = (link.historyCursor ?? link.state.historyToken).flatMap(Self.token(from:))
            var fromStart = token == nil
            let changes: HistoryChanges
            do {
                changes = try await Self.historyChanges(database, zone: link.historyZoneID, since: token)
            } catch let error as CKError where error.code == .changeTokenExpired {
                token = nil
                fromStart = true
                changes = try await Self.historyChanges(database, zone: link.historyZoneID, since: nil)
            }
            // A record CloudKit failed to return still exists: the page fails, so the token never moves past it and a
            // fetch from the start never drops its stored copy.
            if let failure = changes.failure { throw failure }
            link.historyCursor = Self.data(from: changes.token)
            var page = RemoteHistoryPage(fromStart: fromStart, more: changes.more)
            page.seen = changes.names.compactMap { RemoteSchema.historyPart(fromRecordName: $0) }
            for record in changes.records {
                if let day = RemoteSchema.historyDay(from: Self.image(of: record)) { page.days.append(day) }
            }
            page.deleted = changes.deleted.compactMap { RemoteSchema.historyPart(fromRecordName: $0) }
            return page
        }
    }

    public func acknowledgeHistory() {
        guard Self.isAvailable, let historyCursor else { return }
        state.historyToken = historyCursor
        saveState()
    }

    public func restartHistoryFetch() {
        guard Self.isAvailable else { return }
        historyCursor = nil
        state.historyToken = nil
        saveState()
    }

    public func open(_ request: RemoteRequest) async throws {
        try await save { try RemoteSchema.record(request) }
        guard !state.openRequests.contains(request.id) else { return }
        state.openRequests.append(request.id)
        saveState()
    }

    public func close(requestID: String) async throws {
        try await run("delete", "\(RemoteSchema.RecordType.request) in \(RemoteSchema.zoneName)") { link, database in
            try await Self.delete([link.recordID(requestID)], in: database)
        }
        state.openRequests.removeAll { $0 == requestID }
        saveState()
    }

    public func fetchAnswers() async throws -> [RemoteAnswer] {
        try await run("fetch", RemoteSchema.zoneName) { link, database in
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
        try await run("delete", "\(RemoteSchema.RecordType.answer) in \(RemoteSchema.zoneName)") { link, database in
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
        // Only this Mac's transcripts and history: another Mac on the same Apple ID shares the zones.
        let transcripts = state.transcripts.keys.sorted()
        let history = state.history.keys.sorted().flatMap { day in
            state.history[day].map { RemoteHistoryOutbox.recordNames(device: device, day: day, published: $0) } ?? []
        }
        for (zone, ids) in [(RemoteSchema.zoneName, names.map { recordID($0) }),
                            (RemoteSchema.transcriptZoneName, transcripts.map { transcriptRecordID($0) }),
                            (RemoteSchema.historyZoneName, history.map { historyRecordID($0) })] where !ids.isEmpty {
            do {
                try await Self.delete(ids, in: database)
            } catch where Self.zoneMissing(error) {
            } catch {
                throw failed(error, "withdraw", zone)
            }
        }
        state.openRequests = []
        state.transcripts = [:]
        state.history = [:]
        state.historyToken = nil
        historyCursor = nil
        leftovers = []
        saveState()
    }

    private nonisolated var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: RemoteSchema.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private nonisolated var transcriptZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: RemoteSchema.transcriptZoneName, ownerName: CKCurrentUserDefaultName)
    }

    private nonisolated var historyZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: RemoteSchema.historyZoneName, ownerName: CKCurrentUserDefaultName)
    }

    private nonisolated func historyRecordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: historyZoneID)
    }

    private nonisolated func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private nonisolated func transcriptRecordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: transcriptZoneID)
    }

    private func cloudContainer() throws -> CKContainer {
        guard Self.isAvailable else { throw CloudLinkError.unavailable }
        if let container { return container }
        let made = CKContainer(identifier: RemoteSchema.containerID)
        container = made
        return made
    }

    private func saveState() {
        do {
            try state.save(to: stateURL)
        } catch {
            Log.icloud.error("Saving the link state failed: \(Log.code(of: error), privacy: .public)")
        }
    }

    private nonisolated func failed(_ error: any Error, _ operation: String, _ target: String) -> any Error {
        Self.log(error, operation: operation, target: target)
        return CloudLinkFailure.wrapping(error)
    }

    static func log(_ error: any Error, operation: String, target: String) {
        let code = Log.code(of: error)
        let retry = (error as? CKError)?.retryAfterSeconds
        let retryText = retry.map { ", retry after \(Int($0.rounded(.up))) s" } ?? ""
        let detail = (error as NSError).localizedDescription
        switch CloudLinkError(error) {
        case .network, .limited:
            Log.icloud.notice("""
                CloudKit \(operation, privacy: .public) on \(target, privacy: .public) failed: \
                \(code, privacy: .public)\(retryText, privacy: .public) (\(detail, privacy: .private))
                """)
        case .unavailable, .noAccount, .quotaExceeded, .other:
            Log.icloud.error("""
                CloudKit \(operation, privacy: .public) on \(target, privacy: .public) failed: \
                \(code, privacy: .public)\(retryText, privacy: .public) (\(detail, privacy: .private))
                """)
        }
    }

    private static func logZoneMissing(_ zone: String, operation: String) {
        Log.icloud.notice("Zone \(zone, privacy: .public) missing during \(operation, privacy: .public); recreating it")
    }

    private func save(_ make: () throws -> RemoteRecord) async throws {
        _ = try cloudContainer()
        let image: RemoteRecord
        do {
            image = try make()
        } catch {
            throw failed(error, "encode", "record")
        }
        try await run("save", "\(image.type) in \(RemoteSchema.zoneName)") { link, database in
            let record = Self.record(from: image, zone: link.zoneID)
            let saved = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys,
                                                         atomically: true).saveResults
            _ = try saved[record.recordID]?.get()
        }
    }

    private func run<T: Sendable>(_ operation: String, _ target: String,
                                  _ body: (isolated CloudLink, CKDatabase) async throws -> T) async throws -> T {
        let database = try cloudContainer().privateCloudDatabase
        do {
            return try await body(self, database)
        } catch where Self.zoneMissing(error) {
            Self.logZoneMissing(RemoteSchema.zoneName, operation: operation)
            state.zoneReady = false
            state.subscriptionReady = false
            state.changeToken = nil
            fetchedToken = nil
            saveState()
            do {
                try await ensureZone(database)
                return try await body(self, database)
            } catch {
                throw failed(error, operation, target)
            }
        } catch {
            throw failed(error, operation, target)
        }
    }

    private func runTranscripts(_ operation: String, _ target: String,
                                _ body: (isolated CloudLink, CKDatabase) async throws -> Void) async throws {
        let database = try cloudContainer().privateCloudDatabase
        do {
            try await body(self, database)
        } catch where Self.zoneMissing(error) {
            Self.logZoneMissing(RemoteSchema.transcriptZoneName, operation: operation)
            state.transcriptZoneReady = false
            saveState()
            do {
                try await ensureTranscriptZone(database)
                try await body(self, database)
            } catch {
                throw failed(error, operation, target)
            }
        } catch {
            throw failed(error, operation, target)
        }
    }

    private func runHistory<T: Sendable>(_ operation: String, _ target: String,
                                         _ body: (isolated CloudLink, CKDatabase) async throws -> T) async throws -> T {
        let database = try cloudContainer().privateCloudDatabase
        do {
            try await ensureHistoryZone(database)
            return try await body(self, database)
        } catch where Self.zoneMissing(error) {
            Self.logZoneMissing(RemoteSchema.historyZoneName, operation: operation)
            state.historyZoneReady = false
            state.historyToken = nil
            historyCursor = nil
            saveState()
            do {
                try await ensureHistoryZone(database)
                return try await body(self, database)
            } catch {
                throw failed(error, operation, target)
            }
        } catch {
            throw failed(error, operation, target)
        }
    }

    private func ensureHistoryZone(_ database: CKDatabase) async throws {
        guard !state.historyZoneReady else { return }
        let zone = CKRecordZone(zoneID: historyZoneID)
        let saved = try await database.modifyRecordZones(saving: [zone], deleting: []).saveResults
        _ = try saved[zone.zoneID]?.get()
        state.historyZoneReady = true
        saveState()
    }

    private func ensureTranscriptZone(_ database: CKDatabase) async throws {
        guard !state.transcriptZoneReady else { return }
        let zone = CKRecordZone(zoneID: transcriptZoneID)
        let saved = try await database.modifyRecordZones(saving: [zone], deleting: []).saveResults
        _ = try saved[zone.zoneID]?.get()
        state.transcriptZoneReady = true
        saveState()
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
        try await ensureTranscriptZone(database)
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

    private struct HistoryChanges: Sendable {
        var records: [CKRecord]
        var names: [String]
        var failure: (any Error)?
        var deleted: [String]
        var token: CKServerChangeToken
        var more: Bool
    }

    private static func historyChanges(_ database: CKDatabase, zone: CKRecordZone.ID,
                                       since token: CKServerChangeToken?) async throws -> HistoryChanges {
        let changes = try await database.recordZoneChanges(inZoneWith: zone, since: token, resultsLimit: 100)
        var records: [CKRecord] = []
        var failure: (any Error)?
        for result in changes.modificationResultsByID.values {
            switch result {
            case .success(let modification): records.append(modification.record)
            case .failure(let error): failure = failure ?? CloudLinkFailure.wrapping(error)
            }
        }
        return HistoryChanges(records: records, names: changes.modificationResultsByID.keys.map(\.recordName),
                              failure: failure, deleted: changes.deletions.map(\.recordID.recordName),
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

extension CloudLink: HistoryCloud {}
