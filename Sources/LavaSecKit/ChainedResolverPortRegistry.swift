import Darwin
import Foundation

/// The local source ports this process currently holds for its own tunnel-pinned DNS queries.
///
/// ## What this is for
///
/// `ChainedOutboundPacketClassifier` drops TCP/53 by design: a DNS-over-TCP packet it cannot
/// read must not be handed to the upstream operator unfiltered. After S8.7b our OWN resolver
/// socket is pinned to the tunnel, so our own retry arrives at that classifier looking exactly
/// like a user app's DNS-over-TCP, and is dropped. This registry is how the classifier tells
/// the two apart.
///
/// The key is the LOCAL SOURCE PORT, and never the destination address. Narrowing DNS
/// interception by destination would hand every hardcoded-resolver query to the upstream
/// operator unfiltered — a leak closed deliberately and pinned by
/// `testADNSQueryToAPublicResolverIsStillIntercepted`.
///
/// ## What a claim is NOT: it is not a capability the kernel enforces
///
/// The obvious reading of this type is "we hold the port, so nobody else can have it". That is
/// FALSE on Darwin, and it was measured rather than assumed (2026-07-29, Darwin 25.1) because
/// the whole carve-out rests on it:
///
/// - Another socket binding the same port PLAIN fails `EADDRINUSE`, in every holding pattern.
/// - Another socket binding it with `SO_REUSEADDR` or `SO_REUSEPORT` **succeeds** — a
///   specific-address bind over our wildcard bind, or a wildcard bind over a specific one.
/// - Holding the port on a CONNECTED socket is WORSE, not better: four of six co-bind variants
///   succeed there, so claiming after `connect` is not a hardening and is not what we do.
///
/// So the honest property is not "cannot" but this: **an attacker must GUESS a kernel-randomised
/// ephemeral port inside its lifetime.** They get no oracle — a `SO_REUSEADDR` bind succeeds
/// whether or not we hold the port, so probing reveals nothing — but a wide speculative bind
/// across the ephemeral range is not prevented, and would let some of their DNS-over-TCP reach
/// the upstream unfiltered.
///
/// That residual is written here rather than argued away because the alternative designs were
/// worse in a way that is easy to understate: a compile-time reserved port range is a published
/// constant in a repository that gets promoted to public, free and reliable forever. This is a
/// blind race against a moving target. Both are non-zero; they are not comparable in cost.
/// pinned: ChainedResolverPortRegistryTests.testAClaimIsNotAKernelEnforcedCapability
///
/// ## Every failure direction narrows
///
/// An unclaimed port drops. An expired entry drops. A malformed packet drops. A claim that would
/// exceed either bound is REFUSED rather than making room, so no BOUND ever removes an entry
/// before its deadline.
///
/// The one removal that is not a bound is the same-key re-claim in `claim(sourcePort:protocolNumber:)`,
/// and it narrows too: the replacement is appended under the same lock with a deadline at least as
/// far out, so that port's protection is extended rather than interrupted. Stated because the
/// sentence above reads absolute and a reader checking it against the code would find that line
/// (Kilo, PR #623). There is no state of this type that widens the carve-out beyond the ports
/// actually claimed, which is what makes it reviewable.
public final class ChainedResolverPortRegistry: @unchecked Sendable {
    /// The bound on LIVE claims — ports currently carved out of the classifier.
    ///
    /// Two per concurrent resolver query, so eviction is unreachable while the admission bound
    /// (`maxConcurrentResolverQueries`) holds. A nonzero ``evictedWhileLiveCount()`` is therefore
    /// a bug report, not a capacity signal — see the counter's own doc.
    ///
    /// 🔴 IT BOUNDS LIVE ENTRIES ONLY, and that word is the whole fix. This rationale is stated in
    /// terms of CONCURRENCY — "two per concurrent query" — but the check counted every entry in
    /// the array, and after PR #495 the array also holds GRACE records, which by definition belong
    /// to work that already finished. Concurrency bounds nothing about those: their occupancy is
    /// `release-rate × releaseGraceSeconds`, so the effective ceiling became rate-driven while its
    /// justification stayed concurrency-driven.
    ///
    /// Measured cost, device 2026-08-29T10:39Z: `chainedResolverPortRefusedAtCapacity` 7 against
    /// 7 resolutions that reported `socketUnavailable` — an exact match, so EVERY socket failure
    /// that session was this bound, hit at ~2.5 claims/s with at most a couple of sockets
    /// genuinely in flight. Each one cost the user a DNS resolution. After the split, 1843
    /// resolutions over a four-hour session refused none (device 2026-08-29T11:11–15:14Z).
    public static let capacity = 16

