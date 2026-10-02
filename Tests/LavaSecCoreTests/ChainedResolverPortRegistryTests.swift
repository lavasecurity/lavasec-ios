import Darwin
import XCTest

@testable import LavaSecKit

/// A mutable cell usable from an `@Sendable` closure. The registry's injected seams are
/// `@Sendable` by design — they cross into the socket layer — so the tests need a box rather
/// than a captured `var`.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// The registry is what lets the classifier tell our own DNS-over-TCP retry from a user app's.
/// Every test here is about a direction it must not widen in.
final class ChainedResolverPortRegistryTests: XCTestCase {
    private func makeRegistry(
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        close: @escaping @Sendable (Int32) -> Void = { _ in },
        shutdown: @escaping @Sendable (Int32) -> Void = { _ in }
    ) -> ChainedResolverPortRegistry {
        ChainedResolverPortRegistry(
            uptimeNanoseconds: now, closeDescriptor: close, shutdownDescriptor: shutdown)
    }

    /// The FIN must be emitted while the claim is STILL recognised.
    ///
    /// `close(2)` on a connected socket emits a FIN, and that FIN travels the tunnel. Released
    /// first, it reaches the classifier unrecognised and is dropped as unfilterable DNS, leaving
    /// the upstream holding a half-open connection until its idle timeout. `shutdown` emits it
    /// while the claim is held.
    ///
    /// Observed from inside the seam, which is the only place the ordering exists: both orders
    /// leave the same state behind.
    func testTheSocketIsShutDownWhileTheClaimIsStillHeld() throws {
        let order = Box<[String]>([])
        let holder = Box<ChainedResolverPortRegistry?>(nil)
        let registry = makeRegistry(
            close: { _ in
                order.value.append(
                    "close:claimed=\(holder.value?.claims(sourcePort: 51_000, protocolNumber: UInt8(IPPROTO_TCP)) ?? false)")
            },
            shutdown: { _ in
                order.value.append(
                    "shutdown:claimed=\(holder.value?.claims(sourcePort: 51_000, protocolNumber: UInt8(IPPROTO_TCP)) ?? false)")
            })
        holder.value = registry
        let claim = try XCTUnwrap(registry.claim(sourcePort: 51_000, protocolNumber: tcp))

        registry.releaseAndClose(claim, descriptor: -1)

        XCTAssertEqual(
            order.value, ["shutdown:claimed=true", "close:claimed=false"],
            "the FIN must be emitted while the carve-out still recognises the port, and the claim "
                + "must still be gone before the descriptor closes")
    }

    /// Nothing is shut down when there was no claim: the `.systemChosen` path never reaches the
    /// classifier, so tearing its socket down gracefully is not this type's business.
    func testTheSystemChosenPathIsNotShutDown() {
        let order = Box<[String]>([])
        let registry = makeRegistry(
            close: { _ in order.value.append("close") },
            shutdown: { _ in order.value.append("shutdown") })
        registry.releaseAndClose(nil, descriptor: 7)
        XCTAssertEqual(order.value, ["close"])
    }

    private let tcp = UInt8(IPPROTO_TCP)
    private let udp = UInt8(IPPROTO_UDP)

    // MARK: - The ordering the residual analysis depends on

    /// The claim must be gone BEFORE the descriptor closes.
    ///
    /// This is the one ordering the type's doc comment rests on: at the instant the port returns
    /// to the ephemeral pool, no entry may still name it, or a later socket handed the same port
    /// inherits our carve-out. Observed from inside the close itself, which is the only place
    /// the two orderings are distinguishable — a `claimedCount() == 0` check afterwards passes
    /// either way, which is why the close callback is injectable at all.
    func testTheClaimIsReleasedBeforeTheDescriptorIsClosed() throws {
        // Boxes rather than captured vars: the close callback is @Sendable, and the point of the
        // test is what it observes at the instant it runs.
        let observed = Box<Bool?>(nil)
        let holder = Box<ChainedResolverPortRegistry?>(nil)
        let registry = makeRegistry(close: { _ in
            observed.value = holder.value?.claims(
                sourcePort: 51_000, protocolNumber: UInt8(IPPROTO_TCP))
        })
        holder.value = registry
        let claim = try XCTUnwrap(registry.claim(sourcePort: 51_000, protocolNumber: tcp))

        registry.releaseAndClose(claim, descriptor: -1)

        XCTAssertEqual(
            observed.value, false,
            "the entry still named the port while the descriptor was closing — for that window "
                + "a socket handed the same port inherits our carve-out")
    }

