import Foundation
import LavaSecKit

/// Per-destination send/receipt accounting for one chained session, bounded and allocation-free
/// on the packet path.
///
/// `INV-CHAIN-6`. The counting half of the split described on ``ChainedDestinationReachabilityPolicy``: this type
/// observes packets and owns no thresholds; the policy owns the thresholds and observes nothing.
/// It exists because a split-tunnel chain's aggregate counters cannot distinguish "the chain is up
/// and carrying your traffic" from "the chain is up and the host you want is silent" — see that
/// type for the field capture and for why raising the aggregate's fidelity can never close it.
///
/// ## IPv4 only, by construction rather than by omission
///
/// The key is a 32-bit IPv4 address because while chained there is no other kind of in-tunnel
/// destination: `ChainedOutboundPacketClassifier` drops every outbound IPv6 packet and chained
/// mode claims `::/0` deliberately so those packets are drawn in and blackholed rather than
/// escaping around the tunnel (`INV-CHAIN-1`). A v6 row could therefore only ever record sends
/// that this process itself discarded, which is not a statement about a destination's
/// reachability. If that ever changes, this key changes with it.
///
/// ## Memory (`INV-MEM-1`)
///
/// Fixed capacity, no per-packet allocation, no dictionary. The storage is a flat array of
/// ``Entry`` sized once at init and never grown; a full table overwrites in place rather than
/// appending, so after warm-up the hot path performs zero heap traffic.
public struct ChainedDestinationTable: Sendable {
    /// How many destinations are tracked at once.
    ///
    /// NOT chosen for its memory cost, which is negligible: an entry is an address, two counters
    /// and three instants — under 48 bytes — so the whole table is about 1.5 KB, three orders of
    /// magnitude below anything the ~50 MB `INV-MEM-1` ceiling reacts to. Doubling it again would
    /// still be free.
    ///
    /// It is chosen for EVICTION. The failure this type reports is "the one host you are waiting
    /// on is silent", so the only harmful eviction is of that host, crowded out by other in-range
    /// chatter. A split tunnel's claimed range is typically a whole tailnet: peer nodes, the
    /// resolver (which sits inside the range in the capture that motivated this), plus discovery
    /// and multicast noise. Sixteen is within reach of that; thirty-two is not, and the entry the
    /// user is actively sending to is by definition the youngest by activity, so it is the last
    /// thing evicted rather than the first.
    ///
    /// The capacity only holds that promise because eviction order is a per-packet SEQUENCE rather
    /// than a timestamp — see ``Entry/lastActivityOrder``. With one-second granularity a burst made
    /// every row compare equally old and the youngest was evicted anyway (Codex P2, PR #593).
    ///
    /// Unlike `ChainedDroppedFragmentTable` — the same number, for unrelated reasons — eviction
    /// here is not fail-closed in any direction. An evicted destination loses a REPORT, gates
    /// nothing, and surrenders nothing, so the honest bias is generous rather than tight.
    /// pinned: ChainedDestinationTableTests.testTheDestinationBeingSentToSurvivesAFullTableOfChatter
    public static let capacity = 32

    /// One destination's raw accounting. Trivial and inline; the array holds these by value.
    private struct Entry {
        var address: UInt32
        var sentPacketCount: UInt64
        var receivedPacketCount: UInt64
        /// Anchor of the open unanswered window, or `nil` once a receipt closed it.
        var firstUnansweredSendAtSeconds: Int?
        /// Sends since this window was anchored. Reset by a receipt and by a re-anchor, so it is
        /// the demand behind THIS wait — see `ChainedDestinationReachabilityPolicy.sustainedSendFloor`.
        var sendsInCurrentWindow: UInt64
        var lastSendAtSeconds: Int
        /// Order of last send OR receipt, on a counter that ticks once per recorded packet.
        ///
        /// A SEQUENCE, not a timestamp, and the difference is load-bearing. This was
        /// `lastActivityAtSeconds`, which has one-second granularity — so with 32 destinations
        /// active inside a single second every row compared equal, the strict `<` in
        /// ``indexEnsuringEntry(for:atSeconds:)`` never moved off index 0, and the next new
        /// destination evicted whatever was inserted first. A send to the wanted host immediately
        /// beforehand could not protect it: bursty tailnet traffic discarded precisely the row
        /// this table exists to keep (Codex P2, PR #593). A per-packet counter has no ties.
        ///
        /// It must be activity rather than receipt: keying on receipts would make a silent
        /// destination the first evicted, which is the same row by another route.
        var lastActivityOrder: UInt64
    }