    /// The separate bound on GRACE records — ports we no longer hold but must not serve yet.
    ///
    /// A DIFFERENT POPULATION WITH A DIFFERENT SHAPE, which is why it gets its own number rather
    /// than sharing one. Live entries are bounded by concurrency; grace records are bounded by
    /// RATE (`release-rate × releaseGraceSeconds`), and mixing the two put a rate-driven quantity
    /// under a concurrency-derived ceiling.
    ///
    /// Sized as a MEMORY backstop, not a correctness bound. The admission gate gives at most
    /// `maxConcurrentResolverQueries` sockets in flight; even at a pathological ~170 releases per
    /// second this cannot fill, and the entries are four scalars each — kilobytes against the
    /// ~50 MB NE ceiling (`INV-MEM-1`). It exists so an unforeseen release storm cannot grow the
    /// array without limit, never as something a healthy device approaches. Hitting it REFUSES
    /// the claim; it never drops a record early — see `claim(sourcePort:protocolNumber:)`.
    public static let graceCapacity = 512

    /// A leak backstop, NOT a correctness bound.
    ///
    /// Many times the TCP DNS timeout, so it can never end a healthy transaction; it exists
    /// only to bound an entry whose release never ran. A carve-out that outlives its socket is
    /// the one way this type can widen over time.
    public static let maximumEntryLifetimeSeconds = 30

    /// An outstanding claim.
    ///
    /// Opaque on purpose: the initializer is internal, so a caller cannot fabricate one, and
    /// cannot release a port it did not claim.
    public struct Claim: Equatable, Sendable {
        public let sourcePort: UInt16
        public let protocolNumber: UInt8

        internal init(sourcePort: UInt16, protocolNumber: UInt8) {
            self.sourcePort = sourcePort
            self.protocolNumber = protocolNumber
        }
    }

    /// How long a released port stays UNSERVABLE as client DNS after its claim ends.
    ///
    /// Not an extension of the claim, and the distinction is the whole design. A packet is
    /// classified on the engine queue, which it reaches through `queue.async` — so an
    /// own-resolver query can arrive while its port is held and be classified after the socket
    /// was torn down. `claims()` is false by then, so the query reads as a CLIENT query and is
    /// handed to the resolver, which answers it by sending another: the self-resolution loop,
    /// through a window neither the carve-out nor a first-arrival rule can see (Codex, PR #495).
    ///
    /// During grace the port is NOT carved out — `claims()` still answers false, so nothing new
    /// egresses on it. The only thing that changes is that a port-53 packet carrying it is
    /// DROPPED rather than served. That is why this does not reopen what
    /// ``releaseAndClose(_:descriptor:)`` rejected: holding the claim itself would widen the
    /// guess window against an `SO_REUSEADDR` co-binder, and this widens nothing — a co-binder
    /// gains the ability to have its port-53 packets dropped, which it could achieve by not
    /// sending them.
    ///
    /// Three seconds, sized against engine-queue backlog rather than either resolver timeout:
    /// the window being closed is arrival-to-classification, not query-to-answer. The cost of
    /// being wrong high is that a client query reusing the port within the window is dropped and
    /// its client retries; the cost of being wrong low is the loop. `INV-DNS-1` picks the drop.
    public static let releaseGraceSeconds = 3

    private struct Entry {
        /// While this is in the future the port is OURS: carved out, never served as DNS.
        var deadlineNanoseconds: UInt64
        /// While this is in the future but `deadlineNanoseconds` has passed, the port is no
        /// longer ours to use and not safe to serve either. See ``releaseGraceSeconds``.
        var graceDeadlineNanoseconds: UInt64
        var sourcePort: UInt16
        var protocolNumber: UInt8
    }

