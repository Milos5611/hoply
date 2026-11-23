import AgentKit
import AgentSystem
import Foundation
import XCTest

private actor FakeHistoryCloud: HistoryCloud {
    nonisolated let device = "mac-a"
    nonisolated let machine: String? = "m-a"
    var days: [String: RemoteHistoryPublished] = [:]
    var published: [[RemoteHistoryDay]] = []
    var deleted: [[String]] = []
    var pages: [RemoteHistoryPage] = []
    var fetches = 0
    var acknowledgedAfter: [Int] = []
    var restarts = 0
    var publishError: CloudLinkError?
    var fetchError: CloudLinkError?

    var historyDays: [String: RemoteHistoryPublished] { days }

    func publishHistory(_ parts: [RemoteHistoryDay]) async throws {
        if let publishError { throw publishError }
        published.append(parts)
        days[parts[0].day] = RemoteHistoryPublished(fingerprint: RemoteHistoryDay.fingerprint(parts), parts: parts.count,
                                                    at: parts[0].updatedAt)
    }

    func deleteHistory(days names: [String]) async throws {
        deleted.append(names)
        for name in names { days[name] = nil }
    }

    func fetchHistory() async throws -> RemoteHistoryPage {
        fetches += 1
        if let fetchError { throw fetchError }
        return pages.isEmpty ? RemoteHistoryPage() : pages.removeFirst()
    }

    func acknowledgeHistory() async { acknowledgedAfter.append(fetches) }
    func restartHistoryFetch() async { restarts += 1 }

    func set(days: [String: RemoteHistoryPublished]) { self.days = days }
    func set(pages: [RemoteHistoryPage]) { self.pages = pages }
    func set(publishError: CloudLinkError?) { self.publishError = publishError }
    func set(fetchError: CloudLinkError?) { self.fetchError = fetchError }
}

