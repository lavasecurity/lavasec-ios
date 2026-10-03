import Foundation
import LavaSecKit

/// The seams the runner is driven through, so the data path is executable outside a Network
/// Extension.
///
/// Every one of these is something the packet tunnel supplies in production and a test supplies
/// directly. They exist because the decisions in this file — drain termination, back-pressure,
/// buffer ownership — have expensive failure modes and are otherwise only reachable inside a
/// process that cannot be unit-tested.
public protocol ChainedUpstreamDatagramChannel: AnyObject, Sendable {
    /// Sends one datagram.
    ///
    /// `datagram` is BORROWED for the duration of the call and no longer: an implementation
    /// that needs the bytes afterwards must copy them before returning. The runner sends from
    /// one reused scratch buffer inside `withUnsafeBytes`, and up to ``inFlightSendBound`` sends
    /// may be outstanding at once — so a transport that held the pointer would be reading a
    /// buffer the next encapsulation has already overwritten, and reading it after the pointer
    /// died in any case.
    ///
    /// `completion` reports when the TRANSPORT is ready for more, which is the only thing
    /// back-pressure is measured against. It says nothing about the buffer, which was released
    /// when this call returned.
    func send(_ datagram: UnsafeRawBufferPointer, completion: @escaping @Sendable (Bool) -> Void)
    /// Delivers inbound datagrams. Called on an arbitrary queue.
    func setReceiveHandler(_ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void)
    /// Tears the transport down. Idempotent.
    func close()
}

/// Where decrypted packets go.
///
/// Called on the engine queue. The arrays are the RUNNER'S REUSED instance storage, cleared
/// and refilled before every call — a conformer that retains either past the call forces a
/// copy-on-write allocation on the very next delivered packet, per-packet heap churn inside
/// the ~50 MB NE ceiling (`INV-MEM-1`). `NEPacketTunnelFlow.writePackets` consumes them
/// synchronously, which is why the reuse is safe for the intended implementation; anything
/// that defers must copy first.
public protocol ChainedTunnelWriter: AnyObject, Sendable {
    func write(_ packets: [Data], protocols: [NSNumber])
}

/// Where outbound packets the classifier judges to be DNS go.
///
/// The runner cannot serve DNS and the provider cannot classify it, so this is the seam between
/// them — and it exists because the obvious alternative is a defect. Letting the provider split
/// the batch first with `IPv4UDPDNSPacket` and hand over only the remainder puts the DNS decision
/// somewhere that cannot see ``ChainedResolverPortRegistry``: our own resolver's query IS a
/// well-formed DNS query, so it would be routed to the resolver, which answers it by sending
/// another one. Classification therefore happens exactly once, here, where the carve-out and the
/// fragment table both live.
///
/// No protocol number, deliberately. `NEPacketTunnelFlow` hands one over and this path discards
/// it: the serving host recovers the family from the packet itself (the classifier routes both
/// IPv4 and IPv6 DNS here since F3c), so threading a second, independently-derived value would
/// only invite it to disagree with the bytes.
///
/// ## The queue obligation, which the signature cannot state
///
/// `serveDNS` is called SYNCHRONOUSLY ON THE ENGINE QUEUE, from inside the per-packet batch
/// loop while that loop holds the queue. The implementation must return without blocking:
/// `ChainedSessionSource` forbids blocking this queue because the armed watchdog's handler is
/// enqueued behind the caller on the same serial queue — a blocking implementation is a
/// blackhole the watchdog cannot bound. The provider's natural body performs several blocking
/// `dnsStateQueue.sync` hops, so a conformer must HOP to its own queue — and not to
/// `dnsStateQueue` either, because serving does resolver I/O that would wedge the DNS state
/// machine for its duration (`INV-QUEUE-1` separately forbids coupling the two confinements).
/// A dedicated serial queue mimics the context `readPackets` used to provide and preserves
/// per-query arrival order.
///
/// The hop transfers RESIDENCY as well as control. The runner's own bounded admission is
/// released when `serveDNS` returns, so whatever a conformer enqueues is under no runner
/// ceiling any more — an unbounded backlog behind a stalled serve turns line-rate client DNS
/// into retained copies inside the ~50 MB ceiling (`INV-MEM-1`). A conformer must bound its
/// own backlog and DROP beyond it: UDP DNS is lossy by contract, so a dropped query is a
/// client retry, while an unbounded one is a jetsam.
public protocol ChainedDNSServing: AnyObject, Sendable {
    /// Serves one IPv4 UDP DNS query the carve-out did NOT claim as our own.
    func serveDNS(_ packet: Data)
}

/// A point-in-time read of the engine's transport byte totals, taken on the engine queue and tagged
/// with the driver's session generation.
///
/// It NARROWS `WireGuardSession.statistics()` (itself already `Sendable`) to the fields the data-path
/// health signal needs, and maps its `timeSinceLastHandshake: Duration?` to a plain `hasHandshake`.
/// The engine's `transmittedByteCount`/`receivedByteCount` are CUMULATIVE since the session was
/// created; `forwardedNonDNSByteCount` is a runner tally that additionally RESETS on a channel rebind
/// (it is per-transport evidence — see its field doc). Either way the provider differences consecutive
/// samples into a per-window delta — holding only one prior sample, never a series (`INV-MEM-1`) — and
/// gates engine counters on ``sessionGeneration``. The forwarding tally also carries
/// ``transportGeneration`` so a rebind is distinguishable from corrupt/regressed same-channel
/// evidence. Forwarding samples are comparable only when both identities match (app PR #725).
public struct ChainedRunnerStatistics: Equatable, Sendable {
    /// Plaintext bytes accepted for encapsulation since the session was created.
    public var transmittedByteCount: UInt64
    /// Plaintext bytes produced by decapsulation since the session was created.
    public var receivedByteCount: UInt64
    /// Received bytes that are NOT a DNS reply from the tunnel's own upstream resolver — i.e.
    /// genuine general-traffic forwarding, with the chain's own DNS replies excluded by source
    /// address AND port 53 (not by address alone — a resolver IP that also serves HTTPS still
    /// counts its non-53 bytes; PR #567 follow-up). This, not `receivedByteCount`, is the connect
    /// gate's "the chain carries your traffic" signal: a chain that answers its own resolver but
    /// forwards nothing else relays only DNS bytes, so this stays at 0 and the gate correctly
    /// refuses to confirm (Codex, PR #558).
    public var forwardedNonDNSByteCount: UInt64
    /// Whether a session is currently established (a completed handshake).
    public var hasHandshake: Bool
    /// The driver's session generation at this sample, bumped whenever the driver adopts or rebuilds
    /// the runner. STAMPED BY THE DRIVER — the runner leaves it at its default, because only the
    /// driver owns the session lifecycle. Two samples' byte totals are differenceable only when
    /// these match.
    public var sessionGeneration: UInt64

    /// Channel incarnation for the forwarding tally, advanced on every successful rebind.
    public var transportGeneration: UInt64

    /// Fresh setup evidence stamped by the driver on the same engine queue as these statistics.
    /// This never constitutes returned traffic or establishes general forwarding.
    public var setupReady = false
    /// Driver-owned evidence epoch; a genuine wake can invalidate proof without replacing transport.
    public var verificationEpoch: UInt64 = 0
    /// Cumulative forwarding already present at this epoch's boundary, on this runner/transport.
    public var forwardingBaseline: UInt64 = 0
    /// Current runtime condition; ordinary in-flight demand is normal, not an invalidation.
    public var runtimeCondition: ChainedRuntimeCondition = .normal

    public init(
        transmittedByteCount: UInt64,
        receivedByteCount: UInt64,
        hasHandshake: Bool,
        forwardedNonDNSByteCount: UInt64 = 0,
        sessionGeneration: UInt64 = 0,
        transportGeneration: UInt64 = 0
    ) {
        self.transmittedByteCount = transmittedByteCount
        self.receivedByteCount = receivedByteCount
        self.forwardedNonDNSByteCount = forwardedNonDNSByteCount
        self.hasHandshake = hasHandshake
        self.sessionGeneration = sessionGeneration
        self.transportGeneration = transportGeneration
    }
}

/// One atomic engine-queue observation, including intervals without a current runner.
public struct ChainedDriverStatusEvidence: Equatable, Sendable {
    public let statistics: ChainedRunnerStatistics?
    public let verificationEpoch: UInt64
    public let forwardingBaseline: UInt64
    public let runtimeCondition: ChainedRuntimeCondition
}

/// Tallies the device log reports. Not user copy.
public struct ChainedRunnerCounters: Equatable, Sendable {
    /// Packets delivered to the existing filtered DNS handler, including malformed DNS questions.
    public var dnsHandledPacketCount = 0
    /// Packets rejected by the outbound classifier before any engine admission.
    public var malformedPacketCount = 0
    /// DNS packets rejected because the filtering path cannot safely inspect them.
    public var unfilterableDNSPacketCount = 0
    /// Packets actually refused by the port-853 policy, disjoint from generic DNS drops.
    /// Counts only directly identified headers; fragment continuations retain the generic
    /// category. This is not a query count, flow count, or evidence of successful evasion.
    public var unfilterableEncryptedDNSPacketCount = 0
    /// Actual nonempty packet calls into the engine, excluding handshake/keepalive production.
    /// An attempt is not proof that the engine sent it or the peer forwarded a reply.
    public var encapsulationAttemptCount = 0
    /// Packets refused admission to the outbound queue under pressure.
    public var shedPacketCount = 0
    /// Decrypted packets whose inner source was outside the peer's AllowedIPs.
    public var spoofedSourceCount = 0
    /// Datagrams the ENGINE produced for the peer and this runner handed to the transport —
    /// handshake initiations and keepalives included, because they are what the engine emits
    /// when there is no session yet.
    ///
    /// THE ONLY POSITIVE SEND EVIDENCE IN THE SNAPSHOT, and the reason it exists: a dark
    /// session reads flat everywhere else. `stateNotReadyTransitionCount` counts transitions
    /// INTO `waiting`/`failed`, so a socket that reached `ready` and stayed there never moves it;
    /// `sendFailedEdgeCount` counts failure edges, so successful sends never move it; and
    /// `transmittedByteCount` is PLAINTEXT accepted for encapsulation, which a handshake
    /// initiation is not. So "the engine emitted initiations and the peer never answered" and
    /// "the engine emitted nothing at all" were the same all-zero sample — the exact ambiguity
    /// the recovery-window counters were added to resolve, which they could not without this
    /// (Codex, PR #585).
    /// pinned: ChainedSessionRunnerTests.testAForcedHandshakeCountsAsEngineOutputEvenWithNoSession
    public var sendToPeerCount = 0
    /// OUTBOUND IPv6 packets discarded rather than encapsulated. Never inbound — see
    /// ``droppedInboundIPv6Count``.
    public var droppedIPv6Count = 0
    /// Packets in outbound batches refused BEFORE the queue hop, because the admitted-but-
    /// undrained backlog was at its ceiling. Distinct from ``shedPacketCount``, which counts
    /// refusals by the queue these packets never reached.
    public var refusedOutboundBacklogPacketCount = 0
    /// Inbound datagrams refused before being copied, for the same reason.
    public var refusedInboundBacklogDatagramCount = 0
    /// Times an engine call found the timers stale and drove a catch-up `update_timers` pass.
    ///
    /// A DIAGNOSTIC, and the only observable this guard has. In steady state it stays at zero:
    /// the owner ticks every 250 ms against a 1 s bound. A nonzero value says the tick stopped
    /// while packets were still moving — which is the condition
    /// ``ChainedSessionRunner/engineTimersAreFreshOnQueue()`` exists for, and the only evidence
    /// that it is load-bearing rather than dead code on a device.
    ///
    /// Counted where the pass is DRIVEN, not where staleness is observed, so it counts work done
    /// rather than questions asked.
    /// pinned: ChainedSessionRunnerTests.testACatchUpPassIsCountedSoTheGuardIsObservable
    public var engineTimerCatchUpCount = 0
    /// IPv6 packets the PEER sent us, discarded after decryption.
    ///
    /// Separate from ``droppedIPv6Count`` because the two are faults at opposite ends of the
    /// tunnel and are fixed in different places. Sharing one tally made a device log report an
    /// upstream forwarding inner IPv6 as this client emitting IPv6 it never sent, which points
    /// the diagnosis at the wrong end (Codex, PR #480).
    /// pinned: ChainedSessionRunnerTests.testIPv6DropsAreCountedPerDirection
    public var droppedInboundIPv6Count = 0
    /// PACKETS — not queries — carried by the carve-out.
    ///
    /// Named for what it counts. One TCP resolver retry produces a SYN, the framed query, ACKs
    /// and any retransmissions, so this arm runs several times per DNS question and ordinary
    /// packet loss moves it on its own. An earlier version of this counter was documented as
    /// tracking truncated-answer retries, with a "spike means the registry is admitting packets
    /// it should not" reading; both were wrong, and the second is the kind of wrong that
    /// manufactures false alarms in a device log (Codex, PR #491).
    ///
    /// It is still worth having separately from the general encapsulation count: it is the only
    /// number that says the carve-out is being used at all, and a nonzero value while no
    /// resolver work is outstanding is still worth looking at — it just needs correlating with
    /// resolver activity rather than read as a query rate.
    ///
    /// Precisely: packets the carve-out CARRIED. Incremented where the packet is handed to the
    /// engine, not where it is classified, because a packet parked under back-pressure is
    /// re-classified on release — counting at classification tallied it twice, and counted a
    /// packet whose claim expired while parked despite it never being carried.
    /// pinned: ChainedSessionRunnerTests.testAnOwnResolverQueryIsEncapsulatedAndCounted
    public var ownResolverPacketCount = 0

    /// Send completions the transport answered with an error, on the CURRENT channel.
    ///
    /// The Bool the channel completion already carries, finally counted instead of discarded —
    /// the brief-stall investigation (2026-08-24) found a user-visible forwarding stall across
    /// which every surfaced counter stayed flat, and this was one of the two transport-failure
    /// signals the runner was throwing away (the other is the connection's own state, which is
    /// the channel's telemetry observer's job). A retired channel's late completion is NOT
    /// counted, for the same reason it may not resume the new channel's slots: it is evidence
    /// about a socket that no longer exists.
    ///
    /// A tally, not a remedy — the existing resume behaviour is unchanged on error, because a
    /// failed send still frees its in-flight slot.
    /// pinned: ChainedSessionRunnerTests.testAFailedSendCompletionIsCountedAndStillFreesItsSlot
    /// pinned: ChainedSessionRunnerTests.testARetiredChannelsFailedCompletionIsNotCountedAgainstTheNewChannel
    public var sendCompletionErrorCount = 0

    /// Delivered inbound bytes that are NOT a DNS reply from the tunnel's own upstream resolver —
    /// the genuine general-traffic forwarding the connect gate keys "Protected" on. Only an actual
    /// DNS reply is EXCLUDED — source ADDRESS the configured resolver AND transport source port 53
    /// (`ChainedInboundDNSReply`, PR #567 follow-up), not the address alone — so a resolver IP that
    /// also serves HTTPS still accrues its non-53 bytes, while a chain that answers its resolver but
    /// forwards nothing else never accrues this and cannot false-confirm (Codex, PR #558).
    /// UInt64 because it feeds a byte-threshold gate; the others are Int event tallies.
    public var forwardedNonDNSByteCount: UInt64 = 0

