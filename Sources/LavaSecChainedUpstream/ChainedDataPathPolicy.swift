import Foundation

/// What the tunnel must do in response to one engine call.
///
/// Plan: lavasec-infra `plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md` (D5).
public enum ChainedDataPathAction: Equatable, Sendable {
    /// The scratch buffer holds a datagram for the peer. Send it.
    case sendToPeer(byteCount: Int)
    /// The scratch buffer holds a decrypted IPv4 packet. Write it to the tunnel.
    case deliverIPv4(byteCount: Int)
    /// A decrypted IPv6 packet, discarded. See ``ChainedDataPathPolicy`` for why this is
    /// deliberate rather than unimplemented.
    case dropIPv6(byteCount: Int)
    /// Nothing to emit. On a drain loop this is also the terminator.
    case idle
    /// Discard this packet and carry on. The session stays up.
    case dropPacket(reason: WireGuardEngineError)
    /// The session is over; escalate to the reconnect path.
    case reconnect(reason: WireGuardEngineError)
    /// A caller-contract violation — a defect in our code, not a wire condition.
    case callerBug(reason: WireGuardEngineError)
}

/// Maps engine outcomes onto tunnel actions.
///
/// ## Why this is a type and not a `switch` in the packet loop
///
/// The packet loop runs inside the Network Extension, where it cannot be unit-tested. The
/// decisions it makes, though, are exactly the ones with expensive failure modes — so they
/// live here, where every case is executable, and the loop keeps only the plumbing.
///
/// ## The distinction that matters: drop versus reconnect
///
/// Getting this wrong does not crash; it produces a reconnect storm. That is the LAV-80
/// class of bug in this codebase — a per-packet condition treated as a session-level
/// failure, so every hostile or malformed datagram tears down a working tunnel and
/// rebuilds it. One attacker packet per second is then enough to keep a user permanently
/// disconnected, and the logs show a flapping VPN rather than an attack.
///
/// So the split is deliberate and narrow:
///
/// - `protocolViolation` is a **per-packet verdict**. Wrong key, bad MAC, replayed
///   counter, unknown type — every one of these is a single datagram that failed to
///   authenticate, which is the normal state of any UDP port on the internet. Drop it.
/// - `connectionExpired` is the **only** wire condition that ends a session. The engine
///   raises it from its timers when the session passes `REJECT_AFTER_TIME`, at which point
///   no further traffic can flow without a fresh handshake.
/// - `noCurrentSession` is a per-packet REJECTION, not idleness. This paragraph used to say
///   the engine had queued an outbound packet and would flush it on the next drain — that
///   origin does not exist. `encapsulate` queues and returns handshake output
///   (`noise/mod.rs:250-268`), so it cannot produce this code; the only producer is
///   `handle_data` (`noise/mod.rs:414-420`), for an inbound datagram whose receiver index
///   maps to an empty session slot. Stale or hostile, and dropped per packet.
/// - `underLoad` is the peer's rate limiter asking for backoff, not a broken session.
///
/// ## Caller bugs are separated from wire conditions — but one code is both
///
/// `invalidArgument` and `packetTooLarge` cannot happen if the loop honours the engine's
/// buffer contract, so seeing one means our code is wrong rather than the network being
/// hostile. They route to `callerBug` so the tunnel can report them loudly instead of
/// silently discarding traffic while looking healthy.
///
/// `destinationBufferTooSmall` used to belong with neither, because it meant both things.
/// The ABI returned it from TWO places on the decapsulate path: a genuine `dst_cap`
/// shortfall, and `src_len > dst_cap` — a bound on the size of the *inbound datagram*,
/// chosen by whoever sent it. That second guard exists because an oversized datagram would
/// otherwise panic the engine before authentication. While the two were indistinguishable
/// here, the safe reading was `dropPacket`: calling it a caller bug would misattribute an
/// attacker's packet to our own buffer discipline and hand anyone who can reach our UDP
/// port a way to generate "our code is wrong" reports at line rate.
///
/// They are distinguishable now. `WireGuardSession` rejects the sender-chosen case BEFORE
/// the ABI call and reports it as `oversizedDatagram`, which keeps the per-packet verdict
/// and the reasoning above. `destinationBufferTooSmall` therefore keeps exactly one
/// meaning — our own buffer was wrong — and routes to `callerBug`. That matters because it
/// is not self-clearing: the packet loop hands over the same undersized buffer every time,
/// so draining it as a drop would discard every packet for the life of the session while
/// the tunnel reported itself healthy.
///
/// ## Ending a session is two questions, not one
///
/// `endsSession` says this session stops; `warrantsAnotherAttempt` says whether to start
/// another. Conflating them left `callerBug` behaviourally identical to `dropPacket` —
/// same predicates, differing only in a log string — so a loop following them kept the
/// tunnel healthy-looking while repeating a deterministic failure forever.
///
/// `unrecognized` is the other case that turns on the distinction. An unknown status code
/// means the Swift declarations and the engine binary disagree, and a fresh session runs
/// the same mismatched code to the same answer, so retrying spends the outage budget on
/// something that cannot succeed. `engineInternal` is genuinely different: a fresh session
/// gets a fresh lock, so it earns another attempt.
public enum ChainedDataPathPolicy {
    /// Decides the action for one engine call's outcome.
    public static func action(
        for outcome: Result<WireGuardOperation, WireGuardEngineError>
    ) -> ChainedDataPathAction {
        switch outcome {
        case .success(let operation):
            return action(for: operation)
        case .failure(let error):
            return action(for: error)
        }
    }

