import AgentKit
import AgentSystem
import Foundation
import XCTest

final class RemoteHistoryStoreTests: XCTestCase {
    private typealias Day = RemoteHistoryDay
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let allTime = DateInterval(start: .distantPast, end: .distantFuture)
    private let resolver = ProjectResolver(home: "/Users/dev")
    private let mine = "mac-a"
    private let air = "mac-b"
    private var day0: Int { RemoteHistoryCalendar.day(of: t0) }
    private var dayName: String { RemoteHistoryCalendar.name(of: day0) }

    private func open(_ directory: TempDirectory, pricing: PricingTable = .bundled()) throws -> (Store, StoreReader) {
        let path = directory.path("hoply.sqlite")
        return (try Store(path: path, pricing: pricing, resolver: resolver), try StoreReader(path: path))
    }

    private func local(_ id: String, cwd: String?, calls: Int = 1, at offset: TimeInterval = 0,
                       model: String = "claude-opus-5-5", tokens: TokenCounts = TokenCounts(input: 10, output: 100),
                       speed: String? = nil, title: String? = nil) -> LedgerBatch {
        let usage = (0..<calls).map { index in
            UsageRecord(dedupeKey: "k:\(id):\(offset):\(index)", source: .claudeCode, sessionID: id,
                        timestamp: t0.addingTimeInterval(offset + Double(index)), model: model, tokens: tokens,
                        speed: speed, cwd: cwd)
        }
        return LedgerBatch(usage: usage, sessions: [
            SessionUpdate(key: SessionKey(source: .claudeCode, id: id), firstAt: t0.addingTimeInterval(offset),
                          lastAt: t0.addingTimeInterval(offset + 60), cwd: cwd, placeIsAuthoritative: cwd != nil,
                          title: title, titleRank: title == nil ? 0 : 1),
        ])
    }

    private func slice(model: String? = "claude-opus-5-5", calls: Int = 1, at offset: TimeInterval = 0,
                       tokens: TokenCounts = TokenCounts(input: 10, output: 100), prompt: Int = 10,
                       nativeUSD: Double? = nil, project: String? = nil) -> Day.Usage {
        Day.Usage(model: model, project: project, at: t0.addingTimeInterval(offset),
                  last: t0.addingTimeInterval(offset + 30), prompt: prompt, tokens: tokens, calls: calls,
                  nativeUSD: nativeUSD)
    }

    private func remote(_ device: String? = nil, name: String? = "Air", part: Int = 0, parts: Int = 1,
                        at offset: TimeInterval = 0, sessions: [Day.Session], projects: [Day.Project]) -> Day {
        Day(device: device ?? air, deviceName: name, day: dayName, part: part, parts: parts,
            updatedAt: t0.addingTimeInterval(3_600 + offset), projects: projects, sessions: sessions)
    }

    private func session(_ id: String, project: String? = "p1", title: String? = "x",
                         usage: [Day.Usage]) -> Day.Session {
        Day.Session(key: "claude-code:\(id)", agent: "claude-code", project: project, title: title,
                    start: usage.first?.at ?? t0, end: usage.last?.last ?? t0, usage: usage)
    }

    private func project(_ id: String, _ name: String, origin: String? = nil, kind: Day.ProjectKind = .folder) -> Day.Project {
        Day.Project(id: id, name: name, origin: origin, kind: kind)
    }

    private func callsByProject(_ reader: StoreReader, scope: MacScope = .all) async throws -> [String: Int] {
        var result: [String: Int] = [:]
        for summary in try await reader.projects(in: allTime, scope: scope) {
            result[summary.project?.name ?? "unassigned"] = summary.totals.calls
        }
        return result
    }

    private func projectID(_ store: Store, _ cwd: String) async throws -> Int64 {
        let found = try await store.projects(forCwds: [cwd])[cwd]
        return try XCTUnwrap(found).id
    }

    private func requireRemoteProject(_ reader: StoreReader, _ id: String) async throws -> ProjectRef {
        let found = try await remoteProject(reader, id)
        return try XCTUnwrap(found)
    }

    private func remoteProject(_ reader: StoreReader, _ id: String) async throws -> ProjectRef? {
        try await reader.session(SessionKey(source: .claudeCode, id: id), device: air)?.project
    }

    // MARK: - Merging

    func testOtherMacsRowsStayOutOfThisMacsLedger() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(local("s1", cwd: "/Users/dev/hoply", calls: 2))
        let before = try await reader.overview(scope: .thisMac)
        let day = remote(sessions: [session("r1", usage: [slice(calls: 3), slice(model: "claude-sonnet-5-5", at: 3_600)])],
                         projects: [project("p1", "hoply")])
        let applied = try await store.applyRemoteHistory([day], device: mine)
        XCTAssertTrue(applied)

        let thisMac = try await reader.overview(scope: .thisMac)
        XCTAssertEqual(thisMac, before, "this Mac's totals never include another Mac")
        let unscoped = try await reader.overview()
        XCTAssertEqual(unscoped, before, "existing callers keep showing this Mac")
        let all = try await reader.overview(scope: .all)
        XCTAssertEqual(all.allTime.calls, 6, "a remote row stands for its calls")
        let device = try await reader.overview(scope: .device(air))
        XCTAssertEqual(device.allTime.calls, 4)
        let nobody = try await reader.overview(scope: .device("mac-c"))
        XCTAssertEqual(nobody.allTime, .zero)
        XCTAssertEqual(all.allTime.costUSD, before.allTime.costUSD + device.allTime.costUSD, accuracy: 1e-9)