    // The per-destination reachability LEVELS. Not tallies: they are stamped at snapshot from
    // `ChainedDestinationTable`, the way the driver stamps `isSuspended`, so a consumer must
    // ASSIGN them from the live runner rather than accumulate them across retired ones. A
    // retired session's unanswered destination is not a fact about the live session, and adding
    // the two would report a wait that nothing is still waiting on.
    // pinned: ChainedSessionRunnerTests.testTheReachabilityLevelsAreStampedFromTheLiveTable
    // pinned: ChainedOutageDriverTests.testTheReachabilityLevelsAreAssignedFromTheLiveRunnerNotAccumulated

    /// How many in-tunnel destinations are currently under sustained demand with nothing coming
    /// back — `ChainedDestinationReachability.unanswered`. Zero is the healthy reading.
    ///
    /// The signal a split-tunnel chain had no way to produce. `forwardedNonDNSByteCount` cannot
    /// answer it there: PR #558 empties the resolver exclusion in split tunnel, so that counter
    /// includes DNS replies, and in the 2026-08-27 field capture it stood at 338311 — equal to
    /// `receivedByteCount` to the byte — while the one host the user wanted answered nothing.
    public var unansweredDestinationCount = 0

    /// The longest current unanswered wait in seconds, or zero when none. Carries no address:
    /// the duration is the reportable half, and a tailnet address names the user's network as
    /// surely as a resolver address does.
    public var longestUnansweredDestinationSeconds = 0

    public init() {}
    // Aggregate the two bounded runners; reachability duration is a maximum, not a tally.
    mutating func addStackCounters(_ other: Self) {
        dnsHandledPacketCount &+= other.dnsHandledPacketCount
        malformedPacketCount &+= other.malformedPacketCount
        unfilterableDNSPacketCount &+= other.unfilterableDNSPacketCount
        unfilterableEncryptedDNSPacketCount &+= other.unfilterableEncryptedDNSPacketCount
        encapsulationAttemptCount &+= other.encapsulationAttemptCount
        shedPacketCount &+= other.shedPacketCount
        spoofedSourceCount &+= other.spoofedSourceCount
        sendToPeerCount &+= other.sendToPeerCount
        droppedIPv6Count &+= other.droppedIPv6Count
        refusedOutboundBacklogPacketCount &+= other.refusedOutboundBacklogPacketCount
        refusedInboundBacklogDatagramCount &+= other.refusedInboundBacklogDatagramCount
        engineTimerCatchUpCount &+= other.engineTimerCatchUpCount
        droppedInboundIPv6Count &+= other.droppedInboundIPv6Count
        ownResolverPacketCount &+= other.ownResolverPacketCount
        sendCompletionErrorCount &+= other.sendCompletionErrorCount
        forwardedNonDNSByteCount &+= other.forwardedNonDNSByteCount
        unansweredDestinationCount &+= other.unansweredDestinationCount
        longestUnansweredDestinationSeconds = max(longestUnansweredDestinationSeconds, other.longestUnansweredDestinationSeconds)
    }

}

/// A data-path pressure moment, emitted AT the eviction or refusal rather than inferred from a
/// 60 s counter delta — telemetry only, decided nowhere.
///
/// The tallies already exist (`ChainedPacketQueue.shedPacketCount`, the admission gauges'
/// refused counts) and stay authoritative; what they cannot carry is WHEN. A brief forwarding
/// stall is sub-60 s by definition, so a counter that moved somewhere inside the window cannot
/// be correlated with the blip the user saw — the event's log timestamp is the correlation
/// (brief-stall investigation, 2026-08-24).
///
/// Emitted UNTHROTTLED, on the failure paths only — under sustained overload that is one
/// closure call per shed arrival, on a path already copying and dropping. The consumer owns
/// rate-bounding what it LOGS (`ChainedTransportDiagnosticsRecorder`), so the volume never
/// reaches the log file while the tallies still record it exactly.
public enum ChainedDataPathPressureEvent: Equatable, Sendable {
    /// The bounded outbound queue evicted older packets — or refused the arrival — while
    /// absorbing a park at the send bound. `admission` is `ChainedQueueAdmission.logValue`.
    case outboundQueuePressure(admission: String, queueDepth: Int)
    /// A whole outbound batch was refused at the dispatch boundary because the
    /// admitted-but-undrained backlog was at its ceiling.
    case outboundBacklogRefused(packets: Int, bytes: Int)
    /// An inbound datagram was refused at the dispatch boundary, before the copy.
    case inboundBacklogRefused(bytes: Int)
}

/// Owns one WireGuard session and everything that touches it.
///
/// ## Queue confinement is the whole design
///
/// `WireGuardSession` documents that the engine "has no internal concurrency design; confine
/// all calls for one instance to a single serial queue", and is deliberately not `Sendable`.
/// This runner is that queue's owner. It is `@unchecked Sendable` because it does NOT inherit
/// sendability from the session it holds — it establishes it, by never letting the session or
/// the scratch buffers escape `queue`.
///
/// Never `dnsStateQueue` (`INV-QUEUE-1`). The DNS state machine and the engine are two
/// independent confinements, and hanging the engine off the DNS queue would couple a
/// crypto-bound loop to the queue that answers queries.
///
/// ## Why the entry point takes a BATCH
///
/// `NEPacketTunnelFlow.readPackets` hands back parallel arrays, and the whole batch hops to
/// this queue once. Branching per packet in the provider's callback would either allocate a
/// closure per packet or copy each packet into a queue to cross the hop — both of which are
/// exactly the per-packet churn `INV-MEM-1` forbids, and neither is visible to a test that
/// lives below the queue boundary.
///
/// ## Buffer ownership
///
/// Two scratch buffers, allocated once in `init` and never resized: outbound for
/// `encapsulate`/`drain`, inbound for `decapsulate`. Sized at the engine's required capacity by
/// `ChainedDataPathBuffers`. The write batch is one reused `[Data]`/`[NSNumber]` pair cleared
/// with `removeAll(keepingCapacity:)`.
///
/// The runner does NOT queue during the pre-handshake window. The engine already heap-copies
/// outbound packets into its own 256-entry queue while no session is current and releases them
/// through `drain(into:)` — calling `encapsulate` transfers ownership. Queueing as well would
/// store the same bytes twice and retransmit them on drain. This runner's queue exists for a
/// different state entirely: the session is current but the CHANNEL is not taking bytes.
///
/// Pinned on the DUPLICATE, which is the only observable that separates the two designs. Two
/// weaker ones were tried and both are blind: queue depth is back to zero before any assertion
/// runs, because a packet stored here as well is released by the very next completion; and the
/// datagram count is blind because `format_handshake_initiation(dst, false)` answers `Done`
/// while a handshake is already in progress, so re-encapsulating a double-stored packet emits
/// nothing. Both were mutation-checked against a runner that double-stores and both passed it.
/// What does not pass is the peer: two copies in the engine's queue drain as two data packets
/// once a session exists.
/// pinned: ChainedSessionRunnerTests.testThePreHandshakeWindowIsTheEnginesQueueNotOurs
public final class ChainedSessionRunner: @unchecked Sendable {
    /// The engine queue, OWNED BY THE TUNNEL rather than by this runner.
    ///
    /// A tunnel lifecycle outlives its sessions — the outage budget spans attempts and a fresh
    /// runner is built per attempt — so several runners and the driver's timers share one
    /// queue. The key that answers "am I on it?" therefore belongs to the queue; see
    /// ``ChainedEngineQueue`` for what goes wrong when each runner keeps its own.
    private let engineQueue: ChainedEngineQueue
    private var queue: DispatchQueue { engineQueue.queue }
    private let session: WireGuardSession
    /// The store generation whose key material built ``session``.
    ///
    /// IMMUTABLE FOR THE RUNNER'S LIFE, because the credentials are read once per build — so
    /// while this runner exists, this IS the rotation the engine is running, and reading it
    /// cannot fail.
    ///
    /// NOT ON ``ChainedRunnerStatistics``, which is where it started. That type is built from
    /// `session.statistics()`, which can throw — so an engine error made `sampleStatistics()`
    /// return nil for a runner that plainly exists, the provider read that as "no chained
    /// session", and the freshness panel went silent for as long as the error persisted. Runner
    /// identity must not be contingent on a fallible transport read (Codex P2, PR #613).
    public let acceptedUpstreamGeneration: UInt64
    private let buffers = ChainedDataPathBuffers()
    private let interceptInbound: (@Sendable (Data) -> Bool)?
    private var channel: ChainedUpstreamDatagramChannel
    /// Which transport the runner is on.
    ///
    /// Every send completion and every receive handler carries the generation it was installed
    /// for, and a closure from a retired generation is INERT. That is what makes
    /// `outstandingSends` mean the current socket's back-pressure and an inbound datagram
    /// attributable to the socket that carried it — both of which were true by accident while a
    /// channel lived exactly as long as its session, and stop being true the moment one can be
    /// replaced (R2).
    private var channelGeneration = 0
    private let writer: ChainedTunnelWriter
    private let allowedIPs: ChainedAllowedIPs
    /// The tunnel's own upstream DNS resolver address(es), as host prefixes. A delivered packet
    /// whose source matches AND whose transport source port is 53 is a DNS reply to our own
    /// resolver, NOT general forwarding — so its bytes are excluded from `forwardedNonDNSByteCount`,
    /// the connect gate's evidence. A resolver IP that also serves ordinary traffic (HTTPS on the
    /// same address) still contributes its non-53 bytes as forwarding — the port-aware exclusion is
    /// in `deliverOnQueue` via ``ChainedInboundDNSReply`` (PR #567 follow-up). Empty (the default)
    /// means nothing is excluded (every delivery counts), which is the pre-tighten behaviour tests
    /// rely on.
    private let resolverSourceAddresses: ChainedAllowedIPs
    private let peer: WireGuardPeerAddress

    private var outboundQueue: ChainedPacketQueue
    /// Sends handed to the channel whose completion has not come back.
    ///
    /// A COUNT, not a boolean. The first version gated on "a send is in flight", which
    /// serialised the whole data path behind one completion: every packet after the first
    /// parked, so a steady state ran entirely through the back-pressure queue — copying every
    /// packet, which is the churn `INV-MEM-1` forbids, in the mechanism meant to protect it.
    /// UDP has no such ordering requirement. Back-pressure is the transport falling BEHIND,
    /// which is outstanding sends piling up, not one being in progress.
    private var outstandingSends = 0
    /// Whether the engine may still be holding packets it queued before a session existed.
    ///
    /// Set on any engine output and cleared the moment a drain returns something that is not a
    /// send. It exists so the drain can STOP at the send bound and be resumed by a completion
    /// rather than running to exhaustion in one go.
    private var enginePacketsPending = false
    /// Guards ``releaseStored`` against re-entering itself.
    ///
    /// Not a lock — everything here is already queue-confined. It converts a recursion into an
    /// extra pass of the loop that is already running; see ``releaseStored``.
    private var isReleasing = false
    /// One outbound batch the send bound interrupted, held by REFERENCE.
    ///
    /// See ``processOutboundOnQueue``. At most one, and it is the array the tunnel handed over,
    /// so holding it costs a retain rather than a copy per packet. Bounded by
    /// ``maximumParkedBatchBytes``, because a retain is not a bound.
    private struct PendingBatch {
        let packets: [Data]
        let index: Int
    }
    private var pendingBatch: PendingBatch?
    /// The reassembly identities whose first fragment the classifier dropped as unfilterable
    /// DNS, so their continuations are dropped too.
    ///
    /// Held HERE rather than inside the classifier because it is per-tunnel state and the
    /// classifier is a pure function. It lives on the runner queue like everything else, which
    /// is also what makes `inout` access to it safe without a lock.
    private var droppedFragments = ChainedDroppedFragmentTable()
    /// The source ports this process holds for its own tunnel-pinned resolver queries.
    ///
    /// PROCESS-LIFETIME, not runner-lifetime, which is why it is injected rather than owned
    /// here. `ChainedOutageDriver` rebuilds the runner per attempt, and a runner-held registry
    /// would forget an in-flight retry's port at exactly the moment a reconnect happens — the
    /// retry would then be dropped as unfilterable DNS by the very carve-out meant to carry it.
    private let ownResolverPorts: ChainedResolverPortRegistry
    /// Whether outbound port 853 (DoT/DoQ) is dropped as unfilterable. True only for a full
    /// tunnel; see ``ChainedOutboundPacketClassifier/disposition(for:fragments:ownResolverPorts:claimedResolverDestinations:dropsUnfilterableEncryptedDNS:reclaimsStaleDenials:)``.
    private let dropsUnfilterableEncryptedDNS: Bool
    /// The F4 capture-floor destinations the plan claimed; a `:853` flow to one is refused even in
    /// split. A LIVE box, read per packet rather than copied at construction: the provider
    /// republishes it when the route plan is rebuilt, so the drop tracks the same resolver capture
    /// the routes do. See ``ChainedClaimedResolverDestinationsStore``.
    private let claimedResolverDestinations: ChainedClaimedResolverDestinationsStore
    /// Where `.handleAsDNS` goes. See ``ChainedDNSServing`` for why the runner cannot decide it.
    private let dnsServer: ChainedDNSServing
    /// Where pressure moments go, or nil for none. See ``ChainedDataPathPressureEvent`` — a
    /// telemetry sink, called on whatever thread the pressure happened on (the dispatch-boundary
    /// refusals run on the PRODUCER'S thread, before the hop), and never consulted for a decision.
    private let diagnostics: (@Sendable (ChainedDataPathPressureEvent) -> Void)?
    /// Set by a completion that fired synchronously, read once the buffer borrow has ended.
    ///
    /// An instance property rather than a local, because the completion is `@Sendable` and
    /// cannot mutate a captured `var` — and rather than a box, because a per-send allocation on
    /// the hot path is the churn `INV-MEM-1` forbids.
    private var sawInlineCompletion = false
    /// Whether a `channel.send` call is on the stack right now, at any depth.
    ///
    /// "On the engine queue" stopped being the same question as "inside the send call" the
    /// moment the queue became shared and public (S8.5b): a channel may legitimately schedule
    /// its completions onto it, and such a completion runs as its OWN queue item, after
    /// ``sendOnQueue`` has already read and cleared ``sawInlineCompletion``. Treating it as
    /// inline set a flag nobody would read, so `channelResumed()` never ran, `outstandingSends`
    /// never fell, and after sixteen sends the runner parked everything forever against a
    /// transport that was answering every one (Codex, PR #482).
    ///
    /// A depth counter rather than a Bool because a completion that fires inline re-enters
    /// `sendOnQueue` through `releaseStored`, so sends nest; the flag has to describe the whole
    /// stack, not the innermost frame.
    /// pinned: ChainedSessionRunnerTests.testACompletionDispatchedOntoTheSharedQueueStillFreesItsSlot
    private var sendDepth = 0
    private var writeBatch: [Data] = []
    private var writeProtocols: [NSNumber] = []
    private var counters = ChainedRunnerCounters()
    /// Where this session reports its own death.
    private let events: ChainedSessionEvents
    /// Set once a session-ending action has been reported. Terminal, because the engine repeats
    /// its verdict and a retired session must not keep producing news.
    private var hasEnded = false
    /// Set by ``shutdown()``.
    ///
    /// Distinct from ``hasEnded`` because they mean different things — the session died on its
    /// own, versus the owner retired it — and because only this one has to silence work already
    /// queued on a SHARED engine queue.
    private var isShutDown = false
    /// What the data path has seen since the owner last looked. Read-and-cleared.
    private var liveness = ChainedLivenessSample()
    /// When `update_timers` last ran, on the ENGINE's clock.
    ///
    /// Seeded at construction rather than left at zero: a fresh session's timers are current by
    /// definition, and a zero seed would make the very first packet trigger a catch-up pass
    /// against a `Tunn` that was built microseconds ago. See ``engineClockNanoseconds()`` for why
    /// this is not on the same clock as the blackhole budget.
    private var lastTimerPassAtEngineNanoseconds: UInt64
    /// Reads ``engineClockNanoseconds()`` in production, and a test's own counter in tests.
    ///
    /// Injected because the guard is otherwise unreachable from a test without sleeping for a real
    /// second, and a guard nothing can exercise is a guard nothing can show to be load-bearing.
    /// Production takes the default and reads the engine's clock; the DOMAIN question — that the
    /// default is the same clock boringtun uses — is not what this seam answers and cannot be, so
    /// it is pinned separately against the vendored source.
    private let engineClock: @Sendable () -> UInt64