    // `os_unfair_lock` rather than NSLock: this is read once per outbound TCP/53 packet on the
    // data path, the critical section is a bounded array scan, and there is no waiting involved
    // — the exact shape unfair-lock is for.
    private var lock = os_unfair_lock_s()
    private var entries: ContiguousArray<Entry>
    private var evictedWhileLive = 0
    /// Claims refused because every entry was still inside its window.
    ///
    /// Nonzero means 16 resolver sockets were simultaneously unexpired, which per-query sockets on
    /// a 1-second timeout should never reach. Surfaced so the bound being hit is visible rather
    /// than inferred from a DNS failure.
    private var refusedAtCapacity = 0
    /// Claims refused because the GRACE population was at its backstop. ALWAYS ZERO at any release
    /// rate the admission bound permits — nonzero means `graceCapacity` is mis-sized, not that the
    /// device is unhealthy.
    private var refusedAtGraceCapacity = 0
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let closeDescriptor: @Sendable (Int32) -> Void
    private let shutdownDescriptor: @Sendable (Int32) -> Void

    /// - Parameters:
    ///   - uptimeNanoseconds: the clock, injected so expiry is testable without sleeping.
    ///   - closeDescriptor: injected so ``releaseAndClose(_:descriptor:)``'s ORDER is provable
    ///     by a behavioural test rather than a source pin — the ordering is what the residual
    ///     analysis above depends on.
    ///   - shutdownDescriptor: injected for the same reason — the FIN's ordering relative to the
    ///     release is the property, and it is only observable from inside the seam.
    public init(
        uptimeNanoseconds: @escaping @Sendable () -> UInt64,
        closeDescriptor: @escaping @Sendable (Int32) -> Void = { Darwin.close($0) },
        shutdownDescriptor: @escaping @Sendable (Int32) -> Void = { _ = Darwin.shutdown($0, SHUT_RDWR) }
    ) {
        self.uptimeNanoseconds = uptimeNanoseconds
        self.closeDescriptor = closeDescriptor
        self.shutdownDescriptor = shutdownDescriptor
        self.entries = ContiguousArray()
        self.entries.reserveCapacity(Self.capacity)
    }

    /// Runs `body` under the lock, with a timestamp read INSIDE the critical section.
    ///
    /// 🔴 THE ORDER IS THE INVARIANT, and reading the clock one line earlier is a real bug rather
    /// than a style point. Three accessors used to read `uptimeNanoseconds()` and THEN take the
    /// lock, so a `releaseAndClose` that won the race could demote an entry with a LATER timestamp
    /// than the one the reader was about to compare against — and `entry.deadline > staleNow` then
    /// answers for a state that no longer exists.
    ///
    /// The two directions it broke are not equally bad, which is why this is structural now:
    /// - ``claimedCount()`` counted a just-released grace record as LIVE, inflating the occupancy
    ///   gauge whose entire job is to separate live pressure from grace records (Codex, PR #623).
    /// - ``claims(sourcePort:protocolNumber:)`` answered TRUE for a port whose claim had just
    ///   ended — and that one WIDENS the carve-out, the single direction this type's header
    ///   promises never happens. Microseconds wide and it needs the port reused instantly, but
    ///   "narrow window" is not the property the header claims.
    ///
    /// A helper rather than three corrected call sites: the ordering cannot be got wrong at a call
    /// site that has no timestamp to read.
    /// pinned: ChainedResolverPortRegistryTests.testEveryDeadlineComparisonReadsItsClockUnderTheLock
    private func withLockedNow<T>(_ body: (UInt64) -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body(uptimeNanoseconds())
    }

