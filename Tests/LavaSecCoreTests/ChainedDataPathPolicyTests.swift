import XCTest

@testable import LavaSecChainedUpstream

/// The drop-versus-reconnect boundary, which is where this feature's expensive failure
/// mode lives.
///
/// Getting it wrong does not crash. It produces a reconnect storm: a per-packet condition
/// treated as session-fatal means every malformed datagram tears down a working tunnel, so
/// one hostile packet per second keeps a user permanently disconnected while the logs show
/// a flapping VPN rather than an attack. That is the LAV-80 class in this codebase, and it
/// is why every error case is enumerated here rather than sampled.
final class ChainedDataPathPolicyTests: XCTestCase {
    private static let allErrors: [WireGuardEngineError] = [
        .invalidArgument,
        .destinationBufferTooSmall,
        .noCurrentSession,
        .underLoad,
        .protocolViolation,
        .oversizedDatagram,
        .connectionExpired,
        .engineInternal,
        .packetTooLarge,
        .sessionCreationFailed,
        .unrecognized(code: -99),
    ]

    private func action(_ error: WireGuardEngineError) -> ChainedDataPathAction {
        ChainedDataPathPolicy.action(for: .failure(error))
    }

    private func action(_ operation: WireGuardOperation) -> ChainedDataPathAction {
        ChainedDataPathPolicy.action(for: .success(operation))
    }

    // MARK: - The distinction that matters

    func testAFailedPacketIsDroppedAndNeverEndsTheSession() {
        // Wrong key, bad MAC, replayed counter, unknown type — all arrive as
        // protocolViolation, and all are the normal state of any UDP port on the internet.
        // Escalating here is the reconnect storm.
        XCTAssertEqual(action(.protocolViolation), .dropPacket(reason: .protocolViolation))
        XCTAssertFalse(action(.protocolViolation).endsSession)
    }

    func testOnlyAnExpiredSessionEndsTheSessionAmongWireConditions() {
        // Of everything the wire can cause, exactly one means no further traffic can flow
        // without a fresh handshake.
        let wireConditions: [WireGuardEngineError] = [
            .protocolViolation, .underLoad, .noCurrentSession, .connectionExpired,
            // destinationBufferTooSmall used to sit here, "remotely reachable despite its
            // name". It no longer is: the wrapper splits the sender-chosen case out as
            // oversizedDatagram before the ABI call, so that is the wire condition now.
            .oversizedDatagram,
        ]
        let ending = wireConditions.filter { action($0).endsSession }
        XCTAssertEqual(ending, [.connectionExpired])
    }

    func testAnAbsentSessionIsAPacketRejectionNotIdleness() {
        // This asserted `.idle`, on the belief that the engine had queued an OUTBOUND packet
        // and would flush it later. No such origin exists: `encapsulate` queues and returns
        // handshake output (noise/mod.rs:250-268), so it cannot produce this code. The only
        // producer is `handle_data` (noise/mod.rs:414-420), for an INBOUND datagram whose
        // receiver index maps to an empty session slot — stale or hostile.
        //
        // Reporting it as idleness told the drain there was no work rather than that a
        // datagram had been refused, and dropped the reason from accounting — the signal
        // that separates "the peer went quiet" from "someone is spraying our port".
        XCTAssertEqual(action(.noCurrentSession), .dropPacket(reason: .noCurrentSession))
        XCTAssertFalse(action(.noCurrentSession).endsSession)
    }

    func testACallerBugStopsTheSessionWithoutRetrying() {
        // `.callerBug` used to be behaviourally identical to `.dropPacket` — same
        // endsSession, same terminatesDrain, differing only in a log string. A loop driven
        // by those predicates kept the tunnel reported as healthy while every subsequent
        // call repeated the same deterministic failure, which is exactly what separating
        // caller bugs is supposed to prevent.
        for error in [
            WireGuardEngineError.invalidArgument, .packetTooLarge, .sessionCreationFailed,
            .destinationBufferTooSmall,
        ] {
            let verdict = action(error)
            XCTAssertTrue(verdict.endsSession, "\(error) left the session running")
            XCTAssertFalse(
                verdict.warrantsAnotherAttempt,
                "\(error) would be retried — a contract violation cannot be fixed by trying again"
            )
        }
    }

