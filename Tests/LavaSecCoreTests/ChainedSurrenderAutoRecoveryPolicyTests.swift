import XCTest

@testable import LavaSecKit

final class ChainedSurrenderAutoRecoveryPolicyTests: XCTestCase {
    private typealias Policy = ChainedSurrenderAutoRecoveryPolicy

    func testAnEmptyWindowAllowsRecoveryAndRecordsTheAttempt() {
        let now = 1_000_000.0
        let decision = Policy.evaluate(recentEpochs: [], nowEpoch: now)
        XCTAssertTrue(decision.mayRecover, "the first recovery from a fresh window must be allowed")
        XCTAssertEqual(
            decision.prunedWindow, [now],
            "the attempt must be recorded, or the next recovery is not counted toward the bound")
    }

    func testTheWindowExhaustsAtTheCapThenStops() {
        let now = 1_000_000.0
        let belowCap = Array(repeating: now - 10, count: Policy.maxRecoveriesPerWindow - 1)
        XCTAssertTrue(
            Policy.evaluate(recentEpochs: belowCap, nowEpoch: now).mayRecover,
            "one recovery below the cap must still be allowed")

        let atCap = Array(repeating: now - 10, count: Policy.maxRecoveriesPerWindow)
        let decision = Policy.evaluate(recentEpochs: atCap, nowEpoch: now)
        XCTAssertFalse(
            decision.mayRecover,
            "at the cap the recovery must be refused — a dead chain on a flapping path has to "
                + "converge to DNS-only, not loop recover→surrender→recover")
        XCTAssertEqual(
            decision.prunedWindow.count, Policy.maxRecoveriesPerWindow,
            "a refused evaluation prunes but does not append a new attempt")
    }

    func testEpochsOlderThanTheWindowDoNotCountTowardTheCap() {
        let now = 1_000_000.0
        // A full cap of recoveries, but all OUTSIDE the window: they prune away, so legitimate
        // roaming that recovers windows apart is never permanently blocked.
        let old = Array(
            repeating: now - Policy.windowSeconds - 1, count: Policy.maxRecoveriesPerWindow)
        let decision = Policy.evaluate(recentEpochs: old, nowEpoch: now)
        XCTAssertTrue(
            decision.mayRecover, "recoveries older than the window must not permanently block")
        XCTAssertEqual(
            decision.prunedWindow, [now], "the stale entries pruned; only the fresh attempt remains")
    }

    func testAFutureEpochCountsTowardTheCapSoAClockRollbackCannotManufactureBudget() {
        let now = 1_000_000.0
        // A backwards wall-clock jump leaves earlier recoveries in the "future". They must COUNT
        // toward the cap (conservative), not prune — pruning would restore the budget on every
        // rollback and permit extra restart cycles for a flapping dead chain.
        let mixed = [now + 5_000] + Array(repeating: now - 10, count: Policy.maxRecoveriesPerWindow - 1)
        XCTAssertFalse(
            Policy.evaluate(recentEpochs: mixed, nowEpoch: now).mayRecover,
            "a future (rolled-back) recovery must count toward the cap, or a clock rollback "
                + "manufactures recovery budget for a flapping path")
    }
}
