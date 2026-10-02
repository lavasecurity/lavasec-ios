import Foundation

/// What IPv4 reassembly uses to decide that two fragments belong to the same datagram.
///
/// Source, destination, protocol and identification — and deliberately NOT the ports, because
/// a non-first fragment carries no transport header. That absence is the whole reason this type
/// exists and also its one weakness; see ``ChainedDroppedFragmentTable``.
public struct ChainedFragmentIdentity: Hashable, Sendable {
    public let source: UInt32
    public let destination: UInt32
    public let identification: UInt16
    public let protocolNumber: UInt8

    public init(source: UInt32, destination: UInt32, identification: UInt16, protocolNumber: UInt8) {
        self.source = source
        self.destination = destination
        self.identification = identification
        self.protocolNumber = protocolNumber
    }
}

/// The datagrams whose FIRST fragment was dropped as unfilterable DNS, so their continuations
/// can be dropped too.
///
/// ## The leak this closes
///
/// Dropping fragment zero of a DNS query stops the query from working — the peer holds no UDP
/// header and nothing reassembles — but it does NOT stop the query from being READ. The tails
/// carry the DNS message's own bytes in plaintext, and an observer with all of them can
/// concatenate the QNAME without any transport header or successful reassembly. A first fragment
/// may legally carry as little as the UDP header itself, which leaves the ENTIRE question in the
/// fragments that were forwarded. "Killing the head kills the query" was true; "and denies the
/// observer the part that identifies it" was not, and that half is what `INV-DNS-1` is about.
///
/// ## Why a deny-list rather than an allow-list
///
/// The two shapes fail in opposite directions and the choice is not close.
///
/// Remembering PERMITTED heads and dropping any tail without one fails closed on a miss, which
/// sounds better — until you count misses. Every fragmented flow on the device competes for the
/// table, so under ordinary fragmented traffic entries are evicted between a head and its tails
/// and legitimate datagrams are destroyed continuously.
///
/// Remembering DROPPED DNS heads inverts both: a miss forwards, and a hit drops. The bound that
/// makes it safe is that a miss requires ``capacity`` OTHER DNS fragment heads to be dropped
/// between this head and its own tails. The kernel emits one datagram's fragments back to back,
/// so that is not a probabilistic claim about timing — it is a claim about how many interleaved
/// fragmented DNS queries the device would have to be sending at that instant, and the answer is
/// bounded by the table, not by luck.
/// pinned: ChainedOutboundPacketClassifierTests.testTheTailsOfADroppedDNSHeadAreDroppedToo
///
/// ## The collision, stated rather than dismissed
///
/// The key cannot include ports, so two datagrams to the same destination with the same
/// identification are one identity here. A permitted UDP flow to `8.8.8.8:443` and a DNS query
/// to `8.8.8.8:53` sharing an identification collide, and the permitted flow's tails are dropped.
/// That is the fail-CLOSED direction — a rare functional blip, not a leak — which is the other
/// reason the deny-list is the right way round.
/// pinned: ChainedOutboundPacketClassifierTests.testAnIdentificationCollisionFailsClosed
public struct ChainedDroppedFragmentTable: Equatable, Sendable {
    /// How many dropped heads are remembered.
    ///
    /// Small on purpose. Every entry is one datagram whose tails are still in flight, and
    /// fragments of one datagram are emitted consecutively — so the table needs to span
    /// concurrent fragmented DNS queries, not time. 32 is far past any plausible count of those
    /// and costs 352 bytes, which matters under `INV-MEM-1`: a table sized for comfort is
    /// resident memory in a process bounded at ~50 MB.
    public static let capacity = 32

    /// Oldest first. Not a ring: ``remember(_:)`` has to be able to move an existing entry to
    /// the young end, which a ring cannot do without shifting anyway. Bounded at ``capacity``,
    /// and only a dropped DNS fragment head reaches it — this is not a per-packet path.
    private var entries: [ChainedFragmentIdentity] = []

    public init() {
        entries.reserveCapacity(Self.capacity)
    }

    /// Records that this datagram's head was dropped, or REFRESHES it if already known.
    ///
    /// Refreshing is what makes the bound in this type's documentation true. The first version
    /// returned early when the identity was already present, on the correct reasoning that a
    /// retransmitted head must not consume a second entry — and that left the entry at its
    /// original age. An identity re-remembered while it was already the oldest stayed the
    /// oldest, so ONE further dropped head evicted it, and the tails that arrived after the
    /// retransmission missed the table and were forwarded. The stated bound of 32 intervening
    /// heads was really 1 in exactly the shape a retransmitting resolver produces.
    ///
    /// Moving rather than appending keeps the other property: a head repeated a thousand times
    /// occupies one entry, not a thousand.
    /// pinned: ChainedDroppedFragmentTableTests.testARerememberedIdentityBecomesTheYoungest
    public mutating func remember(_ identity: ChainedFragmentIdentity) {
        if let existing = entries.firstIndex(of: identity) { entries.remove(at: existing) }
        entries.append(identity)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// Whether this datagram's head was dropped.
    public func contains(_ identity: ChainedFragmentIdentity) -> Bool {
        entries.contains(identity)
    }

    /// Releases an identity because a LATER head with the same tuple was FORWARDED.
    ///
    /// The 16-bit identification wraps, and eviction alone releases nothing under ordinary
    /// traffic — only dropped heads evict. So without this, a permitted datagram reusing a
    /// denied tuple had its head forwarded and its tails dropped, recurring on every wrap for
    /// as long as the entry lived. A forwarded head is the classifier's own statement that the
    /// tuple's current datagram is permitted, and the table must not contradict it; the caller
    /// states what that trade costs and why it is accepted.
    /// pinned: ChainedOutboundPacketClassifierTests.testAPermittedHeadReusingAnIdentificationClearsTheStaleDenial
    public mutating func forget(_ identity: ChainedFragmentIdentity) {
        if let existing = entries.firstIndex(of: identity) { entries.remove(at: existing) }
    }

    /// Identities currently remembered. Diagnostics and tests only.
    public var rememberedCount: Int { entries.count }
}