    private var entries: [Entry] = []

    /// Ticks once per recorded packet, so ``Entry/lastActivityOrder`` is total and tie-free.
    /// `&+= 1` because a wrap after 2^64 packets would still order correctly for any window that
    /// fits in the table, and a trap inside a Network Extension is a tunnel abort.
    private var activityCounter: UInt64 = 0

    /// Index of the entry touched last. The packet path arrives in bursts to one destination, so
    /// checking this before scanning turns the common case into a single comparison and leaves
    /// the linear scan for the rare change of destination. A stale hint is harmless — it is only
    /// ever used after its address is confirmed to match.
    private var hotIndex: Int = 0

    /// An empty table sized once. The reserve is the whole memory story: after this the storage
    /// never grows, and a full table overwrites in place rather than reallocating.
    public init() {
        entries.reserveCapacity(Self.capacity)
    }

    /// Records one packet sent into the tunnel toward `address`.
    ///
    /// Opens an unanswered window if none is open. If the previous send is older than
    /// ``ChainedDestinationReachabilityPolicy/demandContinuitySeconds`` the window is RE-ANCHORED
    /// to this send rather than extended: the user asked, stopped, and asked again, and the second
    /// question must not inherit the age of the first. Without this, a destination sent to once
    /// and returned to an hour later would report as unreachable on its very first packet.
    ///
    /// UNLESS THE WINDOW HAS QUALIFIED — past the threshold with
    /// ``ChainedDestinationReachabilityPolicy/sustainedSendFloor`` sends behind it. Then the gaps
    /// ARE the failure (TCP backoff), not a lapse in asking, and re-anchoring on them is what let a
    /// permanent failure disappear from the signal built to report it.
    /// pinned: ChainedDestinationTableTests.testASendAfterALapseReAnchorsTheWindowInsteadOfInheritingIt
    public mutating func recordSend(to address: UInt32, atSeconds now: Int) {
        let index = indexEnsuringEntry(for: address, atSeconds: now)
        entries[index].sentPacketCount &+= 1
        // A window that has ALREADY QUALIFIED is never re-anchored. A stalled TCP connect backs off
        // to gaps far longer than `demandContinuitySeconds`, so the lapse rule would re-anchor on
        // every retransmit and the wait could never accumulate past the threshold twice — which is
        // how a permanently failing host reported for three seconds and then never again
        // (Codex P2, PR #593). Only a receipt clears a qualified window; see
        // `ChainedDestinationReachabilityPolicy.sustainedSendFloor`.
        let anchored = entries[index].firstUnansweredSendAtSeconds
        let qualified =
            anchored.map {
                now - $0 >= ChainedDestinationReachabilityPolicy.unansweredThresholdSeconds
                    && entries[index].sendsInCurrentWindow
                        >= ChainedDestinationReachabilityPolicy.sustainedSendFloor
            } ?? false
        let lapsed =
            now - entries[index].lastSendAtSeconds
            >= ChainedDestinationReachabilityPolicy.demandContinuitySeconds
        if anchored == nil || (lapsed && !qualified) {
            entries[index].firstUnansweredSendAtSeconds = now
            entries[index].sendsInCurrentWindow = 1
        } else {
            entries[index].sendsInCurrentWindow &+= 1
        }
        entries[index].lastSendAtSeconds = now
        activityCounter &+= 1
        entries[index].lastActivityOrder = activityCounter
    }