        let thisMacSessions = try await reader.sessions(in: allTime)
        XCTAssertEqual(thisMacSessions.sessions.map(\.key.id), ["s1"])
        let page = try await reader.sessions(in: allTime, scope: .all)
        XCTAssertEqual(page.totalCount, 2)
        let remoteSession = try XCTUnwrap(page.sessions.first { $0.isRemote })
        XCTAssertEqual(remoteSession.device, air)
        XCTAssertEqual(remoteSession.deviceName, "Air")
        XCTAssertEqual(remoteSession.id, "mac-b/claude-code:r1")
        XCTAssertEqual(remoteSession.turns, 0)
        XCTAssertNil(remoteSession.cwd)
        XCTAssertEqual(remoteSession.totals.calls, 4)
        XCTAssertEqual(remoteSession.models.map(\.model).sorted(), ["claude-opus-5-5", "claude-sonnet-5-5"])
        XCTAssertEqual(remoteSession.project?.name, "hoply", "matched to this Mac's project by folder name")
        XCTAssertEqual(remoteSession.project, page.sessions.first { !$0.isRemote }?.project)
        let onlyAir = try await reader.sessions(in: allTime, scope: .device(air))
        XCTAssertEqual(onlyAir.sessions.map(\.id), ["mac-b/claude-code:r1"])
        let single = try await reader.session(SessionKey(source: .claudeCode, id: "r1"), device: air)
        XCTAssertEqual(single?.totals, remoteSession.totals)
        XCTAssertEqual(single?.deviceName, "Air")
        let missing = try await reader.session(SessionKey(source: .claudeCode, id: "r1"))
        XCTAssertNil(missing, "this Mac has no such session")

        let devices = try await reader.remoteDevices()
        XCTAssertEqual(devices, [RemoteDevice(id: air, name: "Air", updatedAt: t0.addingTimeInterval(3_600))])
        let projects = try await reader.projects(in: allTime, scope: .all)
        XCTAssertEqual(projects.map(\.sessionCount), [2])
        XCTAssertEqual(projects.first?.bySource[.claudeCode]?.calls, 6)
        let models = try await reader.spendByModel(in: allTime, scope: .all)
        XCTAssertEqual(models.first { $0.id == "claude-opus-5-5" }?.totals.calls, 5)
        XCTAssertEqual(models.first { $0.id == "claude-opus-5-5" }?.sessionCount, 2)
        let bySource = try await reader.totalsBySource(in: allTime, scope: .device(air))
        XCTAssertEqual(bySource[.claudeCode]?.calls, 4)
        let daily = try await reader.dailySpend(days: 3, split: .source, now: t0, calendar: utc, scope: .all)
        XCTAssertEqual(daily.points.reduce(0) { $0 + $1.totals.calls }, 6)
        let dailyHere = try await reader.dailySpend(days: 3, split: .source, now: t0, calendar: utc)
        XCTAssertEqual(dailyHere.points.reduce(0) { $0 + $1.totals.calls }, 2)
        let spend = try await reader.spendByProject(in: allTime, scope: .device(air))
        XCTAssertEqual(spend.map(\.sessionCount), [1])

