import XCTest

@testable import LavaSecFilterPipeline

final class CatalogPresentationStateTests: XCTestCase {
    private typealias State = CatalogPresentationState

    func testMissingCatalogHasExplicitFreshnessState() {
        XCTAssertEqual(makeState(cacheAge: nil).freshness, .missing)
    }

    func testCatalogYoungerThanMaximumAgeIsFresh() {
        XCTAssertEqual(makeState(cacheAge: 59, maxAge: 60).freshness, .fresh)
    }

    func testCatalogAtExactMaximumAgeIsStale() {
        XCTAssertEqual(makeState(cacheAge: 60, maxAge: 60).freshness, .stale)
    }

    func testNegativeCatalogAgeIsStale() {
        XCTAssertEqual(makeState(cacheAge: -1).freshness, .stale)
    }

    func testErrorTakesPrecedenceOverCatalogAge() {
        XCTAssertEqual(makeState(cacheAge: nil, statusIsError: true).freshness, .error)
        XCTAssertEqual(makeState(cacheAge: 0, statusIsError: true).freshness, .error)
    }

    func testSyncStatePreservesEachCallerSuppliedPhase() {
        let phases: [State.Sync] = [.idle, .syncing, .succeeded, .failed]

        for phase in phases {
            XCTAssertEqual(makeState(sync: phase).sync, phase)
        }
    }

    func testRuleCountDistinguishesZeroOneAndMany() {
        XCTAssertEqual(makeState(ruleCount: 0).ruleCount, .zero)
        XCTAssertEqual(makeState(ruleCount: 1).ruleCount, .one)
        XCTAssertEqual(makeState(ruleCount: 2).ruleCount, .many(2))
        XCTAssertEqual(makeState(ruleCount: 12_345).ruleCount, .many(12_345))
    }

    func testAppMapsCatalogFactsThroughPureStateAndPreservesMissingCacheAcceptance() throws {
        let source = try readSource(.appViewModel)
        let stateBlock = try sourceBlock(
            in: source,
            startingAt: "private var catalogPresentationState: CatalogPresentationState",
            endingBefore: "var filterFreshnessText: String"
        )
        let freshnessBlock = try sourceBlock(
            in: source,
            startingAt: "var blocklistCatalogIsFresh: Bool",
            endingBefore: "var blocklistCatalogFreshnessTitle: String"
        )

        XCTAssertTrue(stateBlock.contains("CatalogPresentationState("))
        XCTAssertTrue(stateBlock.contains("cacheAge: blocklistCatalogAge"))
        XCTAssertTrue(stateBlock.contains("ruleCount: compiledRuleCount"))
        XCTAssertTrue(
            freshnessBlock.contains("case .missing, .fresh:"),
            "The pure value distinguishes missing data, but the app must preserve the shipped initial-window acceptance until a product change explicitly revisits it."
        )
        XCTAssertTrue(freshnessBlock.contains("case .stale, .error:"))
    }

    private func makeState(
        cacheAge: TimeInterval? = 0,
        maxAge: TimeInterval = 60,
        statusIsError: Bool = false,
        sync: State.Sync = .idle,
        ruleCount: Int = 0
    ) -> State {
        State(
            cacheAge: cacheAge,
            maxAge: maxAge,
            statusIsError: statusIsError,
            sync: sync,
            ruleCount: ruleCount
        )
    }
}
