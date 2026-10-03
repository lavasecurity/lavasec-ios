import XCTest

@testable import LavaSecCore
@testable import LavaSecKit

/// Slice C: `DataPathHealth` — the third connectivity-health signal, detecting a peer that stays
/// reachable but stops forwarding (tx keeps climbing on requests + retransmits while rx stays flat).
/// Pure value type, so behavioral tests (never source pins).
final class DataPathHealthTests: XCTestCase {
    private let ref = Date(timeIntervalSinceReferenceDate: 800_720_000)

    private func inputs(
        tx: UInt64, rx: UInt64,
        handshake: Bool = true, everHandshaked: Bool = false, connected: Bool = true,
        unansweredSeconds: Int = 0
    ) -> ConnectivityHealthInputs {
        ConnectivityHealthInputs(
            isConnected: connected,
            health: TunnelHealthSnapshot(),
            dataPath: DataPathObservation(
                transmittedByteDelta: tx, receivedByteDelta: rx,
                hasHandshake: handshake, everHandshaked: everHandshaked,
                unansweredDestinationSeconds: unansweredSeconds))
    }

    func testIdentifiesAsDataPath() {
        XCTAssertEqual(DataPathHealth().id, .dataPath)
    }

    func testNoObservationReadsHealthy() {
        // DNS-only mode / before the first sample: no data-path evidence, nothing to judge.
        let noSample = ConnectivityHealthInputs(isConnected: true, health: TunnelHealthSnapshot())
        XCTAssertEqual(DataPathHealth().verdict(for: noSample, now: ref), .healthy)
    }

    func testNoHandshakeWhileConnectedReadsDownTunnelConnecting() {
        // Chained + connected but the WG session has not handshaked: establishing, NOT "Healthy" (the
        // first ~10-15 s of a chained connect used to read Healthy — founder dogfood). tx is irrelevant.
        let verdict = DataPathHealth().verdict(for: inputs(tx: 1_000_000, rx: 0, handshake: false), now: ref)
        XCTAssertEqual(verdict, .down("tunnel-connecting"))
        XCTAssertEqual(verdict.reason, DataPathHealth.tunnelConnectingReason)
    }

    func testHandshakeLandingClearsTheEstablishingVerdict() {
        // The instant the handshake completes, an established-but-idle tunnel reads healthy again.
        XCTAssertEqual(
            DataPathHealth().verdict(for: inputs(tx: 0, rx: 0, handshake: true), now: ref),
            .healthy)
    }

    func testExpiredSessionReadsDownTunnelStalled() {
        // Handshaked once, now no session (dead peer, or keepalive-0 idle past REJECT_AFTER_TIME): a
        // real outage, NOT establishing — so it must not read as "connecting" (Kilo #556).
        let verdict = DataPathHealth().verdict(
            for: inputs(tx: 1_000_000, rx: 0, handshake: false, everHandshaked: true), now: ref)
        XCTAssertEqual(verdict, .down("tunnel-stalled"))
        XCTAssertEqual(verdict.reason, DataPathHealth.tunnelStalledReason)
    }

    func testBelowTransmitFloorReadsHealthy() {
        // A quiet tunnel (keepalive-scale tx) has nothing to judge, however lopsided.
        XCTAssertEqual(
            DataPathHealth().verdict(for: inputs(tx: 16_383, rx: 0), now: ref),
            .healthy)
    }

    func testNormalDownloadReadsHealthy() {
        // Real browsing: requests are small, pages are large — rx dominates tx. Never flagged.
        XCTAssertEqual(
            DataPathHealth().verdict(for: inputs(tx: 20_000, rx: 400_000), now: ref),
            .healthy)
    }

    func testReceiveKeepingUpAtTheRatioBoundaryReadsHealthy() {
        // rx * 4 == tx is NOT dominance (the check is strict `<`), so this stays healthy.
        XCTAssertEqual(
            DataPathHealth().verdict(for: inputs(tx: 40_000, rx: 10_000), now: ref),
            .healthy)
    }

    func testTransmitDominatingFlatReceiveReadsDownUpstreamQuiet() {
        // Sent real traffic, nothing came back: the peer is not forwarding.
        let verdict = DataPathHealth().verdict(for: inputs(tx: 65_536, rx: 0), now: ref)
        XCTAssertEqual(verdict, .down("upstream-quiet"))
        XCTAssertEqual(verdict.reason, DataPathHealth.upstreamQuietReason)
    }