    /// Records that this process holds `sourcePort` for `protocolNumber`.
    ///
    /// Returns nil for any protocol that is not TCP or UDP: the key carries the protocol so a
    /// future UDP claim cannot satisfy a TCP lookup, and a value outside that set is a caller
    /// bug rather than something to store.
    public func claim(sourcePort: UInt16, protocolNumber: UInt8) -> Claim? {
        guard protocolNumber == UInt8(IPPROTO_TCP) || protocolNumber == UInt8(IPPROTO_UDP) else {
            return nil
        }
        // Port 0 is "the kernel did not assign one", never a real source port. Storing it would
        // carve out every packet whose port we failed to read.
        guard sourcePort != 0 else { return nil }

        return withLockedNow { now in
        // ONE clock read for the whole decision, and it is the LOCKED one. The sweep, the live
        // count, the grace backstop and the new entry's own deadline must all derive from the
        // SAME instant, or an entry can be swept as expired and still counted as live in the same
        // pass. The deadline used to be computed before the lock, which made a claim's lifetime
        // start marginally before the claim existed — harmless in direction (it expires sooner)
        // but a second clock reading for no reason.
        let deadline = now &+ UInt64(Self.maximumEntryLifetimeSeconds) &* 1_000_000_000
        // Purged on the way in, because entries now outlive their claims by the grace window
        // and a swept-on-read design would let expired ones occupy the slots forever.
        entries.removeAll { $0.graceDeadlineNanoseconds <= now }

        // REFUSED, NOT EVICTED, once every remaining entry is still inside its window — and the
        // reason is that no choice of victim is safe.
        //
        // Dropping a GRACE record lets a delayed own-resolver packet from that port classify as a
        // client query, which restarts the unbounded self-resolution loop the window exists to
        // prevent. Dropping a LIVE claim removes the entry outright, so the same packet reaches
        // the same classification by a shorter route. Re-ordering does not help either: a grace
        // record's deadline is always nearer than a live claim's, so it stays the first victim
        // whichever field the comparison uses. Eviction is not a solution space here
        // (Codex, PR #495).
        //
        // So the bound pushes back on the caller instead. A nil claim refuses the socket, that
        // query fails, and its client retries — the fail-closed direction `INV-DNS-1` takes
        // everywhere else, and the only one that trades no leak for another. This REPLACES the
        // evict-oldest policy; `evictedWhileLiveCount()` is retained and now always answers zero,
        // because a counter whose meaning changed is worse than one that is simply quiet.
        //
        // 🔴 COUNTED OVER LIVE ENTRIES ONLY. The refusal above is the right answer for "too many
        // sockets are open at once"; it is the WRONG answer for "a lot of sockets closed
        // recently", which is what a shared count made it also mean. Grace records hold no port
        // — `claims()` already answers false for them — so they cannot contribute to the
        // exhaustion this bound exists to prevent, and letting them consume it turned a
        // concurrency guard into a rate limiter on the DNS path (device 2026-08-29: 7 refusals at
        // ~2 live sockets, 7 lost resolutions).
        // pinned: ChainedResolverPortRegistryTests.testAClaimIsRefusedRatherThanEvictingAnUnexpiredEntry
        // pinned: ChainedResolverPortRegistryTests.testACapacityRefusalDoesNotDropAGraceRecord
        // pinned: ChainedResolverPortRegistryTests.testGraceRecordsDoNotConsumeLiveCapacity
        let liveCount = entries.reduce(into: 0) { total, entry in
            if entry.deadlineNanoseconds > now { total += 1 }
        }
        if liveCount >= Self.capacity {
            refusedAtCapacity += 1
            return nil
        }
        // THE GRACE BACKSTOP REFUSES TOO, and this is the one place the first draft got it
        // backwards. It dropped the record nearest expiry, on the argument that its protection was
        // about to lapse anyway — but "about to" is not "has", and the whole point of a grace
        // record is that a packet from that port may ALREADY be sitting in the engine queue.
        // Dropping it early lets that packet classify as a client query and restarts the
        // self-resolution loop `releaseGraceSeconds` exists to prevent — trading a bounded memory
        // cost for an unbounded descriptor one (Codex, PR #621).
        //
        // So both bounds now answer the same way, which is also the simpler rule: NO ENTRY IS EVER
        // REMOVED BEFORE ITS DEADLINE. The type's "every failure direction narrows" property holds
        // without an exception, and the caller sees the fail-closed refusal `INV-DNS-1` prefers.
        //
        // The cost of refusing here is the one the live bound's fix removed — a caller denied a
        // socket because of work that already finished — and it is accepted only because of the
        // distance: `graceCapacity` is ~200x the release rate this device actually produces
        // (2.5/s observed against the ~170/s needed to fill it). Reaching it means something
        // pathological, and refusing one DNS query is the right response to that.
        // pinned: ChainedResolverPortRegistryTests.testTheGraceBackstopRefusesRatherThanDroppingARecord
        guard entries.count - liveCount < Self.graceCapacity else {
            refusedAtGraceCapacity += 1
            return nil
        }

        entries.removeAll { $0.sourcePort == sourcePort && $0.protocolNumber == protocolNumber }

        entries.append(
            Entry(
                deadlineNanoseconds: deadline,
                graceDeadlineNanoseconds: deadline
                    &+ UInt64(Self.releaseGraceSeconds) &* 1_000_000_000,
                sourcePort: sourcePort,
                protocolNumber: protocolNumber))
        return Claim(sourcePort: sourcePort, protocolNumber: protocolNumber)
        }
    }

