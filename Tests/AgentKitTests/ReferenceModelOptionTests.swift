@testable import AgentKit
import XCTest

final class ReferenceModelOptionTests: XCTestCase {
    private let priced = ["claude-opus-5", "claude-sonnet-5-5"]

    func testASavedModelInTheListAddsNothing() {
        let options = ReferenceModelOption.options(priced: priced, saved: "claude-sonnet-5-5", savedHasPrice: true)
        XCTAssertEqual(options.map(\.id), priced)
        XCTAssertTrue(options.allSatisfy { !$0.isSavedButUnlisted && !$0.hasNoPrice })
    }

    func testASavedModelThatResolvesIsListedWithoutAWarning() {
        let table = PricingTable.bundled(referenceModel: "claude-sonnet-5-5-20260101",
                                         aliases: ["claude-nova-1": "claude-opus-5"])
        for saved in ["claude-sonnet-5-5-20260101", "claude-nova-1"] {
            let options = ReferenceModelOption.options(priced: table.pricedModelIDs, saved: saved,
                                                       savedHasPrice: table.hasPrice(for: saved))
            let last = options.last
            XCTAssertEqual(last?.id, saved)
            XCTAssertEqual(last?.isSavedButUnlisted, true)
            XCTAssertEqual(last?.hasNoPrice, false, saved)
            XCTAssertEqual(options.count, table.pricedModelIDs.count + 1)
        }
    }

    func testASavedModelWithNoPriceIsListedAndFlagged() {
        let table = PricingTable.bundled(referenceModel: "claude-sonet-5-5")
        let options = ReferenceModelOption.options(priced: priced, saved: table.referenceModel,
                                                   savedHasPrice: table.referenceModelHasPrice)
        XCTAssertEqual(options.map(\.id), priced + ["claude-sonet-5-5"])
        XCTAssertEqual(options.last, ReferenceModelOption(id: "claude-sonet-5-5", isSavedButUnlisted: true, hasNoPrice: true))
        XCTAssertEqual(options.filter(\.hasNoPrice).count, 1)
    }

    func testAnEmptyListAndAnEmptySavedValue() {
        XCTAssertEqual(ReferenceModelOption.options(priced: [], saved: "claude-x", savedHasPrice: false),
                       [ReferenceModelOption(id: "claude-x", isSavedButUnlisted: true, hasNoPrice: true)])
        XCTAssertEqual(ReferenceModelOption.options(priced: [], saved: "claude-x", savedHasPrice: true),
                       [ReferenceModelOption(id: "claude-x", isSavedButUnlisted: true, hasNoPrice: false)])
        XCTAssertEqual(ReferenceModelOption.options(priced: [], saved: "", savedHasPrice: false), [])
        XCTAssertEqual(ReferenceModelOption.options(priced: priced, saved: "", savedHasPrice: false).map(\.id), priced)
    }
}