    /// The clock the destination table's windows are measured on — the UPTIME base, NOT the
    /// engine's.
    ///
    /// A private instance rather than the driver's, and that is safe precisely because no
    /// absolute reading ever leaves this object: the table's instants are compared only against
    /// later readings of this same clock, and what crosses the boundary is a DURATION. Sharing
    /// the driver's would mean threading it through `ChainedSessionSource`; borrowing
    /// ``engineClock`` would mean measuring a user-visible wait on a base that keeps running
    /// while the device sleeps (see ``ChainedMonotonicClock``), so a phone asleep overnight would
    /// wake up reporting eight hours of silence.
    private let reachabilityClock: ChainedMonotonicClock

    /// Per-destination send/receipt accounting. Engine-queue confined, like every other counter
    /// here. NOT reset on a channel rebind the way `forwardedNonDNSByteCount` is: a rebind keeps
    /// the WireGuard session, so the user is still waiting on the same host and the wait they are
    /// living through is exactly what this measures. A session REBUILD gets a fresh runner and
    /// therefore a fresh table, which is honest — a new session is a new chance to answer.
    /// pinned: ChainedSessionRunnerTests.testAChannelRebindDoesNotForgetAnUnansweredDestination
    private var destinations = ChainedDestinationTable()

    // Engine-queue confined, sampled atomically with the tally. A rebind keeps the WG session
    // but resets its forwarding evidence; that reset must not look like regressed old evidence
    // to Guard (Round 7 device incident, app PR #725).
    private var forwardingTransportGeneration: UInt64 = 1

    /// - Parameters:
    ///   - session: the engine, which this runner takes sole ownership of.
    ///   - peer: built ONCE, not per datagram. The channel is connected, so provenance is a
    ///     constant — and `WireGuardPeerAddress.init?(octets:)` takes an `Array`, which on the
    ///     inbound hot path would be an allocation per packet.
    ///   - queueLimits: `nil` is rejected rather than force-unwrapped; a queue with no limits
    ///     is not a smaller queue, it is an unbounded one inside a jetsam ceiling.
    ///   - claimedResolverDestinations: the LIVE box of F4 capture-floor destinations the plan
    ///     claimed; a `:853` flow to one is refused even in split. The runner holds the box and
    ///     reads it per packet, so the provider's reapply republish takes effect without a
    ///     rebuild. Defaults to a fresh empty box.
    public init?(
        session: WireGuardSession,
        peer: WireGuardPeerAddress,
        allowedIPs: ChainedAllowedIPs,
        resolverSourceAddresses: ChainedAllowedIPs = ChainedAllowedIPs([]),
        channel: ChainedUpstreamDatagramChannel,
        writer: ChainedTunnelWriter,
        dnsServer: ChainedDNSServing,
        queueLimits: ChainedPacketQueueLimits?,
        engineQueue: ChainedEngineQueue,
        events: ChainedSessionEvents,
        ownResolverPorts: ChainedResolverPortRegistry,
        dropsUnfilterableEncryptedDNS: Bool = false,
        claimedResolverDestinations: ChainedClaimedResolverDestinationsStore = ChainedClaimedResolverDestinationsStore(),
        engineClock: @escaping @Sendable () -> UInt64 = ChainedSessionRunner.engineClockNanoseconds,
        reachabilityClock: ChainedMonotonicClock = ChainedUptimeClock(),
        diagnostics: (@Sendable (ChainedDataPathPressureEvent) -> Void)? = nil,
        acceptedUpstreamGeneration: UInt64 = 0,
        interceptInbound: (@Sendable (Data) -> Bool)? = nil
    ) {
        guard let queueLimits else { return nil }
        self.interceptInbound = interceptInbound
        self.acceptedUpstreamGeneration = acceptedUpstreamGeneration
        self.diagnostics = diagnostics
        self.engineClock = engineClock
        self.reachabilityClock = reachabilityClock
        self.lastTimerPassAtEngineNanoseconds = engineClock()
        self.ownResolverPorts = ownResolverPorts
        self.dropsUnfilterableEncryptedDNS = dropsUnfilterableEncryptedDNS
        self.claimedResolverDestinations = claimedResolverDestinations
        self.dnsServer = dnsServer
        self.engineQueue = engineQueue
        self.events = events
        self.session = session
        self.peer = peer
        self.allowedIPs = allowedIPs
        self.resolverSourceAddresses = resolverSourceAddresses
        self.channel = channel
        self.writer = writer
        self.outboundQueue = ChainedPacketQueue(limits: queueLimits)
        writeBatch.reserveCapacity(32)
        writeProtocols.reserveCapacity(32)
        let generation = channelGeneration
        channel.setReceiveHandler { [weak self] datagram in
            self?.receive(datagram, generation: generation)
        }
    }

    /// The tallies, read from anywhere.
    ///
    /// The shed count is READ FROM THE QUEUE rather than tallied here, so the two cannot
    /// disagree. They did: this counted only admissions the queue refused outright, while a
    /// full queue under sustained pressure reports `.admittedAfterEvicting` — kept the packet,
    /// dropped an older one. `wasQueued` is true for that case, so the runner's count stayed at
    /// zero through exactly the overload it exists to report, and the device log said "no
    /// shedding" while the queue discarded a packet per arrival.
    /// pinned: ChainedSessionRunnerTests.testEvictionUnderSustainedPressureIsReportedAsShedding
    public func snapshotCounters() -> ChainedRunnerCounters {
        onQueue {
            var snapshot = self.counters
            snapshot.shedPacketCount = self.outboundQueue.shedPacketCount
            snapshot.refusedOutboundBacklogPacketCount = self.outboundAdmission.refusedUnitCount()
            snapshot.refusedInboundBacklogDatagramCount = self.inboundAdmission.refusedUnitCount()
            let reachability = self.reachabilityOnQueue()
            snapshot.unansweredDestinationCount = reachability.count
            snapshot.longestUnansweredDestinationSeconds = reachability.longestSeconds
            return snapshot
        }
    }

    /// The engine's cumulative transport byte totals, read on the engine queue — the same
    /// confinement as ``snapshotCounters()``. `statistics()` does NOT error on a missing session:
    /// with no established session it returns a nil handshake time, surfaced here as
    /// `hasHandshake == false`; `nil` is returned only if the engine call genuinely errors.
    /// `sessionGeneration` is left at its default — the driver stamps the live value in
    /// ``ChainedOutageDriver/snapshotStatistics()``. Diagnostics/health only; never on the packet path.
    public func sampleStatistics() -> ChainedRunnerStatistics? {
        onQueue {
            guard let stats = try? session.statistics() else { return nil }
            return ChainedRunnerStatistics(
                transmittedByteCount: stats.transmittedByteCount,
                receivedByteCount: stats.receivedByteCount,
                hasHandshake: stats.timeSinceLastHandshake != nil,
                // The runner's own tally (engine stats can't distinguish DNS from general traffic).
                // Read on the engine queue, the same confinement `deliverOnQueue` writes it under.
                forwardedNonDNSByteCount: counters.forwardedNonDNSByteCount,
                transportGeneration: forwardingTransportGeneration)
        }
    }

    /// Folds ``ChainedDestinationReachabilityPolicy`` over the destination table.
    ///
    /// Runs at SNAPSHOT cadence (the driver's 500 ms tick and the health poll), never on the
    /// packet path, and at most `ChainedDestinationTable.capacity` evaluations. Engine-queue
    /// confined by its callers.
    ///
    /// The worst wait rather than a sum, because the two numbers answer different questions and
    /// only this pair is honest: a count says how much of the chain is silent, and the longest
    /// wait says how bad the worst of it is. Adding the durations would produce a figure that
    /// grows with the number of hosts and means nothing about any of them.
    private func reachabilityOnQueue() -> (count: Int, longestSeconds: Int) {
        let now = reachabilityClock.nowSeconds()
        var count = 0
        var longest = 0
        for destination in destinations.destinations {
            guard
                case .unanswered(let seconds) = ChainedDestinationReachabilityPolicy.verdict(
                    for: destination.observation, atSeconds: now)
            else { continue }
            count += 1
            longest = max(longest, seconds)
        }
        return (count, longest)
    }

    /// Current outbound queue depth. Diagnostics and tests only.
    public func queuedPacketCount() -> Int {
        onQueue { self.outboundQueue.count }
    }

    // MARK: - Driven by the owner

    /// Drives handshake retries, keepalives and rekeys, sending whatever the engine produces.
    ///
    /// The engine's timers only advance when this is called: `ConnectionExpired` is produced
    /// exclusively from `update_timers`, so a session that is never ticked cannot report its own
    /// death, however long it has been dead.
    ///
    /// `buffers.toNetwork` is already sized at the engine's datagram ceiling, comfortably past
    /// the control-message floor, so this adds no allocation (`INV-MEM-1`).
    public func tick() {
        onQueue {
            guard !isShutDown, !hasEnded else { return }
            driveTimersOnQueue()
        }
    }

    /// One `update_timers` pass, and the stamp that records it happened.
    ///
    /// Split out of ``tick()`` so the freshness guard can drive a catch-up pass without
    /// re-entering the owner's entry point — the owner's tick carries the driver's own
    /// quiescence rules (``ChainedOutageDriver/tick()`` decides nothing while suspended), and a
    /// catch-up pass is not the owner deciding anything. It is this runner refusing to use keys
    /// the engine would have retired if it had been asked.
    private func driveTimersOnQueue() {
        // THE STAMP IS WRITTEN BEFORE THE TICK, and that ordering is what makes the guard
        // non-recursive rather than merely tidy.
        //
        // `perform` can reach the engine again from inside this call: a `.sendToPeer` goes to the
        // transport, a completion that fires inline resumes the parked cursor, and a released
        // packet is re-classified straight back into `encapsulateOnQueue` — which consults the
        // guard again. Stamping first means that re-entrant consultation reads a fresh clock and
        // returns immediately, so the recursion is bounded at depth one by construction.
        //
        // It also means the bound must be STRICTLY POSITIVE. At zero, `now &- last >= 0` holds
        // even immediately after a stamp, the re-entrant call drives another pass, and the runner
        // recurses until the stack is gone — observed as a crash when the bound was mutated to
        // zero during verification, which is the evidence that this ordering is load-bearing.
        // pinned: ChainedSessionRunnerTests.testAStalledBatchDrivesOnePassNotOnePerPacket
        lastTimerPassAtEngineNanoseconds = engineClock()
        let outcome = Result { try session.tick(into: &buffers.toNetwork) }
            .mapError { $0 as? WireGuardEngineError ?? .invalidArgument }
        perform(ChainedDataPathPolicy.action(for: outcome))
    }

    /// How stale the engine's timers may be at the moment we use its keys.
    ///
    /// Four times the owner's 250 ms tick (`ChainedOutageDriver.outageTickInterval`), so
    /// ordinary scheduling jitter never triggers a catch-up pass and only a real stall does.
    /// It bounds excess key lifetime past `REJECT_AFTER_TIME`, which is why it is a small
    /// multiple of the tick rather than a fraction of the 60 s slack between
    /// `REKEY_AFTER_TIME` and `REJECT_AFTER_TIME`: the slack says how much room the protocol
    /// leaves, not how much of it we are entitled to spend.
    static let engineTimerFreshnessBoundNanoseconds: UInt64 = 1_000_000_000

    /// The engine's own clock, read in the engine's own denomination.
    ///
    /// NOT ``ChainedMonotonicClock``, and the difference is the whole correctness of the guard
    /// above it. That clock is the UPTIME base (`CLOCK_UPTIME_RAW`, via
    /// `DispatchTime.uptimeNanoseconds`), which does not advance while the system is asleep —
    /// deliberately, because it is the base `DispatchSourceTimer` can be armed against, which
    /// is what discharges `C1`. boringtun's timers are on `sleepyinstant::Instant`, which
    /// selects `CLOCK_MONOTONIC` for `target_os = "ios"`
    /// (`ThirdParty/wireguard-core/boringtun/src/sleepyinstant/unix.rs`) — a different clock
    /// with a different origin, measurably so: the two read 7.5 seconds apart on the machine
    /// this was written on.
    ///
    /// So measuring staleness on the budget's clock would compare a duration against a session
    /// age counted on another base. After a suspension the budget clock reports almost no
    /// elapsed time while the engine's has advanced by the whole sleep — the guard would read
    /// "fresh", every test written against it would pass, and the one case it exists for would
    /// be exactly the case it missed.
    ///
    /// Calling the SAME clock is what makes the comparison exact, rather than an argument about
    /// which Darwin clock counts sleep. `ChainedEngineClockSourceTests` pins the engine's
    /// selection so an engine upgrade that changes clocks fails a test instead of silently
    /// desynchronising this one.
    /// `public` only because it is this initialiser's default argument, which Swift requires to be
    /// at least as visible as the initialiser. Not API anyone outside is expected to call.
    /// pinned: ChainedEngineClockSourceTests.testTheEngineStillSelectsTheClockThisRunnerReads
    public static func engineClockNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    /// Refuses to use the engine's keys until its timers have been asked the time, and reports
    /// whether the session survived being asked.
    ///
    /// ## The gap this closes
    ///
    /// `REJECT_AFTER_TIME` retires a session, and boringtun enforces it in exactly one place:
    /// `update_timers`. `Tunn::encapsulate` takes `self.current` and formats a packet
    /// (`boringtun/src/noise/mod.rs:250`); `Tunn::handle_data` looks the session up by index and
    /// decrypts (`mod.rs:406`). Neither consults a timer — both only *stamp* them. So retirement
    /// is not a property the session enforces on itself, it is a consequence of somebody calling
    /// `update_timers` punctually, and a session whose timers have gone unasked keeps encrypting
    /// and accepting on a keypair past its specified lifetime, silently.
    ///
    /// Unlike the receive-counter ceiling in `lava_wg_decapsulate` (PR #496) this needs no
    /// attacker at all — only our own tick missing while packets still flow. `ChainedOutageDriver`
    /// guards `tick()` on `!isQuiesced` but `handleOutboundBatch` has no such guard, so the
    /// window between a `sleep()` and its paired `wake()` is one where the engine can be driven
    /// with nothing advancing its timers.
    ///
    /// ## Why the guard sits at the engine call and not at the batch entry
    ///
    /// A batch-entry check would be cheaper and would need an argument that no suspension
    /// boundary can fall between the check and the encapsulations it covers. That argument is
    /// false — the process can be frozen mid-closure — and "a narrower placement is safe" is the
    /// claim that had to be withdrawn three times in this file during S8.8b. At 19 ns per clock
    /// read there is no cost worth buying the argument with, so the guard goes where it cannot be
    /// bypassed: immediately before every engine entry point that uses session keys.
    ///
    /// `forceHandshake` is deliberately NOT guarded, and it is the one exclusion that is not
    /// arbitrary: `format_handshake_initiation` is the single engine entry point that DOES consult
    /// `is_expired()`, clearing the timers itself when it fires (`mod.rs:442`). Guarding it would
    /// be a second opinion on the one question the engine already answers.
    ///
    /// ## What the residual window is, exactly
    ///
    /// A suspension can still land between this consult returning and the engine call it
    /// covers — no in-process check can be atomic with a freeze, including the engine's own
    /// internal ones. What placement buys is a BOUND on the exposure: at most the single
    /// engine call already in flight across the freeze uses the old keypair, because every
    /// subsequent call re-consults a stamp the freeze has made stale, and the owner's 250 ms
    /// tick retires the session independently on resume. One datagram at epsilon past a
    /// lifetime that already carries WireGuard's own 60-second rekey-to-reject margin is not
    /// a meaningful extension of key life; the seconds-to-hours windows this guard closes
    /// were. Taking the exposure to ZERO means enforcing expiry inside the `lava_wg_*` ABI
    /// itself, atomically with key use — the receive-counter ceiling (PR #496) is the
    /// precedent — and that is an engine-rebuild slice of its own, not a placement change
    /// here.
    ///
    /// Returns `false` when the catch-up pass retired the session, in which case the caller must
    /// not touch the engine — the pass has already reported the end through ``events``.
    ///
    /// THAT RETURN IS NOT COVERED BY AN EXECUTABLE TEST, and it is load-bearing rather than
    /// belt-and-braces: `encapsulate` would happily use the retired keypair, since not consulting
    /// a timer is the whole defect this guard is about. It is untested because this runner holds a
    /// real `WireGuardSession` — the fixture drives actual handshakes between two engines rather
    /// than a mock — and reaching `ConnectionExpired` needs `REKEY_ATTEMPT_TIME` (90 s) or
    /// `REJECT_AFTER_TIME` (180 s) of engine time, which no unit test can spend. Covering it would
    /// mean putting the engine behind a protocol so a double could return a session-ending
    /// outcome on demand; that is a larger change than this fix should carry, and it is worth
    /// doing on its own terms rather than as a side effect.
    /// pinned: ChainedSessionRunnerTests.testAStalledTickCannotEncapsulateOnAnUnaskedSession
    /// pinned: ChainedSessionRunnerTests.testAStalledTickCannotDecapsulateOnAnUnaskedSession
    /// pinned: ChainedSessionRunnerTests.testAResumedDrainConsultsTheTimersBeforeUsingTheKeys
    private func engineTimersAreFreshOnQueue() -> Bool {
        guard engineTimersAreStaleOnQueue() else { return true }
        counters.engineTimerCatchUpCount += 1
        driveTimersOnQueue()
        return !isShutDown && !hasEnded
    }