    /// Releases `claim` and closes `descriptor`, in that order.
    ///
    /// THE ONLY RELEASE PATH, and it owns the close, so the two cannot drift apart. The order
    /// is load-bearing: the entry is removed under the lock BEFORE `close(2)`, so the claim's
    /// lifetime is a strict subset of the descriptor's and the port returns to the ephemeral
    /// pool with no entry naming it. A nil claim just closes, so the `.systemChosen` path needs
    /// no branch at the call site and cannot grow one.
    ///
    /// ## Why `shutdown(2)` comes first
    ///
    /// `close(2)` on a CONNECTED socket emits a FIN, and that FIN travels the tunnel like any
    /// other packet — so with the claim already gone it reaches the classifier unrecognised and
    /// is dropped as unfilterable DNS. The upstream resolver then holds a half-open connection
    /// until its own idle timeout instead of closing normally (Codex, PR #491).
    ///
    /// `shutdown` emits the FIN while the claim is STILL HELD, so the common case is carried.
    /// It is a strict improvement and not a complete fix, and the residual is named rather than
    /// implied: the tunnel reads from `packetFlow` asynchronously, so a FIN can still arrive
    /// after the release, and a LOST FIN is retransmitted long after it. Those teardown packets
    /// are dropped. Nothing is lost by that — the DNS answer arrived before any of this — and no
    /// local descriptor leaks; the cost is at the upstream, bounded by the truncated-answer rate.
    ///
    /// The obvious alternative, holding the claim past the close, was rejected on a measurement
    /// rather than a preference. After `close(2)` the port is not reassignable at all — a plain
    /// bind still fails `EADDRINUSE` a second later, because TIME_WAIT holds the tuple — so
    /// extending the claim would buy nothing against a plain binder, while widening the guess
    /// window against the `SO_REUSEADDR` co-binder that IS the residual documented on this type.
    /// It would trade a bounded upstream cost for a wider security window.
    /// pinned: ChainedResolverPortRegistryTests.testTheClaimIsReleasedBeforeTheDescriptorIsClosed
    /// pinned: ChainedResolverPortRegistryTests.testTheSocketIsShutDownWhileTheClaimIsStillHeld
    public func releaseAndClose(_ claim: Claim?, descriptor: Int32) {
        // BEFORE the release, so the FIN is emitted while the classifier can still recognise it.
        // Harmless on a socket that never connected: `ENOTCONN`, which we do not act on.
        if claim != nil {
            shutdownDescriptor(descriptor)
        }
        if let claim {
            os_unfair_lock_lock(&lock)
            if let index = entries.firstIndex(where: {
                $0.sourcePort == claim.sourcePort && $0.protocolNumber == claim.protocolNumber
            }) {
                // DEMOTED, NOT DELETED. The claim ends here — `claims()` answers false from this
                // instant, so the port is no longer carved out and the ordering guarantee this
                // function documents is unchanged. What survives is only the memory that the port
                // was ours, so a packet still in the engine queue cannot be served as a client
                // query. See ``releaseGraceSeconds``.
                let now = uptimeNanoseconds()
                entries[index].deadlineNanoseconds = now
                entries[index].graceDeadlineNanoseconds =
                    now &+ UInt64(Self.releaseGraceSeconds) &* 1_000_000_000
            }
            os_unfair_lock_unlock(&lock)
        }
        closeDescriptor(descriptor)
    }

