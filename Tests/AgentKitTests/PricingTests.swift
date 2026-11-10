@testable import AgentKit
import XCTest

final class PricingTests: XCTestCase {
    private let table = PricingTable.bundled()

    func testModelMatching() {
        XCTAssertEqual(table.match("claude-opus-5-5")?.id, "claude-opus-5-5")
        XCTAssertEqual(table.match("claude-haiku-4-5-20251001")?.id, "claude-haiku-4-5")
        XCTAssertEqual(table.match("claude-opus-4-6[1m]")?.id, "claude-opus-4-6")
        XCTAssertEqual(table.match("anthropic.claude-haiku-5-5")?.id, "claude-haiku-5-5")
        XCTAssertEqual(table.match("us.anthropic.claude-sonnet-4-6-20260101-v1:0")?.id, "claude-sonnet-4-6")
        XCTAssertEqual(table.match("claude-opus-4-7@20260301")?.id, "claude-opus-4-7")
        XCTAssertEqual(table.match("Claude-Sonnet-5-5")?.id, "claude-sonnet-5-5")
        XCTAssertEqual(table.match("claude-sonnet-5-5-thinking")?.id, "claude-sonnet-5-5", "longest prefix wins")
        XCTAssertNil(table.match("claude-opus-5-6"), "a newer minor version must not price as claude-opus-5")
        XCTAssertNil(table.match("claude-opus-4-5"))
        XCTAssertNil(table.match("gpt-5"))
    }

