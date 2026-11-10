import AgentKit
import AgentSystem
import Foundation
import XCTest

final class SessionInsightStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_000)
    private let cwd = "/Users/dev/Project/demo"
    private let resolver = ProjectResolver(home: "/Users/dev")
    private let key = SessionKey(source: .claudeCode, id: "s1")
    private var range: DateInterval { DateInterval(start: t0.addingTimeInterval(-10), end: t0.addingTimeInterval(86_400)) }

    private func open(_ directory: TempDirectory, pricing: PricingTable = .bundled()) throws -> (Store, StoreReader) {
        let path = directory.path("hoply.sqlite")
        return (try Store(path: path, pricing: pricing, resolver: resolver), try StoreReader(path: path))
    }

    private func call(_ id: String, session: String = "s1", source: AgentSource = .claudeCode, at seconds: TimeInterval,
                      model: String? = "claude-opus-5-5", agent: String? = nil, tokens: TokenCounts, speed: String? = nil,
                      cwd: String? = nil) -> UsageRecord {
        UsageRecord(dedupeKey: id, source: source, sessionID: session, timestamp: t0.addingTimeInterval(seconds),
                    model: model, isSidechain: agent != nil, agentID: agent, tokens: tokens, speed: speed,
                    cwd: cwd ?? self.cwd)
    }

    func testLastMainCallSkipsSubagentsAndAdvisorRows() async throws {
        let (store, reader) = try open(try TempDirectory())
        let main = TokenCounts(input: 20, output: 500, cacheRead: 150_000, cacheWrite5m: 1_000, cacheWrite1h: 9_000)
        try await store.apply(LedgerBatch(usage: [
            call("cc:m1:r1", at: 0, tokens: TokenCounts(input: 10, output: 5, cacheRead: 40_000)),
            call("cc:m2:r2", at: 60, model: "claude-opus-4-6", tokens: main),
            call("cc:m2:r2:advisor:1", at: 60, model: "claude-fable-5", tokens: TokenCounts(input: 900, output: 90)),
            call("cc:m3:r3", at: 90, agent: "a1", tokens: TokenCounts(input: 5, output: 5, cacheRead: 700_000)),
            call("cc:o1:r1", session: "s2", at: 30, model: "qwen3-coder", tokens: TokenCounts(input: 3_000, output: 10)),
            call("cc:o2:r2", session: "s3", at: 30, agent: "b1", tokens: TokenCounts(input: 1, output: 1)),
        ]))
        let (s2, s3) = (SessionKey(source: .claudeCode, id: "s2"), SessionKey(source: .claudeCode, id: "s3"))
        let calls = try await reader.lastMainCalls(for: [key, s2, s3, SessionKey(source: .copilotCLI, id: "s1")])
        XCTAssertEqual(calls.count, 2, "a session with only subagent calls has no main call")
        XCTAssertEqual(calls[key], SessionLastCall(key: key, model: "claude-opus-4-6", timestamp: t0.addingTimeInterval(60),
                                                   tokens: main))
        XCTAssertEqual(calls[s2]?.model, "qwen3-coder")

        let window = try XCTUnwrap(calls[key].flatMap { ContextWindow(lastCall: $0) })
        XCTAssertEqual(window.used, 160_020)
        XCTAssertEqual(window.limit, 200_000)
        XCTAssertTrue(window.isWarning)
        XCTAssertNil(calls[s2].flatMap { ContextWindow(lastCall: $0) }, "a local model's window is unknown")
    }

    func testSubagentsWithNamesModelDurationAndCost() async throws {
        let (store, reader) = try open(try TempDirectory())
        let small = TokenCounts(input: 1_000, output: 1_000)
        try await store.apply(LedgerBatch(
            usage: [
                call("cc:m1:r1", at: 0, tokens: small),
                call("cc:a1:1", at: 10, model: "claude-haiku-4-5", agent: "a1", tokens: small),
                call("cc:a1:2", at: 70, model: "claude-opus-5-5", agent: "a1", tokens: small),
                call("cc:a1:3", at: 130, model: "claude-haiku-4-5", agent: "a1", tokens: small),
                call("cc:a2:1", at: 40, model: "mystery-model", agent: "a2", tokens: small),
                call("cc:x1:1", session: "s2", at: 5, agent: "a9", tokens: small),
            ],
            subagents: [SubagentInfo(session: key, agentID: "a1", agentType: "Explore", description: "Find the parser"),
                        SubagentInfo(session: key, agentID: "never-called", agentType: "Plan")]))
        try await store.apply(LedgerBatch(subagents: [SubagentInfo(session: key, agentID: "a1", agentType: nil,
                                                                   description: nil)]))

        let subagents = try await reader.subagents(of: key)
        XCTAssertEqual(subagents.map(\.agentID), ["a1", "a2"])
        let first = try XCTUnwrap(subagents.first)
        XCTAssertEqual(first.name, "Explore")
        XCTAssertEqual(first.description, "Find the parser", "a later batch without names keeps them")
        XCTAssertEqual(first.model, "claude-opus-5-5", "the model with the largest spend")
        XCTAssertEqual(first.firstAt, t0.addingTimeInterval(10))
        XCTAssertEqual(first.duration, 120)
        XCTAssertEqual(first.totals.calls, 3)
        XCTAssertEqual(first.totals.apiEquivUSD, (0.004 + 0.02) + 2 * (0.001 + 0.005), accuracy: 1e-9)
        XCTAssertEqual(subagents[1].name, "Subagent")
        XCTAssertEqual(subagents[1].model, "mystery-model")
        XCTAssertTrue(subagents[1].totals.hasUnpriced)

        let s2 = SessionKey(source: .claudeCode, id: "s2")
        let counts = try await reader.subagentCounts(for: [key, s2, SessionKey(source: .claudeCode, id: "none")])
        XCTAssertEqual(counts, [key: 2, s2: 1])
        let none = try await reader.subagents(of: SessionKey(source: .claudeCode, id: "none"))
        XCTAssertEqual(none, [])
    }

    func testIngestReadsSubagentMetaNextToTheTranscript() async throws {
        let directory = try TempDirectory()
        let session = "22222222-2222-4222-8222-222222222222"
        let folder = "claude/projects/-Users-dev-Project-demo/\(session)/subagents"
        func assistant(_ id: String, agent: String) -> String {
            #"{"parentUuid":null,"isSidechain":true,"agentId":"\#(agent)","message":{"model":"claude-opus-5-5","id":"\#(id)","type":"message","role":"assistant","content":[],"usage":{"input_tokens":2,"output_tokens":10}},"requestId":"req_\#(id)","type":"assistant","timestamp":"2026-11-09T10:00:05.000Z","cwd":"/Users/dev/Project/demo","sessionId":"\#(session)"}"# + "\n"
        }
        try directory.write("\(folder)/agent-a1.jsonl", assistant("m1", agent: "a1"))
        try directory.write("\(folder)/agent-a1.meta.json",
                            #"{"agentType":"swift-core-dev","isBuiltIn":false,"description":"Build the core","spawnDepth":1}"#)
        try directory.write("\(folder)/agent-a2.jsonl", assistant("m2", agent: "a2"))
        try directory.write("\(folder)/agent-a3.jsonl", assistant("m3", agent: "a3"))
        try directory.write("\(folder)/agent-a3.meta.json", "not json")

        let ledger = try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                                   claudeConfigDirectory: directory.path("claude"),
                                                                   copilotHome: directory.path("copilot"),
                                                                   pricingOverridesURL: nil, watchForChanges: false))
        await ledger.ingest.start()
        let progress = await ledger.ingest.progress
        XCTAssertNil(progress.lastError)
        XCTAssertEqual(progress.filesTotal, 3, "meta files are not transcripts")

        let subagents = try await ledger.subagents(of: SessionKey(source: .claudeCode, id: session))
        XCTAssertEqual(subagents.map(\.agentID), ["a1", "a2", "a3"])
        XCTAssertEqual(subagents.map(\.agentType), ["swift-core-dev", nil, nil])
        XCTAssertEqual(subagents.first?.description, "Build the core")

        try directory.write("\(folder)/agent-a2.meta.json", #"{"agentType":"Explore"}"#)
        await ledger.ingest.reindex()
        let renamed = try await ledger.subagents(of: SessionKey(source: .claudeCode, id: session))
        XCTAssertEqual(renamed.map(\.agentType), ["swift-core-dev", "Explore", nil], "Reindex picks up names")
        XCTAssertEqual(renamed.map(\.totals.calls), [1, 1, 1])
    }

    func testModelEfficiency() async throws {
        let (store, reader) = try open(try TempDirectory())
        let cached = TokenCounts(input: 1_000, output: 2_000, cacheRead: 8_000, cacheWrite5m: 500, cacheWrite1h: 500)
        let fast = TokenCounts(input: 100_000, output: 10_000)
        try await store.apply(LedgerBatch(usage: [
            call("cc:1", at: 0, tokens: cached, speed: "standard"),
            call("cc:2", at: 10, tokens: fast, speed: "fast"),
            call("cc:3", at: 20, model: "claude-opus-4-6", tokens: fast, speed: "fast"),
            call("cc:4", at: 30, model: "mystery-model", tokens: cached),
            call("cc:5", at: 40, model: "qwen3-coder", tokens: TokenCounts(input: 500, output: 500)),
            call("cc:6", session: "s9", at: 50, tokens: cached, cwd: "/Users/dev/Project/other"),
            call("cc:7", at: -100, tokens: cached),
        ]))
        let pricing = await store.pricing
        let all = try await reader.modelEfficiency(in: range, pricing: pricing)
        XCTAssertEqual(all.map(\.model), ["claude-opus-5-5", "qwen3-coder", "claude-opus-4-6", "mystery-model"])

        let opus = try XCTUnwrap(all.first)
        XCTAssertEqual(opus.totals.calls, 3)
        XCTAssertEqual(opus.fastCalls, 1)
        XCTAssertEqual(opus.fastUSD, 0.8 + 0.4, accuracy: 1e-9)
        XCTAssertEqual(opus.fastPremiumUSD, 0.6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(opus.cacheHitRate), 16_000.0 / 120_000.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(opus.usdPerMillionTokens),
                       opus.totals.apiEquivUSD / Double(opus.totals.tokens.total) * 1_000_000, accuracy: 1e-9)

        let old = try XCTUnwrap(all.first { $0.model == "claude-opus-4-6" })
        XCTAssertEqual(old.fastCalls, 1)
        XCTAssertTrue(old.totals.hasUnpriced, "no fast price known: unpriced, so no premium either")
        XCTAssertEqual(old.fastPremiumUSD, 0)
        XCTAssertNil(old.usdPerMillionTokens)
        XCTAssertNil(all.last?.usdPerMillionTokens)
        XCTAssertEqual(try XCTUnwrap(all.last?.cacheHitRate), 0.8, accuracy: 1e-9)
        let local = try XCTUnwrap(all.first { $0.model == "qwen3-coder" })
        XCTAssertEqual(local.cacheHitRate, 0)
        XCTAssertGreaterThan(try XCTUnwrap(local.usdPerMillionTokens), 0, "at the reference model's API price")

        let projects = try await store.projects(forCwds: [cwd])
        let demo = try XCTUnwrap(projects[cwd])
        let scoped = try await reader.modelEfficiency(in: range, project: .project(demo.id), pricing: pricing)
        XCTAssertEqual(scoped.first?.totals.calls, 2)
        XCTAssertEqual(scoped.first?.fastCalls, 1)

        XCTAssertNil(ModelEfficiency(model: "x").cacheHitRate)
        XCTAssertNil(ModelEfficiency(model: "x").usdPerMillionTokens)
    }

    func testPriceAsAliasRepricesTheUnpricedModelsRows() async throws {
        let directory = try TempDirectory()
        let ledger = try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                                   claudeConfigDirectory: directory.path("claude"),
                                                                   copilotHome: directory.path("copilot"),
                                                                   pricingOverridesURL: nil, watchForChanges: false))
        let tokens = TokenCounts(input: 1_000_000, output: 100_000)
        try await ledger.store.apply(LedgerBatch(usage: [
            call("cc:1", at: 0, model: "claude-opus-4-5-20251101", tokens: tokens),
            call("cc:2", at: 10, model: "claude-opus-4-5-20251101", tokens: tokens),
            call("cc:3", at: 20, model: "claude-sonnet-4-5", tokens: tokens),
            call("cc:4", at: 30, tokens: tokens),
            call("cc:5", at: 40, model: "qwen3-coder", tokens: tokens),
            UsageRecord(dedupeKey: "cp:1", source: .copilotCLI, sessionID: "c1", timestamp: t0, model: "gpt-9",
                        tokens: tokens, nativeCost: 3, nativeUSD: 0.03),
        ]))
        var unpriced = try await ledger.unpricedModels()
        XCTAssertEqual(unpriced.map(\.model), ["claude-opus-4-5-20251101", "claude-sonnet-4-5"])
        XCTAssertEqual(unpriced.first?.calls, 2)
        XCTAssertEqual(unpriced.first?.tokens.input, 2_000_000)
        XCTAssertEqual(unpriced.first?.lastSeen, t0.addingTimeInterval(10))
        var totals = try await ledger.reader.sessionTotals(for: [key])[key]
        XCTAssertEqual(totals?.hasUnpriced, true)
        let before = try XCTUnwrap(totals?.apiEquivUSD)
        let priced = await ledger.pricedModels()
        XCTAssertTrue(priced.contains("claude-opus-4-6"))

        let changed = try await ledger.updatePricing(localModelPatterns: ["qwen"],
                                                     referenceModel: PricingTable.defaultReferenceModel,
                                                     priceAliases: ["claude-opus-4-5": "claude-opus-4-6"])
        XCTAssertEqual(changed, 5, "every row not priced natively moves to the new revision")
        unpriced = try await ledger.unpricedModels()
        XCTAssertEqual(unpriced.map(\.model), ["claude-sonnet-4-5"])
        totals = try await ledger.reader.sessionTotals(for: [key])[key]
        XCTAssertEqual(try XCTUnwrap(totals?.apiEquivUSD), before + 2 * 7.5, accuracy: 1e-9)

        let kept = try await ledger.updatePricing(localModelPatterns: ["qwen"],
                                                  referenceModel: PricingTable.defaultReferenceModel)
        XCTAssertEqual(kept, 0, "without new aliases the ones in use stay")
        let removed = try await ledger.updatePricing(localModelPatterns: ["qwen"],
                                                     referenceModel: PricingTable.defaultReferenceModel, priceAliases: [:])
        XCTAssertEqual(removed, 5)
        unpriced = try await ledger.unpricedModels()
        XCTAssertEqual(unpriced.count, 2)

        var settings = AppSettings()
        settings.priceAliases = ["claude-sonnet-4-5": "claude-sonnet-4-6"]
        XCTAssertEqual(LedgerConfiguration(settings: settings).priceAliases, settings.priceAliases)
    }
}