    private static func action(for operation: WireGuardOperation) -> ChainedDataPathAction {
        switch operation {
        case .none:
            return .idle
        case .writeToNetwork(let byteCount):
            return .sendToPeer(byteCount: byteCount)
        case .writeToTunnelIPv4(let byteCount):
            return .deliverIPv4(byteCount: byteCount)
        case .writeToTunnelIPv6(let byteCount):
            // Claim-and-drop. The tunnel claims ::/0 precisely so IPv6 cannot leave the
            // device outside the VPN; having claimed it, the packets arrive here and are
            // discarded until the forwarding half lands. Delivering them would be worse
            // than dropping — the tunnel has no IPv6 upstream to have received them from.
            return .dropIPv6(byteCount: byteCount)
        }
    }

    private static func action(for error: WireGuardEngineError) -> ChainedDataPathAction {
        switch error {
        case .protocolViolation, .underLoad, .oversizedDatagram:
            // `oversizedDatagram` is the remotely-reachable half of what used to arrive as
            // `destinationBufferTooSmall`: a datagram larger than our maximum, whose size the
            // SENDER chooses. It is reachable by anyone who can reach our UDP port and by any
            // peer whose tunnel MTU exceeds ours, so it has to stay a per-packet verdict —
            // escalating it would let one hostile packet per second keep a user permanently
            // disconnected, which is the LAV-80 class, and would blame our buffer discipline
            // for someone else's packet.
            return .dropPacket(reason: error)
        case .noCurrentSession:
            // This was `.idle`, on the belief that the engine had queued the packet and
            // would flush it on the next drain. That belief was wrong, and the outbound
            // origin it describes does not exist: `encapsulate` queues the packet and
            // returns handshake output (`noise/mod.rs:250-268`), so it cannot produce this
            // code at all. The only producer is `handle_data` (`noise/mod.rs:414-420`),
            // reached when an INBOUND transport datagram's receiver index maps to an empty
            // session slot — a stale or hostile packet.
            //
            // So it is a per-packet rejection. Reporting it as idleness told the loop there
            // was no work rather than that a datagram had been refused, and lost the reason
            // from drop accounting — which is exactly the signal that distinguishes "the
            // peer went quiet" from "someone is spraying our port".
            return .dropPacket(reason: error)
        case .connectionExpired:
            return .reconnect(reason: error)
        case .invalidArgument, .packetTooLarge, .sessionCreationFailed,
             .destinationBufferTooSmall:
            // `destinationBufferTooSmall` was a per-packet drop while it had two meanings —
            // an undersized scratch buffer OR an oversized inbound datagram from the peer.
            // The wrapper now rejects the remote case as `oversizedDatagram` before the ABI
            // call, so this code keeps exactly one meaning: our own buffer was wrong
            // (`WireGuardSession.swift`, `requireCapacity`). That is not transient and does
            // not clear itself — the packet loop hands over the same undersized buffer every
            // time — so draining it as a drop would silently discard every packet for the
            // life of the session while the tunnel reported itself healthy.
            return .callerBug(reason: error)
        case .engineInternal:
            // A poisoned lock. Not a per-packet condition and not safe to keep driving, so
            // the session ends — but as a reconnect, not a crash: a fresh session gets a
            // fresh lock, so another attempt can genuinely succeed.
            return .reconnect(reason: error)
        case .unrecognized:
            // A status code this wrapper does not know means the Swift declarations and the
            // engine binary disagree — WireGuardSession documents it as an ABI mismatch
            // requiring the header to be resynchronized. That is deterministic: a fresh
            // session runs the same mismatched code and returns the same unknown value, so
            // retrying spends the whole outage budget on an operation that cannot succeed.
            // It ends the session WITHOUT another attempt, which surrenders to DNS-only
            // immediately rather than after a minute of pretending.
            return .callerBug(reason: error)
        }
    }
}

