import Foundation
import XCTest
@testable import LavaSecCore
@testable import LavaSecDNS

/// Executable coverage for the DoT retry decision that was previously inlined in
/// `DoTConnection.failOrRetryCurrentQuery` and reachable only through a live
/// NWConnection: timeouts retry exactly once and only on a reused (possibly zombie)
/// pooled connection, while non-timeout failures walk the bootstrap address list.
final class DoTQueryRetryPolicyTests: XCTestCase {
    func testTimeoutOnReusedConnectionRetriesExactlyOnce() {
        // First attempt rode a pooled connection that may have been closed
        // server-side while idle: one fresh-connection retry, even when the
        // endpoint has a single bootstrap address.
        XCTAssertTrue(DoTQueryRetryPolicy.shouldRetry(
            outcome: .timeout,
            priorAttemptCount: 0,
            attemptRodeReusedConnection: true,
            bootstrapAddressCount: 1
        ))

        // The stale-connection retry is granted BEFORE the max(1, bootstrapAddressCount)
        // clamp can short-circuit it: an empty bootstrap list (count 0) still earns the one
        // fresh-connection retry for a reused-connection timeout. (OCR review on the 1.2.4 sync)
        XCTAssertTrue(DoTQueryRetryPolicy.shouldRetry(
            outcome: .timeout,
            priorAttemptCount: 0,
            attemptRodeReusedConnection: true,
            bootstrapAddressCount: 0
        ))

        // The stale-connection allowance is spent after the first attempt: a
        // second timeout fails the query so worst-case latency stays bounded.
        XCTAssertFalse(DoTQueryRetryPolicy.shouldRetry(
            outcome: .timeout,
            priorAttemptCount: 1,
            attemptRodeReusedConnection: true,
            bootstrapAddressCount: 4
        ))
    }

    func testTimeoutOnFreshConnectionNeverRetries() {
        // A fresh connection that timed out is a slow upstream, not a zombie:
        // retrying would double the worst-case latency for no new information.
        for bootstrapAddressCount in [1, 2, 4] {
            XCTAssertFalse(DoTQueryRetryPolicy.shouldRetry(
                outcome: .timeout,
                priorAttemptCount: 0,
                attemptRodeReusedConnection: false,
                bootstrapAddressCount: bootstrapAddressCount
            ))
        }
    }

    func testNonTimeoutFailuresWalkTheBootstrapAddressList() {
        let failureOutcomes: [DNSTransportOutcome] = [.sendFailed, .receiveFailed, .mismatchedResponse]

        for outcome in failureOutcomes {
            // Three bootstrap addresses allow three attempts total: retries are
            // granted after the first and second failures, not the third.
            XCTAssertTrue(DoTQueryRetryPolicy.shouldRetry(
                outcome: outcome,
                priorAttemptCount: 0,
                attemptRodeReusedConnection: false,
                bootstrapAddressCount: 3
            ), "\(outcome)")
            XCTAssertTrue(DoTQueryRetryPolicy.shouldRetry(
                outcome: outcome,
                priorAttemptCount: 1,
                attemptRodeReusedConnection: false,
                bootstrapAddressCount: 3
            ), "\(outcome)")
            XCTAssertFalse(DoTQueryRetryPolicy.shouldRetry(
                outcome: outcome,
                priorAttemptCount: 2,
                attemptRodeReusedConnection: false,
                bootstrapAddressCount: 3
            ), "\(outcome)")
        }
    }

    func testNonTimeoutOutcomeIgnoresReusedConnectionFlag() {
        // The reused-connection allowance is a timeout-only concession (it gates on
        // `outcome == .timeout`); a non-timeout outcome must decide identically whether or
        // not the attempt rode a reused connection. Pin both the equality of the two flag
        // variants and the concrete decision, so a regression that leaked the flag into the
        // non-timeout path is caught. (OCR review on the 1.2.4 sync)
        let configurations: [(priorAttemptCount: Int, bootstrapAddressCount: Int, expected: Bool)] = [
            (0, 2, true),   // a second address remains to walk to
            (0, 1, false),  // single address: no same-address retry
            // Upper boundary, where the non-reused decision is already false: a leaked
            // OR-with-reused-flag regression would flip false → true here, caught only by the
            // equality assertion at the cap (OCR review on the 1.2.4 sync).
            (1, 2, false),  // one attempt in, one address left of two: no retry
            (2, 3, false),  // two attempts in, one address left of three: no retry
        ]
        for configuration in configurations {
            let rodeReusedConnection = DoTQueryRetryPolicy.shouldRetry(
                outcome: .sendFailed,
                priorAttemptCount: configuration.priorAttemptCount,
                attemptRodeReusedConnection: true,
                bootstrapAddressCount: configuration.bootstrapAddressCount
            )
            let rodeFreshConnection = DoTQueryRetryPolicy.shouldRetry(
                outcome: .sendFailed,
                priorAttemptCount: configuration.priorAttemptCount,
                attemptRodeReusedConnection: false,
                bootstrapAddressCount: configuration.bootstrapAddressCount
            )
            XCTAssertEqual(
                rodeReusedConnection, rodeFreshConnection,
                "reused-connection flag must not change a non-timeout decision (bootstrapAddressCount: \(configuration.bootstrapAddressCount))"
            )
            XCTAssertEqual(
                rodeReusedConnection, configuration.expected,
                "bootstrapAddressCount: \(configuration.bootstrapAddressCount)"
            )
        }
    }

    func testNonTimeoutFailureWithSingleAddressFailsImmediately() {
        // One bootstrap address means one attempt: there is no other address to
        // walk to, so the failure surfaces without a same-address retry.
        XCTAssertFalse(DoTQueryRetryPolicy.shouldRetry(
            outcome: .receiveFailed,
            priorAttemptCount: 0,
            attemptRodeReusedConnection: true,
            bootstrapAddressCount: 1
        ))

        // An empty bootstrap list clamps to one attempt rather than zero.
        XCTAssertFalse(DoTQueryRetryPolicy.shouldRetry(
            outcome: .receiveFailed,
            priorAttemptCount: 0,
            attemptRodeReusedConnection: false,
            bootstrapAddressCount: 0
        ))
    }
}
