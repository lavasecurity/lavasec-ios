import Foundation
import LavaSecKit

/// What happened to a packet offered to a bounded queue.
public enum ChainedQueueAdmission: Equatable, Sendable {
    /// Queued with room to spare.
    case admitted
    /// Queued, after evicting this many of the oldest packets to make room.
    case admittedAfterEvicting(packets: Int, bytes: Int)
    /// Larger than the whole byte budget, so no amount of eviction could ever fit it. The
    /// queue is left untouched — evicting everything for a packet that still would not fit
    /// would discard live traffic and gain nothing.
    case refusedOversized(bytes: Int, limit: Int)
    /// A zero-length packet. Nothing to send, and admitting it would let a stream of them
    /// consume the packet budget while moving no bytes.
    case refusedEmpty
    /// The queue has no packet capacity at all, whatever the packet's size. Kept distinct from
    /// ``refusedOversized`` because they point at different bugs: this one says the limits are
    /// degenerate, that one says the arrival is too big.
    case refusedNoCapacity
}

/// How much the tunnel may hold on a packet's behalf.
///
/// ## Why a byte budget and not just a packet count
///
/// The engine bounds its own queue by COUNT (`MAX_QUEUE_DEPTH`), which is fine for it: every
/// packet it queues is one it produced under a known MTU. Ours accepts whatever the tunnel
/// interface hands over, and a count alone does not bound memory — 256 packets is 328 KB at
/// MTU 1280 and several megabytes if something upstream offers jumbo buffers. `INV-MEM-1`
/// bounds the NE process at ~50 MB with the engine and its session state already resident, so
/// the constraint that actually matters is bytes.
public struct ChainedPacketQueueLimits: Equatable, Sendable {
    public let maximumPackets: Int
    public let maximumBytes: Int

    /// Clamped at BOTH ends, and the top end matters as much as the bottom.
    ///
    /// The bottom was always clamped; the top was not, and the ring made that a defect rather
    /// than a curiosity. Storage is allocated eagerly at `maximumPackets` slots, so a caller
    /// passing ten million built ten million slots before the first packet arrived — residency
    /// set by the packet bound, escaping the byte budget entirely, in a process bounded at
    /// ~50 MB. The growing array this replaced merely wasted the limit; the ring traps on it.
    ///
    /// `engineQueueDepth` is the ceiling for the same reason it is the default: a queue deeper
    /// than the thing it feeds cannot raise throughput, so above it every slot is pure latency
    /// and resident memory.
    /// pinned: ChainedPacketQueueTests.testAnAbsurdPacketLimitIsClampedRatherThanAllocated
    public init(maximumPackets: Int, maximumBytes: Int) {
        self.maximumPackets = min(max(0, maximumPackets), Self.engineQueueDepth)
        self.maximumBytes = max(0, maximumBytes)
    }

    /// The engine's own queue depth, which is the ceiling for ours.
    ///
    /// Not a preference. A queue deeper than the thing it feeds cannot raise throughput — the
    /// engine drains at its own rate regardless — so every extra slot only adds latency and
    /// resident memory. That is textbook bufferbloat, and here it is also a jetsam risk.
    ///
    /// Matching rather than exceeding also keeps the failure legible: when packets are being
    /// shed, there is one queue to look at, not a shallow one hiding behind a deep one.
    /// pinned: ChainedPacketQueueTests.testTheDepthCeilingIsReadFromTheEngineNotRestated
    public static let engineQueueDepth = 256

    /// The largest MTU this queue will size itself for.
    ///
    /// The engine's own datagram ceiling, not the IP maximum. 65535 was the first answer and
    /// it is far too generous: 256 x 65535 is ~16 MB per direction, over 32 MB for both,
    /// inside a process bounded at ~50 MB with the engine and its session state already
    /// resident. A "bound" that large is a bound in name only.
    ///
    /// The engine cannot produce a datagram bigger than this, so nothing legitimate is lost.
    public static let maximumPlausibleMTU = WireGuardSession.maximumDatagramByteCount

