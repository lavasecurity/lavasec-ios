import XCTest
@testable import LavaSecCore

final class DNSQueryDispatcherTests: XCTestCase {
    private let dispatcher = DNSQueryDispatcher()
    private let bootstrapData = Data([0xBE, 0xEF])

    // MARK: precedence

    func testBootstrapWinsEvenWhenPausedAndWouldBlock() {
        // The hard invariant: a resolver-bootstrap query is never paused or
        // blocked, or encrypted-DNS bootstrap fails and the tunnel can't resolve.
        let decision = dispatcher.decide(
            bootstrapResponse: { self.bootstrapData },
            isProtectionPaused: { true },
            filterDecision: { FilterDecision(action: .block, reason: .blocklist) }
        )
        XCTAssertEqual(decision, .bootstrap(bootstrapData))
    }

    func testPauseWinsOverFilterBlockWhenNoBootstrap() {
        let decision = dispatcher.decide(
            bootstrapResponse: { nil },
            isProtectionPaused: { true },
            filterDecision: { FilterDecision(action: .block, reason: .blocklist) }
        )
        XCTAssertEqual(decision, .pausedForward)
    }

    func testFilterBlockWhenNoBootstrapAndNotPaused() {
        let blocked = FilterDecision(action: .block, reason: .blocklist)
        let decision = dispatcher.decide(
            bootstrapResponse: { nil },
            isProtectionPaused: { false },
            filterDecision: { blocked }
        )
        XCTAssertEqual(decision, .filtered(blocked))
    }

    func testFilterAllowForwardsAndCarriesReason() {
        let allowed = FilterDecision(action: .allow, reason: .localAllowlist)
        let decision = dispatcher.decide(
            bootstrapResponse: { nil },
            isProtectionPaused: { false },
            filterDecision: { allowed }
        )
        XCTAssertEqual(decision, .filtered(allowed))
    }

    // MARK: laziness / short-circuit (preserves the original per-query cost)

    func testBootstrapShortCircuitsPauseAndFilterReads() {
        var pauseRead = false
        var filterRead = false
        _ = dispatcher.decide(
            bootstrapResponse: { self.bootstrapData },
            isProtectionPaused: { pauseRead = true; return false },
            filterDecision: { filterRead = true; return .defaultAllow }
        )
        XCTAssertFalse(pauseRead, "Pause state must not be read once a bootstrap response exists.")
        XCTAssertFalse(filterRead, "The snapshot filter must not be read once a bootstrap response exists.")
    }

    func testPauseShortCircuitsTheFilterRead() {
        var filterRead = false
        _ = dispatcher.decide(
            bootstrapResponse: { nil },
            isProtectionPaused: { true },
            filterDecision: { filterRead = true; return .defaultAllow }
        )
        XCTAssertFalse(filterRead, "The snapshot filter must not be read while protection is paused.")
    }
}
