import XCTest

@testable import LavaSecChainedUpstream

/// C4's crash-window ordering, as an executable property.
final class ChainedSurrenderRecoveryTests: XCTestCase {
    func testTheSuppressionIsDurableBeforeTheRestartBegins() {
        var order: [String] = []

        let outcome = ChainedSurrenderRecovery.perform(
            persistSuppression: { order.append("persist") },
            restartIntoDNSOnly: { order.append("restart") })

        XCTAssertEqual(
            order, ["persist", "restart"],
            "the suppression must be durable BEFORE the restart begins — a crash between a "
                + "restart-first pair wakes into a latch that still selects chained, and the "
                + "blackhole the surrender ended comes back wearing a fresh session")
        XCTAssertEqual(outcome, .persisted)
    }

    func testAFailedPersistStillRestarts() {
        struct KeychainRefused: Error {}
        var restarted = false

        let outcome = ChainedSurrenderRecovery.perform(
            persistSuppression: { throw KeychainRefused() },
            restartIntoDNSOnly: { restarted = true })

        XCTAssertTrue(
            restarted,
            "a suppression that could not persist is honoured for this lifecycle by the "
                + "driver's own latch; refusing to restart leaves the claimed default route "
                + "with no data path — the state C4 exists to end")
        guard case .persistFailed = outcome else {
            return XCTFail("a failed persist must be reported for the loud log, not hidden")
        }
    }
}