    /// Limits for one direction of a chained tunnel, or `nil` when `mtu` is not an MTU.
    ///
    /// `mtu` is the chained plan's MTU (1280, the IPv6 minimum). The byte budget is the depth
    /// times the MTU, so the two bounds agree instead of one silently dominating: at 1280 that
    /// is 320 KB per direction, 640 KB across both, against a ~50 MB process ceiling.
    ///
    /// Input below the chained plan's MTU is REFUSED rather than clamped. Clamping fabricated an
    /// apparently valid 256-byte queue that refuses every ordinary packet as oversized — a
    /// caller bug presenting as a working queue that drops all traffic, which is the hardest
    /// shape to diagnose. Returning nil makes the caller's mistake its own.
    public static func forChainedTunnel(mtu: Int) -> ChainedPacketQueueLimits? {
        guard mtu > 0 else { return nil }
        // Clamped at the top, REJECTED at the bottom — the two ends are handled differently,
        // and the guard below is what enforces the floor.
        //
        // Two earlier versions were wrong in the same direction. Saturating the product at
        // `Int.max` on overflow inverted the type's purpose entirely — with the byte budget
        // infinite, the packet count is the only defence, so 256 packets of a gigabyte each is
        // ~256 GB resident and every one reports as admitted. Clamping to 65535 replaced that
        // with ~16 MB per direction, over 32 MB for both, inside a ~50 MB process: smaller,
        // still not a bound.
        //
        // Clamping to the ENGINE's datagram ceiling is the honest one: 256 x 1532 is ~392 KB
        // per direction, ~766 KB for both, and the engine cannot produce anything larger so
        // nothing legitimate is lost.
        //
        // Below the chained plan's MTU is refused rather than raised: a positive-but-tiny
        // value like 1 passed the nonpositive guard and produced an apparently usable
        // 256-byte queue that refuses every real packet as oversized — the same
        // silently-drops-everything shape, reached by a different input.
        guard mtu >= TunnelRoutePlan.minimumIPv6LinkMTU else { return nil }
        let clampedMTU = min(mtu, maximumPlausibleMTU)
        return ChainedPacketQueueLimits(
            maximumPackets: engineQueueDepth,
            maximumBytes: engineQueueDepth * clampedMTU
        )
    }
}

/// A bounded, back-pressured packet queue.
///
/// ## The failure this exists to prevent
///
/// Unbounded buffering in the extension is the documented SpeedTest jetsam mode: a fast
/// downlink offers packets faster than the engine can encapsulate them, the queue grows to
/// absorb the difference, and the process is killed for exceeding its memory limit. The user
/// sees the VPN drop mid-transfer. Bounding the queue converts that into packet loss, which
/// every transport above it already handles.
///
/// ## Why the OLDEST packet is evicted, where the engine drops the newest
///
/// `boringtun`'s `queue_packet` refuses the incoming packet once `MAX_QUEUE_DEPTH` is reached.
/// That is right for its queue, which holds traffic waiting for a handshake to complete — the
/// backlog is the point, and it drains in order the moment a session exists.
///
/// This queue is a different thing: it absorbs a rate mismatch on an established session, and
/// under sustained overload it is always full. A packet that has sat here longer than the path
/// RTT is already useless — TCP has retransmitted it, so delivering it spends bandwidth on
/// something the receiver will discard as a duplicate. Evicting the oldest therefore delivers
/// strictly more useful bytes than refusing the newest, and it bounds queueing delay instead
/// of pinning it at the full depth.
///
/// The cost is reordering, which is real and accepted: TCP recovers by fast retransmit, and a
/// queue that is overflowing has already caused loss by definition.
/// pinned: ChainedPacketQueueTests.testTheQueueShedsUnderSustainedOverloadRatherThanGrowing
public struct ChainedPacketQueue: Sendable {
    public let limits: ChainedPacketQueueLimits