    func testTransmitDominatingModeratelyReadsDown() {
        // rx * 4 = 16_000 < tx = 40_001 — dominance crosses the threshold just past the boundary.
        XCTAssertEqual(
            DataPathHealth().verdict(for: inputs(tx: 40_001, rx: 10_000), now: ref),
            .down("upstream-quiet"))
    }

    func testAtTransmitFloorWithFlatReceiveReadsDown() {
        // Exactly at the floor (>=) with no reply is the smallest flagged case.
        XCTAssertEqual(
            DataPathHealth().verdict(for: inputs(tx: 16_384, rx: 0), now: ref),
            .down("upstream-quiet"))
    }

    func testDisconnectedReadsHealthy() {
        XCTAssertEqual(
            DataPathHealth().verdict(for: inputs(tx: 1_000_000, rx: 0, connected: false), now: ref),
            .healthy)
    }

    func testPureAndDeterministic() {
        let signal = DataPathHealth()
        let i = inputs(tx: 65_536, rx: 0)
        XCTAssertEqual(signal.verdict(for: i, now: ref), signal.verdict(for: i, now: ref))
    }

    func testUsableThroughTheExistentialProtocol() {
        let signal: any ConnectivityHealthSignal = DataPathHealth()
        XCTAssertEqual(signal.id, .dataPath)
        XCTAssertEqual(signal.verdict(for: inputs(tx: 65_536, rx: 0), now: ref), .down("upstream-quiet"))
    }
    // MARK: - Per-destination reachability (INV-CHAIN-6)

    func testAnUnansweredDestinationReadsDownWithItsOwnReason() {
        // The case every other field in this signal reads healthy in: a chain with a live
        // handshake, carrying its range, whose replies keep up with its sends — and one host the
        // user is asking for that answers nothing.
        XCTAssertEqual(
            DataPathHealth().verdict(for: inputs(tx: 0, rx: 0, unansweredSeconds: 21), now: ref),
            .down("destination-unanswered"))
    }

    func testTheDestinationReasonWinsOverTheByteRatioHeuristic() {
        // Both would fire. The byte ratio is a coarse whole-session aggregate a bulk upload also
        // satisfies; a destination the user is actively asking for and hearing nothing from is a
        // direct observation. The specific reason is the useful one, so it is checked first.
        XCTAssertEqual(
            DataPathHealth().verdict(
                for: inputs(tx: 1_000_000, rx: 0, unansweredSeconds: 40), now: ref),
            .down("destination-unanswered"))
    }

    func testAnUnansweredDestinationNeverPreemptsTheEstablishingVerdict() {
        // A chain with no handshake cannot have delivered anything to anyone, so a stale wait must
        // not overwrite "Connecting…" with a host-is-down reading the user cannot act on.
        XCTAssertEqual(
            DataPathHealth().verdict(
                for: inputs(tx: 0, rx: 0, handshake: false, unansweredSeconds: 40), now: ref),
            .down("tunnel-connecting"))
    }

    func testZeroSecondsIsNotAComplaint() {
        // The healthy reading, and the one a DNS-only or freshly rebuilt session leaves behind.
        XCTAssertEqual(
            DataPathHealth().verdict(for: inputs(tx: 1_000, rx: 900, unansweredSeconds: 0), now: ref),
            .healthy)
    }

    func testAnUnansweredDestinationIsReportedWithoutAnyRecommendedAction() {
        // `INV-CHAIN-6`. The exclusion is STRUCTURAL and belongs to the whole data-path signal —
        // `ConnectivityHealthSupervisor` never consults it for `recommendedAction` — so this new
        // reason inherits it exactly as `upstream-quiet` does. Restarting the tunnel cannot fix
        // somebody else's host being down, and recommending it would send the user to disable the
        // feature that is working.
        let assessment = ConnectivityHealthSupervisor().assess(
            for: inputs(tx: 0, rx: 0, unansweredSeconds: 40),
            authority: DNSHealthAuthority(chainedIsLatched: true),
            now: ref)
        XCTAssertNotEqual(
            assessment.recommendedAction, .reconnect,
            "a silent destination recommended a reconnect — the data-path signal must never gate")
        XCTAssertTrue(
            assessment.unhealthySignals.contains {
                $0.verdict.reason == DataPathHealth.destinationUnansweredReason
            },
            "the reason was swallowed instead of surfaced")
    }

}