        let own = try await store.applyRemoteHistory([remote(mine, sessions: [session("x", usage: [slice()])],
                                                             projects: [])], device: mine)
        XCTAssertFalse(own, "a record from this Mac itself is ignored")
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    func testANewerSummaryReplacesTheDeviceDayAndADeletionRemovesIt() async throws {
        let (store, reader) = try open(try TempDirectory())
        let projects = [project("p1", "hoply")]
        try await store.applyRemoteHistory([remote(sessions: [session("r1", usage: [slice(calls: 4)])],
                                                   projects: projects)], device: mine)
        try await store.applyRemoteHistory([remote(name: "Air 2", at: 60,
                                                   sessions: [session("r1", usage: [slice(calls: 6)])],
                                                   projects: projects)], device: mine)
        var calls = try await reader.overview(scope: .all).allTime.calls
        XCTAssertEqual(calls, 6, "replaced, never added")
        let older = try await store.applyRemoteHistory([remote(at: 30, sessions: [session("r1", usage: [slice(calls: 9)])],
                                                               projects: projects)], device: mine)
        XCTAssertFalse(older)
        calls = try await reader.overview(scope: .all).allTime.calls
        XCTAssertEqual(calls, 6)
        var devices = try await reader.remoteDevices()
        XCTAssertEqual(devices.map(\.name), ["Air 2"], "the newest name is remembered")

        let split = [
            remote(part: 0, parts: 2, at: 120, sessions: [session("r1", usage: [slice(calls: 2)])], projects: projects),
            remote(part: 1, parts: 2, at: 120, sessions: [session("r2", usage: [slice(calls: 3)])], projects: projects),
        ]
        try await store.applyRemoteHistory(split, device: mine)
        calls = try await reader.overview(scope: .all).allTime.calls
        XCTAssertEqual(calls, 5)
        try await store.applyRemoteHistory([remote(at: 180, sessions: [session("r1", usage: [slice(calls: 1)])],
                                                   projects: projects)], device: mine)
        calls = try await reader.overview(scope: .all).allTime.calls
        XCTAssertEqual(calls, 1, "a day that shrank to one part drops its old second part")
        let sessionCount = try await reader.sessions(in: allTime, scope: .all).totalCount
        XCTAssertEqual(sessionCount, 1)

        let key = RemoteHistoryPartKey(device: air, day: dayName, part: 0)
        let removed = try await store.applyRemoteHistory([], deleted: [key], device: mine)
        XCTAssertTrue(removed)
        calls = try await reader.overview(scope: .all).allTime.calls
        XCTAssertEqual(calls, 0)
        devices = try await reader.remoteDevices()
        XCTAssertEqual(devices, [], "a Mac with nothing left leaves the filter")

        try await store.applyRemoteHistory([remote(at: 240, sessions: [session("r1", usage: [slice()])],
                                                   projects: projects)], device: mine)
        let kept = try await store.dropRemoteHistory(keeping: [key])
        XCTAssertFalse(kept)
        let dropped = try await store.dropRemoteHistory(keeping: [])
        XCTAssertTrue(dropped, "after a fetch from the start, parts the zone no longer has go")
        calls = try await reader.overview(scope: .all).allTime.calls
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Pricing

    func testRemoteRowsArePricedHereAndRepricedWithThisMacsTable() async throws {
        let directory = try TempDirectory()
        let (store, reader) = try open(directory)
        let tokens = TokenCounts(input: 1_000, output: 2_000, cacheRead: 3_000)
        let big = TokenCounts(input: 400_000, output: 1_000)
        try await store.applyRemoteHistory([remote(sessions: [
            session("known", usage: [slice(tokens: tokens)]),
            session("mystery", usage: [slice(model: "mystery-model", tokens: tokens)]),
            session("native", usage: [slice(model: "gpt-5.5", tokens: tokens, nativeUSD: 0.25)]),
            session("qwen", usage: [slice(model: "qwen3-coder", tokens: tokens)]),
            session("tier", usage: [slice(model: "gpt-5.5", calls: 4, tokens: big, prompt: 100_000)]),
        ], projects: [project("p1", "hoply")])], device: mine)
        let pricing = await store.pricing
        func cost(_ id: String) async throws -> LedgerTotals? {
            try await reader.session(SessionKey(source: .claudeCode, id: id), device: air)?.totals
        }
        let known = try await cost("known")
        XCTAssertEqual(known?.costUSD ?? 0, pricing.price(model: "claude-opus-5-5", tokens: tokens, speed: nil).costUSD ?? -1,
                       accuracy: 1e-12)
        XCTAssertEqual(known?.hasUnpriced, false)
        let mystery = try await cost("mystery")
        XCTAssertEqual(mystery?.hasUnpriced, true, "an unknown model stays unpriced, never $0")
        XCTAssertEqual(mystery?.costUSD, 0)
        let native = try await cost("native")
        XCTAssertEqual(native?.costUSD, 0.25, "a native cost is kept")
        let qwen = try await cost("qwen")
        XCTAssertEqual(qwen?.costUSD, 0, "a local model costs nothing here too")
        XCTAssertEqual(qwen?.hasUnpriced, false)
        XCTAssertGreaterThan(qwen?.apiEquivUSD ?? 0, 0)
        let tier = try await cost("tier")
        XCTAssertEqual(tier?.costUSD ?? 0, (400_000 * 5 + 1_000 * 30) / 1_000_000, accuracy: 1e-9,
                       "four calls of 100k are not one call of 400k")

        let aliased = PricingTable.bundled(aliases: ["mystery-model": "claude-opus-5-5"])
        let repriced = try await store.setPricing(aliased)
        XCTAssertGreaterThan(repriced, 0)
        let priced = try await cost("mystery")
        XCTAssertEqual(priced?.hasUnpriced, false)
        XCTAssertEqual(priced?.costUSD ?? 0, known?.costUSD ?? -1, accuracy: 1e-12)
        let stillNative = try await cost("native")
        XCTAssertEqual(stillNative?.costUSD, 0.25)
        let unpriced = try await reader.unpricedModels()
        XCTAssertEqual(unpriced, [], "the unpriced list is this Mac's own")

        let (_, reopened) = try open(directory, pricing: .bundled())
        let back = try await reopened.session(SessionKey(source: .claudeCode, id: "mystery"), device: air)
        XCTAssertEqual(back?.totals.hasUnpriced, true, "opening with the old table re-prices again")
    }

    // MARK: - Projects

    func testProjectsMatchAcrossMacsByOriginThenFolderName() async throws {
        let directory = try TempDirectory()
        try directory.write("code/hoply/.git/config", "[remote \"origin\"]\n\turl = git@github.com:org/hoply.git\n")
        try directory.mkdir("code/hoply/src")
        let (store, reader) = try open(directory)
        try await store.apply(local("s1", cwd: directory.path("code/hoply/src")))
        let origin = try XCTUnwrap(GitRemote.originHash("https://github.com/org/hoply"))
        try await store.applyRemoteHistory([remote(sessions: [
            session("r1", project: "p1", usage: [slice()]),
            session("r2", project: "p2", usage: [slice()]),
            session("r3", project: nil, usage: [slice()]),
        ], projects: [project("p1", "hoply-elsewhere", origin: origin, kind: .repo), project("p2", "site")])],
                                           device: mine)
        let localProject = try await reader.session(SessionKey(source: .claudeCode, id: "s1"))?.project
        let r1 = try await remoteProject(reader, "r1")
        XCTAssertEqual(r1, localProject, "the same origin is the same project, whatever the folder is called")
        let found = try await remoteProject(reader, "r2")
        let r2 = try XCTUnwrap(found)
        XCTAssertTrue(r2.isRemoteOnly)
        XCTAssertEqual(r2.title, "site")
        let r3 = try await remoteProject(reader, "r3")
        XCTAssertNil(r3)
        let calls = try await callsByProject(reader)
        XCTAssertEqual(calls, ["hoply": 2, "site": 1, "unassigned": 1])
        let here = try await callsByProject(reader, scope: .thisMac)
        XCTAssertEqual(here, ["hoply": 1])

        try await store.apply(local("s2", cwd: "/Users/dev/site"))
        try await store.applyRemoteHistory([remote(at: 60, sessions: [session("r2", project: "p2", usage: [slice()])],
                                                   projects: [project("p2", "site")])], device: mine)
        let moved = try await remoteProject(reader, "r2")
        XCTAssertEqual(moved?.root, "/Users/dev/site", "once this Mac has the folder, the other Mac's sessions join it")
    }

    func testManualEditsOnAnotherMacsProjectsWinOverReSync() async throws {
        let directory = try TempDirectory()
        var (store, reader) = try open(directory)
        try await store.apply(local("w1", cwd: "/Users/dev/web"))
        try await store.apply(local("h1", cwd: "/Users/dev/hoply"))
        let refs = try await store.projects(forCwds: ["/Users/dev/web", "/Users/dev/hoply"])
        let web = try XCTUnwrap(refs["/Users/dev/web"]).id
        let hoply = try XCTUnwrap(refs["/Users/dev/hoply"]).id
        let projects = [project("p2", "site"), project("p1", "hoply")]
        func sync(_ offset: TimeInterval) async throws {
            try await store.applyRemoteHistory([remote(at: offset, sessions: [
                session("r1", project: "p2", usage: [slice()]),
                session("r2", project: "p1", usage: [slice()]),
            ], projects: projects)], device: mine)
        }
        try await sync(0)
        let first = try await remoteProject(reader, "r1")
        let site = try XCTUnwrap(first)
        XCTAssertTrue(site.isRemoteOnly)

        try await store.mergeProject(site.id, into: web)
        var r1 = try await remoteProject(reader, "r1")
        XCTAssertEqual(r1?.id, web)
        try await sync(60)
        r1 = try await remoteProject(reader, "r1")
        XCTAssertEqual(r1?.id, web, "a merge stands after a re-sync")
        let merged = try await reader.mergedProjects()
        XCTAssertEqual(merged.map(\.project.id), [site.id])

        let key = SessionKey(source: .claudeCode, id: "r2")
        try await store.assign(session: key, device: air, toProject: web)
        var r2 = try await remoteProject(reader, "r2")
        XCTAssertEqual(r2?.id, web)
        try await sync(120)
        (store, reader) = try open(directory)
        try await store.resetCursors(source: .claudeCode)
        try await sync(180)
        r2 = try await remoteProject(reader, "r2")
        XCTAssertEqual(r2?.id, web, "a session move stands after a re-sync, a relaunch and Reindex")
        let assignments = try await reader.sessionAssignments()
        XCTAssertEqual(assignments.map(\.id), ["mac-b/claude-code:r2"])
        XCTAssertEqual(assignments.first?.device, air)

        try await store.unassign(session: key, device: air)
        r2 = try await remoteProject(reader, "r2")
        XCTAssertEqual(r2?.id, hoply, "undo puts it back on the matched project")
        try await store.mergeProject(hoply, into: web)
        r2 = try await remoteProject(reader, "r2")
        XCTAssertEqual(r2?.id, web, "merging this Mac's project takes the other Mac's sessions along")
        try await store.unmergeProject(hoply)
        try await store.unmergeProject(site.id)
        r2 = try await remoteProject(reader, "r2")
        r1 = try await remoteProject(reader, "r1")
        XCTAssertEqual(r2?.id, hoply)
        XCTAssertEqual(r1?.id, site.id)
        let calls = try await callsByProject(reader)
        XCTAssertEqual(calls, ["web": 1, "hoply": 2, "site": 1])

        await XCTAssertThrowsEditError(.unknownSession) {
            try await store.assign(session: SessionKey(source: .claudeCode, id: "nope"), device: air, toProject: web)
        }
    }

    func testOneMacIsNeverCountedTwice() async throws {
        let (store, reader) = try open(try TempDirectory())
        func day(_ device: String, name: String, machine: String?, at offset: TimeInterval, calls: Int) -> Day {
            let id = device.hasPrefix("air") ? "air-s" : "\(device)-s"
            var day = remote(device, name: name, at: offset,
                             sessions: [session(id, usage: [slice(calls: calls, at: offset)])],
                             projects: [project("p1", "hoply")])
            day.machine = machine
            return day
        }
        let own = try await store.applyRemoteHistory([day("mac-a-store", name: "Mine", machine: "m-a", at: 0, calls: 9)],
                                                     device: mine, machine: "m-a")
        XCTAssertFalse(own, "this Mac's other edition is this Mac, already counted here")
        try await store.applyRemoteHistory([day("air-direct", name: "Air", machine: "m-b", at: 0, calls: 2),
                                            day("air-store", name: "Air", machine: "m-b", at: 60, calls: 3),
                                            day("studio", name: "Studio", machine: "m-c", at: 0, calls: 4)],
                                           device: mine, machine: "m-a")
        var calls = try await reader.overview(scope: .all).allTime.calls
        XCTAssertEqual(calls, 7, "two editions of one Mac carry the same sessions: the copy used last counts")
        var devices = try await reader.remoteDevices()
        XCTAssertEqual(devices.map(\.id), ["air-store", "studio"])
        let sessions = try await reader.sessions(in: allTime, scope: .all)
        XCTAssertEqual(sessions.sessions.compactMap(\.device).sorted(), ["air-store", "studio"])
        let superseded = try await reader.overview(scope: .device("air-direct"))
        XCTAssertEqual(superseded.allTime.calls, 0)

        try await store.applyRemoteHistory([day("air-direct", name: "Air", machine: "m-b", at: 120, calls: 5)],
                                           device: mine, machine: "m-a")
        calls = try await reader.overview(scope: .all).allTime.calls
        XCTAssertEqual(calls, 9, "switching back to the other edition switches which one counts")
        devices = try await reader.remoteDevices()
        XCTAssertEqual(devices.map(\.id), ["air-direct", "studio"])
    }

    func testAMigratedMacCountsTheOldMacsHistoryOnce() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(local("copied", cwd: "/Users/dev/hoply", calls: 2))
        try await store.apply(local("new-here", cwd: "/Users/dev/hoply", at: 3_600))
        let here = try await reader.overview(scope: .thisMac)
        try await store.applyRemoteHistory([remote("old-mac", name: "Old", sessions: [
            session("copied", usage: [slice(calls: 2)]),
        ], projects: [project("p1", "hoply")])], device: mine)
        var all = try await reader.overview(scope: .all)
        XCTAssertEqual(all, here, "the old Mac's records of sessions this ledger copied add nothing")
        var devices = try await reader.remoteDevices()
        XCTAssertEqual(devices, [], "a Mac that adds nothing is not in the filter")
        let page = try await reader.sessions(in: allTime, scope: .all)
        XCTAssertEqual(page.totalCount, 2)
        XCTAssertTrue(page.sessions.allSatisfy { !$0.isRemote })
        let device = try await reader.overview(scope: .device("old-mac"))
        XCTAssertEqual(device.allTime, .zero)

        try await store.applyRemoteHistory([remote("old-mac", name: "Old", at: 60, sessions: [
            session("copied", usage: [slice(calls: 2)]), session("kept-using-it", usage: [slice(calls: 5)]),
        ], projects: [project("p1", "hoply")])], device: mine)
        all = try await reader.overview(scope: .all)
        XCTAssertEqual(all.allTime.calls, here.allTime.calls + 5, "the old Mac still in use adds only its new sessions")
        devices = try await reader.remoteDevices()
        XCTAssertEqual(devices.map(\.id), ["old-mac"])
        let models = try await reader.spendByModel(in: allTime, scope: .all)
        XCTAssertEqual(models.reduce(0) { $0 + $1.totals.calls }, all.allTime.calls)
        let projects = try await reader.projects(in: allTime, scope: .all)
        XCTAssertEqual(projects.map(\.sessionCount), [3])
    }