    /// A fixed ring, not a growing array.
    ///
    /// `Array.removeFirst()` shifts every remaining element, so on the eviction path — which
    /// runs on EVERY arrival once the queue is full, and a full queue is the steady state this
    /// type exists for — each packet cost O(depth). That is the rate mismatch this queue is
    /// meant to absorb being made worse by the absorbing.
    ///
    /// The capacity is known at construction and bounded (`engineQueueDepth`, 256), so the
    /// ring is allocated once and never resized: enqueue, evict and dequeue are all O(1) with
    /// no allocation beyond the one per-packet copy.
    private var storage: [[UInt8]]
    /// Index of the oldest packet. Meaningless when `occupied == 0`.
    private var head = 0
    private var occupied = 0
    private var queuedBytes = 0

    /// Packets evicted or refused since this queue was created. Diagnostics only — the tunnel
    /// reports shedding rather than inferring it from a throughput dip.
    public private(set) var shedPacketCount = 0
    public private(set) var shedByteCount = 0

    public init(limits: ChainedPacketQueueLimits) {
        self.limits = limits
        // `max(0,)` because a zero-capacity queue is a representable configuration — the
        // `maximumPackets > 0` guard in `enqueue` reports it as `refusedNoCapacity` — and
        // `Array(repeating:count:)` traps on a negative count.
        self.storage = Array(repeating: [], count: max(0, limits.maximumPackets))
    }

    public var count: Int { occupied }
    public var byteCount: Int { queuedBytes }
    public var isEmpty: Bool { occupied == 0 }

    /// Drops the oldest packet, returning it. The caller has already checked `occupied > 0`.
    ///
    /// The vacated slot is reset to an empty array rather than left holding the packet. The
    /// ring outlives its entries, so a stale slot would keep that buffer alive after the
    /// packet was accounted as gone — `queuedBytes` would fall while the memory did not, which
    /// is exactly the accounting-vs-residency gap this type exists to close (`INV-MEM-1`).
    private mutating func dropOldest() -> [UInt8] {
        let packet = storage[head]
        storage[head] = []
        head = (head + 1) % storage.count
        occupied -= 1
        queuedBytes -= packet.count
        return packet
    }

    /// Offers a BORROWED packet, copying it once.
    ///
    /// The overload that matters on the congestion path. Going through the array form cost two
    /// copies of every parked packet — one to make the `[UInt8]`, one for the queue's own compact
    /// storage — which doubles allocation and memcpy exactly where memory and CPU pressure are
    /// already highest, and contradicts this type's stated one-copy-per-packet design.
    /// 🔴 NOT BEHAVIOURALLY OBSERVABLE, which is why the pin below is a source assertion and why
    /// the original one caught nothing. Forwarding to the array form leaves the queue in
    /// byte-for-byte identical state — same counters, same admission value, same dequeued bytes —
    /// so every assertion the old test could make held equally for the defect it was named after
    /// (sweep, PR #623). The difference is an allocation and a memcpy, and the only instrument
    /// that sees it is the shape of this function.
    /// pinned: ChainedPacketQueueTests.testABorrowedPacketIsCopiedExactlyOnce
    @discardableResult
    public mutating func enqueue(_ packet: UnsafeRawBufferPointer) -> ChainedQueueAdmission {
        guard !packet.isEmpty else {
            shedPacketCount += 1
            return .refusedEmpty
        }
        guard limits.maximumPackets > 0 else {
            shedPacketCount += 1
            shedByteCount += packet.count
            return .refusedNoCapacity
        }
        guard packet.count <= limits.maximumBytes else {
            shedPacketCount += 1
            shedByteCount += packet.count
            return .refusedOversized(bytes: packet.count, limit: limits.maximumBytes)
        }
        var evictedPackets = 0
        var evictedBytes = 0
        while occupied > 0
            && (occupied + 1 > limits.maximumPackets
                || queuedBytes + packet.count > limits.maximumBytes)
        {
            let evicted = dropOldest()
            evictedPackets += 1
            evictedBytes += evicted.count
        }
        var owned = [UInt8]()
        owned.reserveCapacity(packet.count)
        owned.append(contentsOf: packet)
        storage[(head + occupied) % storage.count] = owned
        occupied += 1
        queuedBytes += owned.count
        shedPacketCount += evictedPackets
        shedByteCount += evictedBytes
        return evictedPackets == 0
            ? .admitted
            : .admittedAfterEvicting(packets: evictedPackets, bytes: evictedBytes)
    }

