import Foundation

/// The chained data path's destination buffers, allocated once and reused for the life of a
/// session.
///
/// `INV-MEM-1` is the reason this type exists rather than two locals. The Network Extension
/// runs under a ~50 MB jetsam ceiling, and the measured co-residency of the filter and a
/// WireGuard session under load was ~14 MB peak — of which roughly 5.5–7 MB was the *loaded
/// data path's* working set: per-packet allocations, encapsulation scratch, `Data` copies and
/// socket buffers. Allocation churn, not steady-state size, is what moves that number, so the
/// data path allocates its buffers at session construction and never again.
///
/// Two buffers, not one, and not three:
///
/// - ``toNetwork`` receives everything travelling outward — `encapsulate`, `tick`,
///   `forceHandshake` and `drain` all write here. One buffer serves all four because they are
///   serialised on a single queue and the bytes are handed to the socket before the next call
///   begins. `drain` in particular must be sized for a DATAGRAM rather than an IP packet: the
///   engine re-encapsulates a packet it queued earlier, whose size is unrelated to whatever
///   inbound datagram prompted the drain.
/// - ``toTunnel`` receives everything travelling inward from `decapsulate`. It is separate
///   because the engine's contract forbids a destination that aliases its source, and because
///   a single inbound datagram can produce a `writeToNetwork` result — a cookie or handshake
///   reply — while the caller still holds the decrypted packet it is about to deliver.
///
/// Both are sized at ``WireGuardSession/maximumDatagramByteCount``, which the engine's buffer
/// discipline names as the one rule that makes its internal panic paths unreachable. Sizing
/// either at the MTU instead would be smaller and wrong.
///
/// This type deliberately does NOT own a packet queue. The engine already queues outbound
/// packets itself while no session is current — heap-copying each one into a 256-entry queue
/// released by `drain(into:)` — so a caller that also queues stores the same bytes twice and
/// retransmits them on drain. Queueing in the chained runner is for a different state
/// entirely: the session is current but the socket is not.
///
/// Not `Sendable`, matching ``WireGuardSession``. The buffers are confined to the same serial
/// queue as the session that writes into them; handing them across a queue hop is the mistake
/// this type is shaped to make awkward.
public final class ChainedDataPathBuffers {
    /// Destination for every outbound engine call: encapsulate, tick, forceHandshake, drain.
    public var toNetwork: [UInt8]
    /// Destination for every inbound engine call: both `decapsulate` forms.
    public var toTunnel: [UInt8]

    /// Allocates both buffers at the engine's required capacity.
    ///
    /// `repeating: 0` rather than `reserveCapacity`: a reserved-but-empty array has a `count`
    /// of zero, and every engine entry point checks `buffer.count` against the required
    /// capacity before it will run. Reserving would throw `destinationBufferTooSmall` on the
    /// first call.
    public init() {
        toNetwork = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        toTunnel = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
    }
}
