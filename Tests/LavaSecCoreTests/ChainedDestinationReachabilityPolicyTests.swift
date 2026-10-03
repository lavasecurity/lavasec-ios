import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// The judgement half of the per-destination signal: given raw counts and instants, is this one
/// host behind the chain answering, and is the answer honest at every boundary?
final class ChainedDestinationReachabilityPolicyTests: XCTestCase {

    func testADestinationNothingWasEverSentToIsIdle() {
        let verdict = ChainedDestinationReachabilityPolicy.verdict(
            for: Self.observation(sent: 0, received: 0, since: nil, lastSend: nil), atSeconds: 500)
        XCTAssertEqual(verdict, .idle, "a destination nobody addressed was judged anyway")
    }

    func testAClosedWindowReadsAsAnswering() {
        // A receipt is the only thing that clears the anchor, so a nil anchor beside a real send
        // means this destination answered since the last time we started waiting on it.
        let verdict = ChainedDestinationReachabilityPolicy.verdict(
            for: Self.observation(sent: 9, received: 4, since: nil, lastSend: 100), atSeconds: 101)
        XCTAssertEqual(verdict, .answering)
    }

    func testSustainedDemandInsideTheThresholdIsAwaitingAndNotAComplaint() {
        // The ordinary state of any connection during its first round trip. Reporting it would
        // put "your host is not answering" on screen for every page load.
        let waited = ChainedDestinationReachabilityPolicy.unansweredThresholdSeconds - 1
        let verdict = ChainedDestinationReachabilityPolicy.verdict(
            for: Self.observation(sent: 6, received: 0, since: 100, lastSend: 100 + waited),
            atSeconds: 100 + waited)
        XCTAssertEqual(verdict, .awaiting(seconds: waited))
    }

    func testSustainedDemandAtTheThresholdIsUnansweredAndCarriesItsDuration() {
        let waited = ChainedDestinationReachabilityPolicy.unansweredThresholdSeconds
        let verdict = ChainedDestinationReachabilityPolicy.verdict(
            for: Self.observation(sent: 8, received: 0, since: 100, lastSend: 100 + waited),
            atSeconds: 100 + waited)
        XCTAssertEqual(
            verdict, .unanswered(seconds: waited),
            "the threshold is inclusive, matching the egress-dead arm's `>=`")
    }

    func testALapseInDemandYieldsIdleEvenWithALongOpenWindow() {
        // THE GUARD THAT KEEPS THIS SIGNAL FALSIFIABLE. The window stays open across the lapse —
        // clearing it is the table's job on the next send, where it can re-anchor — so the policy
        // has to refuse to count idle time itself. Without this a host the user stopped using
        // reports as unreachable forever, which is both untestable by the user and useless.
        let observation = Self.observation(sent: 3, received: 0, since: 100, lastSend: 104)
        let lapsed = 104 + ChainedDestinationReachabilityPolicy.demandContinuitySeconds
        XCTAssertEqual(
            ChainedDestinationReachabilityPolicy.verdict(for: observation, atSeconds: lapsed - 1),
            .awaiting(seconds: lapsed - 1 - 100),
            "demand had not lapsed yet")
        XCTAssertEqual(
            ChainedDestinationReachabilityPolicy.verdict(for: observation, atSeconds: lapsed),
            .idle)
        XCTAssertEqual(
            ChainedDestinationReachabilityPolicy.verdict(for: observation, atSeconds: 100_000),
            .idle,
            "an abandoned destination became a complaint by waiting")
    }

    func testOneSendFollowedBySilenceCanNeverBecomeUnanswered() {
        // Why the policy needs no minimum send count: the lapse guard already subsumes it. A
        // single packet's window dies at `demandContinuitySeconds`, less than half the threshold,
        // so it cannot survive long enough to be reported no matter how far the clock runs.
        let observation = Self.observation(sent: 1, received: 0, since: 40, lastSend: 40)
        for now in 40...400 {
            let verdict = ChainedDestinationReachabilityPolicy.verdict(
                for: observation, atSeconds: now)
            if case .unanswered = verdict {
                XCTFail("a one-shot packet was reported as an unreachable destination at \(now)s")
            }
        }
    }

    func testABackwardClockReadingNeverManufacturesAWait() {
        // `ChainedUptimeClock` never goes backwards, but the policy is handed two independently
        // sampled instants and clamping is cheaper than trusting the caller to have ordered them.
        let verdict = ChainedDestinationReachabilityPolicy.verdict(
            for: Self.observation(sent: 2, received: 0, since: 500, lastSend: 500), atSeconds: 495)
        XCTAssertEqual(verdict, .awaiting(seconds: 0))
    }

