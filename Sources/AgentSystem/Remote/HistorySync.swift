import AgentKit
import Foundation
import os

public struct HistorySyncResult: Sendable, Equatable {
    public var talked: Bool
    public var applied: Bool
    public var wait: TimeInterval

    public init(talked: Bool = false, applied: Bool = false, wait: TimeInterval) {
        self.talked = talked
        self.applied = applied
        self.wait = wait
    }
}

public actor HistorySync {
    public static let pagesPerSync = 50

    private let cloud: any HistoryCloud
    private let fileSystem: any ProjectFileSystem & Sendable
    private var outbox = RemoteHistoryOutbox()
    private var store: ObjectIdentifier?
    private var lastCheck: Date?
    private var lastFetch: Date?
    private var fetchedFromStart: Set<RemoteHistoryPartKey>?
    private var origins: [String: String?] = [:]
    public private(set) var publishRetry = RemoteRetry()
    public private(set) var fetchRetry = RemoteRetry()
    public private(set) var health = HistorySyncHealth()

    public init(cloud: any HistoryCloud, fileSystem: any ProjectFileSystem & Sendable = LocalProjectFileSystem()) {
        self.cloud = cloud
        self.fileSystem = fileSystem
    }

    public func reset() {
        outbox = RemoteHistoryOutbox()
        store = nil
        lastCheck = nil
        lastFetch = nil
        fetchedFromStart = nil
        publishRetry = RemoteRetry()
        fetchRetry = RemoteRetry()
        health = HistorySyncHealth()
    }

    public func fetchSoon() {
        lastFetch = nil
    }

    // Only when the user turns the link off, never on an error or a lost account: the next link starts from an
    // empty copy and fetches every other Mac's history again.
    public func clearReceived(from ledger: Ledger?) async throws {
        fetchedFromStart = nil
        lastFetch = nil
        await cloud.restartHistoryFetch()
        try await ledger?.clearRemoteHistory()
    }

    // Publishing and fetching back off apart, so a full iCloud on this Mac never stops other Macs' history coming in.
    // Only `.unavailable` and `.noAccount` are thrown; nothing else fails the link.
    public func sync(ledger: Ledger?, sharing: Bool, deviceName: String?, now: Date = Date()) async throws -> HistorySyncResult {
        var result = HistorySyncResult(wait: RemoteHistoryPolicy.checkEvery)
        var moreToFetch = false
        if !publishRetry.isWaiting(at: now) {
            do {
                if try await publish(ledger: ledger, sharing: sharing, deviceName: deviceName, now: now) {
                    result.talked = true
                }
                succeeded(.publish, retry: &publishRetry)
            } catch {
                try backOff(error, .publish, retry: &publishRetry, now: now)
            }
        }
        if let ledger, !fetchRetry.isWaiting(at: now),
           now.timeIntervalSince(lastFetch ?? .distantPast) >= RemoteHistoryPolicy.fetchEvery {
            do {
                let fetched = try await fetch(into: ledger)
                result.applied = fetched.applied
                moreToFetch = fetched.more
                lastFetch = fetched.more ? nil : now
                result.talked = true
                if fetched.applied { Log.history.debug("History fetch applied other Macs' changes") }
                succeeded(.fetch, retry: &fetchRetry)
            } catch {
                try backOff(error, .fetch, retry: &fetchRetry, now: now)
            }
        }
        result.wait = wait(ledger: ledger, sharing: sharing, moreToFetch: moreToFetch, now: now)
        return result
    }

    private func succeeded(_ operation: HistorySyncOperation, retry: inout RemoteRetry) {
        let failures = retry.failures
        if failures > 0 || health.failure(of: operation) != nil {
            Log.history.notice("""
                History \(operation.rawValue, privacy: .public) recovered after \(failures, privacy: .public) \
                failure(s)
                """)
        }
        retry.succeeded()
        health.succeeded(operation)
    }

    private func backOff(_ error: any Error, _ operation: HistorySyncOperation, retry: inout RemoteRetry,
                         now: Date) throws {
        if error is CancellationError { throw error }
        try Task.checkCancellation()
        let link = CloudLinkError(error)
        let code = Log.code(of: error)
        switch link {
        case .unavailable, .noAccount:
            Log.history.notice("""
                History \(operation.rawValue, privacy: .public) stopped: \(link.name, privacy: .public) \
                (\(code, privacy: .public))
                """)
            throw error
        case .limited(let retryAfter):
            retry.failed(retryAfter: retryAfter, now: now)
        case .quotaExceeded, .network:
            retry.failed(now: now)
        case .other:
            retry.failed(now: now)
            health.failed(operation, error: (error as? CloudLinkFailure)?.cause ?? error as NSError, at: now)
        }
        let wait = Int((retry.retryAt ?? now).timeIntervalSince(now).rounded(.up))
        let failures = retry.failures
        let problem = health.failure(of: operation)?.problem.rawValue ?? "not counted"
        switch link {
        case .network, .limited:
            Log.history.notice("""
                History \(operation.rawValue, privacy: .public) failed: \(link.name, privacy: .public) \
                (\(code, privacy: .public)), failure \(failures, privacy: .public), retry in \
                \(wait, privacy: .public) s
                """)
        default:
            Log.history.error("""
                History \(operation.rawValue, privacy: .public) failed: \(link.name, privacy: .public) \
                (\(code, privacy: .public)), health \(problem, privacy: .public), failure \
                \(failures, privacy: .public), retry in \(wait, privacy: .public) s
                """)
        }
    }

    private func wait(ledger: Ledger?, sharing: Bool, moreToFetch: Bool, now: Date) -> TimeInterval {
        var waits: [TimeInterval] = []
        for retry in [publishRetry, fetchRetry] {
            if let at = retry.retryAt, now < at { waits.append(at.timeIntervalSince(now)) }
        }
        let publishing = sharing && !publishRetry.isWaiting(at: now)
        let fetching = ledger != nil && !fetchRetry.isWaiting(at: now)
        if ledger != nil, (moreToFetch && fetching) || (publishing && !outbox.pending.isEmpty) {
            waits.append(RemoteHistoryPolicy.backfillPause)
        }
        if fetching { waits.append(RemoteHistoryPolicy.fetchEvery - now.timeIntervalSince(lastFetch ?? .distantPast)) }
        if publishing, ledger != nil {
            waits.append(RemoteHistoryPolicy.checkEvery - now.timeIntervalSince(lastCheck ?? .distantPast))
        }
        return max(waits.min() ?? RemoteHistoryPolicy.checkEvery, 1)
    }

    private func publish(ledger: Ledger?, sharing: Bool, deviceName: String?, now: Date) async throws -> Bool {
        let published = await cloud.historyDays
        guard sharing else {
            outbox = RemoteHistoryOutbox()
            store = nil
            let stale = RemoteHistoryOutbox.stale(published, ledgerDays: nil, enabled: false)
            guard !stale.isEmpty else { return false }
            try await cloud.deleteHistory(days: stale)
            return true
        }
        guard let ledger else { return false }
        let id = ObjectIdentifier(ledger.store)
        if store != id {
            store = id
            outbox = RemoteHistoryOutbox()
            lastCheck = nil
        }
        let due = now.timeIntervalSince(lastCheck ?? .distantPast) >= RemoteHistoryPolicy.checkEvery
        guard due || !outbox.pending.isEmpty else { return false }
        if due {
            outbox.note(await ledger.store.takeHistoryChanges())
            lastCheck = now
        }
        var talked = false
        if outbox.needsScan {
            let days = try await ledger.reader.ledgerDays()
            let stale = RemoteHistoryOutbox.stale(published, ledgerDays: days, enabled: true)
            if !stale.isEmpty {
                try await cloud.deleteHistory(days: stale)
                talked = true
            }
            outbox.scanned(ledgerDays: days)
        }
        let thresholds = await ledger.store.pricing.contextThresholds
        for day in outbox.next(limit: RemoteHistoryPolicy.daysPerPass) {
            try Task.checkCancellation()
            let name = RemoteHistoryCalendar.name(of: day)
            let previous = await cloud.historyDays[name]
            let local = try await ledger.reader.localHistoryDay(day, contextThresholds: thresholds)
            guard !local.sessions.isEmpty else {
                if previous != nil {
                    try await cloud.deleteHistory(days: [name])
                    talked = true
                }
                outbox.done(day)
                continue
            }
            let projects = local.projects.map { source -> RemoteHistoryDay.Project in
                var project = source.project
                if project.origin == nil, source.kind == .repo { project.origin = origin(of: source.root) }
                return project
            }
            let parts = RemoteHistoryDay.build(device: cloud.device, deviceName: deviceName, machine: cloud.machine,
                                               day: day, sessions: local.sessions, projects: projects,
                                               updatedAt: RemoteHistoryOutbox.buildTime(now: Date(), previous: previous))
            if RemoteHistoryOutbox.needsPublish(RemoteHistoryDay.fingerprint(parts), published: previous) {
                try await cloud.publishHistory(parts)
                talked = true
            }
            outbox.done(day)
        }
        return talked
    }

    private func fetch(into ledger: Ledger) async throws -> (applied: Bool, more: Bool) {
        var applied = false
        for _ in 0..<Self.pagesPerSync {
            try Task.checkCancellation()
            let page = try await cloud.fetchHistory()
            if page.fromStart { fetchedFromStart = [] }
            fetchedFromStart?.formUnion(page.seen)
            if try await ledger.store.applyRemoteHistory(page.days, deleted: page.deleted, device: cloud.device,
                                                         machine: cloud.machine) {
                applied = true
            }
            // A fetch from the zone's start keeps no token until its last page, so one cut short by a relaunch starts
            // over and still drops the parts the zone no longer has.
            guard page.more else {
                if let seen = fetchedFromStart {
                    if try await ledger.store.dropRemoteHistory(keeping: seen) { applied = true }
                    fetchedFromStart = nil
                }
                await cloud.acknowledgeHistory()
                return (applied, false)
            }
            if fetchedFromStart == nil { await cloud.acknowledgeHistory() }
        }
        return (applied, true)
    }

    private func origin(of root: String) -> String? {
        if let cached = origins[root] { return cached }
        let hash = GitRemote.originHash(ofRepoAt: root, fileSystem: fileSystem)
        origins[root] = hash
        return hash
    }
}
