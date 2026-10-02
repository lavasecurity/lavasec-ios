import XCTest
import LavaSecDNS
@testable import LavaSecCore
@testable import LavaSecKit

final class ResolverBootstrapServiceTests: XCTestCase {
    private final class ResolverSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var resolveCount = 0
        var result = ResolverBootstrapService.ResolvedAddresses(ipv4: ["1.2.3.4"], ipv6: ["::1"])
        var gate: DispatchSemaphore?

        var count: Int {
            lock.lock()
            defer {
                lock.unlock()
            }
            return resolveCount
        }

        func resolve(_ hostname: String) -> ResolverBootstrapService.ResolvedAddresses {
            gate?.wait()
            lock.lock()
            resolveCount += 1
            let result = result
            lock.unlock()
            return result
        }
    }

    private func makeService(spy: ResolverSpy, queue: DispatchQueue) -> ResolverBootstrapService {
        ResolverBootstrapService(
            resolveAddresses: { hostname, _ in
                spy.resolve(hostname)
            },
            queue: queue
        )
    }

    func testPrewarmCarriesTheKicksAdmissionTokenAcrossItsQueueHop() {
        // The lookup runs on the service's own queue an unbounded time after the kick, so
        // the resolver closure must receive the KICK's token verbatim — a value minted on
        // the far side of the hop would name whatever session is live by then, and every
        // downstream admission check would pass trivially (PR #524).
        final class TokenBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [UInt64] = []
            func record(_ token: UInt64) {
                lock.lock(); stored.append(token); lock.unlock()
            }
            var tokens: [UInt64] {
                lock.lock(); defer { lock.unlock() }; return stored
            }
        }
        let received = TokenBox()
        let queue = DispatchQueue(label: "test.bootstrap.epoch")
        let service = ResolverBootstrapService(
            resolveAddresses: { _, admittedAtEpoch in
                received.record(admittedAtEpoch)
                return ResolverBootstrapService.ResolvedAddresses(ipv4: ["9.9.9.9"], ipv6: [])
            },
            queue: queue
        )

        service.prewarm(hostname: "doq.example", admittedAtEpoch: 7)
        queue.sync {}

        XCTAssertEqual(
            received.tokens, [7],
            "the resolver closure must see the session that accepted the pre-warm, "
                + "not a value invented after the queue hop"
        )
    }

    func testANewSessionsPrewarmSupersedesAnOldSessionsInFlightLookup() {
        // The fail-closed companion of carrying the token: an old session's in-flight
        // lookup now correctly resolves nothing once its session ends — so if it also
        // SUPPRESSED the new session's pre-warm, nothing would repopulate the cache and
        // custom encrypted endpoints would fail their initial queries until an unrelated
        // cold miss (Codex P2, PR #524). A kick from a different session must run; only
        // a same-session, same-generation duplicate is deduplicated.
        final class TokenBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [UInt64] = []
            func record(_ token: UInt64) {
                lock.lock(); stored.append(token); lock.unlock()
            }
            var tokens: [UInt64] {
                lock.lock(); defer { lock.unlock() }; return stored
            }
        }
        let received = TokenBox()
        let queue = DispatchQueue(label: "test.bootstrap.supersede")
        let service = ResolverBootstrapService(
            resolveAddresses: { _, admittedAtEpoch in
                received.record(admittedAtEpoch)
                // Session 1's lookup resolves nothing (its session ended under it);
                // session 2's resolves real addresses.
                return admittedAtEpoch == 1
                    ? ResolverBootstrapService.ResolvedAddresses(ipv4: [], ipv6: [])
                    : ResolverBootstrapService.ResolvedAddresses(ipv4: ["9.9.9.9"], ipv6: [])
            },
            queue: queue
        )

        // Both kicks land before the serial queue runs either lookup, which is the
        // stop/start shape: A's lookup still queued when B's startup pre-warm arrives.
        queue.suspend()
        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        service.prewarm(hostname: "doq.example", admittedAtEpoch: 2)
        service.prewarm(hostname: "doq.example", admittedAtEpoch: 2)
        queue.resume()
        queue.sync {}

        XCTAssertEqual(
            received.tokens, [1, 2],
            "the new session's kick must run (and its same-session duplicate must not)"
        )
        XCTAssertEqual(
            service.cachedAddresses(forHostname: "doq.example"),
            ResolverBootstrapService.ResolvedAddresses(ipv4: ["9.9.9.9"], ipv6: []),
            "the cache must hold the LIVE session's result — the superseded lookup's "
                + "empty answer must not stand in its way"
        )
    }

    func testAnOlderSessionsStragglingKickCannotDisplaceTheLiveOne() {
        // The other direction of superseding, one round later (Codex P2, PR #524): an old
        // session's cold-miss kick — fence passed, thread descheduled — that lands AFTER
        // the live session's startup pre-warm must not steal the marker. If it did, the
        // live lookup's valid result would be dropped as unowned while the stale lookup
        // resolves nothing, and the cache would sit empty until an unrelated kick.
        final class TokenBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [UInt64] = []
            func record(_ token: UInt64) {
                lock.lock(); stored.append(token); lock.unlock()
            }
            var tokens: [UInt64] {
                lock.lock(); defer { lock.unlock() }; return stored
            }
        }
        let received = TokenBox()
        let queue = DispatchQueue(label: "test.bootstrap.older")
        let service = ResolverBootstrapService(
            resolveAddresses: { _, admittedAtEpoch in
                received.record(admittedAtEpoch)
                return admittedAtEpoch == 1
                    ? ResolverBootstrapService.ResolvedAddresses(ipv4: [], ipv6: [])
                    : ResolverBootstrapService.ResolvedAddresses(ipv4: ["9.9.9.9"], ipv6: [])
            },
            queue: queue
        )

        queue.suspend()
        service.prewarm(hostname: "doq.example", admittedAtEpoch: 2)
        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        queue.resume()
        queue.sync {}

        XCTAssertEqual(
            received.tokens, [2],
            "an older session's straggling kick must be suppressed, not treated as newer"
        )
        XCTAssertEqual(
            service.cachedAddresses(forHostname: "doq.example"),
            ResolverBootstrapService.ResolvedAddresses(ipv4: ["9.9.9.9"], ipv6: []),
            "the live session's result must land — its marker was never stolen"
        )
    }

    func testPrewarmResolvesOnceAndServesFromCache() {
        let spy = ResolverSpy()
        let queue = DispatchQueue(label: "test.bootstrap")
        let service = makeService(spy: spy, queue: queue)

        XCTAssertNil(service.cachedAddresses(forHostname: "doq.example"))

        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        queue.sync {}

        XCTAssertEqual(
            service.cachedAddresses(forHostname: "doq.example"),
            ResolverBootstrapService.ResolvedAddresses(ipv4: ["1.2.3.4"], ipv6: ["::1"])
        )

        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        queue.sync {}

        XCTAssertEqual(spy.count, 1, "A cached hostname must not resolve again.")
    }

    func testConcurrentPrewarmsCoalesceWhileLookupIsInFlight() {
        let spy = ResolverSpy()
        let gate = DispatchSemaphore(value: 0)
        spy.gate = gate
        let queue = DispatchQueue(label: "test.bootstrap")
        let service = makeService(spy: spy, queue: queue)

        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        gate.signal()
        queue.sync {}

        XCTAssertEqual(spy.count, 1, "Duplicate pre-warms must join the in-flight lookup.")
        XCTAssertNotNil(service.cachedAddresses(forHostname: "doq.example"))
    }

    func testEmptyResultsAreNotCachedSoRetriesResolveAgain() {
        let spy = ResolverSpy()
        spy.result = ResolverBootstrapService.ResolvedAddresses(ipv4: [], ipv6: [])
        let queue = DispatchQueue(label: "test.bootstrap")
        let service = makeService(spy: spy, queue: queue)

        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        queue.sync {}

        XCTAssertNil(service.cachedAddresses(forHostname: "doq.example"))

        spy.result = ResolverBootstrapService.ResolvedAddresses(ipv4: ["9.9.9.9"], ipv6: [])
        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        queue.sync {}

        XCTAssertEqual(spy.count, 2, "A failed lookup must not poison the cache.")
        XCTAssertEqual(
            service.cachedAddresses(forHostname: "doq.example"),
            ResolverBootstrapService.ResolvedAddresses(ipv4: ["9.9.9.9"], ipv6: [])
        )
    }

    func testInvalidateAllDropsCacheAndAllowsReResolution() {
        let spy = ResolverSpy()
        let queue = DispatchQueue(label: "test.bootstrap")
        let service = makeService(spy: spy, queue: queue)

        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        queue.sync {}
        service.invalidateAll()

        XCTAssertNil(service.cachedAddresses(forHostname: "doq.example"))

        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        queue.sync {}

        XCTAssertEqual(spy.count, 2)
        XCTAssertNotNil(service.cachedAddresses(forHostname: "doq.example"))
    }

    func testInvalidateAllDiscardsResultOfInFlightLookup() {
        let spy = ResolverSpy()
        let gate = DispatchSemaphore(value: 0)
        spy.gate = gate
        let queue = DispatchQueue(label: "test.bootstrap")
        let service = makeService(spy: spy, queue: queue)

        // Kick a lookup and hold it mid-flight (blocked in resolve) on the gate.
        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        // Invalidate while that lookup is still running — e.g. a network change or
        // wake landed before the pre-sleep lookup returned.
        service.invalidateAll()
        // Let the stale lookup finish; its previous-network result must be dropped.
        gate.signal()
        queue.sync {}

        XCTAssertEqual(spy.count, 1, "The in-flight lookup still ran.")
        XCTAssertNil(
            service.cachedAddresses(forHostname: "doq.example"),
            "A lookup kicked before invalidateAll() must not repopulate the freshly-cleared cache."
        )

        // A fresh pre-warm after invalidation resolves on the new generation and caches.
        spy.gate = nil
        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        queue.sync {}

        XCTAssertEqual(spy.count, 2)
        XCTAssertNotNil(service.cachedAddresses(forHostname: "doq.example"))
    }

    func testReprewarmAfterInvalidationKicksFreshLookupWhilePriorStillInFlight() {
        let spy = ResolverSpy()
        let gate = DispatchSemaphore(value: 0)
        spy.gate = gate
        let queue = DispatchQueue(label: "test.bootstrap")
        let service = makeService(spy: spy, queue: queue)

        // Lookup A is kicked and held mid-flight on the gate.
        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        // A network change / wake invalidates while A is still running...
        service.invalidateAll()
        // ...and re-prewarms. The superseded in-flight A must not suppress this
        // fresh lookup B, or the freshly-cleared cache would stay empty after the
        // handoff until a later cold-miss query.
        service.prewarm(hostname: "doq.example", admittedAtEpoch: 1)
        // Release both queued lookups (serial queue runs A then B).
        gate.signal()
        gate.signal()
        queue.sync {}

        XCTAssertEqual(
            spy.count,
            2,
            "The post-invalidation prewarm must kick a fresh lookup, not coalesce into the superseded one."
        )
        XCTAssertNotNil(
            service.cachedAddresses(forHostname: "doq.example"),
            "The fresh lookup repopulates the cache after the handoff."
        )
    }

    func testHostnamesAreCachedIndependently() {
        let spy = ResolverSpy()
        let queue = DispatchQueue(label: "test.bootstrap")
        let service = makeService(spy: spy, queue: queue)

        service.prewarm(hostname: "a.example", admittedAtEpoch: 1)
        service.prewarm(hostname: "b.example", admittedAtEpoch: 1)
        queue.sync {}

        XCTAssertEqual(spy.count, 2)
        XCTAssertNotNil(service.cachedAddresses(forHostname: "a.example"))
        XCTAssertNotNil(service.cachedAddresses(forHostname: "b.example"))
        XCTAssertNil(service.cachedAddresses(forHostname: "c.example"))
    }
}
