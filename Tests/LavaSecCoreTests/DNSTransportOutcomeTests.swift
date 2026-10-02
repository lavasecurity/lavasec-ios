import XCTest
import LavaSecKit

@testable import LavaSecDNS

/// Executable coverage for `DNSTransportOutcome.isTransportFailureEvidence`.
///
/// The property decides whether an encrypted executor tears down a pooled session when a query
/// comes back empty. It carried a `pinned:` breadcrumb naming a SOURCE test that counts call sites
/// across the provider's sources and never evaluates the property — and the
/// provider is an app-target file that the SPM test target does not link, so its three call sites
/// had no executable coverage either. `return false` could be flipped to `return true` with the
/// entire suite green (sweep, PR #623). This file is that missing coverage.
final class DNSTransportOutcomeTests: XCTestCase {
    /// A DECLINED SEND is not evidence the transport is unhealthy; everything else here is.
    ///
    /// Driven off `allCases` rather than a written-out list, because the doc block's own
    /// justification for making this a category is that "a fourth refusal added later would have
    /// to find all of them" — a hand-maintained list is exactly what fails to deliver that.
    func testOnlyADeclinedSendIsNotTransportFailureEvidence() {
        let declined: Set<DNSTransportOutcome> = [.refusedAfterLatchReplaced, .expiredBeforeSend]
        for outcome in DNSTransportOutcome.allCases {
            XCTAssertEqual(
                outcome.isTransportFailureEvidence, !declined.contains(outcome),
                "\(outcome.rawValue) is classified against the declined-send set, not by default")
        }
    }

    func testExpiryBeforeSendIsNeutralAndEndsTheResolverLadder() {
        let outcome = ResolverAttemptOutcome(DNSTransportOutcome.expiredBeforeSend)
        XCTAssertTrue(outcome.isDeliberateRefusal)
        XCTAssertTrue(outcome.endsTheResolutionLadder)
        XCTAssertFalse(outcome.reachedTheWire)
        XCTAssertFalse(outcome.isTransientLocalFailure)
        XCTAssertEqual(ResolverBackoffPolicy.AttemptOutcome(outcome), .backedOff)
        XCTAssertEqual(ResolverOrganicUpstreamEvidence.AttemptOutcome(outcome), .notAttempted)
    }

    /// The discrimination, stated as the consequence rather than the classification.
    ///
    /// `.refusedAfterLatchReplaced` is the device declining to send: nothing is wrong with the
    /// connection, and discarding the pool for it throws away healthy lanes — including lanes for
    /// the resolver the user has just switched TO — forcing avoidable handshakes at exactly the
    /// moment they changed setting.
    func testADeclinedSendDoesNotCondemnTheConnectionButARealFailureDoes() {
        XCTAssertFalse(
            DNSTransportOutcome.refusedAfterLatchReplaced.isTransportFailureEvidence,
            "a write that was never attempted says nothing about the connection")
        for genuine: DNSTransportOutcome in [.timeout, .sendFailed, .receiveFailed] {
            XCTAssertTrue(
                genuine.isTransportFailureEvidence,
                "\(genuine.rawValue) reached the transport and failed there — the pool is suspect")
        }
    }
}