    /// The staleness reading alone, with no pass and no counter.
    ///
    /// Split out for the one caller that must ask WITHOUT acting: the inbound path at the
    /// send bound, where driving the pass would let its emission bypass the in-flight limit
    /// and not driving it would decapsulate on unasked timers — so the datagram is dropped
    /// instead, and the reading is all that decision needs.
    ///
    /// `&-` for the same reason the clock file gives: a trap inside a Network Extension is a
    /// tunnel abort. A wrapped reading produces one spurious catch-up pass, which is
    /// harmless — `update_timers` is what the owner calls every 250 ms anyway.
    private func engineTimersAreStaleOnQueue() -> Bool {
        engineClock() &- lastTimerPassAtEngineNanoseconds
            >= Self.engineTimerFreshnessBoundNanoseconds
    }

    /// Replaces the transport, preserving the engine.
    ///
    /// THE POINT OF R2. `Tunn` holds keys, an index and a packet queue — no socket and no
    /// endpoint (`boringtun/src/noise/mod.rs`), and `peer` here derives from the REMOTE
    /// endpoint rather than our local address. So a path change invalidates the socket and
    /// nothing else, and replacing just the socket costs one keepalive on the existing keypair
    /// instead of a handshake, a retry delay and a ladder rung.
    ///
    /// THE KEEPALIVE IS GATED, and the gate is the whole reason this returns an outcome rather
    /// than Void. `encapsulate` emits a keepalive only while a keypair is current; with none it
    /// QUEUES the empty packet and returns a handshake initiation, which answers `Done` when a
    /// handshake is already in flight — zero bytes on the new socket, no counter, no event. A
    /// path change landing in a rekey window is exactly that case, so it is reported as
    /// ``ChainedRebindOutcome/noCurrentSession`` and the caller rebuilds rather than believing
    /// a probe went out. `timeSinceLastHandshake != nil` is not a proxy for "a keypair is
    /// current" — it is that condition.
    ///
    /// The keepalive is `.unobliging` ON PURPOSE. The peer owes nothing for an empty keepalive
    /// — ``ChainedSessionEvents`` says so — so arming the silence clock on it would be waiting
    /// for an answer that was never due, and would manufacture an outage on a healthy link 21
    /// seconds later. Confirming the rebind is the driver's job, with its own bounded deadline.
    /// pinned: ChainedSessionRunnerTests.testAdoptingAChannelWithNoKeypairReportsItRatherThanProbing
    /// pinned: ChainedSessionRunnerTests.testARetiredChannelsLateCompletionCannotResumeTheNewOne
    public func adoptChannel(_ replacement: ChainedUpstreamDatagramChannel) -> ChainedRebindOutcome {
        onQueue {
            guard !isShutDown, !hasEnded else {
                replacement.close()
                return .refused
            }
            // A send is on the stack, which means the scratch buffer is lent to the OUTGOING
            // channel right now. Closing it there is the overlapping mutable access this file
            // restructured `sendOnQueue` to avoid. Refusing is fail-safe and synchronous; the
            // caller falls back to a full rebuild, which is what it would have done anyway.
            guard sendDepth == 0 else {
                replacement.close()
                return .refused
            }

            // EVERY CLOSURE CAPTURED BEFORE THIS LINE IS NOW INERT.
            channelGeneration += 1
            let generation = channelGeneration

            // Closed BEFORE the new one is installed, and unconditionally. `close()` is
            // idempotent per channel, so closing twice is safe; closing zero times leaks a bound
            // UDP port with its receive loop still re-arming itself.
            channel.close()
            channel = replacement
            replacement.setReceiveHandler { [weak self] datagram in
                self?.receive(datagram, generation: generation)
            }

            // Back-pressure is a property of the CURRENT socket. The retired channel's slots are
            // gone with it, and its late completions can no longer touch this count.
            outstandingSends = 0
            sawInlineCompletion = false

            // Forwarding evidence is a property of the CURRENT transport too. A rebind does NOT bump
            // `sessionGeneration` (the WG session persists), so without this the connect gate would keep
            // differencing `forwardedNonDNSByteCount` across the channel swap and could certify
            // "Protected" from bytes the RETIRED channel forwarded while the replacement socket has
            // received nothing and is about to miss its rebind deadline (Codex, PR #558). Reset it so
            // the gate requires evidence from the transport that is live NOW.
            counters.forwardedNonDNSByteCount = 0
            forwardingTransportGeneration += 1

            // FRESHNESS BEFORE THE KEYPAIR QUESTION, because the catch-up pass can change the
            // answer to it: a rebind following a suspension is exactly when the session the
            // statistics call is about has already outlived `REJECT_AFTER_TIME`. Asking first and
            // freshening second would probe a keypair the engine would have retired.
            //
            // `.noCurrentSession` is the honest outcome when the pass retires the session — it is
            // the vocabulary the caller already handles for "swapped, but nothing to probe", and
            // it routes to a rebuild rather than to a confirmation that cannot arrive. The pass
            // has already reported the end through `events`.
            guard engineTimersAreFreshOnQueue() else { return .noCurrentSession }
            guard (try? session.statistics())?.timeSinceLastHandshake != nil else {
                return .noCurrentSession
            }
            // CONSULTED AGAIN, immediately before the engine call that uses the keys. The
            // consult above is for the KEYPAIR question — the pass it can drive changes the
            // statistics answer. A suspension can still land between that statistics read and
            // this encapsulation, and the engine's clock advances through it, which is the
            // same mid-closure argument that puts the guard at every engine call rather than
            // at an entry point (Codex, PR #497). Fresh-path cost is one clock read; the stale
            // branch is reachable only across that freeze, so like the retest in
            // `releaseStored` it is enforced by the argument — no fixture can suspend a held
            // queue between two statements.
            guard engineTimersAreFreshOnQueue() else { return .noCurrentSession }
            // THE PROBE RESPECTS THE BOUND TOO. Either consult above can emit a timer
            // datagram, and its `perform` runs `releaseStored()` — which can hand the
            // REPLACEMENT channel a pending batch and a parked queue up to the bound before
            // control returns here. This encapsulation does not go through
            // `encapsulateOnQueue`'s post-pass check, so without a recheck it would raise
            // `outstandingSends` past the hard limit (Codex, PR #497). Reported as `.rebound`
            // rather than refused: every send that filled the bound went out on the
            // replacement — `outstandingSends` was reset for it a few lines up — and user
            // traffic is `.obliging`, so the path is being probed harder than the keepalive
            // would have, by datagrams the peer actually owes an answer to.
            // pinned: ChainedSessionRunnerTests.testARebindWhoseConsultFillsTheChannelSkipsTheProbe
            guard outstandingSends < Self.inFlightSendBound else { return .rebound }
            let outcome = Result { try session.encapsulate([], into: &buffers.toNetwork) }
                .mapError { $0 as? WireGuardEngineError ?? .invalidArgument }
            perform(ChainedDataPathPolicy.action(for: outcome), origin: .unobliging)
            return .rebound
        }
    }

    /// Emits a handshake initiation so the session comes up without waiting for traffic.
    public func forceHandshake() {
        onQueue {
            guard !isShutDown, !hasEnded else { return }
            let outcome = Result { try session.forceHandshake(into: &buffers.toNetwork) }
                .mapError { $0 as? WireGuardEngineError ?? .invalidArgument }
            perform(ChainedDataPathPolicy.action(for: outcome), origin: .obliging)
        }
    }

    /// Reads and CLEARS what the data path has seen since the last call.
    ///
    /// Read-and-clear rather than a level, because the owner is asking "since when I last
    /// looked", and a flag that stays set credits one packet forever — a peer that answered
    /// once an hour ago would read as flowing indefinitely.
    public func takeLivenessSample() -> ChainedLivenessSample {
        onQueue {
            var sample = liveness
            liveness = ChainedLivenessSample()
            // A LEVEL, read at sample time rather than latched: the transport being wedged right
            // now is the condition that makes an obliging send impossible, so a stale edge would
            // report a saturation that had already cleared.
            sample.sendChannelSaturated = outstandingSends >= Self.inFlightSendBound
            return sample
        }
    }

    /// Retires this runner: closes the transport and makes everything already in flight inert.
    ///
    /// The latch is what the shared engine queue makes necessary. `receive` copies at the
    /// boundary and hops, so datagrams accepted before teardown are already queued behind
    /// whatever runs next — including the REPLACEMENT session's work. Without this they would
    /// decapsulate on a retired session and write the abandoned peer's packets into the tunnel,
    /// after the owner had decided that peer was gone and, at the end of the budget, after
    /// surrender.
    /// pinned: ChainedSessionRunnerTests.testAShutDownRunnerWritesNothingFromDatagramsAlreadyInFlight
    public func shutdown() {
        onQueue {
            guard !isShutDown else { return }
            isShutDown = true
            pendingBatch = nil
            outboundQueue.removeAll()
            channel.close()
        }
    }

    // MARK: - Outbound

    /// Sends a provider-built IPv4 UDP/53 packet directly through the established engine.
    /// Unready or saturated engines refuse immediately: DNS must not wait in a packet queue
    /// after its caller's deadline, and this path never grants client packets a DNS carve-out.
    public func sendResolverPacket(_ packet: Data, deadline: MonotonicDeadline) -> Bool {
        onQueue {
            guard !isShutDown, !hasEnded, !deadline.hasExpired(),
                  packet.count >= 28, packet.count <= 1260,
                  packet[0] == 0x45, packet[9] == UInt8(IPPROTO_UDP),
                  packet[22] == 0, packet[23] == 53,
                  engineTimersAreFreshOnQueue(),
                  (try? session.statistics().timeSinceLastHandshake) != nil,
                  outstandingSends < Self.inFlightSendBound,
                  !deadline.hasExpired() else { return false }
            return packet.withUnsafeBytes {
                encapsulateOnQueue($0, isOwnResolverQuery: true, allowsParking: false)
            }
        }
    }

    // Only the stack's connected nested transport calls this seam. The packet is
    // already a WireGuard UDP envelope, not client DNS, and must not count as user
    // forwarding evidence. No parking: the nested engine owns retry/backpressure.
    func sendTransportPacket(_ packet: Data) -> Bool {
        onQueue {
            guard !isShutDown, !hasEnded, packet.count <= WireGuardSession.maximumIPPacketByteCount,
                  engineTimersAreFreshOnQueue(), outstandingSends < Self.inFlightSendBound,
                  (try? session.statistics().timeSinceLastHandshake) != nil else { return false }
            let outcome = Result { try packet.withUnsafeBytes { try session.encapsulate($0, into: &buffers.toNetwork) } }
                .mapError { $0 as? WireGuardEngineError ?? .invalidArgument }
            perform(ChainedDataPathPolicy.action(for: outcome), origin: .obliging)
            if case .success = outcome { return true }; return false
        }
    }

    /// What the outbound dispatch backlog may hold before batches are refused.
    ///
    /// Both ceilings are derived, not chosen. Bytes: twice ``maximumParkedBatchBytes`` — the
    /// backlog is the same kind of transient as the parked cursor, and a caller pacing itself
    /// on completions (the provider's readPackets loop) keeps at most one batch in flight, so
    /// two ceiling-sized batches waiting already means the producer has stopped listening.
    /// Count: sixteen closures is an order of magnitude past that legitimate cadence, and it is
    /// what bounds a runaway producer of EMPTY batches, which the byte ceiling never sees.
    static let outboundAdmissionLimits = ChainedAdmissionGauge.Limits(
        maximumBytes: 2 * maximumParkedBatchBytes, maximumCount: 16)

    /// What the inbound dispatch backlog may hold before datagrams are refused.
    ///
    /// A datagram is at most an MTU plus encapsulation overhead, so 512 KiB is ~350 full-size
    /// datagrams of decrypt backlog — seconds of flood, far past any burst the engine drains
    /// in normal operation. The count ceiling is what actually binds under a flood of MINIMAL
    /// datagrams (a keepalive is 32 bytes): 1024 closures ≈ a few hundred KB of closure
    /// overhead the byte ceiling cannot see. Dropping under either is UDP semantics — the
    /// protocol's loss handling, engine included, exists for exactly this.
    static let inboundAdmissionLimits = ChainedAdmissionGauge.Limits(
        maximumBytes: 512 << 10, maximumCount: 1024)

    /// Internal (not private) so tests can saturate a ceiling deterministically rather than by
    /// racing the queue.
    let outboundAdmission = ChainedAdmissionGauge(limits: ChainedSessionRunner.outboundAdmissionLimits)
    let inboundAdmission = ChainedAdmissionGauge(limits: ChainedSessionRunner.inboundAdmissionLimits)

