import Foundation

/// What the two seam adapters need from the tunnel provider.
///
/// A protocol rather than a reference to `PacketTunnelProvider`, and it buys two things. The
/// provider is outside this package, so a direct reference is impossible — but more usefully,
/// the adapters' actual behaviour (the queue hop, the weak reference, the ordering) becomes
/// executable-testable against a double instead of pinned as provider text. The provider
/// conforms with two thin methods that forward to work it already does.
public protocol ChainedTunnelSeamHost: AnyObject, Sendable {
    /// Writes decrypted packets into the tunnel. Called ON the engine queue.
    func writeDecryptedPackets(_ packets: [Data], protocols: [NSNumber])
    /// Serves one client DNS query the carve-out did not claim. Called OFF the engine queue,
    /// on the serving adapter's own queue.
    ///
    /// `lifecycleToken` is the value the adapter was constructed with, so the host can
    /// reject work queued by a RETIRED runtime: provider instances are reused across
    /// starts, and a query still sitting on the serving queue at teardown would otherwise
    /// resolve against the next lifecycle's configuration, mutate its DNS health state and
    /// write a stale answer into its packet flow (Codex, PR #508).
    func serveClientDNSQuery(_ packet: Data, lifecycleToken: UInt64)
}

/// Adapts a tunnel host to ``ChainedTunnelWriter``.
///
/// A SEPARATE OBJECT HOLDING THE HOST WEAKLY, which is the whole reason it exists rather than
/// the host conforming directly. `PacketTunnelProvider` is `final class ... @unchecked
/// Sendable`, so a direct conformance compiles cleanly — but ``ChainedUpstreamSessionFactory``
/// stores its `writer` and `dnsServer` STRONGLY and the provider owns the factory, so the
/// direct route is a retain cycle that keeps an engine, its buffers and the outage driver
/// alive across a session teardown, inside the ~50 MB ceiling (`INV-MEM-1`).
///
/// The arrays pass straight through: `NEPacketTunnelFlow.writePackets` consumes them
/// synchronously, which is what makes the runner's reuse of its own storage safe on this path
/// — see ``ChainedTunnelWriter``.
/// pinned: ChainedTunnelSeamAdapterTests.testTheWriterHoldsTheHostWeakly
/// pinned: ChainedTunnelSeamAdapterTests.testTheWriterForwardsBatchesUnchanged
public final class ChainedTunnelWriterAdapter: ChainedTunnelWriter, @unchecked Sendable {
    private weak var host: ChainedTunnelSeamHost?

    public init(host: ChainedTunnelSeamHost) {
        self.host = host
    }

    public func write(_ packets: [Data], protocols: [NSNumber]) {
        host?.writeDecryptedPackets(packets, protocols: protocols)
    }
}