    func testASessionResumedOnTheOldMacAddsOnlyItsNewCalls() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(local("copied", cwd: "/Users/dev/hoply", calls: 2))
        let here = try await reader.overview(scope: .thisMac)
        try await store.applyRemoteHistory([remote("old-mac", name: "Old", sessions: [
            session("copied", usage: [slice(calls: 2), slice(calls: 3, at: 7_200)]),
        ], projects: [project("p1", "hoply")])], device: mine)
        let thisMac = try await reader.overview(scope: .thisMac)
        XCTAssertEqual(thisMac, here, "this Mac's own rows stay its authority")
        let all = try await reader.overview(scope: .all)
        XCTAssertEqual(all.allTime.calls, 5, "the calls after this Mac's last one were made on the old Mac")
        let old = try await reader.overview(scope: .device("old-mac"))
        XCTAssertEqual(thisMac.allTime.calls + old.allTime.calls, all.allTime.calls)
        let page = try await reader.sessions(in: allTime, scope: .all)
        XCTAssertEqual(page.sessions.map(\.id).sorted(), ["claude-code:copied", "old-mac/claude-code:copied"])
        XCTAssertEqual(page.sessions.first { $0.isRemote }?.totals.calls, 3)
        let devices = try await reader.remoteDevices()
        XCTAssertEqual(devices.map(\.id), ["old-mac"])