    /// Offers a packet, evicting the oldest as needed to stay inside both bounds.
    @discardableResult
    public mutating func enqueue(_ packet: [UInt8]) -> ChainedQueueAdmission {
        guard !packet.isEmpty else {
            shedPacketCount += 1
            return .refusedEmpty
        }
        // Two different refusals, kept apart because the device log has to be able to tell
        // them apart. A packet that fits the byte budget but arrives at a queue with no packet
        // capacity is not oversized, and reporting it as `refused-oversized` sends anyone
        // reading the log looking for a jumbo frame that does not exist.
        guard limits.maximumPackets > 0 else {
            shedPacketCount += 1
            shedByteCount += packet.count
            return .refusedNoCapacity
        }
        guard packet.count <= limits.maximumBytes else {
            shedPacketCount += 1
            shedByteCount += packet.count
            return .refusedOversized(bytes: packet.count, limit: limits.maximumBytes)
        }

        var evictedPackets = 0
        var evictedBytes = 0
        // Both bounds, and the packet bound leaves room for the arrival rather than merely
        // being satisfied — otherwise a full queue admits one more and exceeds its own limit.
        while occupied > 0
            && (occupied + 1 > limits.maximumPackets
                || queuedBytes + packet.count > limits.maximumBytes)
        {
            let evicted = dropOldest()
            evictedPackets += 1
            evictedBytes += evicted.count
        }

        // Stored COMPACT, not as handed over. `[UInt8]` is copy-on-write, so appending the
        // caller's array retains ITS backing buffer — a multi-megabyte allocation trimmed to a
        // few bytes still pins the whole thing. The queue would then report a few hundred
        // kilobytes while holding arbitrary memory, which is precisely the jetsam bound this
        // type exists to provide, defeated by an accounting that measures `count` and a buffer
        // that is sized by `capacity`.
        //
        // One copy per packet, bounded by the byte budget that is already enforced above.
        var owned = [UInt8]()
        owned.reserveCapacity(packet.count)
        owned.append(contentsOf: packet)
        storage[(head + occupied) % storage.count] = owned
        occupied += 1
        queuedBytes += owned.count
        shedPacketCount += evictedPackets
        shedByteCount += evictedBytes

        return evictedPackets == 0
            ? .admitted
            : .admittedAfterEvicting(packets: evictedPackets, bytes: evictedBytes)
    }

    /// Removes and returns the oldest packet.
    public mutating func dequeue() -> [UInt8]? {
        guard occupied > 0 else { return nil }
        return dropOldest()
    }

    /// Discards everything without counting it as shed.
    ///
    /// Used when a session ends: those packets were not dropped under pressure, they belong to
    /// a tunnel that no longer exists. Counting them would make a reconnect look like
    /// congestion in the diagnostics.
    public mutating func removeAll() {
        // A fresh ring rather than a loop clearing each slot. Both release the packets, but
        // only this one is correct BY CONSTRUCTION: a loop that misses a slot leaves a buffer
        // resident while the queue reports empty, and that difference is invisible to a
        // behavioural test — every observable (`count`, `byteCount`, ordering) is identical
        // either way, so the loop version was verified by reading it. Assigning a new array
        // cannot leave a stale entry, so there is nothing left to get wrong.
        //
        // One allocation, on session end, which is not a path under time pressure.
        storage = Array(repeating: [], count: storage.count)
        head = 0
        occupied = 0
        queuedBytes = 0
    }
}

extension ChainedQueueAdmission {
    /// Whether the queue kept the packet.
    public var wasQueued: Bool {
        switch self {
        case .admitted, .admittedAfterEvicting:
            return true
        case .refusedOversized, .refusedEmpty, .refusedNoCapacity:
            return false
        }
    }

    /// Stable identifier for device logs. Never user copy.
    public var logValue: String {
        switch self {
        case .admitted:
            return "queued"
        case .admittedAfterEvicting(let packets, _):
            return "queued-evicting-\(packets)"
        case .refusedOversized:
            return "refused-oversized"
        case .refusedEmpty:
            return "refused-empty"
        case .refusedNoCapacity:
            return "refused-no-capacity"
        }
    }
}