    /// Drops every claim. Tunnel teardown and interface change.
    public func releaseAll() {
        os_unfair_lock_lock(&lock)
        entries.removeAll(keepingCapacity: true)
        os_unfair_lock_unlock(&lock)
    }

    /// Whether this process currently holds `sourcePort` for `protocolNumber`.
    ///
    /// The one hot-path read. False for an unknown port, a mismatched protocol, or an entry
    /// past its deadline — expiry is checked on READ rather than swept, so a stale entry can
    /// never carve out even if nothing ever calls back into this type.
    public func claims(sourcePort: UInt16, protocolNumber: UInt8) -> Bool {
        withLockedNow { now in
            entries.contains {
                $0.sourcePort == sourcePort
                    && $0.protocolNumber == protocolNumber
                    && $0.deadlineNanoseconds > now
            }
        }
    }

    /// Claims refused at capacity. Diagnostics and tests.
    public func refusedAtCapacityCount() -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return refusedAtCapacity
    }

    /// Claims refused at the grace backstop, and a canary rather than a rate.
    ///
    /// Reaching it needs a release rate the admission gate does not permit, so a nonzero value
    /// says the sizing argument on ``graceCapacity`` no longer holds — read it before concluding
    /// anything about the device. Separate from ``refusedAtCapacityCount()`` because the two
    /// refusals have different remedies: that one means too many sockets are open at once, this
    /// one means too many closed recently.
    public func refusedAtGraceCapacityCount() -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return refusedAtGraceCapacity
    }

    /// Live entries dropped to make room.
    ///
    /// ALWAYS ZERO since `claim` began refusing at capacity rather than evicting. Kept rather than
    /// deleted because it is read from the device log: a build that starts reporting a nonzero
    /// value has had the eviction path reintroduced, which is exactly the regression the refusal
    /// exists to prevent.
    /// pinned: ChainedResolverPortRegistryTests.testAClaimIsRefusedRatherThanEvictingAnUnexpiredEntry
    public func evictedWhileLiveCount() -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return evictedWhileLive
    }

    /// Whether `sourcePort` is ours OR was ours recently enough that a packet carrying it may
    /// still be in flight. See ``releaseGraceSeconds``.
    ///
    /// The question the DNS decision asks, and it is deliberately NOT ``claims(sourcePort:protocolNumber:)``:
    /// that one asks whether the port may be used, this one asks whether serving it could feed
    /// our own query back to our own resolver.
    public func wasRecentlyClaimed(sourcePort: UInt16, protocolNumber: UInt8) -> Bool {
        withLockedNow { now in
            entries.contains {
                $0.sourcePort == sourcePort
                    && $0.protocolNumber == protocolNumber
                    && $0.graceDeadlineNanoseconds > now
            }
        }
    }

    /// LIVE claims only — ports actually carved out of the classifier right now.
    ///
    /// Counts what is claimed, not what is remembered: entries outlive their claims by the grace
    /// window, and a count that included them would report a released port as still held. This is
    /// also the population ``capacity`` bounds, so a capture can show occupancy against the bound
    /// instead of inferring it from refusals.
    ///
    /// THE ONLY ACCESSOR FOR THIS NUMBER. A second one (`liveClaimCount()`) was added for the
    /// capture and was this function with the clock read moved inside the lock — two public names
    /// for one gauge, in a type whose whole fix was that one number had been made to mean two
    /// things (Kilo, PR #623).
    public func claimedCount() -> Int {
        withLockedNow { now in entries.count { $0.deadlineNanoseconds > now } }
    }
}