    /// Classifies and encapsulates one batch from the tunnel.
    ///
    /// One hop for the whole batch — see the type's note on why this is not per packet.
    ///
    /// ADMISSION RUNS HERE, on the caller's thread, before the hop. A closure waiting for the
    /// queue is visible to no bound on the queue — see ``ChainedAdmissionGauge`` — so a caller
    /// outrunning the runner grew an unbounded backlog of retained batches. Refusal drops the
    /// batch outright. The byte measurement is O(count) on header words only, paid by the
    /// producer, not the queue.
    ///
    /// THE CHARGE IS HELD UNTIL PROCESSING RETURNS, not returned as the closure's first act,
    /// and the difference is the whole bound. Releasing on entry left the ACTIVE batch
    /// uncounted while its array was still retained and scanned — so a producer of batches
    /// larger than ``maximumParkedBatchBytes`` (which cannot park, and so are scanned end to
    /// end) kept one unbounded array active while the emptied gauge admitted the next one
    /// behind it, and repeated it at every queue transition. Two unbounded arrays resident
    /// against a 2 MiB ceiling, inside a ~50 MB process (`INV-MEM-1`).
    ///
    /// Held to the end, every retention site is covered by exactly one bound with no gap
    /// between them: the gauge covers a batch from arrival until processing returns, and after
    /// that the only thing still holding it is the parked cursor, which has its own residency
    /// ceiling and admits at most one. `defer` so the shutdown latch below cannot leak a
    /// charge — a gauge that ratchets shut is an outbound blackhole.
    /// pinned: ChainedSessionRunnerTests.testABatchArrivingAtASaturatedBacklogIsRefusedAndCounted
    /// pinned: ChainedSessionRunnerTests.testTheBacklogGaugeReadsZeroOnceTheQueueHasDrained
    /// pinned: ChainedSessionRunnerTests.testAnOversizedBatchStaysChargedWhileItIsBeingProcessed
    public func handleOutboundBatch(_ packets: [Data], protocols: [NSNumber]) {
        let batchBytes = packets.reduce(0) { $0 + $1.count }
        guard outboundAdmission.admit(bytes: batchBytes, units: packets.count) else {
            // The gauge has already tallied the refusal; this names its MOMENT in the log.
            diagnostics?(.outboundBacklogRefused(packets: packets.count, bytes: batchBytes))
            return
        }
        queue.async { [self] in
            defer { outboundAdmission.release(bytes: batchBytes) }
            guard !isShutDown, !hasEnded else { return }
            processOutboundOnQueue(packets, from: 0)
        }
    }

    /// Classifies a batch, stopping at the send bound rather than copying the rest away.
    ///
    /// ## Why the CURSOR is what gets parked
    ///
    /// Running a batch to completion made its LENGTH decide congestion. Channel completions
    /// arrive on another queue and hop back to this one, so nothing can decrement
    /// `outstandingSends` while this loop holds the queue: past 16 packets the remainder was
    /// copied into the back-pressure queue, and past 272 that queue began evicting — with a
    /// transport that had been keeping up the whole time. Copying and packet loss, caused by
    /// how much the tunnel happened to hand over at once.
    ///
    /// Yielding on a timer or a stride does not fix it, because the loop cannot tell a slow
    /// transport from a busy queue: re-dispatching the remainder either spins while the
    /// transport is genuinely stalled, or lands behind the very completions it was waiting for.
    /// So the batch is not re-dispatched at all. Its position is remembered and released by a
    /// completion, exactly like a parked packet — the difference being that a cursor into a
    /// copy-on-write `[Data]` costs one retain, not one heap copy per packet (`INV-MEM-1`). The
    /// bytes are the array `NEPacketTunnelFlow` already allocated, and at most ONE batch is held,
    /// of bounded size: a second batch arriving while the first is stalled takes the copying path
    /// into the bounded queue, which is what that queue is for, and so does a first batch too
    /// large to hold — see ``maximumParkedBatchBytes``, which is why "held by reference" is not
    /// by itself an answer to `INV-MEM-1`.
    /// pinned: ChainedSessionRunnerTests.testALargeBatchDoesNotManufactureItsOwnBackPressure
    private func processOutboundOnQueue(
        _ packets: [Data],
        from start: Int,
        isResumption: Bool = false
    ) {
        var index = start
        // Once a claim has been refused it cannot be admitted later in the same call, so the
        // O(count) residency measurement runs at most once. Every disqualifier is monotone here:
        // the array does not change, `pendingBatch` stays as it is, and the first packet that
        // takes the copying path leaves the queue non-empty. Nothing sends while the bound is
        // held either — `encapsulateOnQueue` only parks — so `outstandingSends` cannot fall back
        // below the bound and re-open the question.
        var cursorRefused = false
        while index < packets.count {
            // THE CURSOR IS CLAIMED ONLY WHEN IT WOULD BE THE OLDEST THING WAITING, which is
            // what makes releasing it first correct rather than merely convenient.
            //
            // `pendingBatch == nil` alone was not enough, and the sequence that breaks it is
            // short: batch A stalls and claims the cursor, batch B arrives and parks, A resumes
            // and finishes — clearing the cursor while B is still parked — and then batch C
            // arrives at the bound and claims the now-free cursor. C is newer than B and was
            // released first, and under sustained traffic a new C per completion window starves B
            // until the queue evicts it. "Age order by construction" was the claim and it was
            // false.
            //
            // Requiring the queue to be EMPTY restores it: the cursor can only be taken when
            // nothing older is parked, so the cursor is older than every parked packet for as
            // long as it exists. A resumption is exempt — it re-claims the batch it is already
            // in the middle of, which is by definition older than anything parked behind it.
            //
            // A resumption is also exempt from the RESIDENCY ceiling below, for the same reason:
            // it re-claims an array that already passed it, and the answer cannot have changed.
            //
            // RE-CHECKED EVERY ITERATION, not once at the entry point. A packet in the middle
            // of this batch can end the session — an oversized one classifies as `.callerBug` —
            // and `sessionEnded` is delivered synchronously, so by the time control returns here
            // the owner has typically already called `shutdown()` and built a replacement. A
            // latch tested only at the hop lets the RETIRED runner finish the batch, driving an
            // engine and a channel that belong to a session nobody is listening to.
            // pinned: ChainedSessionRunnerTests.testABatchStopsAtThePacketThatEndsTheSession
            if isShutDown || hasEnded { return }
            if outstandingSends >= Self.inFlightSendBound, !cursorRefused {
                if isResumption
                    || (pendingBatch == nil && outboundQueue.isEmpty
                        && Self.fitsParkedBatchCeiling(packets))
                {
                    pendingBatch = PendingBatch(packets: packets, index: index)
                    return
                }
                cursorRefused = true
            }
            // A resumption is a RE-classification of a packet that has been waiting, so newer
            // denials may already be in the table — it may not reclaim, for the same reason the
            // release path may not. Re-evaluated per packet because this loop parks as it goes.
            let mayReclaim = !isResumption && pendingBatch == nil && outboundQueue.isEmpty
            // THE REGISTRY DECIDES, NOT THIS CALL SITE. Earlier versions narrowed here —
            // first-classification, then first-arrival, then not-a-resumption — and each
            // narrowing was wrong for a reason the last one did not cover. The question was
            // never WHERE a packet is being classified; it is whether the port was ours recently
            // enough that a packet carrying it may still be in flight, and only
            // `ChainedResolverPortRegistry` can answer that.
            //
            // With `wasRecentlyClaimed` in the classifier, an own-resolver query whose claim
            // lapsed or was released while it waited classifies as `.dropUnfilterableDNS` — the
            // loop is closed by the predicate rather than by refusing to serve. Suppressing here
            // as well discarded LEGITIMATE client queries: every packet after the 16-send cursor
            // in a large batch is classified on resumption, so a never-claimed client query
            // sitting there was silently dropped, and so were its retries under repeated large
            // batches (Codex, PR #495).
            // pinned: ChainedSessionRunnerTests.testAClientQueryAfterTheSendBoundIsStillServed
            let packet = packets[index]
            let consumed = packet.withUnsafeBytes {
                classifyAndAct($0, mayReclaim: mayReclaim, dnsPacket: packet)
            }
            // A DECLINED packet re-enters the loop at the SAME index. The decline means the
            // freshness pass inside `encapsulateOnQueue` consumed the last transport slot after
            // this loop's bound check ran, and this loop's park logic is the only place that can
            // put the packet back in the cursor WITH the rest of its batch — anywhere else and
            // either the arrival order breaks or the remainder is forced onto the copying path.
            // Progress is guaranteed: the re-test sees the bound full and either parks the
            // cursor or, refused, the entry check inside `encapsulateOnQueue` parks the packet
            // in the queue — both consume.
            // pinned: ChainedSessionRunnerTests.testATimerPassThatConsumesTheLastSlotParksThePacket
            if !consumed { continue }
            index += 1
        }
    }

    /// The most one parked cursor may hold resident, and deliberately NOT the queue's budget.
    ///
    /// Holding the batch by reference costs no allocation, but a retain is not a bound. `[Data]`
    /// keeps EVERY element alive, including the ones already sent, so the resident cost of a
    /// cursor at index 900 of a 1000-packet batch is all 1000 payloads — for as long as the
    /// transport stays stalled. `NEPacketTunnelFlow.readPackets` documents no ceiling on how much
    /// it hands over at once, so "at most one batch" bounds the COUNT of arrays and nothing about
    /// their size, inside a process capped at ~50 MB (`INV-MEM-1`).
    ///
    /// The queue's own budget is the wrong ceiling, and adopting it would undo the cursor rather
    /// than bound it. That budget is `engineQueueDepth * mtu`, so for MTU-sized packets "over
    /// budget" means "longer than 256 packets" — which is exactly the batch-length-causes-loss
    /// failure the cursor exists to remove, reintroduced by the check meant to make it safe. The
    /// pinned test below sheds 144 packets against a transport that was keeping up if this
    /// constant is replaced by `outboundQueue.limits.maximumPackets`.
    /// pinned: ChainedSessionRunnerTests.testALargeBatchDoesNotManufactureItsOwnBackPressure
    ///
    /// So the ceiling is a residency decision instead of a queueing one. ~1 MB is 2% of the
    /// process ceiling for a transient the process is already holding, and at the chained plan's
    /// 1280-byte MTU it is over 800 packets — past anything the interface hands over in one go,
    /// so ordinary traffic never reaches it. What it does bound is the arrival that would
    /// otherwise pin arbitrary memory behind a stalled socket; that one takes the copying,
    /// shedding path, like every other packet the transport is behind on.
    /// pinned: ChainedSessionRunnerTests.testABatchTooLargeToHoldTakesTheBoundedPathInstead
    static let maximumParkedBatchBytes = 1 << 20

    /// Whether the WHOLE array is small enough to hold by reference while the transport is
    /// stalled.
    ///
    /// Measured over the entire batch, not the unsent suffix. The suffix is the intuitive
    /// measurement and it is wrong: the cursor retains the ARRAY, which retains every element in
    /// it, so a suffix measurement reports a fraction of what is actually held and admits exactly
    /// the batch it was added to refuse.
    ///
    /// O(count), run at most once per batch and only after the send bound is already hit with an
    /// otherwise-claimable cursor — the rare path by construction. The early exit makes the case
    /// that refuses cheaper than the case that admits.
    private static func fitsParkedBatchCeiling(_ packets: [Data]) -> Bool {
        var bytes = 0
        for packet in packets {
            bytes += packet.count
            if bytes > maximumParkedBatchBytes { return false }
        }
        return true
    }

    /// Classifies one packet and acts on the verdict.
    ///
    /// Shared by arrival and by RELEASE, and that sharing is the point. Classification used to
    /// happen once, when the packet arrived — which was fine until the fragment deny-list made
    /// a verdict depend on what the classifier had already seen. Back-pressure then broke it:
    /// a batch stalling before it reached a DNS fragment head, while a later batch carrying the
    /// matching TAIL ran to completion behind it, classified the tail against a table that did
    /// not yet know about the head. The tail parked as ordinary traffic and was released
    /// straight to the engine, forwarding the DNS bytes the table exists to suppress.
    ///
    /// Re-classifying on release costs one pure function call per parked packet — no I/O, no
    /// allocation — and makes the verdict a function of the table as it stands when the packet
    /// actually leaves, which is the only moment that matters.
    /// pinned: ChainedSessionRunnerTests.testAParkedTailIsReclassifiedAgainstTheHeadThatOvertookIt
    ///
    /// ## Why the classifier is told whether this is release order
    ///
    /// Re-classifying on release fixed the direction where a tail is judged before its head is
    /// known. The mirror case leaks, and it arrived with the tuple reclaim: while a batch is
    /// parked, a NEWER permitted fragment head is still classified at arrival, and if it clears
    /// a denial, the older parked DNS tail is later re-classified against a table that no longer
    /// denies it — its query bytes going to the peer (Codex, PR #480).
    ///
    /// ONLY A FIRST CLASSIFICATION WITH NOTHING PARKED MAY RECLAIM, and the two weaker rules
    /// tried before it were both wrong in ways worth keeping written down, because "this packet
    /// is the oldest" turned out not to be the property that matters.
    ///
    /// The table does not see one order. A DROP mutates it at ARRIVAL and is never queued —
    /// there is nothing left to release — while a forward's reclaim would happen at RELEASE. So
    /// a released head is not the oldest thing that has touched the table: a NEWER DNS head can
    /// have arrived, been dropped, and recorded its denial while that head sat in the queue. A
    /// release that reclaims then deletes a denial from the future, and the newer datagram's
    /// tails go to the peer with their query bytes (Codex, PR #480).
    ///
    /// Requiring an empty queue on the release path does not save it either: the emptiness says
    /// nothing about denials recorded while the packet waited.
    ///
    /// What remains is the case with no ambiguity at all — a packet classified for the first
    /// time when nothing is parked. Nothing older can be awaiting classification, and nothing
    /// newer can have touched the table, because on a serial queue this packet IS the newest
    /// thing that has happened.
    ///
    /// The cost is that under sustained back-pressure the reclaim is off, so a permitted flow
    /// reusing a denied tuple keeps losing its tails until the entry is evicted. That is
    /// fail-CLOSED — traffic lost, not query bytes leaked — which is the direction this
    /// subsystem chooses everywhere else.
    /// pinned: ChainedSessionRunnerTests.testAHeadOvertakingAParkedTailDoesNotReleaseItsDenial
    /// pinned: ChainedSessionRunnerTests.testAReleasedHeadDoesNotDeleteADenialRecordedWhileItWaited
    /// pinned: ChainedSessionRunnerTests.testAResumedCursorHeadDoesNotDeleteADenialRecordedWhileItWaited
    ///
    /// `dnsPacket` is the packet's own bytes when this is the FIRST classification of it, and nil
    /// when it is a re-classification. That is not a convenience — it is what makes serving DNS
    /// first-pass-only structural rather than a flag a later edit can flip.
    ///
    /// THE RELEASE PATH MUST NOT SERVE DNS. `releaseStored` re-classifies a packet that was
    /// parked as ordinary traffic, and a parked own-resolver query whose claim expired while it
    /// waited re-classifies as `.handleAsDNS`. Handing THAT to the resolver is the self-resolution
    /// loop by another route: our own query, served by us, answered by sending another. The
    /// carve-out closed the front door (PR #494) and this is the side one.
    ///
    /// A resumed BATCH is a first classification, not a re-classification, and the distinction is
    /// worth stating because the reclaim rule treats them alike. `pendingBatch` is stored BEFORE
    /// the packet at its cursor is classified, so a resumption classifies that packet for the
    /// first time; it may not RECLAIM because the table moved while it waited, which is a
    /// different question from whether the packet has been seen.
    /// pinned: ChainedSessionRunnerTests.testAResumedBatchDoesNotServeAQueryWhoseClaimLapsed
    /// Returns whether the packet was consumed. Only the two encapsulating dispositions can
    /// decline — see ``encapsulateOnQueue(_:isOwnResolverQuery:)`` — every other arm's decision
    /// is final by definition.
    private func classifyAndAct(
        _ bytes: UnsafeRawBufferPointer, mayReclaim: Bool, dnsPacket: Data?
    ) -> Bool {
        switch ChainedOutboundPacketClassifier.disposition(
            for: bytes, fragments: &droppedFragments, ownResolverPorts: ownResolverPorts,
            claimedResolverDestinations: claimedResolverDestinations.latest(),
            dropsUnfilterableEncryptedDNS: dropsUnfilterableEncryptedDNS,
            reclaimsStaleDenials: mayReclaim) {
        case .encapsulate:
            return encapsulateOnQueue(bytes)
        case .encapsulateOwnResolverQuery:
            // Our own retry, carved out of the TCP/53 drop. Encapsulated exactly like ordinary
            // traffic — the ONLY difference from `.encapsulate` is that it is counted, which is
            // what makes the carve-out visible in a device log.
            //
            // COUNTED AT ADMISSION TO THE ENGINE, not here. Under back-pressure this packet is
            // parked and `releaseStored()` RE-CLASSIFIES it, so counting on the classification
            // tallies the same packet twice; and a packet whose claim expired while parked
            // would be counted despite never being carried. `mayReclaim` cannot stand in for
            // "this is a re-classification" — the first pass also passes false whenever
            // something is already parked (Codex, PR #491).
            return encapsulateOnQueue(bytes, isOwnResolverQuery: true)
        case .dropOutboundIPv6:
            counters.droppedIPv6Count += 1
            return true
        case .handleAsDNS:
            // HANDED BACK OUT, not dropped. This arm used to `break` alongside the two drops,
            // which was right while nothing fed this runner: the provider still parsed DNS itself
            // and the chained path was unreachable. With the batch arriving here first, dropping
            // would blackhole every query the tunnel is supposed to filter (`INV-DNS-1`).
            // pinned: ChainedSessionRunnerTests.testAClientDNSQueryIsServedRatherThanDropped
            if let dnsPacket {
                counters.dnsHandledPacketCount += 1
                dnsServer.serveDNS(dnsPacket)
            }
            return true
        case .dropUnfilterableDNS:
            counters.unfilterableDNSPacketCount += 1
            return true
        case .dropUnfilterableEncryptedDNS:
            // Count the actual refusal once, without a second packet observer or an inferred
            // bypass. The packet is consumed here and never enters the engine or send backlog.
            counters.unfilterableEncryptedDNSPacketCount += 1
            return true
        case .dropMalformed:
            counters.malformedPacketCount += 1
            // Decisions the classifier already made — a query it cannot filter, and a packet no
            // reader can act on. Forwarding either would undo the decision.
            return true
        }
    }