    func testTheDescriptorIsClosedEvenWhenThereIsNothingToRelease() {
        let closed = Box<[Int32]>([])
        let registry = makeRegistry(close: { closed.value.append($0) })
        registry.releaseAndClose(nil, descriptor: 7)
        XCTAssertEqual(
            closed.value, [7],
            "the .systemChosen path passes a nil claim; if that skipped the close the DNS-only "
                + "path would leak a descriptor per query")
    }

    // MARK: - What the kernel does NOT enforce

    /// A claim is not a capability, and this test is the measurement that says so.
    ///
    /// Characterisation, not aspiration. The design's first draft asserted that another socket
    /// binding a port we hold fails `EADDRINUSE` in every variant; measured on Darwin, two of
    /// them SUCCEED. That falsified the leak proof, and the honest response is to record what
    /// the kernel actually does so nobody rebuilds on the wrong assumption.
    ///
    /// If this ever starts failing because a co-bind is REFUSED, that is good news and the
    /// type's doc comment should be strengthened — the failure message says so.
    func testAClaimIsNotAKernelEnforcedCapability() throws {
        let holder = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try XCTSkipIf(holder < 0, "no socket")
        defer { Darwin.close(holder) }

        var wildcard = sockaddr_in()
        wildcard.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        wildcard.sin_family = sa_family_t(AF_INET)
        wildcard.sin_addr.s_addr = INADDR_ANY.bigEndian
        wildcard.sin_port = 0
        let bound = withUnsafePointer(to: &wildcard) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(holder, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTSkipIf(bound != 0, "could not bind a wildcard ephemeral port")

        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &named) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(holder, $0, &length) == 0
            }
        }
        try XCTSkipIf(!gotName, "getsockname failed")
        let held = UInt16(bigEndian: named.sin_port)

        func rebind(address: String?, reuseAddress: Bool, reusePort: Bool) -> Bool {
            let other = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard other >= 0 else { return false }
            defer { Darwin.close(other) }
            var one: Int32 = 1
            if reuseAddress {
                setsockopt(other, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            }
            if reusePort {
                setsockopt(other, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
            }
            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_family = sa_family_t(AF_INET)
            target.sin_addr.s_addr = address.map { inet_addr($0) } ?? INADDR_ANY.bigEndian
            target.sin_port = held.bigEndian
            return withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(other, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }

        // What DOES hold, and what the common accidental-collision case relies on.
        XCTAssertFalse(
            rebind(address: nil, reuseAddress: false, reusePort: false),
            "a plain wildcard bind over a held port must still fail")
        XCTAssertFalse(
            rebind(address: "127.0.0.1", reuseAddress: false, reusePort: false),
            "a plain specific-address bind over a held wildcard port must still fail")

        // What does NOT hold. Measured 2026-07-29 on Darwin 25.1.
        XCTAssertTrue(
            rebind(address: "127.0.0.1", reuseAddress: true, reusePort: false),
            "This co-bind was expected to SUCCEED and did not. If the kernel now refuses it, the "
                + "residual documented on ChainedResolverPortRegistry has closed and that doc "
                + "comment should be strengthened rather than this test weakened.")
        XCTAssertTrue(
            rebind(address: "127.0.0.1", reuseAddress: false, reusePort: true),
            "Same: SO_REUSEPORT co-binding was measured to succeed. A refusal here is an "
                + "improvement to document, not a failure to suppress.")
    }

    // MARK: - Every failure direction narrows

    func testAnExpiredClaimStopsBeingRecognised() {
        let now = Box<UInt64>(0)
        let registry = makeRegistry(now: { now.value })
        _ = registry.claim(sourcePort: 51_000, protocolNumber: tcp)
        XCTAssertTrue(registry.claims(sourcePort: 51_000, protocolNumber: tcp))

        now.value = UInt64(ChainedResolverPortRegistry.maximumEntryLifetimeSeconds) * 1_000_000_000 + 1
        XCTAssertFalse(
            registry.claims(sourcePort: 51_000, protocolNumber: tcp),
            "an entry past its deadline must stop carving out even if nothing sweeps it — the "
                + "backstop only works if expiry is checked on READ")
    }

    /// At capacity a claim is REFUSED, and nothing unexpired is dropped to make room.
    ///
    /// This replaces an evict-oldest contract, and the replacement is a behaviour change worth
    /// stating: the seventeenth simultaneous unexpired entry does not displace the first, it fails.
    /// A resolver socket is refused, that query fails, and its client retries.
    ///
    /// The old policy could not be made safe by choosing a better victim. Dropping a grace record
    /// lets a delayed own-resolver packet classify as a client query and restart the
    /// self-resolution loop; dropping a live claim removes the entry outright and the same packet
    /// reaches the same classification sooner. Fail-closed is the only option that trades no leak
    /// for another (`INV-DNS-1`, Codex PR #495).
    func testAClaimIsRefusedRatherThanEvictingAnUnexpiredEntry() {
        let registry = makeRegistry()
        for offset in 0..<ChainedResolverPortRegistry.capacity {
            XCTAssertNotNil(registry.claim(sourcePort: UInt16(40_000 + offset), protocolNumber: tcp))
        }
        XCTAssertEqual(registry.claimedCount(), ChainedResolverPortRegistry.capacity)

        XCTAssertNil(
            registry.claim(
                sourcePort: UInt16(40_000 + ChainedResolverPortRegistry.capacity),
                protocolNumber: tcp),
            "the claim past capacity was admitted, which means something unexpired was dropped to "
                + "make room for it")
        XCTAssertTrue(
            registry.claims(sourcePort: 40_000, protocolNumber: tcp),
            "the OLDEST entry was evicted — a delayed packet from that port is now classified as a "
                + "client query")
        XCTAssertEqual(registry.refusedAtCapacityCount(), 1, "the refusal must be visible")
        XCTAssertEqual(
            registry.evictedWhileLiveCount(), 0,
            "nothing may be evicted while live; a nonzero value here means the eviction path was "
                + "reintroduced")
    }

    /// The purge is what keeps the refusal from becoming permanent.
    ///
    /// Refusing at capacity makes this load-bearing in a way eviction hid. With eviction, a table
    /// full of expired entries still admitted new claims by dropping one; now, if nothing clears
    /// them, the sixteen slots are held forever and EVERY subsequent resolver socket is refused —
    /// chained DNS stops working permanently, from a table of entries nobody holds.
    ///
    /// A mutation that removed the purge survived the rest of this suite.
    func testExpiredEntriesAreClearedSoTheRefusalIsNotPermanent() {
        let now = Box<UInt64>(0)
        let registry = makeRegistry(now: { now.value })
        for offset in 0..<UInt16(ChainedResolverPortRegistry.capacity) {
            XCTAssertNotNil(registry.claim(sourcePort: 40_000 + offset, protocolNumber: tcp))
        }
        XCTAssertNil(
            registry.claim(sourcePort: 60_000, protocolNumber: tcp), "the table should be full")

        // Everything ages out, grace window included.
        now.value = UInt64(
            ChainedResolverPortRegistry.maximumEntryLifetimeSeconds
                + ChainedResolverPortRegistry.releaseGraceSeconds + 1) * 1_000_000_000

        XCTAssertNotNil(
            registry.claim(sourcePort: 60_000, protocolNumber: tcp),
            "expired entries were never cleared, so the table stays full of ports nobody holds and "
                + "every resolver socket from here on is refused — chained DNS is permanently down")
    }

    /// The refusal protects GRACE records specifically, which is what the P1 was about.
    ///
    /// A released entry has its live deadline demoted to `now`, so under any eviction policy
    /// ordered by deadline it is the first victim — before live claims and before its own window
    /// has run.
    func testACapacityRefusalDoesNotDropAGraceRecord() throws {
        let registry = makeRegistry()
        let released: UInt16 = 51_000
        let claim = try XCTUnwrap(registry.claim(sourcePort: released, protocolNumber: tcp))
        registry.releaseAndClose(claim, descriptor: -1)
        XCTAssertTrue(
            registry.wasRecentlyClaimed(sourcePort: released, protocolNumber: tcp),
            "the grace record is the precondition for this test")

        // Fill to the LIVE bound. Under the live-only count these all fit alongside the grace
        // record — which is the fix — so none of them is the refusal this test is about.
        for offset in 0..<UInt16(ChainedResolverPortRegistry.capacity) {
            XCTAssertNotNil(
                registry.claim(sourcePort: 40_000 + offset, protocolNumber: tcp),
                "a grace record must not consume live capacity")
        }
        XCTAssertEqual(registry.claimedCount(), ChainedResolverPortRegistry.capacity)

        // 🔴 THE CLAIM THAT ACTUALLY REFUSES, and the reason this assertion exists at all. Without
        // it the test passed vacuously after the bound became live-only: sixteen claims alongside
        // one grace record never reach `liveCount >= capacity`, so no refusal was exercised and
        // the closing assertion held for free. A regression dropping a grace record on the
        // live-capacity path would have gone straight through (Kilo, PR #623).
        XCTAssertNil(
            registry.claim(sourcePort: 60_000, protocolNumber: tcp),
            "sixteen simultaneously-live claims is the bound — the seventeenth must be refused")
        XCTAssertEqual(registry.refusedAtCapacityCount(), 1, "and refused at the LIVE bound")

        XCTAssertTrue(
            registry.wasRecentlyClaimed(sourcePort: released, protocolNumber: tcp),
            "the grace record was dropped to admit a live claim, so a delayed own-resolver packet "
                + "from that port is served as a client query and the loop reopens")
    }

    func testTheProtocolIsPartOfTheKey() {
        let registry = makeRegistry()
        _ = registry.claim(sourcePort: 51_000, protocolNumber: tcp)
        XCTAssertTrue(registry.claims(sourcePort: 51_000, protocolNumber: tcp))
        XCTAssertFalse(
            registry.claims(sourcePort: 51_000, protocolNumber: udp),
            "a TCP claim must not satisfy a UDP lookup — the UDP carve-out is a later slice and "
                + "must not arrive early by accident")
    }

    func testUnusableClaimsAreRefusedRatherThanStored() {
        let registry = makeRegistry()
        XCTAssertNil(
            registry.claim(sourcePort: 0, protocolNumber: tcp),
            "port 0 means the kernel assigned nothing; storing it would carve out every packet "
                + "whose source port we failed to read")
        XCTAssertNil(
            registry.claim(sourcePort: 51_000, protocolNumber: UInt8(IPPROTO_ICMP)),
            "only TCP and UDP carry the ports this registry is keyed on")
        XCTAssertEqual(registry.claimedCount(), 0)
    }

    func testReleaseAllDropsEverything() {
        let registry = makeRegistry()
        _ = registry.claim(sourcePort: 51_000, protocolNumber: tcp)
        _ = registry.claim(sourcePort: 51_001, protocolNumber: tcp)
        registry.releaseAll()
        XCTAssertEqual(registry.claimedCount(), 0)
        XCTAssertFalse(registry.claims(sourcePort: 51_000, protocolNumber: tcp))
    }

    /// Re-claiming a port inside its grace window replaces the stale entry.
    ///
    /// The kernel can hand back a port whose grace entry is still present. A second entry with
    /// the same key is not merely redundant: `releaseAndClose` finds by `firstIndex`, so closing
    /// the NEW socket demotes the OLD entry and leaves the new one live until its 30-second
    /// backstop — and `claims()` keeps carving out port-53 traffic from a port this process no
    /// longer holds.
    func testReclaimingAPortInsideItsGraceWindowReplacesTheEntry() throws {
        let registry = makeRegistry()
        let port: UInt16 = 51_000
        let udp = UInt8(IPPROTO_UDP)

        let first = try XCTUnwrap(registry.claim(sourcePort: port, protocolNumber: udp))
        registry.releaseAndClose(first, descriptor: -1)
        XCTAssertFalse(registry.claims(sourcePort: port, protocolNumber: udp))
        XCTAssertTrue(
            registry.wasRecentlyClaimed(sourcePort: port, protocolNumber: udp),
            "the grace entry is the precondition for this test")

        // The kernel hands the same port back while the grace entry is still there.
        let second = try XCTUnwrap(registry.claim(sourcePort: port, protocolNumber: udp))
        XCTAssertEqual(registry.claimedCount(), 1, "a duplicate entry was appended for one key")

        registry.releaseAndClose(second, descriptor: -1)
        XCTAssertFalse(
            registry.claims(sourcePort: port, protocolNumber: udp),
            "closing the new socket demoted the stale entry instead, so the port stays carved out "
                + "for up to 30 s after this process stopped holding it — and the next user of a "
                + "recycled port gets their DNS encapsulated unfiltered")
    }


    // MARK: - Live claims and grace records are separate populations

    /// A released port must not consume the bound that exists for OPEN sockets.
    ///
    /// `capacity` is justified as "two per concurrent resolver query", which is a statement about
    /// how many sockets are open AT ONCE. Grace records belong to sockets that already closed, so
    /// counting them against that bound made a concurrency guard behave as a rate limiter: at a
    /// steady ~2.5 claims/s the table filled with 3-second memories and refused live work, costing
    /// 7 DNS resolutions in one 60 s window on device (2026-08-29).
    func testGraceRecordsDoNotConsumeLiveCapacity() throws {
        let clock = Box<UInt64>(1_000_000_000)
        let registry = makeRegistry(now: { clock.value })

        // Fill the table with claims and release every one, so each becomes a grace record.
        for offset in 0..<UInt16(ChainedResolverPortRegistry.capacity) {
            let claim = try XCTUnwrap(
                registry.claim(sourcePort: 40_000 + offset, protocolNumber: tcp))
            registry.releaseAndClose(claim, descriptor: -1)
        }
        XCTAssertEqual(registry.claimedCount(), 0, "every claim was released")
        XCTAssertTrue(
            registry.wasRecentlyClaimed(sourcePort: 40_000, protocolNumber: tcp),
            "the grace records are the precondition for this test")

        // The bound is for live sockets, and there are none — so a new claim must succeed.
        XCTAssertNotNil(
            registry.claim(sourcePort: 50_000, protocolNumber: tcp),
            "a claim was refused because of sockets that had already closed")
        XCTAssertEqual(registry.refusedAtCapacityCount(), 0)
        // …and the grace records are still intact, so nothing was traded for it.
        XCTAssertTrue(registry.wasRecentlyClaimed(sourcePort: 40_000, protocolNumber: tcp))
    }

    /// The live bound still binds. The split must not become "capacity never refuses".
    func testTheLiveBoundStillRefusesWhenSocketsAreGenuinelyOpen() throws {
        let clock = Box<UInt64>(1_000_000_000)
        let registry = makeRegistry(now: { clock.value })
        for offset in 0..<UInt16(ChainedResolverPortRegistry.capacity) {
            XCTAssertNotNil(registry.claim(sourcePort: 40_000 + offset, protocolNumber: tcp))
        }
        XCTAssertEqual(registry.claimedCount(), ChainedResolverPortRegistry.capacity)
        XCTAssertNil(
            registry.claim(sourcePort: 50_000, protocolNumber: tcp),
            "with every slot genuinely live, the bound must still push back")
        XCTAssertEqual(registry.refusedAtCapacityCount(), 1)
    }

    /// The grace backstop REFUSES the claim; it never drops a record before its deadline.
    ///
    /// Unreachable at any rate the admission gate permits, so this drives the clock directly. What
    /// it pins is the direction of the pushback: an unexpired grace record still protects against a
    /// packet already in the engine queue, so dropping one to admit a claim would reopen the
    /// self-resolution loop `releaseGraceSeconds` exists to close (Codex, PR #621).
    func testTheGraceBackstopRefusesRatherThanDroppingARecord() throws {
        let clock = Box<UInt64>(1_000_000_000)
        let registry = makeRegistry(now: { clock.value })
        let second: UInt64 = 1_000_000_000

        // The record nearest expiry — the one the first draft would have dropped.
        let oldest = try XCTUnwrap(registry.claim(sourcePort: 39_000, protocolNumber: tcp))
        registry.releaseAndClose(oldest, descriptor: -1)

        // Fill grace to EXACTLY its bound, each a tick later so the ordering is unambiguous.
        // One short of the capacity, because the record above is already the first: the backstop
        // is evaluated BEFORE each admission, so the last iteration here must still see a count
        // under the bound.
        clock.value += second / 1000
        for offset in 0..<UInt16(ChainedResolverPortRegistry.graceCapacity - 1) {
            let claim = try XCTUnwrap(
                registry.claim(sourcePort: 40_000 + offset, protocolNumber: tcp))
            registry.releaseAndClose(claim, descriptor: -1)
        }
        XCTAssertEqual(
            registry.refusedAtGraceCapacityCount(), 0, "exactly at the bound, not over it")

        // One more claim tips it over. The claim is REFUSED and every grace record survives.
        XCTAssertNil(
            registry.claim(sourcePort: 60_000, protocolNumber: tcp),
            "at the grace bound the claim must be refused, not admitted by making room")
        XCTAssertEqual(registry.refusedAtGraceCapacityCount(), 1)
        XCTAssertTrue(
            registry.wasRecentlyClaimed(sourcePort: 39_000, protocolNumber: tcp),
            "the record nearest expiry has not expired, so it must still protect its port")
        XCTAssertEqual(registry.evictedWhileLiveCount(), 0, "a live claim must never be a victim")
        XCTAssertEqual(
            registry.refusedAtCapacityCount(), 0,
            "the LIVE bound was nowhere near — the two refusals must stay distinguishable")
    }

    /// Every deadline comparison reads its clock WHILE THE LOCK IS HELD.
    ///
    /// Not a style property. Reading `uptimeNanoseconds()` before taking the lock lets a
    /// `releaseAndClose` that wins the race demote an entry with a LATER timestamp than the one
    /// the reader is about to compare against, so `entry.deadline > staleNow` answers for a state
    /// that no longer exists — `claimedCount()` counts a released grace record as live, and
    /// `claims()` reports a port as still carved out after its claim ended, which is the widening
    /// direction this type's header promises never happens (Codex, PR #623).
    ///
    /// DISCRIMINATED BY BLOCKING, because ordering is not visible from a return value. The
    /// injected clock parks inside its own read; while it is parked, a second thread tries to take
    /// the lock. If the read happens under the lock, that thread CANNOT proceed — so "the mutation
    /// did not complete" is the pass condition, and a pre-lock read fails by completing.
    func testEveryDeadlineComparisonReadsItsClockUnderTheLock() throws {
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let parking = Box<Bool>(false)
        let clock = Box<UInt64>(1_000_000_000)

        let registry = makeRegistry(now: {
            if parking.value {
                parking.value = false
                parked.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            clock.value &+= 1_000
            return clock.value
        })
        _ = try XCTUnwrap(registry.claim(sourcePort: 41_000, protocolNumber: tcp))

        // `protocolNumber` is lifted out of the closures: capturing `self.tcp` makes the test case
        // itself a `@Sendable` capture, which only `-warnings-as-errors` rejects.
        let protocolNumber = tcp

        // EVERY CONSUMER, not just the one a review happened to name. They share `withLockedNow`
        // today, so probing one would pass while a future edit reintroduced the pre-lock read in
        // another — and `claims()` is the one whose error WIDENS the carve-out, which is the
        // direction this type's header promises never happens (Kilo, PR #623).
        let readers: [(String, @Sendable () -> Void)] = [
            ("claimedCount", { _ = registry.claimedCount() }),
            ("claims", { _ = registry.claims(sourcePort: 41_000, protocolNumber: protocolNumber) }),
            ("wasRecentlyClaimed", {
                _ = registry.wasRecentlyClaimed(sourcePort: 41_000, protocolNumber: protocolNumber)
            }),
        ]
        for (index, (name, read)) in readers.enumerated() {
            // Park this accessor inside its clock read.
            parking.value = true
            DispatchQueue(label: "reader-\(name)").async(execute: read)
            XCTAssertEqual(
                parked.wait(timeout: .now() + 5), .success, "\(name) never read its clock")

            // A mutation needing the lock must NOT get through while the reader is parked.
            let mutated = DispatchSemaphore(value: 0)
            let port = UInt16(41_001 + index)
            DispatchQueue(label: "mutator-\(name)").async {
                _ = registry.claim(sourcePort: port, protocolNumber: protocolNumber)
                mutated.signal()
            }
            XCTAssertEqual(
                mutated.wait(timeout: .now() + 1), .timedOut,
                "\(name) read its clock BEFORE taking the lock — a concurrent release can demote "
                    + "an entry with a later timestamp, so the comparison answers for a state that "
                    + "no longer exists")

            release.signal()
            XCTAssertEqual(
                mutated.wait(timeout: .now() + 5), .success, "\(name) never released the lock")
        }
    }

    /// A grace refusal never reports itself as a live-capacity refusal, and vice versa.
    ///
    /// The two counters exist because the remedies differ — too many sockets open at once versus
    /// too many closed recently — and a reader who cannot tell them apart is back where the
    /// original conflation left us.
    func testTheTwoRefusalsAreCountedSeparately() throws {
        let clock = Box<UInt64>(1_000_000_000)
        let registry = makeRegistry(now: { clock.value })

        for offset in 0..<UInt16(ChainedResolverPortRegistry.capacity) {
            XCTAssertNotNil(registry.claim(sourcePort: 40_000 + offset, protocolNumber: tcp))
        }
        XCTAssertNil(registry.claim(sourcePort: 50_000, protocolNumber: tcp))

        XCTAssertEqual(registry.refusedAtCapacityCount(), 1)
        XCTAssertEqual(
            registry.refusedAtGraceCapacityCount(), 0,
            "sixteen LIVE claims is the live bound; grace was empty")
    }
}