    func testClaudeCallPrice() {
        let tokens = TokenCounts(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                                 cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        let opus = table.price(model: "claude-opus-5-5", tokens: tokens, speed: "standard")
        // 4 + 20 + 0.20 + 5 + 8
        XCTAssertEqual(opus.costUSD ?? 0, 37.2, accuracy: 1e-9)
        XCTAssertEqual(opus.apiEquivUSD, opus.costUSD)
        XCTAssertFalse(opus.isLocal)

        let sonnet46 = table.price(model: "claude-sonnet-4-6", tokens: tokens, speed: nil)
        // 3 + 15 + 0.30 + 3.75 + 6
        XCTAssertEqual(sonnet46.costUSD ?? 0, 28.05, accuracy: 1e-9)
    }

    func testFastModeAndLongContextTiers() {
        let tokens = TokenCounts(input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(table.price(model: "claude-opus-5-5", tokens: tokens, speed: "fast").costUSD ?? 0, 48, accuracy: 1e-9)
        XCTAssertEqual(table.price(model: "claude-opus-5", tokens: tokens, speed: "fast").costUSD ?? 0, 60, accuracy: 1e-9)
        XCTAssertNil(table.price(model: "claude-sonnet-5-5", tokens: tokens, speed: "fast").costUSD,
                     "fast mode without a known fast price is unpriced, not standard")

        let short = TokenCounts(input: 50_000, output: 1_000, cacheRead: 50_000)
        let shortCost = table.price(model: "claude-haiku-5-5", tokens: short, speed: nil).costUSD ?? 0
        XCTAssertEqual(shortCost, (50_000 * 0.10 + 1_000 * 0.50 + 50_000 * 0.01) / 1e6, accuracy: 1e-12)

        let long = TokenCounts(input: 50_000, output: 1_000, cacheRead: 50_001)
        let longCost = table.price(model: "claude-haiku-5-5", tokens: long, speed: nil).costUSD ?? 0
        XCTAssertEqual(longCost, (50_000 * 0.50 + 1_000 * 2.50 + 50_001 * 0.05) / 1e6, accuracy: 1e-12)
    }

    func testUnknownModelIsUnpricedNotFree() {
        let priced = table.price(model: "claude-opus-4-5-20251101", tokens: TokenCounts(input: 10, output: 10), speed: nil)
        XCTAssertNil(priced.costUSD)
        XCTAssertNil(priced.apiEquivUSD)
        XCTAssertNil(table.price(model: nil, tokens: TokenCounts(input: 10), speed: nil).costUSD)
    }

    func testLocalModelsAreFreeWithApiEquivalentAtTheReference() {
        let tokens = TokenCounts(input: 1_000_000, output: 1_000_000)
        let local = table.price(model: "Qwen3.8-Flash-Next", tokens: tokens, speed: nil)
        XCTAssertTrue(local.isLocal)
        XCTAssertEqual(local.costUSD, 0)
        XCTAssertEqual(local.apiEquivUSD ?? 0, 12, accuracy: 1e-9, "claude-sonnet-5-5: 2 + 10")

        let custom = PricingTable.bundled(localModelPatterns: ["llama", " "], referenceModel: "claude-opus-5-5")
        XCTAssertFalse(custom.isLocal("Qwen3.8-Flash-Next"))
        XCTAssertTrue(custom.isLocal("Meta-Llama-4"))
        XCTAssertEqual(custom.price(model: "meta-llama-4", tokens: tokens, speed: nil).apiEquivUSD ?? 0, 24, accuracy: 1e-9)
    }

    func testOverridesAndRevision() throws {
        let json = #"{"models":{"claude-opus-4-5":{"input":5,"output":25},"claude-opus-5-5":{"input":3,"output":15},"broken":{"input":"x"}}}"#
        let overrides = try PricingTable.Document.decode(Data(json.utf8))
        XCTAssertEqual(overrides.models.count, 2, "a malformed entry drops only itself")
        let merged = PricingTable.bundled(overrides: overrides)
        XCTAssertNotNil(merged.match("claude-opus-4-5"))
        XCTAssertEqual(merged.match("claude-opus-5-5")?.price.input, 3)
        XCTAssertEqual(merged.match("claude-opus-5-5")?.price.cacheRead, nil, "an override replaces the whole entry")

        XCTAssertEqual(PricingTable.bundled().revision, table.revision, "the revision is a stable content hash")
        XCTAssertNotEqual(merged.revision, table.revision)
        XCTAssertNotEqual(PricingTable.bundled(referenceModel: "claude-opus-5").revision, table.revision)
        XCTAssertNotEqual(PricingTable.bundled(localModelPatterns: ["qwen", "llama"]).revision, table.revision)
        XCTAssertEqual(PricingTable.bundled(localModelPatterns: ["QWEN"]).revision, table.revision)
        XCTAssertEqual(try PricingTable.Document.decode(Data("{}".utf8)).models.count, 0)
    }

    func testPriceAsAliasPricesAnUnknownModelAndChangesTheRevision() {
        let tokens = TokenCounts(input: 1_000_000, output: 100_000)
        let plain = PricingTable.bundled()
        XCTAssertNil(plain.price(model: "claude-opus-4-5-20251101", tokens: tokens, speed: nil).costUSD)

        let aliased = PricingTable.bundled(aliases: [" Claude-Opus-4-5 ": "claude-opus-4-6", "gpt-x": "no-such-model",
                                                     "claude-sonnet-5": "claude-sonnet-5", "": "claude-opus-5"])
        XCTAssertEqual(aliased.aliases, ["claude-opus-4-5": "claude-opus-4-6", "gpt-x": "no-such-model"])
        XCTAssertEqual(aliased.match("claude-opus-4-5-20251101")?.id, "claude-opus-4-6", "found by the normalized id")
        XCTAssertEqual(aliased.price(model: "claude-opus-4-5-20251101", tokens: tokens, speed: nil).costUSD ?? 0, 7.5,
                       accuracy: 1e-9)
        XCTAssertNil(aliased.price(model: "gpt-x", tokens: tokens, speed: nil).costUSD, "an alias to nothing stays unpriced")
        XCTAssertEqual(aliased.price(model: "claude-sonnet-5", tokens: tokens, speed: nil),
                       plain.price(model: "claude-sonnet-5", tokens: tokens, speed: nil))

        XCTAssertNotEqual(aliased.revision, plain.revision)
        XCTAssertEqual(PricingTable.bundled(aliases: [:]).revision, plain.revision)
        XCTAssertEqual(PricingTable.bundled(aliases: ["claude-opus-4-5": "claude-opus-4-6", "gpt-x": "no-such-model"]).revision,
                       aliased.revision)
        XCTAssertTrue(plain.pricedModelIDs.contains("claude-opus-4-6"))
        XCTAssertEqual(plain.pricedModelIDs, plain.pricedModelIDs.sorted())
    }

    func testBundledTableDecodes() {
        XCTAssertEqual(BundledPricing.document.models.count, 14)
        XCTAssertEqual(BundledPricing.document.webSearchPerThousand, 10)
    }

    /// A real session (Opus main thread with 1h cache writes plus a Haiku subagent with 5m writes), stripped to
    /// usage. Summing the ledger price of its deduped calls must land within 2% of Claude Code's own total.
    func testCostStateCalibration() throws {
        let lines = JSONLines.complete(in: try Fixture.data("claude_calibration.jsonl")).lines
        let batch = ClaudeTranscriptParser.batch(from: lines)
        let state = try XCTUnwrap(batch.sessions.values.first?.costState)
        XCTAssertLessThan(batch.usage.count, lines.count - 1, "repeated content blocks are deduped")
        XCTAssertTrue(batch.usage.contains { $0.isSidechain && $0.model == "claude-haiku-5-5" })

        var total = 0.0
        for record in batch.usage {
            total += try XCTUnwrap(table.price(model: record.model, tokens: record.tokens, speed: record.speed).costUSD)
        }
        XCTAssertEqual(total, state.totalCostUSD, accuracy: state.totalCostUSD * 0.02)

        var opus = 0.0
        for record in batch.usage where record.model == "claude-opus-5-5" {
            opus += table.price(model: record.model, tokens: record.tokens, speed: record.speed).costUSD ?? 0
        }
        let reportedOpus = try XCTUnwrap(state.models["claude-opus-5-5"]?.costUSD)
        XCTAssertEqual(opus, reportedOpus, accuracy: reportedOpus * 0.02)

        XCTAssertEqual(PricingCalibration.check(state, table: table).filter(\.isOff), [])
    }

    func testCalibrationAccountsForWebSearchAndUnknownCacheSplit() throws {
        // Real cost-state shapes: Haiku with web searches ($10 per 1,000), and an older Opus entry with
        // no 5m/1h split that Claude Code billed at the 1 hour rate.
        let line = #"{"type":"cost-state","sessionId":"s","totalCostUSD":0.272562,"modelUsage":{"claude-haiku-5-5":{"inputTokens":1194,"outputTokens":252,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"webSearchRequests":2,"costUSD":0.0202454},"claude-opus-5-5":{"inputTokens":510,"outputTokens":1944,"cacheReadInputTokens":157865,"cacheCreationInputTokens":22041,"webSearchRequests":0,"costUSD":0.248821},"Qwen3.8-Flash-Next":{"inputTokens":9,"outputTokens":9,"costUSD":0.0035}},"hasUnknownModelCost":true}"#
        guard case .costState(let state)? = ClaudeTranscriptParser.item(from: Data(line.utf8)) else {
            return XCTFail("expected a cost-state")
        }
        let rows = PricingCalibration.check(state, table: table)
        XCTAssertEqual(rows.map(\.model), ["claude-haiku-5-5", "claude-opus-5-5"], "local models are not calibrated")
        XCTAssertEqual(rows.filter(\.isOff), [])

        var wrong = state
        wrong.models["claude-opus-5-5"]?.costUSD = 0.5
        XCTAssertEqual(PricingCalibration.check(wrong, table: table).filter(\.isOff).map(\.model), ["claude-opus-5-5"])
    }
}

final class ModelNameTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(ModelName.display("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelName.display("claude-opus-5"), "Opus 5")
        XCTAssertEqual(ModelName.display("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelName.display("anthropic.claude-sonnet-4-6"), "Sonnet 4.6")
        XCTAssertEqual(ModelName.display("us.anthropic.claude-sonnet-5-5[1m]"), "Sonnet 5.5")
        XCTAssertEqual(ModelName.display("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(ModelName.display("Qwen3.8-Flash-Next"), "Qwen3.8-Flash-Next")
        XCTAssertEqual(ModelName.display("openrouter/qwen3-coder"), "qwen3-coder")
        XCTAssertEqual(ModelName.display(""), "Unknown model")
    }

    func testFamilies() {
        XCTAssertEqual(ModelName.family("claude-opus-5-5"), .opus)
        XCTAssertEqual(ModelName.family("claude-haiku-5-5"), .haiku)
        XCTAssertEqual(ModelName.family("Qwen3.8-Flash-Next"), .other)
        XCTAssertEqual(ModelName.family("Qwen3.8-Flash-Next", isLocal: true), .local)
        XCTAssertEqual(ModelName.family("claude-nova-1"), .other)
    }
}