    /// Returns whether this call took ownership of the packet: encapsulated it, parked it, or
    /// dropped it with a retired session.
    ///
    /// `false` is one narrow outcome — the freshness pass consumed the last transport slot
    /// AFTER the entry decision was made — and it deliberately hands the packet's placement
    /// back to the CALLER. Parking here instead would put a mid-batch packet into the queue
    /// while its own batch can still claim the cursor: released cursor-first, that is a
    /// reorder of the arrival order `releaseStored` pins; and refusing the cursor to prevent
    /// it would push the whole remainder onto the copying path, which can shed a batch the
    /// transport was keeping up with. The batch loop re-runs the same index instead, so the
    /// packet stays with its batch under the loop's own park logic (Codex, PR #497).
    private func encapsulateOnQueue(
        _ packet: UnsafeRawBufferPointer, isOwnResolverQuery: Bool = false, allowsParking: Bool = true
    ) -> Bool {
        // BACK-PRESSURE ONLY. If the channel is behind the bytes are parked; otherwise they
        // go straight to the engine, which owns the pre-handshake window itself.
        if outstandingSends >= Self.inFlightSendBound {
            guard allowsParking else { return false }
            parkInOutboundQueue(packet)
            return true
        }
        // BELOW the back-pressure decision and ABOVE the carve-out tally, and both halves of that
        // placement are load-bearing.
        //
        // Below the park, because parking is a transport decision that says nothing about keys —
        // driving a timer pass for a packet that is not reaching the engine on this pass would
        // count work the guard did not need to do.
        //
        // Above the tally, for the reason the tally's own comment gives: a catch-up pass here can
        // retire the session and drop this packet, so incrementing first would tally a packet that
        // was never handed over — the same double-count that comment records fixing, reintroduced
        // in a new place.
        //
        // A packet dropped by the retiring pass is CONSUMED: its loss model is the session end
        // the pass has already reported, and the caller's own latch checks stop the batch.
        guard engineTimersAreFreshOnQueue() else { return true }
        // RE-CHECKED, not merely checked: the catch-up pass above can itself send — a keepalive
        // or retransmission emitted by `update_timers` takes a transport slot through the same
        // `perform` as everything else — and the back-pressure decision at the top of this
        // method was made before the pass ran. With the transport one slot short of its bound,
        // proceeding would put this packet past the hard in-flight limit exactly when the
        // transport is nearly saturated (Codex, PR #497). Declined, not parked — see the doc
        // comment for why the placement belongs to the caller.
        // pinned: ChainedSessionRunnerTests.testATimerPassThatConsumesTheLastSlotParksThePacket
        // pinned: ChainedSessionRunnerTests.testArrivalOrderHoldsAcrossTimerStallsAndTheirKeepalives
        if outstandingSends >= Self.inFlightSendBound { return false }
        // Here, and only here: the packet is going to the engine on THIS pass. A parked packet
        // is counted when its release actually admits it, and never if the release re-classifies
        // it into a drop — so the tally is packets CARRIED by the carve-out, which is the only
        // reading that survives back-pressure.
        // pinned: ChainedSessionRunnerTests.testAParkedOwnResolverQueryIsCountedOnceNotTwice
        if isOwnResolverQuery {
            counters.ownResolverPacketCount += 1
        }
        // The reachability SEND seam, at the same narrowest point as the carve-out tally: this
        // packet is going to the engine on this pass. The own-resolver carve-out is recorded too
        // — the resolver is a destination like any other, and giving it its own row is what lets
        // this signal stay clear of the DNS contamination `forwardedNonDNSByteCount` suffers in
        // split tunnel (PR #558) without touching any exclusion set.
        if let destination = ChainedOutboundPacketClassifier.ipv4Destination(of: packet) {
            destinations.recordSend(to: destination, atSeconds: reachabilityClock.nowSeconds())
        }
        counters.encapsulationAttemptCount += 1
        let outcome = Result { try session.encapsulate(packet, into: &buffers.toNetwork) }
            .mapError { $0 as? WireGuardEngineError ?? .invalidArgument }
        // General user traffic is the egress-dead demand signal; the resolver-query carve-out
        // obliges the peer too but must not, so a DNS-only session cannot arm egress-dead.
        perform(
            ChainedDataPathPolicy.action(for: outcome),
            origin: isOwnResolverQuery ? .obliging : .obligingNonDNS
        )
        return true
    }

    /// Parks one packet in the bounded queue, naming the moment when the park lost something.
    ///
    /// The admission verdict is NOT tallied here. Every outcome that loses a packet — refused,
    /// or admitted after evicting an older one — is already counted by the queue, and
    /// `snapshotCounters()` reads it from there; tallying separately here is what let the runner
    /// report zero shedding through sustained overload. What the verdict feeds is the
    /// event-driven telemetry alone: a lossless `.admitted` park is ordinary back-pressure and
    /// emits nothing, while an eviction or refusal is a packet lost NOW, at a timestamp a 60 s
    /// counter delta cannot recover.
    /// pinned: ChainedSessionRunnerTests.testAnEvictingParkEmitsAPressureEventAtTheMoment
    private func parkInOutboundQueue(_ packet: UnsafeRawBufferPointer) {
        let admission = outboundQueue.enqueue(packet)
        switch admission {
        case .admitted:
            break
        case .admittedAfterEvicting, .refusedOversized, .refusedEmpty, .refusedNoCapacity:
            diagnostics?(
                .outboundQueuePressure(
                    admission: admission.logValue, queueDepth: outboundQueue.count))
        }
    }

    // MARK: - Inbound

    private func receive(_ datagram: UnsafeRawBufferPointer, generation: Int) {
        // ADMISSION FIRST, so a refused datagram is never copied at all. The network can
        // deliver faster than the queue decrypts, and each waiting closure retains its copy —
        // the same invisible backlog as outbound, fed by the transport instead of the tunnel
        // (`ChainedAdmissionGauge`). Refusal is a UDP drop, which is the loss model every
        // protocol above this already lives with.
        // pinned: ChainedSessionRunnerTests.testADatagramArrivingAtASaturatedBacklogIsRefusedBeforeTheCopy
        // pinned: ChainedSessionRunnerTests.testTheInboundGaugeReadsZeroOnceTheQueueHasDrained
        let datagramBytes = datagram.count
        guard inboundAdmission.admit(bytes: datagramBytes, units: 1) else {
            // Tallied by the gauge; the event names the moment. Emitted before the copy the
            // refusal exists to avoid, exactly like the refusal itself.
            diagnostics?(.inboundBacklogRefused(bytes: datagramBytes))
            return
        }
        // Copied at the boundary because the borrowed buffer dies when this returns and the
        // work happens on another queue. This is the one copy the design accepts; it is per
        // DATAGRAM from the network, not per packet from the tunnel, and there is no way to
        // hold a borrow across a queue hop.
        let bytes = [UInt8](datagram)
        queue.async { [self] in
            // Held until the decrypt returns, for the reason `handleOutboundBatch` states: the
            // copy is retained for the whole closure, so releasing on entry leaves the datagram
            // being worked on uncounted. `defer`, so the latch below cannot leak a charge.
            defer { inboundAdmission.release(bytes: datagramBytes) }
            // The latch is checked HERE, after the hop, not at the boundary above. A datagram
            // accepted a moment before teardown is already on its way; what must not happen is
            // that it reaches a retired session.
            guard !isShutDown, !hasEnded else { return }
            // A DATAGRAM FROM A RETIRED SOCKET IS NOT EVIDENCE, and this is checked AFTER the
            // hop for the same reason the latch is. Checking it at the boundary instead reads
            // `channelGeneration` on the delivery thread, and a rebind landing between that read
            // and this closure running would let a datagram that arrived on the socket we just
            // abandoned cancel the NEW socket's confirmation deadline — certifying a rebind that
            // may be dead, which is the one failure this whole slice exists to catch
            // (Codex, PR #493). Both flags below are set inside this closure, so the check has to
            // be inside it too.
            // pinned: ChainedSessionRunnerTests.testADatagramFromTheRetiredChannelIsNotCreditedAsLiveness
            // pinned: ChainedSessionRunnerTests.testADatagramOvertakenByARebindDuringTheHopIsNotCredited
            guard generation == channelGeneration else { return }
            // The inbound side has the SAME gap as the outbound one, and covering only one would
            // have been arbitrary: `Tunn::handle_data` looks the session up by receiver index and
            // decrypts (`boringtun/src/noise/mod.rs:406`) without consulting a timer either — it
            // only stamps `TimeLastPacketReceived`. `REJECT_AFTER_TIME` bounds the keys, not one
            // direction of them, so accepting on an unasked session is the same defect facing the
            // other way.
            //
            // A datagram dropped by our own catch-up pass is a UDP drop, which is the loss model
            // everything above this already lives with, and the liveness credit below is moot for
            // a session the pass has just retired — the driver rebuilds rather than crediting.
            //
            // AT THE SEND BOUND, A STALE DATAGRAM IS DROPPED WITHOUT DRIVING THE PASS. The
            // pass can emit — a due keepalive, a rekey, a retransmission — and its emission
            // takes a transport slot through the same `perform` as everything else, so
            // initiating it here would bypass the hard in-flight limit from the one path
            // with no capacity check ahead of it (Codex, PR #497). Not driving the pass and
            // decapsulating anyway would accept on unasked timers, so neither half runs:
            // the drop is the same UDP loss the line above already accepts, and the next
            // completion or owner tick drives the pass with room to emit.
            // pinned: ChainedSessionRunnerTests.testASaturatedInboundPathDropsStaleDatagramsWithoutDrivingThePass
            if outstandingSends >= Self.inFlightSendBound, engineTimersAreStaleOnQueue() {
                return
            }
            guard engineTimersAreFreshOnQueue() else { return }
            // AT THE BOUND — whether it was full on arrival or the pass above just filled
            // it — a datagram that OBLIGES A REPLY is dropped before decapsulation: a
            // handshake initiation produces our response and a handshake response produces
            // our keepalive, both through the same `perform` as everything else, which
            // would take a slot past the hard limit (Codex, PR #497). The type gate is what
            // keeps this from coupling the directions: transport data — user traffic and
            // peer keepalives, the overwhelming case — never sends from decapsulation and
            // still delivers at full outbound saturation.
            // pinned: ChainedSessionRunnerTests.testAReplyObligingDatagramIsDroppedAtTheBound
            if outstandingSends >= Self.inFlightSendBound,
                bytes.first == Self.handshakeInitiationMessageType
                    || bytes.first == Self.handshakeResponseMessageType
            {
                return
            }
            var source = WireGuardSourceAddress()
            let outcome = Result {
                try bytes.withUnsafeBytes {
                    try session.decapsulate(
                        $0, from: peer, into: &buffers.toTunnel, capturingSourceAddress: &source)
                }
            }.mapError { $0 as? WireGuardEngineError ?? .invalidArgument }
            // AUTHENTICATED, therefore unforgeable — recorded before the action is interpreted.
            // A failed decapsulation proves nothing, because `protocolViolation`,
            // `noCurrentSession` and an oversized datagram are all producible by anyone who can
            // reach our UDP port.
            //
            // AND SUCCESS ALONE IS NOT ENOUGH EITHER — one decapsulation succeeds without the
            // peer's key at all. The rule is stated once, where the two cases are told apart:
            // see ``provesPeerKeyPossession(inboundMessageType:operation:outboundMessageType:)``.
            // pinned: ChainedSessionRunnerTests.testOnlyAnAuthenticatedDatagramCountsAsPeerLiveness
            if case .success(let operation) = outcome,
                Self.provesPeerKeyPossession(
                    inboundMessageType: bytes.first, operation: operation,
                    outboundMessageType: buffers.toTunnel.first)
            {
                liveness.sawAuthenticatedPeerDatagram = true
            }
            perform(ChainedDataPathPolicy.action(for: outcome), source: source, producedInto: .toTunnel)
        }
    }

    // MARK: - Acting on one engine outcome