        try await store.apply(local("copied", cwd: "/Users/dev/hoply", at: 9_000))
        let later = try await reader.overview(scope: .all)
        XCTAssertEqual(later.allTime.calls, 3, "resumed here later: this Mac's copy covers it again")
    }

    func testTwoMacsCarryingOneSessionCountItOnce() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.applyRemoteHistory([
            remote("mac-x", name: "X", sessions: [session("shared", usage: [slice(calls: 2)]),
                                                 session("only-x", usage: [slice(calls: 1)])],
                   projects: [project("p1", "hoply")]),
            remote("mac-y", name: "Y", at: 60, sessions: [session("shared", usage: [slice(calls: 2)])],
                   projects: [project("p1", "hoply")]),
        ], device: mine)
        let all = try await reader.overview(scope: .all)
        XCTAssertEqual(all.allTime.calls, 3)
        let page = try await reader.sessions(in: allTime, scope: .all)
        XCTAssertEqual(page.totalCount, 2)
        XCTAssertEqual(page.sessions.first { $0.key.id == "shared" }?.device, "mac-y", "the more recently updated Mac's copy")
        let x = try await reader.overview(scope: .device("mac-x"))
        let y = try await reader.overview(scope: .device("mac-y"))
        XCTAssertEqual(x.allTime.calls + y.allTime.calls, all.allTime.calls, "the Macs add up to All Macs")
        let byDevice = try await reader.sessions(in: allTime, scope: .device("mac-x"))
        XCTAssertEqual(byDevice.sessions.map(\.key.id), ["only-x"])
        let daily = try await reader.dailySpend(days: 3, split: .model, now: t0, calendar: utc, scope: .all)
        XCTAssertEqual(daily.points.reduce(0) { $0 + $1.totals.calls }, 3)
        let projects = try await reader.projects(in: allTime, scope: .all)
        XCTAssertEqual(projects.map(\.sessionCount), [2])
    }

    func testANewOrDepartingMacNeverSplitsAMerge() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(local("w1", cwd: "/Users/dev/web"))
        let web = try await projectID(store, "/Users/dev/web")
        func day(_ device: String, at offset: TimeInterval = 0, origin: String? = "abc", name: String = "hoply") -> Day {
            remote(device, name: device, at: offset, sessions: [session("\(device)-s", project: "x", usage: [slice()])],
                   projects: [project("x", name, origin: origin, kind: .repo)])
        }
        func target(_ device: String) async throws -> Int64? {
            try await reader.session(SessionKey(source: .claudeCode, id: "\(device)-s"), device: device)?.project?.id
        }
        try await store.applyRemoteHistory([day("mac-c"), day("mac-d", name: "hoply-copy")], device: mine)
        let first = try await target("mac-c")
        let collapsed = try XCTUnwrap(first)
        let d = try await target("mac-d")
        XCTAssertEqual(d, collapsed)
        try await store.mergeProject(collapsed, into: web)

        try await store.applyRemoteHistory([day("mac-b")], device: mine)
        for device in ["mac-b", "mac-c", "mac-d"] {
            let found = try await target(device)
            XCTAssertEqual(found, web, "\(device): a Mac sorting first joins the merge instead of splitting it")
        }
        var merged = try await reader.mergedProjects()
        XCTAssertEqual(merged.map(\.project.id), [collapsed])

        try await store.applyRemoteHistory([], deleted: [RemoteHistoryPartKey(device: "mac-c", day: dayName, part: 0)],
                                           device: mine)
        let afterC = try await target("mac-d")
        XCTAssertEqual(afterC, web, "the Mac whose copy was merged leaves; the others stay merged")
        for device in ["mac-b", "mac-d"] {
            try await store.applyRemoteHistory([], deleted: [RemoteHistoryPartKey(device: device, day: dayName, part: 0)],
                                               device: mine)
        }
        merged = try await reader.mergedProjects()
        XCTAssertEqual(merged, [], "an emptied merge leaves no empty entry behind")
        let list = try await reader.projectList()
        XCTAssertEqual(list.map(\.id), [web])

        try await store.applyRemoteHistory([day("mac-e", name: "renamed")], device: mine)
        let later = try await target("mac-e")
        XCTAssertEqual(later, web, "a later copy of that project still lands where the user merged it")
        try await store.applyRemoteHistory([day("mac-f", origin: "zzz")], device: mine)
        let other = try await target("mac-f")
        XCTAssertNotEqual(other, web, "a repo with another origin doesn't")
    }

    func testOneMacsTwoSameNamedProjectsStayApart() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.applyRemoteHistory([remote(sessions: [
            session("work", project: "w", usage: [slice()]), session("play", project: "p", usage: [slice()]),
        ], projects: [project("w", "app", origin: "abc", kind: .repo), project("p", "app")])], device: mine)
        var work = try await remoteProject(reader, "work")
        var play = try await remoteProject(reader, "play")
        XCTAssertNotEqual(work?.id, play?.id, "that Mac keeps them apart, so this one does")
        try await store.applyRemoteHistory([remote("mac-c", name: "C", sessions: [
            session("c-app", project: "c", usage: [slice()]),
        ], projects: [project("c", "app", origin: "abc", kind: .repo)])], device: mine)
        work = try await remoteProject(reader, "work")
        play = try await remoteProject(reader, "play")
        let c = try await reader.session(SessionKey(source: .claudeCode, id: "c-app"), device: "mac-c")?.project
        XCTAssertEqual(c?.id, work?.id, "the same origin on a third Mac joins the repo")
        XCTAssertNotEqual(play?.id, work?.id, "and still not the plain folder")
    }

    func testTwoClonesOfOneRepoOnAnotherMacBothJoinThisMacsProject() async throws {
        let directory = try TempDirectory()
        try directory.write("code/hoply/.git/config", "[remote \"origin\"]\n\turl = git@github.com:org/hoply.git\n")
        let (store, reader) = try open(directory)
        try await store.apply(local("s1", cwd: directory.path("code/hoply")))
        let mine = try await projectID(store, directory.path("code/hoply"))
        let origin = try XCTUnwrap(GitRemote.originHash("https://github.com/org/hoply"))
        try await store.applyRemoteHistory([remote(sessions: [
            session("a", project: "c1", usage: [slice()]), session("b", project: "c2", usage: [slice()]),
            session("c", project: "f", usage: [slice()]),
        ], projects: [project("c1", "hoply", origin: origin, kind: .repo),
                      project("c2", "hoply-2", origin: origin, kind: .repo), project("f", "hoply")])],
                                           device: self.mine)
        let a = try await remoteProject(reader, "a")
        let b = try await remoteProject(reader, "b")
        let c = try await remoteProject(reader, "c")
        XCTAssertEqual(a?.id, mine)
        XCTAssertEqual(b?.id, mine, "the same origin is the same project, however many clones that Mac has")
        XCTAssertNotEqual(c?.id, mine, "a plain folder of that Mac never joins by name what that Mac keeps apart")
    }

    func testThreeMacsShareOneProjectThisMacDoesNotHave() async throws {
        let (store, reader) = try open(try TempDirectory())
        func day(_ device: String, _ name: String, origin: String?) -> Day {
            remote(device, name: device, sessions: [session("\(device)-s", project: "x-\(device)", usage: [slice()])],
                   projects: [project("x-\(device)", name, origin: origin, kind: .repo)])
        }
        try await store.applyRemoteHistory([day("mac-c", "hoply", origin: "abc")], device: mine)
        try await store.applyRemoteHistory([day("mac-b", "hoply-clone", origin: "abc"), day("mac-d", "hoply", origin: nil),
                                            day("mac-e", "hoply", origin: "zzz")], device: mine)
        let projects = try await reader.projects(in: allTime, scope: .all)
        let counts = Dictionary(projects.map { ($0.project?.root ?? "", $0.sessionCount) }, uniquingKeysWith: +)
        XCTAssertEqual(counts.count, 2, "one project for the shared origin, one for the different origin")
        let shared = try XCTUnwrap(projects.first { $0.sessionCount == 3 }?.project)
        XCTAssertTrue(shared.isRemoteOnly)
        XCTAssertEqual(shared.root, ProjectRef.remoteRootPrefix + "mac-b/x-mac-b", "the first device's copy wins")
        let list = try await reader.projectList()
        XCTAssertEqual(list.filter(\.isRemoteOnly).count, 2, "the collapsed copies leave no empty projects behind")
    }

    func testLeftoversGoAndRenamesArrive() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.applyRemoteHistory([remote(sessions: [session("r1", project: "p2", usage: [slice()])],
                                                   projects: [project("p2", "site")])], device: mine)
        var site = try await remoteProject(reader, "r1")
        XCTAssertEqual(site?.name, "site")
        var renamed = project("p2", "website")
        renamed.title = "Web site"
        try await store.applyRemoteHistory([remote(at: 60, sessions: [session("r1", project: "p2", usage: [slice()])],
                                                   projects: [renamed])], device: mine)
        site = try await remoteProject(reader, "r1")
        XCTAssertEqual(site?.title, "Web site", "a rename on the other Mac arrives here")
        XCTAssertEqual(site?.name, "website")
        var list = try await reader.projectList()
        XCTAssertEqual(list.map(\.name), ["website"])

        try await store.applyRemoteHistory([], deleted: [RemoteHistoryPartKey(device: air, day: dayName, part: 0)],
                                           device: mine)
        list = try await reader.projectList()
        XCTAssertEqual(list, [], "a remote-only project with nothing left in it goes")
        let devices = try await reader.remoteDevices()
        XCTAssertEqual(devices, [])
    }

    func testThisMacsNewProjectPicksUpAnIdleMacsSessions() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.applyRemoteHistory([remote(sessions: [session("r1", project: "p2", usage: [slice()])],
                                                   projects: [project("p2", "site")])], device: mine)
        let before = try await remoteProject(reader, "r1")
        XCTAssertEqual(before?.isRemoteOnly, true)
        try await store.apply(local("s1", cwd: "/Users/dev/site"))
        let after = try await remoteProject(reader, "r1")
        XCTAssertEqual(after?.root, "/Users/dev/site", "no new summary needed: this Mac's own ingest re-matches")
        let list = try await reader.projectList()
        XCTAssertEqual(list.map(\.root), ["/Users/dev/site"])
    }

    func testARemoteOnlyProjectNeverHoldsThisMacsSessions() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(local("s1", cwd: "/Users/dev/web"))
        let web = try await projectID(store, "/Users/dev/web")
        try await store.applyRemoteHistory([remote(sessions: [session("r1", project: "p2", usage: [slice()]),
                                                              session("r2", project: "p3", usage: [slice()])],
                                                   projects: [project("p2", "site"), project("p3", "docs")])],
                                           device: mine)
        let site = try await requireRemoteProject(reader, "r1")
        let docs = try await requireRemoteProject(reader, "r2")
        XCTAssertFalse(site.acceptsLocalSessions)
        let local = SessionKey(source: .claudeCode, id: "s1")
        for attempt in [{ try await store.mergeProject(web, into: site.id) },
                        { try await store.assign(session: local, toProject: site.id) },
                        { try await store.assign(path: "/Users/dev/other", toProject: site.id) }] as [() async throws -> Set<SessionKey>] {
            do {
                _ = try await attempt()
                XCTFail("a remote-only project took this Mac's sessions")
            } catch {
                XCTAssertEqual(error as? RemoteProjectEditError, .localIntoRemoteOnly)
            }
        }
        let unchanged = try await reader.session(local)?.project?.id
        XCTAssertEqual(unchanged, web)
        try await store.mergeProject(docs.id, into: site.id)
        let r2 = try await remoteProject(reader, "r2")
        XCTAssertEqual(r2?.id, site.id, "another Mac's projects may still merge into one")
        try await store.assign(session: SessionKey(source: .claudeCode, id: "r1"), device: air, toProject: web)
        try await store.mergeProject(site.id, into: web)
        let both = try await callsByProject(reader)
        XCTAssertEqual(both, ["web": 3])
    }

    func testTurningTheLinkOffClearsWhatOtherMacsSent() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(local("s1", cwd: "/Users/dev/web"))
        let web = try await projectID(store, "/Users/dev/web")
        try await store.applyRemoteHistory([remote(sessions: [session("r1", project: "p2", usage: [slice()]),
                                                              session("r2", project: "p1", usage: [slice()])],
                                                   projects: [project("p2", "site"), project("p1", "web")])],
                                           device: mine)
        let site = try await requireRemoteProject(reader, "r1")
        try await store.mergeProject(site.id, into: web)
        try await store.assign(session: SessionKey(source: .claudeCode, id: "r2"), device: air, toProject: web)
        let before = try await reader.overview(scope: .thisMac)

        let cleared = try await store.clearRemoteHistory()
        XCTAssertTrue(cleared)
        let all = try await reader.overview(scope: .all)
        XCTAssertEqual(all, before)
        let devices = try await reader.remoteDevices()
        XCTAssertEqual(devices, [])
        let list = try await reader.projectList()
        XCTAssertEqual(list.map(\.id), [web], "remote-only projects go, this Mac's stay")
        let merged = try await reader.mergedProjects()
        XCTAssertEqual(merged, [])
        let assignments = try await reader.sessionAssignments()
        XCTAssertEqual(assignments, [])
        let again = try await store.clearRemoteHistory()
        XCTAssertFalse(again)
    }

    // MARK: - Publishing

    func testADayToPublishHoldsThisMacsUsageOnly() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(local("s1", cwd: "/Users/dev/hoply", calls: 2, title: "x"))
        try await store.apply(local("s1", cwd: "/Users/dev/hoply", at: 3_600))
        try await store.apply(local("s1", cwd: "/Users/dev/hoply", at: 3_700, model: "gpt-5.5",
                                    tokens: TokenCounts(input: 300_000, output: 10)))
        try await store.apply(local("s1", cwd: "/Users/dev/hoply", at: 3_800, model: "gpt-5.5",
                                    tokens: TokenCounts(input: 1_000, output: 10)))
        try await store.apply(local("s1", cwd: "/Users/dev/hoply", at: 3_900, speed: "fast"))
        try await store.apply(local("y1", cwd: "/Users/dev/hoply", at: -86_400))
        try await store.applyRemoteHistory([remote(sessions: [session("r1", usage: [slice()])],
                                                   projects: [project("p1", "hoply")])], device: mine)

        let days = try await reader.ledgerDays()
        XCTAssertEqual(days, [day0 - 1, day0])
        let thresholds = await store.pricing.contextThresholds
        let day = try await reader.localHistoryDay(day0, contextThresholds: thresholds)
        XCTAssertEqual(day.sessions.map(\.key), ["claude-code:s1"], "another Mac's sessions are never sent back")
        let usage = try XCTUnwrap(day.sessions.first?.usage)
        XCTAssertEqual(usage.map(\.calls).reduce(0, +), 6)
        XCTAssertEqual(usage.count, 5, "split by hour, model, speed and price tier")
        XCTAssertEqual(usage.first { $0.model == "claude-opus-5-5" && $0.speed == nil && $0.calls == 2 }?.at, t0)
        XCTAssertEqual(usage.filter { $0.model == "gpt-5.5" }.map(\.prompt).sorted(), [1_000, 300_000])
        XCTAssertEqual(day.sessions.first?.title, "x")
        XCTAssertEqual(day.projects.map(\.project.id), [Day.Project.id(root: "/Users/dev/hoply")])
        XCTAssertEqual(day.projects.first?.project.name, "hoply")

        let parts = Day.build(device: mine, deviceName: nil, day: day0, sessions: day.sessions,
                              projects: day.projects.map(\.project), updatedAt: t0)
        let text = String(decoding: try RemoteSchema.encode(parts), as: UTF8.self)
        XCTAssertFalse(text.contains("/Users/"), "never a path or cwd")
        let empty = try await reader.localHistoryDay(day0 + 5)
        XCTAssertEqual(empty.sessions, [])
    }

    func testTheStoreTracksWhichDaysChanged() async throws {
        let (store, _) = try open(try TempDirectory())
        var changes = await store.takeHistoryChanges()
        XCTAssertEqual(changes, .all, "a new Store checks every day once")
        changes = await store.takeHistoryChanges()
        XCTAssertEqual(changes, .none)
        try await store.apply(local("s1", cwd: "/Users/dev/hoply", at: 86_400 * 3))
        changes = await store.takeHistoryChanges()
        XCTAssertEqual(changes, .days([day0 + 3]))
        try await store.apply(local("s1", cwd: nil, at: 86_400 * 4, title: "x"))
        changes = await store.takeHistoryChanges()
        XCTAssertEqual(changes, .days([day0 + 3, day0 + 4]), "a new title touches every day of the session")
        try await store.applyRemoteHistory([remote(sessions: [session("r1", usage: [slice()])], projects: [])],
                                           device: mine)
        changes = await store.takeHistoryChanges()
        XCTAssertEqual(changes, .none, "other Macs' rows never change what this Mac publishes")
        let refs = try await store.projects(forCwds: ["/Users/dev/hoply"])
        let id = try XCTUnwrap(refs["/Users/dev/hoply"]).id
        try await store.assign(path: "/Users/dev/other", toProject: id)
        changes = await store.takeHistoryChanges()
        XCTAssertEqual(changes, .all, "a project edit can touch any day")
    }

    func testHistorySyncNeverReachesCloudKitWithoutTheEntitlement() async throws {
        let directory = try TempDirectory()
        let url = directory.url.appendingPathComponent("Hoply/icloud-link.json")
        let cloud = CloudLink(stateURL: url)
        let sync = HistorySync(cloud: cloud)
        let idle = try await sync.sync(ledger: nil, sharing: false, deviceName: nil, now: t0)
        XCTAssertFalse(idle.talked, "nothing published, nothing to delete")
        XCTAssertEqual(idle.wait, RemoteHistoryPolicy.checkEvery, "no ledger yet: no reason to come back soon")
        let ledger = try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                                   claudeConfigDirectory: directory.path("claude"),
                                                                   copilotHome: directory.path("copilot"),
                                                                   pricingOverridesURL: nil, watchForChanges: false))
        try await ledger.store.apply(local("s1", cwd: "/Users/dev/hoply"))
        for sharing in [true, false] {
            do {
                _ = try await sync.sync(ledger: ledger, sharing: sharing, deviceName: nil, now: t0)
                XCTFail("reached CloudKit")
            } catch {
                XCTAssertEqual(error as? CloudLinkError, .unavailable)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

private func XCTAssertThrowsEditError(_ expected: ProjectEditError, _ body: () async throws -> Void,
                                      file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await body()
        XCTFail("no error", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? ProjectEditError, expected, file: file, line: line)
    }
}