    /// Records one packet delivered out of the tunnel from `address`, closing its window.
    ///
    /// An address with no entry is IGNORED rather than admitted. The table's population is driven
    /// by demand — a destination nobody asked about has no window to close, and admitting it would
    /// let unsolicited inbound traffic evict the row the user is waiting on, which is the one
    /// eviction ``capacity`` is sized to prevent.
    /// pinned: ChainedDestinationTableTests.testAReceiptFromAnUnknownSourceDoesNotClaimASlot
    public mutating func recordReceipt(from address: UInt32, atSeconds now: Int) {
        guard let index = indexOfExistingEntry(for: address) else { return }
        entries[index].receivedPacketCount &+= 1
        entries[index].firstUnansweredSendAtSeconds = nil
        entries[index].sendsInCurrentWindow = 0
        activityCounter &+= 1
        entries[index].lastActivityOrder = activityCounter
        hotIndex = index
    }

    /// This destination's raw accounting, or `nil` if it is not tracked.
    public func observation(for address: UInt32) -> ChainedDestinationObservation? {
        guard let index = indexOfExistingEntry(for: address) else { return nil }
        return Self.observation(of: entries[index])
    }

    /// Every tracked destination, in no meaningful order.
    ///
    /// The one allocating member, and deliberately so: it is read on the outage driver's tick, not
    /// on the packet path, and at most ``capacity`` elements. Nothing on the hot path calls it.
    public var destinations: [(address: UInt32, observation: ChainedDestinationObservation)] {
        entries.map { (address: $0.address, observation: Self.observation(of: $0)) }
    }

    /// How many destinations are tracked. Diagnostics and tests only.
    public var trackedCount: Int { entries.count }

    private static func observation(of entry: Entry) -> ChainedDestinationObservation {
        ChainedDestinationObservation(
            sentPacketCount: entry.sentPacketCount,
            receivedPacketCount: entry.receivedPacketCount,
            firstUnansweredSendAtSeconds: entry.firstUnansweredSendAtSeconds,
            lastSendAtSeconds: entry.lastSendAtSeconds,
            sendsInCurrentWindow: entry.sendsInCurrentWindow)
    }

    private func indexOfExistingEntry(for address: UInt32) -> Int? {
        if hotIndex < entries.count, entries[hotIndex].address == address { return hotIndex }
        return entries.firstIndex { $0.address == address }
    }

    /// The index for `address`, creating or REPLACING an entry when it is not tracked yet.
    ///
    /// Replacement overwrites the least recently active slot in place; the array is never
    /// reordered and never grown past ``capacity``, so no packet allocates. Ties go to the lowest
    /// index; with ``Entry/lastActivityOrder`` being a per-packet counter there are no ties to
    /// break, but the rule is stated so a future coarser key cannot reintroduce them silently.
    private mutating func indexEnsuringEntry(for address: UInt32, atSeconds now: Int) -> Int {
        if let existing = indexOfExistingEntry(for: address) {
            hotIndex = existing
            return existing
        }
        let fresh = Entry(
            address: address,
            sentPacketCount: 0,
            receivedPacketCount: 0,
            firstUnansweredSendAtSeconds: nil,
            sendsInCurrentWindow: 0,
            lastSendAtSeconds: now,
            lastActivityOrder: activityCounter &+ 1)
        if entries.count < Self.capacity {
            entries.append(fresh)
            hotIndex = entries.count - 1
            return hotIndex
        }
        var oldest = 0
        for index in 1..<entries.count
        where entries[index].lastActivityOrder < entries[oldest].lastActivityOrder {
            oldest = index
        }
        entries[oldest] = fresh
        hotIndex = oldest
        return oldest
    }
}