extension ChainedDataPathAction {
    /// Whether this action ends the session.
    public var endsSession: Bool {
        switch self {
        case .reconnect, .callerBug:
            return true
        case .sendToPeer, .deliverIPv4, .dropIPv6, .idle, .dropPacket:
            return false
        }
    }

    /// Whether ending the session should be followed by another attempt.
    ///
    /// `endsSession` alone used to mean "reconnect", which left `.callerBug` with nowhere to
    /// go: it had to return `false` and became behaviourally identical to `.dropPacket` —
    /// same `endsSession`, same `terminatesDrain`, differing only in a log string. A loop
    /// driven by those predicates kept the tunnel reported as healthy while every subsequent
    /// call repeated the same deterministic failure, which is precisely the outcome the
    /// classifier separates caller bugs in order to avoid.
    ///
    /// Splitting the two questions gives the caller-bug case a control flow of its own. A
    /// contract violation is not a network condition, so retrying it in place would burn the
    /// outage budget on an operation that cannot succeed — the session stops, and the tunnel
    /// fails safe to DNS-only rather than pretending to carry traffic it is dropping.
    /// pinned: ChainedDataPathPolicyTests.testACallerBugStopsTheSessionWithoutRetrying
    public var warrantsAnotherAttempt: Bool {
        switch self {
        case .reconnect:
            return true
        case .callerBug, .sendToPeer, .deliverIPv4, .dropIPv6, .idle, .dropPacket:
            return false
        }
    }

    /// Whether a drain loop should stop on this action.
    ///
    /// The engine's drain contract is "call again with an empty source until it stops
    /// returning `WRITE_TO_NETWORK`". Anything that is not another datagram for the peer
    /// terminates the loop — including errors, which must not be retried in place or the
    /// loop spins on a permanent condition.
    public var terminatesDrain: Bool {
        switch self {
        case .sendToPeer:
            return false
        case .idle, .deliverIPv4, .dropIPv6, .dropPacket, .reconnect, .callerBug:
            return true
        }
    }

    /// Stable identifier for device logs. Never user copy.
    public var logValue: String {
        switch self {
        case .sendToPeer:
            return "send-to-peer"
        case .deliverIPv4:
            return "deliver-ipv4"
        case .dropIPv6:
            return "drop-ipv6"
        case .idle:
            return "idle"
        case .dropPacket(let reason):
            return "drop-packet-\(reason.logValue)"
        case .reconnect(let reason):
            return "reconnect-\(reason.logValue)"
        case .callerBug(let reason):
            return "caller-bug-\(reason.logValue)"
        }
    }
}

extension WireGuardEngineError {
    /// Stable identifier for device logs. Never user copy.
    public var logValue: String {
        switch self {
        case .invalidArgument: return "invalid-argument"
        case .destinationBufferTooSmall: return "destination-buffer-too-small"
        case .noCurrentSession: return "no-current-session"
        case .underLoad: return "under-load"
        case .protocolViolation: return "protocol-violation"
        case .oversizedDatagram: return "oversized-datagram"
        case .connectionExpired: return "connection-expired"
        case .engineInternal: return "engine-internal"
        case .packetTooLarge: return "packet-too-large"
        case .sessionCreationFailed: return "session-creation-failed"
        case .unrecognized(let code): return "unrecognized-\(code)"
        }
    }
}