    func testOnlyAWireConditionEarnsAnotherAttempt() {
        // The two questions are distinct: .callerBug ends the session but must not be
        // retried, .reconnect ends it and must be. Nothing else may claim either.
        for error in Self.allErrors {
            let verdict = action(error)
            if verdict.warrantsAnotherAttempt {
                XCTAssertEqual(verdict, .reconnect(reason: error))
            }
            XCTAssertEqual(
                verdict.endsSession,
                verdict == .reconnect(reason: error) || verdict == .callerBug(reason: error)
            )
        }
    }

    func testBackpressureIsNotABrokenSession() {
        XCTAssertEqual(action(.underLoad), .dropPacket(reason: .underLoad))
    }

    // MARK: - Caller bugs are not wire conditions

    func testContractViolationsAreReportedAsOurBugRatherThanSilentlyDropped() {
        // These cannot happen if the loop honours the engine's buffer contract, so one
        // means our code is wrong. Folding them into dropPacket would let the tunnel look
        // healthy while discarding every packet.
        for error in [
            WireGuardEngineError.invalidArgument,
            .packetTooLarge,
            .sessionCreationFailed,
        ] {
            XCTAssertEqual(action(error), .callerBug(reason: error))
            XCTAssertFalse(
                action(error).warrantsAnotherAttempt,
                "a caller bug is not a wire condition to reconnect over")
        }
    }

    func testAnOversizedInboundDatagramIsAPerPacketVerdict() {
        // The reasoning here used to hang on destinationBufferTooSmall, because the ABI
        // returned that code from two places on the decapsulate path: a genuine dst_cap
        // shortfall, and `src_len > dst_cap` — a bound on the INBOUND datagram, whose size
        // the SENDER chooses. The wrapper now rejects the remote case before the ABI call
        // and reports it as `oversizedDatagram`, so the argument moves here intact.
        //
        // It is reachable by anyone who can reach our UDP port, and by any peer whose tunnel
        // MTU exceeds ours. Classifying it as a caller bug would let an attacker generate
        // "our code is wrong" reports at line rate, and would blame our buffer discipline
        // for their packet.
        XCTAssertEqual(
            action(.oversizedDatagram),
            .dropPacket(reason: .oversizedDatagram)
        )
        XCTAssertFalse(action(.oversizedDatagram).endsSession)
    }

    func testAnUndersizedScratchBufferIsACallerBug() {
        // The other half of the split. Once the remote case leaves as `oversizedDatagram`,
        // destinationBufferTooSmall keeps exactly one meaning — our own buffer was wrong —
        // and that is neither transient nor self-clearing: the packet loop hands over the
        // same undersized buffer every time. Draining it as a per-packet drop would discard
        // every packet for the life of the session while the tunnel reported itself healthy,
        // which is silent total data loss presented as a working VPN.
        XCTAssertEqual(
            action(.destinationBufferTooSmall),
            .callerBug(reason: .destinationBufferTooSmall)
        )
    }

    func testUnknownAndInternalFailuresEndTheSessionRatherThanBeingIgnored() {
        // Neither is a per-packet condition and neither is safe to keep driving, so both end
        // the session. They differ on whether another attempt is worth making.
        for error in [WireGuardEngineError.engineInternal, .unrecognized(code: -99)] {
            XCTAssertTrue(action(error).endsSession, "\(error) must not keep driving")
        }

        // A poisoned lock is worth one more try: a fresh session gets a fresh lock.
        XCTAssertEqual(action(.engineInternal), .reconnect(reason: .engineInternal))

        // An unknown status code is not. It means the Swift declarations and the engine
        // binary disagree, and a fresh session runs the same mismatched code to the same
        // answer — so retrying would spend the whole outage budget on an operation that
        // cannot succeed, delaying the DNS-only fallback by a minute for nothing.
        XCTAssertEqual(
            action(.unrecognized(code: -99)), .callerBug(reason: .unrecognized(code: -99)))
        XCTAssertFalse(action(.unrecognized(code: -99)).warrantsAnotherAttempt)
    }

