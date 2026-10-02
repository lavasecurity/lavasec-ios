import XCTest

@testable import LavaSecCore
@testable import LavaSecKit

/// PR #558: `ChainedEstablishmentPolicy` gates the chained-connect success signal on the chain
/// actually FORWARDING traffic (bytes received back from the peer), with a deterministic
/// unconfirmed verdict at the timeout. Pure → behavioral.
final class ChainedEstablishmentPolicyTests: XCTestCase {
    private let timeout: TimeInterval = 15
    private var threshold: UInt64 { ChainedEstablishmentPolicy.forwardingConfirmedByteThreshold }

    func testDNSOnlyIsConfirmedImmediatelyWithNoChainToWaitFor() {
        // DNS-only has no chain; the tunnel being up IS the connect — confirm regardless of time/bytes.
        XCTAssertEqual(
            ChainedEstablishmentPolicy.outcome(
                isChained: false, receivedByteDelta: 0, elapsedSeconds: 0, timeoutSeconds: timeout),
            .confirmed)
        XCTAssertEqual(
            ChainedEstablishmentPolicy.outcome(
                isChained: false, receivedByteDelta: nil, elapsedSeconds: 999, timeoutSeconds: timeout),
            .confirmed)
    }

    func testForwardingConfirmedIsConfirmed() {
        // The peer relayed real data back (delta ≥ threshold) — the chain is carrying traffic.
        XCTAssertEqual(
            ChainedEstablishmentPolicy.outcome(
                isChained: true, receivedByteDelta: threshold, elapsedSeconds: 3, timeoutSeconds: timeout),
            .confirmed)
    }

    func testForwardingConfirmedIsConfirmedEvenPastTheTimeout() {
        // The forwarding check precedes the timeout: bytes arriving right at the deadline are
        // confirmed rather than unconfirmed.
        XCTAssertEqual(
            ChainedEstablishmentPolicy.outcome(
                isChained: true, receivedByteDelta: threshold * 10, elapsedSeconds: 100,
                timeoutSeconds: timeout),
            .confirmed)
    }

    func testChainedWithoutForwardingIsUnconfirmedAtTheTimeoutBoundary() {
        // `>=`: exactly at the cap with no forwarding proven is already unconfirmed, never a false
        // "Protected" verdict.
        XCTAssertEqual(
            ChainedEstablishmentPolicy.outcome(
                isChained: true, receivedByteDelta: 0, elapsedSeconds: 15, timeoutSeconds: timeout),
            .unconfirmed)
        XCTAssertEqual(
            ChainedEstablishmentPolicy.outcome(
                isChained: true, receivedByteDelta: threshold - 1, elapsedSeconds: 15,
                timeoutSeconds: timeout),
            .unconfirmed)
    }

    func testUnknownReplyKeepsEstablishingThenIsUnconfirmedAtTheTimeout() {
        // A nil (lost / no-session) reply is not proof of forwarding — keep waiting, then resolve
        // unconfirmed at the cap so a jetsam-blinded poll cannot hang the gate forever.
        XCTAssertEqual(
            ChainedEstablishmentPolicy.outcome(
                isChained: nil, receivedByteDelta: nil, elapsedSeconds: 4, timeoutSeconds: timeout),
            .establishing)
        XCTAssertEqual(
            ChainedEstablishmentPolicy.outcome(
                isChained: nil, receivedByteDelta: nil, elapsedSeconds: 20, timeoutSeconds: timeout),
            .unconfirmed)
    }

    func testDefaultTimeoutIsThreeHandshakeAttempts() {
        // 3 × WireGuard's 5 s REKEY_TIMEOUT.
        XCTAssertEqual(ChainedEstablishmentPolicy.defaultTimeoutSeconds, 15)
    }

    func testAnySingleForwardedNonDNSByteConfirms() {
        // Literal values (not the `threshold` symbol) to pin the INTENT: the signal is already filtered
        // to delivered non-DNS inner packets, so ONE byte is real general forwarding and must confirm —
        // a small first response (SYN-ACK, HTTP 204) under any size floor would otherwise false-close
        // (Codex, PR #558). Zero stays establishing; a size floor > 1 would regress this.
        XCTAssertEqual(ChainedEstablishmentPolicy.forwardingConfirmedByteThreshold, 1)
        XCTAssertEqual(
            ChainedEstablishmentPolicy.outcome(
                isChained: true, receivedByteDelta: 1, elapsedSeconds: 2, timeoutSeconds: timeout),
            .confirmed)
        XCTAssertEqual(
            ChainedEstablishmentPolicy.outcome(
                isChained: true, receivedByteDelta: 0, elapsedSeconds: 2, timeoutSeconds: timeout),
            .establishing)
    }

    // MARK: - receivedByteDelta baseline