    func testTheThresholdMatchesTheEgressDeadDerivation() {
        // Reused rather than tuned: both are derived from the ENGINE's own recovery (a fresh
        // handshake at KEEPALIVE_TIMEOUT + REKEY_TIMEOUT, plus one lost-datagram REKEY_TIMEOUT),
        // and a reporting signal that fires under that tells the user their host is dead while
        // WireGuard is mid-rekey — whose remedy, restarting the VPN, destroys the recovery.
        XCTAssertEqual(
            ChainedDestinationReachabilityPolicy.unansweredThresholdSeconds,
            ChainedOutageDriver.egressDeadThresholdSeconds)
        XCTAssertEqual(
            ChainedDestinationReachabilityPolicy.demandContinuitySeconds,
            ChainedOutageDriver.egressDeadDemandContinuitySeconds)
    }

    func testTheLapseGuardAlwaysFiresBeforeTheThresholdCould() {
        // The relationship, not the two numbers: a lapse must be able to reset a window before it
        // could ever be reported, or the guard is decorative.
        XCTAssertLessThan(
            ChainedDestinationReachabilityPolicy.demandContinuitySeconds,
            ChainedDestinationReachabilityPolicy.unansweredThresholdSeconds)
    }

    /// THE FAILURE THIS TYPE EXISTS FOR, AND IT USED TO BE INVISIBLE.
    ///
    /// A stalled TCP connect retransmits at roughly 1/2/4/8 s. With sends at 0/1/3/7/15 the window
    /// crossed the threshold at 21 s — and then `lastSend` was 15, so the lapse fired at 25 and
    /// turned it back to `.idle`; the retransmit near 31 re-anchored because its gap exceeded
    /// `demandContinuitySeconds`, and every later backoff gap is longer still. A permanently
    /// failing host was therefore reportable for a three-second window and then never again, and
    /// the shipping mirror samples at ~60 s so it saw none of it (Codex P2, PR #593).
    ///
    /// A qualified window now survives the backoff. Only a receipt clears it.
    func testASustainedFailureStaysReportableThroughBackoff() {
        // Sends at 0/1/3/7/15: five in the window, anchored at 0.
        let stalled = Self.observation(sent: 5, received: 0, since: 0, lastSend: 15, inWindow: 5)
        for now in [21, 25, 30, 45, 90, 600] {
            XCTAssertEqual(
                ChainedDestinationReachabilityPolicy.verdict(for: stalled, atSeconds: now),
                .unanswered(seconds: now),
                "a host failing under TCP backoff stopped being reportable at \(now)s — the gaps "
                    + "ARE the failure, not the user losing interest")
        }
    }

    func testTheSendFloorIsWhatSeparatesBackoffFromAStrayPacket() {
        // Same shape, same age, one send behind it: still just a stray packet, so the lapse governs.
        let stray = Self.observation(sent: 1, received: 0, since: 0, lastSend: 0, inWindow: 1)
        XCTAssertEqual(
            ChainedDestinationReachabilityPolicy.verdict(for: stray, atSeconds: 40), .idle,
            "one packet then silence must never qualify, however long ago it was")

        let sustained = Self.observation(
            sent: 1, received: 0, since: 0, lastSend: 0,
            inWindow: ChainedDestinationReachabilityPolicy.sustainedSendFloor)
        XCTAssertEqual(
            ChainedDestinationReachabilityPolicy.verdict(for: sustained, atSeconds: 40),
            .unanswered(seconds: 40),
            "at the floor it is sustained demand, and the lapse no longer applies")
    }

    func testTheFloorOnlyRelaxesTheLapseAboveTheThreshold() {
        // Below the threshold a lapse still means idle no matter how many sends are behind it —
        // otherwise a burst that stopped would report as a wait nobody is having.
        let lapsedEarly = Self.observation(sent: 9, received: 0, since: 100, lastSend: 104, inWindow: 9)
        XCTAssertEqual(
            ChainedDestinationReachabilityPolicy.verdict(for: lapsedEarly, atSeconds: 114), .idle)
    }

    private static func observation(
        sent: UInt64, received: UInt64, since: Int?, lastSend: Int?, inWindow: UInt64 = 0
    ) -> ChainedDestinationObservation {
        ChainedDestinationObservation(
            sentPacketCount: sent,
            receivedPacketCount: received,
            firstUnansweredSendAtSeconds: since,
            lastSendAtSeconds: lastSend,
            sendsInCurrentWindow: inWindow)
    }
}