final class HistorySyncTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var day0: Int { RemoteHistoryCalendar.day(of: t0) }
    private func name(_ offset: Int) -> String { RemoteHistoryCalendar.name(of: day0 + offset) }
    private var old: RemoteHistoryPublished { RemoteHistoryPublished(fingerprint: "old", parts: 1, at: t0) }

    private func ledger(_ directory: TempDirectory) throws -> Ledger {
        try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                      claudeConfigDirectory: directory.path("claude"),
                                                      copilotHome: directory.path("copilot"),
                                                      pricingOverridesURL: nil, watchForChanges: false))
    }

    private func usage(_ id: String, at offset: TimeInterval = 0) -> LedgerBatch {
        LedgerBatch(usage: [UsageRecord(dedupeKey: "k:\(id):\(offset)", source: .claudeCode, sessionID: id,
                                        timestamp: t0.addingTimeInterval(offset), model: "claude-opus-5-5",
                                        tokens: TokenCounts(input: 10, output: 100), cwd: "/Users/dev/hoply")],
                    sessions: [SessionUpdate(key: SessionKey(source: .claudeCode, id: id), firstAt: t0,
                                             lastAt: t0.addingTimeInterval(offset), cwd: "/Users/dev/hoply")])
    }

    private func remoteDay(_ device: String, part: Int = 0, parts: Int = 1, machine: String? = nil) -> RemoteHistoryDay {
        let usage = RemoteHistoryDay.Usage(model: "claude-opus-5-5", at: t0, last: t0,
                                           tokens: TokenCounts(output: 10), calls: 1)
        return RemoteHistoryDay(device: device, machine: machine, day: name(0), part: part, parts: parts, updatedAt: t0,
                                sessions: [RemoteHistoryDay.Session(key: "claude-code:\(device)-\(part)",
                                                                    agent: "claude-code", start: t0, end: t0,
                                                                    usage: [usage])])
    }

    private func remoteCalls(_ ledger: Ledger) async throws -> Int {
        try await ledger.reader.overview(scope: .all).allTime.calls - ledger.reader.overview().allTime.calls
    }

    func testSharingOffDeletesEveryDayThisMacPublished() async throws {
        let cloud = FakeHistoryCloud()
        await cloud.set(days: [name(0): old, name(-1): old])
        let sync = HistorySync(cloud: cloud)
        let result = try await sync.sync(ledger: nil, sharing: false, deviceName: nil, now: t0)
        XCTAssertTrue(result.talked)
        let deleted = await cloud.deleted
        XCTAssertEqual(deleted, [[name(-1), name(0)]])
        let again = try await sync.sync(ledger: nil, sharing: false, deviceName: nil, now: t0)
        XCTAssertFalse(again.talked, "nothing left to delete")
    }

    func testPublishingSendsChangedDaysAndDeletesOnesThatEmptied() async throws {
        let directory = try TempDirectory()
        let ledger = try ledger(directory)
        try await ledger.store.apply(usage("s1"))
        let cloud = FakeHistoryCloud()
        await cloud.set(days: [name(5): old])
        let sync = HistorySync(cloud: cloud)
        _ = try await sync.sync(ledger: ledger, sharing: true, deviceName: "Studio", now: t0)
        var published = await cloud.published
        XCTAssertEqual(published.map { $0.map(\.day) }, [[name(0)]])
        XCTAssertEqual(published.first?.first?.machine, "m-a", "every day carries this Mac's fingerprint")
        XCTAssertEqual(published.first?.first?.device, "mac-a")
        var deleted = await cloud.deleted
        XCTAssertEqual(deleted, [[name(5)]], "a day the ledger no longer has goes on the first scan")

        await cloud.set(days: [name(0): await cloud.days[name(0)]!, name(2): old])
        try await ledger.store.apply(LedgerBatch(sessions: [
            SessionUpdate(key: SessionKey(source: .claudeCode, id: "s1"), lastAt: t0.addingTimeInterval(2 * 86_400)),
        ]))
        _ = try await sync.sync(ledger: ledger, sharing: true, deviceName: "Studio",
                                now: t0.addingTimeInterval(RemoteHistoryPolicy.checkEvery))
        deleted = await cloud.deleted
        XCTAssertEqual(deleted.last, [name(2)], "a changed day with no usage left deletes its old record")
        published = await cloud.published
        XCTAssertEqual(published.count, 1, "an unchanged day is never uploaded again")
    }

    func testANewStoreRescansEveryDay() async throws {
        let directory = try TempDirectory()
        let first = try ledger(directory)
        try await first.store.apply(usage("s1"))
        let cloud = FakeHistoryCloud()
        let sync = HistorySync(cloud: cloud)
        _ = try await sync.sync(ledger: first, sharing: true, deviceName: nil, now: t0)
        var days = await cloud.days
        days[name(9)] = old
        await cloud.set(days: days)
        _ = try await sync.sync(ledger: first, sharing: true, deviceName: nil,
                                now: t0.addingTimeInterval(RemoteHistoryPolicy.checkEvery))
        var deleted = await cloud.deleted
        XCTAssertEqual(deleted, [], "the same Store with no changes scans nothing")

        let reopened = try ledger(directory)
        _ = try await sync.sync(ledger: reopened, sharing: true, deviceName: nil,
                                now: t0.addingTimeInterval(RemoteHistoryPolicy.checkEvery + 1))
        deleted = await cloud.deleted
        XCTAssertEqual(deleted, [[name(9)]], "a new Store looks at every day again")
        let published = await cloud.published
        XCTAssertEqual(published.count, 1, "and uploads only what changed")
    }

    func testAFetchFromTheStartKeepsNoTokenUntilItsLastPageThenDropsWhatIsGone() async throws {
        let directory = try TempDirectory()
        let ledger = try ledger(directory)
        try await ledger.store.applyRemoteHistory([remoteDay("mac-z")], device: "mac-a")
        let cloud = FakeHistoryCloud()
        let b = remoteDay("mac-b"), c = remoteDay("mac-c")
        await cloud.set(pages: [
            RemoteHistoryPage(days: [b], seen: [b.key], fromStart: true, more: true),
            RemoteHistoryPage(days: [c], seen: [c.key, RemoteHistoryPartKey(device: "mac-d", day: name(0), part: 0)]),
        ])
        let sync = HistorySync(cloud: cloud)
        let result = try await sync.sync(ledger: ledger, sharing: false, deviceName: nil, now: t0)
        XCTAssertTrue(result.applied)
        let acknowledged = await cloud.acknowledgedAfter
        XCTAssertEqual(acknowledged, [2], "the token is kept only after the last page")
        let devices = try await ledger.remoteDevices().map(\.id)
        XCTAssertEqual(devices, ["mac-b", "mac-c"], "a part the zone no longer has is dropped")

        await cloud.set(pages: [RemoteHistoryPage(days: [remoteDay("mac-e")], seen: [remoteDay("mac-e").key], more: true),
                                RemoteHistoryPage()])
        await sync.fetchSoon()
        _ = try await sync.sync(ledger: ledger, sharing: false, deviceName: nil, now: t0)
        let incremental = await cloud.acknowledgedAfter
        XCTAssertEqual(incremental, [2, 3, 4], "an incremental fetch keeps each page's token")
        let kept = try await ledger.remoteDevices().map(\.id)
        XCTAssertEqual(kept, ["mac-b", "mac-c", "mac-e"], "only a fetch from the start drops anything")
    }

    func testThisMacsOtherEditionIsIgnored() async throws {
        let ledger = try ledger(try TempDirectory())
        let cloud = FakeHistoryCloud()
        await cloud.set(pages: [RemoteHistoryPage(days: [remoteDay("mac-a-store", machine: "m-a")])])
        let result = try await HistorySync(cloud: cloud).sync(ledger: ledger, sharing: false, deviceName: nil, now: t0)
        XCTAssertFalse(result.applied)
        let calls = try await remoteCalls(ledger)
        XCTAssertEqual(calls, 0)
    }

    func testAFailingPublishNeverBlocksTheFetch() async throws {
        let ledger = try ledger(try TempDirectory())
        try await ledger.store.apply(usage("s1"))
        let cloud = FakeHistoryCloud()
        await cloud.set(publishError: .quotaExceeded)
        await cloud.set(pages: [RemoteHistoryPage(days: [remoteDay("mac-b")])])
        let sync = HistorySync(cloud: cloud)
        let result = try await sync.sync(ledger: ledger, sharing: true, deviceName: nil, now: t0)
        XCTAssertTrue(result.applied, "this Mac's full iCloud still lets other Macs' history in")
        let calls = try await remoteCalls(ledger)
        XCTAssertEqual(calls, 1)
        let publishRetry = await sync.publishRetry
        let fetchRetry = await sync.fetchRetry
        XCTAssertEqual(publishRetry.failures, 1)
        XCTAssertEqual(fetchRetry.failures, 0)
        XCTAssertEqual(result.wait, RemoteRetry.backoff(after: 1), accuracy: 1, "back for the upload once its wait ends")
    }

    func testErrorsBackOffAndOnlyAccountErrorsAreThrown() async throws {
        let ledger = try ledger(try TempDirectory())
        let cloud = FakeHistoryCloud()
        let sync = HistorySync(cloud: cloud)
        await cloud.set(fetchError: .network)
        let failed = try await sync.sync(ledger: ledger, sharing: false, deviceName: nil, now: t0)
        XCTAssertEqual(failed.wait, RemoteRetry.backoff(after: 1), accuracy: 1)
        _ = try await sync.sync(ledger: ledger, sharing: false, deviceName: nil, now: t0.addingTimeInterval(1))
        var fetches = await cloud.fetches
        XCTAssertEqual(fetches, 1, "no fetch while backing off")

        await cloud.set(fetchError: .limited(retryAfter: 120))
        let later = t0.addingTimeInterval(10)
        let limitedResult = try await sync.sync(ledger: ledger, sharing: false, deviceName: nil, now: later)
        let limited = await sync.fetchRetry
        XCTAssertEqual(limited.retryAt?.timeIntervalSince(later) ?? 0, 120, accuracy: 0.001, "retryAfter is honoured")
        XCTAssertEqual(limitedResult.wait, 120, accuracy: 0.001)

        await sync.reset()
        await cloud.set(fetchError: .noAccount)
        do {
            _ = try await sync.sync(ledger: ledger, sharing: false, deviceName: nil, now: t0.addingTimeInterval(20))
            XCTFail("a lost account must reach the link")
        } catch {
            XCTAssertEqual(error as? CloudLinkError, .noAccount)
        }
        await cloud.set(fetchError: nil)
        await sync.reset()
        _ = try await sync.sync(ledger: ledger, sharing: false, deviceName: nil, now: t0.addingTimeInterval(30))
        fetches = await cloud.fetches
        XCTAssertEqual(fetches, 4)
    }

    func testClearingReceivedHistoryStartsTheFetchOver() async throws {
        let ledger = try ledger(try TempDirectory())
        let cloud = FakeHistoryCloud()
        await cloud.set(pages: [RemoteHistoryPage(days: [remoteDay("mac-b")])])
        let sync = HistorySync(cloud: cloud)
        _ = try await sync.sync(ledger: ledger, sharing: false, deviceName: nil, now: t0)
        var calls = try await remoteCalls(ledger)
        XCTAssertEqual(calls, 1)
        try await sync.clearReceived(from: ledger)
        calls = try await remoteCalls(ledger)
        XCTAssertEqual(calls, 0)
        let restarts = await cloud.restarts
        XCTAssertEqual(restarts, 1, "the next link fetches every other Mac's history again")
    }
}