    /// Where a `.sendToPeer` came from, so the predicate can tell an obliging send from one the
    /// peer owes nothing for.
    enum SendOrigin {
        /// An obliging send the peer must answer, but which is NOT general user traffic: the
        /// tunnel's own resolver-query carve-out or a forced handshake. Arms the link-silence
        /// clock, but is not the egress-dead demand signal (a resolver-only or handshake-only
        /// exchange must not look like the user asking for the internet).
        case obliging
        /// GENERAL user (non-DNS) IPv4 traffic through the tunnel: the peer is obliged to answer
        /// AND this is the demand half of the egress-dead predicate. A strict subset of
        /// `.obliging` semantics — it also arms the link-silence clock.
        case obligingNonDNS
        /// The engine's own timer output or a reply produced while handling an inbound datagram.
        /// The peer owes nothing for these, so arming a silence clock on them would be waiting
        /// for an answer that was never due.
        case unobliging
    }

    /// Which scratch buffer the engine call that produced this action wrote into.
    ///
    /// A `.sendToPeer` can come from EITHER buffer, and that is the whole reason this exists:
    /// `encapsulate`, `tick`, `forceHandshake` and `drain` write outward into
    /// ``ChainedDataPathBuffers/toNetwork``, but `decapsulate` writes into
    /// ``ChainedDataPathBuffers/toTunnel`` — and a single INBOUND datagram can still produce a
    /// network-bound reply, which is a cookie reply or our answer to a peer-initiated
    /// handshake. `ChainedDataPathBuffers` says exactly that; the send path did not honour it
    /// and transmitted `toNetwork` unconditionally, so every such reply went out as whatever
    /// the last outbound call had left there, with a length taken from the other buffer.
    /// pinned: ChainedSessionRunnerTests.testAReplyToAPeerInitiatedHandshakeReachesThePeerIntact
    enum ProducingBuffer {
        case toNetwork
        case toTunnel
    }

    private func perform(
        _ action: ChainedDataPathAction,
        source: WireGuardSourceAddress? = nil,
        origin: SendOrigin = .unobliging,
        producedInto: ProducingBuffer = .toNetwork
    ) {
        switch action {
        case .sendToPeer(let byteCount):
            // Set BEFORE the send, not after. A transport that completes inline re-enters
            // `releaseStored` from inside `sendOnQueue`, and that pass has to know the engine
            // may be holding packets or it releases only our queue and stops.
            enginePacketsPending = true
            // Counted for EVERY origin, including `.unobliging`: the question this answers is
            // whether the engine produced anything at all, and a keepalive or a tick
            // retransmission is engine output exactly as an obliging send is.
            counters.sendToPeerCount += 1
            if origin == .obliging || origin == .obligingNonDNS { liveness.sawObligingSend = true }
            // The egress-dead demand signal is ONLY general user traffic: not the resolver
            // carve-out, a forced handshake, or a drain whose original classification is lost.
            if origin == .obligingNonDNS { liveness.sawObligingNonDNSSend = true }
            sendOnQueue(byteCount: byteCount, from: producedInto)
            releaseStored()
        case .deliverIPv4(let byteCount):
            deliverOnQueue(byteCount: byteCount, source: source)
        case .dropIPv6(let byteCount):
            _ = byteCount
            // NOT LIVENESS, and my first comment here contained its own refutation: it said the
            // IPv6-ness "says nothing about whether the peer's egress works" and then counted it
            // as evidence that the peer's egress works.
            //
            // This tunnel drops every OUTBOUND IPv6 packet locally, so an inbound one cannot be
            // a response to anything this session carried — it is unsolicited, and a peer
            // emitting it periodically is no better evidence than the keepalive excluded a few
            // lines down. Counting it would let such a peer hold the outage clock at zero
            // indefinitely while the IPv4 egress it is supposed to be providing is dead.
            counters.droppedInboundIPv6Count += 1
        case .idle, .dropPacket:
            // A per-packet verdict. `.idle` covers the authenticated KEEPALIVE, and it is
            // deliberately NOT liveness: a peer whose WireGuard link is healthy but whose
            // egress is dead keepalives forever, which is exactly the failure chained mode
            // exists to survive. Counting it would mean the outage clock never starts and the
            // tunnel blackholes `0.0.0.0/0` with nothing measuring it.
            // pinned: ChainedSessionRunnerTests.testAKeepalivingPeerWithNoReturnDataIsNotFlowing
            break
        case .reconnect, .callerBug:
            reportSessionEnd(action)
        }
    }

    /// Reports a session-ending action to the owner, at most once, and stops driving the engine.
    ///
    /// ONCE, because the engine keeps producing the same verdict: `handshake.is_expired()` makes
    /// every subsequent `update_timers` return `ConnectionExpired`, so a runner that reported on
    /// each occurrence would deliver the same end at the tick rate — and each delivery would be
    /// classified against a budget that had already moved on from it.
    ///
    /// Through `ChainedSessionEndCause(_:)`, which is the validated door: it re-derives the
    /// action from the error and refuses anything `ChainedDataPathPolicy` would not have
    /// produced, so a per-packet verdict cannot reach the reconnect policy wearing a
    /// session-ending shape.
    /// pinned: ChainedSessionRunnerTests.testTheRunnerReportsASessionEndOnceAndThenStopsDrivingTheEngine
    private func reportSessionEnd(_ action: ChainedDataPathAction) {
        guard !hasEnded, let cause = ChainedSessionEndCause(action) else { return }
        hasEnded = true
        events.sessionEnded(cause)
    }

    private func deliverOnQueue(byteCount: Int, source: WireGuardSourceAddress?) {
        guard let source else { return }
        switch allowedIPs.verdict(source: source, byteCount: byteCount) {
        case .deliver:
            // Nested transport replies feed the second engine, never utun or general
            // forwarding evidence. End buffer borrowing before reentrant delivery.
            if let interceptInbound, interceptInbound(Data(buffers.toTunnel[..<byteCount])) { return }
            // LIVENESS IS RECORDED HERE, at the narrowest point: a packet the peer forwarded
            // from the internet, whose source it was actually granted, written into the tunnel.
            //
            // Not inside `perform`, which is reached by `tick()` and by the drain as well as by
            // `receive` — recording there lets the tunnel certify itself, since a tick emitting a
            // handshake retransmission would read as the peer answering, the precise condition
            // an outage is defined by the absence of.
            // pinned: ChainedSessionRunnerTests.testATicksOwnOutputDoesNotCertifyLiveness
            //
            // And not before the AllowedIPs verdict: a peer claiming a source it was never
            // granted is misbehaving, and treating its packets as proof the tunnel is healthy
            // would let exactly that peer keep the outage clock from starting.
            // pinned: ChainedSessionRunnerTests.testASpoofedSourceIsNotEvidenceTheTunnelIsWorking
            liveness.sawInboundData = true
            // The reachability RECEIPT seam, under the same AllowedIPs verdict for the same
            // reason: a spoofed source must not be able to close a window it was never sent to.
            //
            // NO DNS EXCLUSION HERE, deliberately, and it is the difference between this signal
            // and the byte counter below it. That counter must exclude DNS replies because it
            // answers "is the chain carrying GENERAL traffic" for the connect gate. This answers
            // "is THIS destination answering", where the resolver is simply one row and the host
            // the user wants is another — so an exclusion would blind the table to the resolver's
            // own reachability while doing nothing for anyone else's.
            if let destination = source.ipv4Address {
                destinations.recordReceipt(
                    from: destination, atSeconds: reachabilityClock.nowSeconds())
            }
            // Forwarding evidence for the connect gate — but ONLY when this delivery is not an
            // actual DNS reply from our own upstream resolver. A DNS reply is DNS, not the general
            // traffic "Protected" must mean; counting it would let a chain that answers its
            // resolver but forwards nothing else false-confirm (Codex, PR #558).
            //
            // PORT-AWARE, not address-wide (PR #567 follow-up). The exclusion used to drop EVERY
            // byte whose source ADDRESS is a resolver, which was wrong for a resolver IP that also
            // serves ordinary traffic: `1.1.1.1`/`8.8.8.8`/`9.9.9.9` all answer HTTPS, so a
            // transfer FROM that one IP as the user's sole traffic left the counter flat and could
            // false-reject the connect gate / false-surrender the egress-dead arm (device-confirmed
            // 2026-08-23). The exclusion is now exactly a DNS reply: the source ADDRESS is a
            // resolver (allocation-free `permits(source:)` — `WireGuardSourceAddress.octets`
            // allocates, the buffer overload does not) AND the transport SOURCE port is 53. A
            // resolver-sourced packet on any other readable port is the general forwarding it is,
            // and counts. `carriesNonDNSSourcePort` is fail-closed for the gate: a packet whose
            // port it cannot read stays excluded — see ``ChainedInboundDNSReply``.
            //
            // An empty resolver set (the default) excludes nothing — the first disjunct is always
            // true — so the pre-tighten behaviour is unchanged.
            // pinned: ChainedSessionRunnerTests.testNonDNSTrafficFromAResolverIPCountsAsForwarding
            // pinned: ChainedSessionRunnerTests.testAReplyFromTheResolverIsDeliveredButNotForwardingEvidence
            if !resolverSourceAddresses.permits(source: source)
                || buffers.toTunnel.withUnsafeBytes({ raw in
                    ChainedInboundDNSReply.carriesNonDNSSourcePort(
                        UnsafeRawBufferPointer(rebasing: raw[..<byteCount]))
                }) {
                counters.forwardedNonDNSByteCount += UInt64(byteCount)
            }
            writeBatch.removeAll(keepingCapacity: true)
            writeProtocols.removeAll(keepingCapacity: true)
            writeBatch.append(Data(buffers.toTunnel[..<byteCount]))
            writeProtocols.append(NSNumber(value: AF_INET))
            writer.write(writeBatch, protocols: writeProtocols)
        case .dropSpoofedSource:
            counters.spoofedSourceCount += 1
        case .dropMalformedSource:
            counters.spoofedSourceCount += 1
        }
    }

    /// How many sends may be outstanding before packets park.
    ///
    /// A bound rather than a boolean, and a small one: it exists to notice a transport that has
    /// stopped taking bytes, not to build a second buffer in front of the socket. Three places
    /// hold an outbound packet — the engine's pre-handshake queue, the batch cursor, and this
    /// queue — and every one of them is bounded: `MAX_QUEUE_DEPTH`, ``maximumParkedBatchBytes``,
    /// and ``ChainedPacketQueueLimits`` respectively.
    static let inFlightSendBound = 16

    /// WireGuard message types, the first byte of a datagram (`boringtun/src/noise/mod.rs`).
    static let handshakeInitiationMessageType: UInt8 = 1
    static let handshakeResponseMessageType: UInt8 = 2
    static let cookieReplyMessageType: UInt8 = 3
    static let transportDataMessageType: UInt8 = 4

    /// Whether one decapsulation outcome required the PEER'S key to produce.
    ///
    /// The signal the outage predicate rests on, so it has to admit everything that genuinely
    /// proves the peer is there and nothing that does not — and getting either side wrong has
    /// already cost a round here.
    ///
    /// TRANSPORT DATA (type 4) qualifies outright: it is carried under the session keys, and a
    /// keepalive is a type-4 datagram with an empty payload.
    ///
    /// A HANDSHAKE RESPONSE (type 2) qualifies, because accepting one requires the ephemeral
    /// state of the initiation WE just sent — so it proves the peer answered THIS attempt, not
    /// merely that it once existed. `receive_handshake_response` decrypts against the live
    /// handshake's chaining key (`handshake.rs:565`), which a stale capture cannot satisfy.
    ///
    /// A HANDSHAKE INITIATION (type 1) does NOT qualify, and this is the leg that took three
    /// revisions to get right. It is authenticated but REPLAYABLE HERE: WireGuard's defence is
    /// the TAI64N `last_handshake_timestamp`, which starts at `Tai64N::zero()` on every fresh
    /// `Handshake` (`handshake.rs:430`, checked at `:543`) — and the driver builds a NEW
    /// session per retry attempt, so that window resets every time. An on-path party who once
    /// captured a genuine initiation from the peer can replay it after each rebuild, get us to
    /// emit a type-2 response, and have it credited as the peer being alive — ending the
    /// outage, refunding the budget, and preventing the DNS-only fallback indefinitely while
    /// the tunnel is blackholed (Codex, PR #483).
    ///
    /// The COOKIE REPLY path is excluded by the same output check either way:
    /// `RateLimiter::verify_packet` answers a handshake whose mac2 fails under load with a
    /// cookie reply (`rate_limiter.rs:177-185`), which `decapsulate` returns as an ordinary
    /// `WriteToNetwork` before any Noise processing (`mod.rs:293-296`) — and mac1 is keyed on
    /// OUR static public key, which is not a secret from anyone who can address us. That output
    /// is type 3; a genuine response to our initiation produces type 4 (our keepalive), which
    /// is emitted from the INBOUND buffer — see ``ProducingBuffer`` for why that mattered.
    ///
    /// Excluding handshakes wholesale — an earlier round's fix — was wrong in the direction
    /// that matters most: on every retry WE initiate, so the peer's authenticated type-2
    /// response is the recovery signal, and our own answering keepalive is consumed by the peer
    /// as `Done` with nothing sent back (`mod.rs:405-428`, `:464-466`).
    ///
    /// AND NO INBOUND TYPE 4 EVER ARRIVES on that path unless the peer has traffic of its own.
    /// The passive keepalive needs `data_packet_received > aut_packet_sent` (`timers.rs:282-288`)
    /// and our keepalive returns at `mod.rs:466` before `:500` ticks
    /// `TimeLastDataPacketReceived`, so it never qualifies; persistent keepalive is off
    /// (`timers.rs:291-298`); and the peer is the responder, so the initiator-only rekeys at
    /// `timers.rs:244-265` do not apply. The wait is unbounded, not merely long — a type-4-only
    /// rule surrendered EVERY recovery against a peer with nothing to send, which is the
    /// recovery path the whole ladder exists to reach.
    /// pinned: ChainedSessionRunnerTests.testAHandshakeResponseCountsAsPeerLiveness
    /// pinned: ChainedSessionRunnerTests.testACookieReplyIsNotEvidenceThePeerIsAlive
    /// pinned: ChainedSessionRunnerTests.testAReplayedInitiationIsNotEvidenceThePeerIsAlive
    static func provesPeerKeyPossession(
        inboundMessageType: UInt8?,
        operation: WireGuardOperation,
        outboundMessageType: UInt8?
    ) -> Bool {
        guard let inboundMessageType else { return false }
        if inboundMessageType == transportDataMessageType { return true }
        guard inboundMessageType == handshakeResponseMessageType else { return false }
        // Only the network-bound answer distinguishes the two, so anything else is not evidence.
        guard case .writeToNetwork = operation else { return false }
        return outboundMessageType != cookieReplyMessageType
    }