    func testTheFirstReadingAnchorsAtZeroAndCreditsForwardingSinceTheSessionStart() {
        // The engine resets its byte total to 0 with the generation bump, so the first reading of a
        // generation IS that session's forwarding so far — credit it, don't discard it. Anchoring at
        // the current reading (returning 0) discarded forwarding that arrived before the first poll
        // (~1 s in) and could false-close a healthy connection that forwarded its startup traffic then
        // went idle (Codex, PR #558). The baseline anchors at the session's true start, 0.
        var baseline: (received: UInt64, generation: UInt64)?
        let delta = ChainedEstablishmentPolicy.receivedByteDelta(
            currentReceived: 4_096, currentGeneration: 7, baseline: &baseline)
        XCTAssertEqual(delta, 4_096, "first reading credits the session's forwarding so far")
        XCTAssertEqual(baseline?.received, 0, "baseline anchors at the session's true start, 0")
        XCTAssertEqual(baseline?.generation, 7)
    }

    func testWithinAGenerationTheDeltaIsCurrentMinusBaseline() {
        var baseline: (received: UInt64, generation: UInt64)? = (received: 1_000, generation: 7)
        let delta = ChainedEstablishmentPolicy.receivedByteDelta(
            currentReceived: 4_096, currentGeneration: 7, baseline: &baseline)
        XCTAssertEqual(delta, 3_096)
        XCTAssertEqual(baseline?.received, 1_000, "the baseline is not moved while the generation holds")
    }

    func testAGenerationChangeReanchorsAtZeroAndCreditsOnlyTheNewSession() {
        // A reconnect mid-connect resets the engine's byte totals and bumps the generation; the baseline
        // must re-anchor to the new session's true start (0) and credit only what the NEW session has
        // forwarded — never a stale cross-session delta. Here the new session has only handshaked (32 B),
        // well under the threshold, so the gate stays establishing.
        var baseline: (received: UInt64, generation: UInt64)? = (received: 900_000, generation: 7)
        let delta = ChainedEstablishmentPolicy.receivedByteDelta(
            currentReceived: 32, currentGeneration: 8, baseline: &baseline)
        XCTAssertEqual(delta, 32, "credit the new session's bytes from a 0 anchor, not a cross-session delta")
        XCTAssertEqual(baseline?.received, 0, "re-anchored at the new session's start")
        XCTAssertEqual(baseline?.generation, 8)
    }

    func testACounterRegressionWithinAGenerationClampsToZero() {
        // Defense in depth: a spurious same-generation regression must never read negative and
        // falsely satisfy the gate.
        var baseline: (received: UInt64, generation: UInt64)? = (received: 5_000, generation: 7)
        let delta = ChainedEstablishmentPolicy.receivedByteDelta(
            currentReceived: 4_000, currentGeneration: 7, baseline: &baseline)
        XCTAssertEqual(delta, 0)
    }

    // MARK: - Optional post-window promotion predicate
    //
    // This legacy helper stays narrowly byte-positive. The lifecycle reducer now owns persistent
    // monitoring, but another caller must not reuse outcome as a chained promotion predicate.

    /// A promotion helper must never treat a non-chained value as chained forwarding evidence.
    /// Current provider replies retain chained identity through runner gaps; legacy ambiguous false
    /// replies are kept unknown by the wire adapter rather than reaching this helper as DNS-only.
    func testPromotionPredicateRejectsAnUnchainedReply() {
        XCTAssertFalse(ChainedEstablishmentPolicy.promotesAfterWindow(
            isChained: false, receivedByteDelta: nil))
        XCTAssertFalse(
            ChainedEstablishmentPolicy.promotesAfterWindow(isChained: false, receivedByteDelta: 4096),
            "not even with bytes: promotion requires explicit chained runtime identity")
    }

    /// An IPC that the extension is not answering must never read as confirmation.
    func testPromotionPredicateRejectsAMissingReply() {
        XCTAssertFalse(ChainedEstablishmentPolicy.promotesAfterWindow(
            isChained: nil, receivedByteDelta: nil))
        XCTAssertFalse(ChainedEstablishmentPolicy.promotesAfterWindow(
            isChained: nil, receivedByteDelta: 1))
    }

    /// The promotion floor is the SAME single byte the window uses — one rule, two clocks.
    func testPromotionPredicateAcceptsASingleForwardedByte() {
        XCTAssertTrue(ChainedEstablishmentPolicy.promotesAfterWindow(
            isChained: true, receivedByteDelta: 1))
    }

    /// A live chain that has still carried nothing cannot satisfy the promotion predicate.
    func testPromotionPredicateRejectsZeroBytesFromALiveChain() {
        XCTAssertFalse(ChainedEstablishmentPolicy.promotesAfterWindow(
            isChained: true, receivedByteDelta: 0))
    }

    /// The field case this whole change exists for: a split-tunnel connect resolves unconfirmed at
    /// the cap with an idle tailnet, and then the user opens a tailnet host at t=40 s. The window
    /// is long over; promotion must still be available or the surface is stuck orange forever.
    func testALateByteConfirmsAfterTheWindowHasAlreadyReportedUnconfirmed() {
        XCTAssertEqual(
            ChainedEstablishmentPolicy.outcome(
                isChained: true, receivedByteDelta: 0, elapsedSeconds: 15),
            .unconfirmed)
        XCTAssertTrue(
            ChainedEstablishmentPolicy.promotesAfterWindow(isChained: true, receivedByteDelta: 535),
            "the predicate itself has no deadline — a caller may apply it to a later byte")
    }
}