    // MARK: - Totality

    func testEveryErrorIsClassifiedAndNoneFallsThrough() {
        // A new engine error must be triaged deliberately. The switch is exhaustive so it
        // will not compile until someone chooses — this asserts the chosen answers are
        // meaningful rather than a catch-all.
        for error in Self.allErrors {
            switch ChainedDataPathPolicy.action(for: .failure(error)) {
            case .dropPacket, .reconnect, .callerBug, .idle:
                continue
            case .sendToPeer, .deliverIPv4, .dropIPv6:
                XCTFail("\(error) was classified as a successful data outcome")
            }
        }
    }

    func testNoErrorClassEndsTheSessionSilently() {
        // Every session-ending action must name its cause, so a field log can answer "why
        // did the tunnel stop" without guessing.
        //
        // Two classes end it now, and they mean different things: a wire condition earns
        // another attempt, a caller bug does not. Both prefixes are accepted here because
        // the property under test is that the cause is NAMED — which of the two it is, is
        // testOnlyAWireConditionEarnsAnotherAttempt's job.
        for error in Self.allErrors where action(error).endsSession {
            let logValue = action(error).logValue
            XCTAssertTrue(
                logValue.hasPrefix("reconnect-") || logValue.hasPrefix("caller-bug-"),
                "\(error) ends the session without naming itself in the log (\(logValue))"
            )
        }
    }

    // MARK: - Successful outcomes

    func testDataOutcomesMapToTheirTransports() {
        XCTAssertEqual(action(.none), .idle)
        XCTAssertEqual(action(.writeToNetwork(byteCount: 120)), .sendToPeer(byteCount: 120))
        XCTAssertEqual(action(.writeToTunnelIPv4(byteCount: 40)), .deliverIPv4(byteCount: 40))
    }

    func testDecryptedIPv6IsDroppedDeliberatelyRatherThanDelivered() {
        // The tunnel claims ::/0 so IPv6 cannot leave the device outside the VPN. Having
        // claimed it, these packets arrive here — and until the forwarding half lands,
        // dropping is the correct implementation, not a gap.
        XCTAssertEqual(action(.writeToTunnelIPv6(byteCount: 60)), .dropIPv6(byteCount: 60))
        XCTAssertFalse(action(.writeToTunnelIPv6(byteCount: 60)).endsSession)
    }

    // MARK: - Drain loop

    func testOnlyAnotherDatagramForThePeerContinuesTheDrain() {
        // The engine's contract is "call again with an empty source until it stops
        // returning WRITE_TO_NETWORK". Anything else must terminate — including errors,
        // which would otherwise spin the loop on a permanent condition.
        XCTAssertFalse(action(.writeToNetwork(byteCount: 100)).terminatesDrain)

        for action in [
            ChainedDataPathAction.idle,
            .deliverIPv4(byteCount: 10),
            .dropIPv6(byteCount: 10),
            .dropPacket(reason: .protocolViolation),
            .reconnect(reason: .connectionExpired),
            .callerBug(reason: .invalidArgument),
        ] {
            XCTAssertTrue(action.terminatesDrain, "\(action.logValue) must not continue the drain")
        }
    }

    func testEveryErrorTerminatesTheDrain() {
        for error in Self.allErrors {
            XCTAssertTrue(
                action(error).terminatesDrain,
                "\(error) would spin the drain loop"
            )
        }
    }

    // MARK: - Log identifiers

    func testLogValuesAreDistinctSoAFieldLogCanTellCausesApart() {
        let values = Self.allErrors.map { action($0).logValue }
        XCTAssertEqual(Set(values).count, values.count, "two causes share a log identifier")
        XCTAssertTrue(values.allSatisfy { !$0.isEmpty })
    }
}