/// Adapts a tunnel host to ``ChainedDNSServing``, hopping off the caller's queue.
///
/// THE HOP IS THE POINT, not an implementation detail. ``ChainedDNSServing/serveDNS(_:)`` is
/// called synchronously on the engine queue from inside the runner's per-packet batch loop,
/// while that loop holds the queue; the provider's DNS path performs several blocking
/// `dnsStateQueue.sync` reads. Wiring it straight through blocks the engine queue mid-batch —
/// the blackhole the armed watchdog cannot bound, because its handler is enqueued behind the
/// caller on that same serial queue.
///
/// And the hop is deliberately NOT onto `dnsStateQueue`: serving does resolver I/O, so running
/// it there would wedge the DNS state machine for the duration, and `INV-QUEUE-1` forbids
/// coupling the two confinements in the first place. A third serial queue mimics the context
/// `readPackets`' callback used to provide, and being serial it preserves the arrival order of
/// queries — which the DNS path's own fragment and coalescing state assumes.
///
/// The hop is BOUNDED, because it transfers residency as well as control. The runner releases
/// its own admission charge the moment ``serveDNS(_:)`` returns, so every closure waiting here
/// is under no other ceiling — and serving can stall for real stretches (its `dnsStateQueue`
/// hops wait on whatever that queue is doing), while client DNS arrives at line rate. Beyond
/// the ceiling, queries are DROPPED, which is UDP resolver semantics: the client retries a
/// lost datagram, and an answer computed after the client's own timeout is work the ~50 MB
/// process (`INV-MEM-1`) paid for nothing. Drops are tallied, not logged — a flood would
/// otherwise buy log churn with the memory it was denied.
/// pinned: ChainedTunnelSeamAdapterTests.testServingReturnsWithoutRunningOnTheCallersQueue
/// pinned: ChainedTunnelSeamAdapterTests.testQueriesAreServedInArrivalOrder
/// pinned: ChainedTunnelSeamAdapterTests.testTheDNSAdapterHoldsTheHostWeakly
/// pinned: ChainedTunnelSeamAdapterTests.testAStalledServeDropsBeyondTheBacklogCeilingAndRecovers
public final class ChainedDNSServingAdapter: ChainedDNSServing, @unchecked Sendable {
    private weak var host: ChainedTunnelSeamHost?
    private let queue: DispatchQueue
    /// Identifies the runtime this adapter belongs to; travels with every served query.
    private let lifecycleToken: UInt64
    private let admission = ChainedAdmissionGauge(limits: ChainedDNSServingAdapter.backlogLimits)

    /// What the serving backlog may hold before queries are dropped.
    ///
    /// Both ceilings are derived from what a stalled serve can usefully drain later. Bytes:
    /// 128 KiB is ~90 full-MTU queries or several hundred ordinary ones — anything past that
    /// would be answered after every client resolver timeout has already expired. Count: 256
    /// closures binds a flood of minimal queries, whose closure overhead is the real cost and
    /// which the byte ceiling never sees (the same two-ceiling reasoning as the runner's own
    /// admission gauges).
    static let backlogLimits = ChainedAdmissionGauge.Limits(
        maximumBytes: 128 << 10, maximumCount: 256)

    /// - Parameter queue: a SERIAL queue that is neither the engine queue nor `dnsStateQueue`.
    ///   Injected rather than created here so a test can supply one it can observe; production
    ///   passes ``makeServingQueue()``.
    public init(host: ChainedTunnelSeamHost, queue: DispatchQueue, lifecycleToken: UInt64) {
        self.host = host
        self.queue = queue
        self.lifecycleToken = lifecycleToken
    }

    /// The production serving queue: serial, and its own confinement.
    public static func makeServingQueue() -> DispatchQueue {
        DispatchQueue(label: "com.lavasec.tunnel.chained-dns-serving", qos: .userInitiated)
    }

    /// Queries dropped at the backlog ceiling so far. Diagnostics and tests; the provider
    /// reports it at teardown rather than per-drop.
    public func droppedQueryCount() -> Int {
        admission.refusedUnitCount()
    }

    public func serveDNS(_ packet: Data) {
        // The admission check runs HERE, on the caller's thread, before the hop — the gauge's
        // whole design: a closure waiting for the queue is visible to no bound that lives on
        // it. A refused query is dropped silently; the tally is the observability.
        guard admission.admit(bytes: packet.count, units: 1) else { return }
        // ASYNC — a `sync` here would satisfy "hops off the engine queue" and still block it
        // for the whole serve, which is the entire defect wearing a different queue label.
        //
        // The bytes are already the runner's own `Data` copy: the seam takes `Data` rather
        // than a borrow precisely so this hop does not have to reason about a borrowed
        // buffer's lifetime across it.
        queue.async { [weak self] in
            // Released as the closure's first act, per the gauge's contract: from this moment
            // the packet is the running serve's, and at most one serve runs at a time on a
            // serial queue — so the ceiling bounds what WAITS, plus one in flight.
            self?.admission.release(bytes: packet.count)
            guard let self else { return }
            self.host?.serveClientDNSQuery(packet, lifecycleToken: self.lifecycleToken)
        }
    }
}