    private func sendOnQueue(byteCount: Int, from producingBuffer: ProducingBuffer) {
        outstandingSends += 1
        // DEFERRED PAST THE BORROW. An inline completion used to call `channelResumed()` from
        // inside this closure — while `withUnsafeBytes` is still lending the scratch buffer to
        // the channel. `channelResumed` releases stored packets, which encapsulates or drains
        // straight back into `buffers.toNetwork`: an overlapping mutable access to the very
        // array the channel has been handed, during the one window the protocol says it may read
        // it. An implementation that copies late transmits the NEXT datagram's bytes, and Swift's
        // exclusivity checking is entitled to trap on it outright.
        //
        // So the completion only records that it fired, and the resume happens below, after the
        // borrow has ended.
        //
        // NOT PINNED, and I could not construct an observable. A fake that completes inline and
        // then re-reads the bytes it was lent — which is what any transport copying late does —
        // does not see them change, even with the engine drain releasing queued packets into the
        // same array during the borrow. Two scenarios were built and mutation-checked and both
        // passed against the unsafe version, so a breadcrumb here would claim an enforcement
        // that does not exist. The change is kept because the overlapping access is real
        // regardless of whether this suite can see it: Swift's exclusivity checking is entitled
        // to trap on it, and the deferral costs one Bool.
        sendDepth += 1
        let generation = channelGeneration
        let send: (UnsafeRawBufferPointer) -> Void = { [self] whole in
            self.channel.send(UnsafeRawBufferPointer(rebasing: whole[..<byteCount])) { [weak self] sent in
                guard let self else { return }
                // GENERATION FIRST, before the three-case discriminator below.
                //
                // Nothing obliges a transport to fire the completions it still holds when it is
                // closed — the protocol's whole teardown contract is "Tears the transport down.
                // Idempotent", and this repo's own reference conformer proves the hole with a
                // literal `func close() {}` that drops its pending array on the floor.
                //
                // So neither keeping nor resetting `outstandingSends` across a swap is right.
                // Keeping it means the new socket is born saturated by the old one's slots, at
                // exactly the moment a swap happens. Resetting it alone is worse and SILENTLY
                // so: each late completion from the retired channel would run `channelResumed()`
                // → `max(0, outstandingSends - 1)` → `releaseStored()` → refill to the bound, so
                // twice the bound sits genuinely outstanding while the counter reads the bound.
                // The `max(0,)` is exactly what hides it; without the clamp it would go negative
                // and be loud.
                //
                // Ignoring retired completions entirely makes both questions disappear — the
                // error tally below included, because a retired socket's failure is evidence
                // about a transport that no longer exists.
                guard self.engineQueue.run({
                    guard generation == self.channelGeneration else { return false }
                    // Counted, no longer discarded (see the field's doc). Inside this same
                    // queue acquisition so the tally shares the generation check's confinement;
                    // the RESUME below is deliberately untouched by the outcome — a failed send
                    // still frees its in-flight slot, exactly as before.
                    if !sent { self.counters.sendCompletionErrorCount += 1 }
                    return true
                }) else { return }
                // Three cases, not two, and conflating the middle one with the first wedged the
                // data path.
                //
                // An unconditional `async` was wrong in a way that only showed under load: a
                // completion that fires synchronously got scheduled BEHIND every batch already
                // queued, so `outstandingSends` climbed to the bound and a steady state parked
                // — manufacturing the back-pressure the count exists to detect.
                //
                // But `isCurrent` alone is not "inline". Since the engine queue is shared and
                // public, a channel may schedule its completions onto it: that runs on the
                // queue, yet as its OWN item, long after the `sendDepth` frame that would have
                // read the flag. `sendDepth > 0` is the exact discriminator — the serial queue
                // guarantees that if a send call is on the stack, we are inside it rather than
                // in a later item, because no other item can be running.
                //
                //   inside the send call → record, and let `sendOnQueue` resume past the borrow
                //   on the queue, not inside a send → resume directly; no borrow is active
                //   off the queue → hop
                //
                // THE THIRD CASE IS NOT `NWConnection`, which this comment used to name.
                // `ChainedUpstreamSessionFactory.makeChannel` starts the connection with
                // `queue: engineQueue.queue`, so the framework delivers its completions ON the
                // engine queue as their own item — the second case. The hop exists because
                // `ChainedUpstreamDatagramChannel` is public and promises nothing about which
                // queue a completion arrives on, not because the shipped conformer needs it.
                if self.engineQueue.isCurrent {
                    if self.sendDepth > 0 {
                        self.sawInlineCompletion = true
                    } else {
                        self.channelResumed()
                    }
                } else {
                    // RE-CHECKED AFTER THE HOP, exactly as `receive` does, and for the same
                    // reason: the check above ran in a separate queue acquisition, so a rebind
                    // can land between it and this closure. `adoptChannel` resets
                    // `outstandingSends` to zero, so a retired channel's late completion would
                    // decrement the REPLACEMENT's count and `releaseStored()` onto it — pushing
                    // genuinely in-flight sends past `inFlightSendBound` while the counter reads
                    // below it. Unreachable with the shipped conformer, which never takes this
                    // branch; the guard is here because the protocol allows a conformer that does
                    // (Codex, PR #493).
                    //
                    // NOT PINNED, for the reason the `sendDepth` comment above gives about its own
                    // change. `testARetiredChannelsLateCompletionCannotResumeTheNewOne` reaches
                    // this branch but not this race: it rebinds BEFORE the completion fires, so the
                    // check above already rejects it. The race needs the rebind to land BETWEEN
                    // that check and this closure, and forcing that interleaving would take a
                    // scheduling hook in this file that exists only for the test. A breadcrumb here
                    // would name a test that does not exercise what it claims.
                    self.engineQueue.enqueue {
                        guard generation == self.channelGeneration else { return }
                        self.channelResumed()
                    }
                }
            }
        }
        // THE BUFFER THE ENGINE ACTUALLY WROTE, chosen here rather than assumed. Borrowing the
        // wrong one sends stale bytes with the right length, which is a datagram that looks
        // well-formed and fails authentication at the peer.
        switch producingBuffer {
        case .toNetwork: buffers.toNetwork.withUnsafeBytes(send)
        case .toTunnel: buffers.toTunnel.withUnsafeBytes(send)
        }
        sendDepth -= 1
        // Read-and-clear, which is what makes a NESTED send safe: the release below can send
        // again, and each level pairs with its own completion because this queue is serial and
        // the whole path is synchronous.
        let fired = sawInlineCompletion
        sawInlineCompletion = false
        if fired { channelResumed() }
    }

    private func channelResumed() {
        outstandingSends = max(0, outstandingSends - 1)
        releaseStored()
    }

    /// Moves stored packets to the transport while it has room, from both places one can be.
    ///
    /// Releases while there is room rather than one per completion: a completion that freed a
    /// slot should let the backlog move, otherwise a queue that filled during a stall drains
    /// only as fast as new completions arrive and never catches up.
    ///
    /// ## Iterative, not recursive
    ///
    /// A transport that completes on THIS queue re-enters through `channelResumed` from inside
    /// `sendOnQueue`. That used to cost one stack frame per packet — `channelResumed` ->
    /// `encapsulateOnQueue` -> `perform` -> `sendOnQueue` -> completion -> `channelResumed` —
    /// several hundred deep for a full queue, through a chain Swift does not fold into tail
    /// calls. `NWConnection` does not take that path, so production never would; a test fake
    /// does, and the inline completion is deliberate and staying, so the depth is real.
    ///
    /// The flag turns that recursion into an extra pass of the loop already running: a
    /// re-entrant call decrements the count and returns, and the outer `while` observes the
    /// freed slot on its next test. Not a lock — everything here is queue-confined already.
    /// pinned: ChainedSessionRunnerTests.testASynchronousTransportDrainsTheQueueIteratively
    private func releaseStored() {
        if isShutDown || hasEnded { return }
        if isReleasing { return }
        isReleasing = true
        defer { isReleasing = false }
        // OLDEST FIRST, and the age order is now enforced where the cursor is CLAIMED rather
        // than asserted here. The engine's queue predates any session, so it predates
        // everything. The cursor is older than every parked packet because it can only be taken
        // when nothing is parked — see `processOutboundOnQueue`, where the earlier version of
        // this reasoning was wrong: it argued the queue only fills while a batch is stopped,
        // which is true, and forgot that the batch can FINISH while the queue is still full, at
        // which point a newer batch could take the cursor and jump the line.
        // pinned: ChainedSessionRunnerTests.testPacketsReachThePeerInArrivalOrderAcrossInterleavedBatches
        while outstandingSends < Self.inFlightSendBound {
            // Same reason as the batch loop: `drainOneFromEngine` can report the session dead,
            // and the entry guard above was tested before that happened. Without this the loop
            // keeps releasing a pending batch and a parked queue into an engine that is gone.
            if isShutDown || hasEnded { return }
            if enginePacketsPending {
                if drainOneFromEngine() { continue }
                // A false return can also mean the drain's own catch-up pass RETIRED the
                // session, and the latch above was tested before the one call that can flip it.
                // Falling through would hand the parked queue to `encapsulateOnQueue`, whose
                // freshness guard the retiring pass has just restamped — the engine would be
                // touched after its end, which is exactly what the guard's false return forbids.
                // Untestable for the reason `engineTimersAreFreshOnQueue()` gives: reaching
                // `ConnectionExpired` needs 90-180 s of a REAL engine's time.
                if isShutDown || hasEnded { return }
                // And it can mean the pass consumed the last slot. The loop's entry test ran
                // before the drain did; nothing below can move a packet at the bound — a cursor
                // claim would only re-park itself — so answer the completion that resumes this
                // loop, which is the next thing that frees a slot.
                if outstandingSends >= Self.inFlightSendBound { return }
            }
            if let pending = pendingBatch {
                pendingBatch = nil
                processOutboundOnQueue(pending.packets, from: pending.index, isResumption: true)
                continue
            }
            if outboundQueue.isEmpty { return }
            // THE HEAD IS NOT DEQUEUED UNTIL IT CAN REACH THE ENGINE ON THIS PASS. The guard is
            // consulted BEFORE the dequeue because its catch-up pass can emit and consume the
            // last slot — and a head dequeued first would have nowhere to go back but the TAIL,
            // which is the reorder the OLDEST-FIRST contract above forbids. Consulted here, the
            // pass either retires the session, fills the bound (the head stays the head and the
            // withheld send's completion resumes this loop), or leaves a stamp fresh enough
            // that the per-packet guard below cannot drive a second pass.
            //
            // The stale branches here are reachable only across a suspension that freezes the
            // process between the drain above and this line — the same mid-closure argument
            // that put the guard at every engine call — so they are enforced by that argument
            // rather than by a test: no fixture can freeze a held queue mid-pass.
            guard engineTimersAreFreshOnQueue() else { return }
            if outstandingSends >= Self.inFlightSendBound { return }
            guard let parked = outboundQueue.dequeue() else { return }
            // RE-CLASSIFIED, not sent straight to the engine. See `classifyAndAct`: a packet
            // parked before the head that silences it was classified against a table that did
            // not know about that head yet.
            // Serves DNS like any other classification. The registry's grace window is what
            // makes that safe on this path too — see the resumption comment in
            // `processOutboundOnQueue`.
            // pinned: ChainedSessionRunnerTests.testAReleasedPacketThatReclassifiesAsDNSIsNotServed
            let consumed = parked.withUnsafeBytes { p in
                classifyAndAct(p, mayReclaim: false, dnsPacket: Data(p))
            }
            // Reachable only across the same mid-pass suspension as above: the pre-dequeue
            // consult just restamped, so the per-packet guard declines only if the clock jumped
            // the whole bound in between. A declined head must not be lost; the tail is the one
            // place it can go back, and one reordered packet beats a dropped one.
            if !consumed { parked.withUnsafeBytes { parkInOutboundQueue($0) } }
        }
    }

    /// Releases at most ONE packet the engine queued while no session was current, reporting
    /// whether it produced a send.
    ///
    /// Bounded on being a SEND, not on the session ending. A `.none` operation carries a byte
    /// count of zero, so a loop that continued on it would send the stale contents of the
    /// scratch buffer as a datagram.
    /// pinned: ChainedSessionRunnerTests.testTheDrainLoopStopsOnAnythingThatIsNotASend
    ///
    /// ONE packet per call, with the caller applying the send bound between them. Draining to
    /// exhaustion inside `perform` meant a handshake completing against a stalled channel
    /// handed all 256 engine-queued datagrams to the transport in one go: `outstandingSends`
    /// went an order of magnitude past its bound, and the bytes moved out of bounded storage
    /// into a socket buffer that has none. That is the jetsam shape the bound exists to prevent
    /// (`INV-MEM-1`), reached by the one path that arrives with a full queue.
    /// pinned: ChainedSessionRunnerTests.testTheEngineDrainStopsAtTheSendBound
    private func drainOneFromEngine() -> Bool {
        // THE DRAIN USES SESSION KEYS TOO. An empty-datagram drain is boringtun's
        // `send_queued_packet`, which calls `encapsulate` on whatever keypair is current — and
        // the path that arrives here stale is real: a transport completion resuming
        // `releaseStored` is the first thing that runs after a suspension ends, before any owner
        // tick. Leaving this one entry point unguarded was the counterexample to "immediately
        // before every engine call that uses session keys" (Codex, PR #497).
        // pinned: ChainedSessionRunnerTests.testAResumedDrainConsultsTheTimersBeforeUsingTheKeys
        guard engineTimersAreFreshOnQueue() else { return false }
        // RE-CHECKED AFTER THE PASS, because the pass itself can send: a keepalive or
        // retransmission emitted by the catch-up tick takes a transport slot through the same
        // `perform` as everything else, and the caller's bound was tested before the pass ran.
        // Proceeding would put the drained packet past the hard in-flight limit precisely when
        // the transport is nearly saturated. Returning false loses nothing — the engine still
        // holds the packet and `enginePacketsPending` stays set, so the next completion resumes
        // the drain.
        // pinned: ChainedSessionRunnerTests.testAResumedDrainConsultsTheTimersBeforeUsingTheKeys
        guard outstandingSends < Self.inFlightSendBound else { return false }
        let outcome = Result { try session.drain(into: &buffers.toNetwork) }
            .mapError { $0 as? WireGuardEngineError ?? .invalidArgument }
        let action = ChainedDataPathPolicy.action(for: outcome)
        // ONE bound, not two. This read `if action.terminatesDrain { return }` above the
        // pattern match, and the pattern match already exits on everything that is not a
        // send — so the policy consultation was dead code, and mutating it away changed
        // nothing, so a breadcrumb claiming a test enforced it would have been false.
        //
        // The pattern match is kept because it is the one that cannot go wrong: it exits on
        // anything without a byte count rather than on anything the policy labels
        // terminal. `terminatesDrain` is the policy's name for exactly this condition, and
        // that equivalence is now asserted directly instead of being restated here.
        // pinned: ChainedSessionRunnerTests.testTerminatesDrainMeansExactlyNotASend
        guard case .sendToPeer(let byteCount) = action else {
            enginePacketsPending = false
            // A NON-SEND HERE MAY STILL BE A SESSION END, and discarding it lost the only
            // engine fault the reconnect policy grants another attempt for. `.engineInternal`
            // classifies as `.reconnect`, and the drain is a path it can arrive on — `drain` is
            // `decapsulate([])`, so anything decapsulation can fail with surfaces here.
            // Reporting it through the same door as `perform` means the drain cannot be the one
            // path where a dead session goes unnoticed.
            //
            // NOT PINNED, and the reason is a property of the engine rather than of the tests.
            // Reaching this branch with a session-ending action needs `drain` to fail, and the
            // runner holds a REAL `WireGuardSession` with no seam to inject one: boringtun's
            // `send_queued_packet` swallows its own errors by requeueing, our buffer is already
            // at the engine's ceiling so `destinationBufferTooSmall` is unreachable, and
            // `.engineInternal` means a poisoned lock. `reportSessionEnd` itself is covered
            // through `perform`; what is unenforced is that THIS call site exists.
            reportSessionEnd(action)
            return false
        }
        // A drained packet is user traffic the engine held back, so it obliges the peer exactly
        // as the original send would have.
        liveness.sawObligingSend = true
        sendOnQueue(byteCount: byteCount, from: .toNetwork)  // drain writes outward
        return true
    }

    private func onQueue<T>(_ work: () -> T) -> T { engineQueue.run(work) }
}
