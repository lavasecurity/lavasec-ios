import XCTest
import LavaSecKit
@testable import LavaSecDNS

/// DoT work must not outlive the tunnel lifecycle that started it.
///
/// The sibling of `DoQTransportLifecycleTests`, for the same two lanes and the same two
/// causes: an isolated lane (the smoke probe's) was never in `connections` for `cancel` to
/// walk, and a pooled lane was cancelled but immediately REBUILT by the failover ladder of the
/// very queries that cancellation failed.
///
/// What differs is the cost, and it is worth stating because it changes what these tests are
/// defending. No energy counter reads the DoT callback, so there is no contaminated
/// measurement here — this is a live TLS connection and socket outliving the tunnel, plus a
/// teardown that recreated what it had just cancelled. The pooled half bites harder than it
/// does for DoQ: DoT REUSES lanes across queries, so a pool rebuilt by a straggler is still
/// there for the next session to serve from.
///
/// Network-free by construction, on the same seam as the DoQ suite: a refusal completes
/// synchronously on the caller's thread, while admission is proven by the transport's
/// lock-protected lane bookkeeping rather than by racing the callback from `DoTConnection.resolve`'s
/// own queue. An empty query is rejected by `connectThenSendCurrentQuery`'s transaction-ID check
/// before any `NWConnection` is built.
final class DoTTransportLifecycleTests: XCTestCase {
    /// TEST-NET-3 (RFC 5737) — documentation space, never routable, so a test that did reach
    /// the network could not reach a real resolver.
    private static let endpoint = DNSOverTLSEndpoint(
        hostname: "203.0.113.1",
        bootstrapIPv4Servers: [],
        bootstrapIPv6Servers: []
    )

    func testAnExpiredQueuedLookupFinishesWithoutOpeningAConnection() {
        let connection = DoTConnection(endpoint: Self.endpoint, timeoutSeconds: 30, debugLogger: nil)
        defer { connection.cancel() }
        let done = expectation(description: "expired lookup finishes once")
        done.assertForOverFulfill = true
        connection.resolve(DNSResolverSmokeProbe.query(), deadline: MonotonicDeadline(after: 0)) { response in
            XCTAssertNil(response.response)
            XCTAssertEqual(response.outcome, .expiredBeforeSend)
            XCTAssertFalse(response.outcome.isTransportFailureEvidence)
            XCTAssertFalse(ResolverAttemptOutcome(response.outcome).reachedTheWire)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    private func makeTransport() -> DoTTransport {
        DoTTransport(timeoutSeconds: 30)
    }

    // MARK: - Refusal after teardown

    func testACancelledTransportRefusesPooledWork() {
        let transport = makeTransport()
        transport.cancel()

        let outcome = DoTOutcome()
        transport.resolve(Data(), endpoint: Self.endpoint) { outcome.record($0) }

        XCTAssertTrue(
            outcome.settledSynchronously,
            "a quiesced transport must refuse on the caller's thread — an asynchronous "
                + "completion means a lane was handed out and the pool was rebuilt after teardown"
        )
        XCTAssertNil(outcome.response, "a refusal carries no response")
        XCTAssertEqual(
            transport.laneBookkeeping.pooledEndpointCount, 0,
            "the refusal must not have built a pool for the endpoint"
        )
    }

    func testACancelledTransportRefusesIsolatedWork() {
        let transport = makeTransport()
        transport.cancel()

        let outcome = DoTOutcome()
        transport.resolveIsolated(Data(), endpoint: Self.endpoint) { outcome.record($0) }

        XCTAssertTrue(
            outcome.settledSynchronously,
            "a quiesced transport must refuse isolated work too — the smoke probe's lane is "
                + "the one that outlived stopTunnel"
        )
        XCTAssertNil(outcome.response, "a refusal carries no response")
        XCTAssertEqual(
            transport.laneBookkeeping.isolatedLaneCount, 0,
            "the refusal must not have registered a lane"
        )
    }

    // MARK: - Re-admission for the next lifecycle

    func testResumeReadmitsPooledWork() {
        let transport = makeTransport()
        transport.cancel()
        transport.resume()
        defer { transport.cancel() }

        let outcome = DoTOutcome()
        let completed = expectation(description: "pooled query completes")
        transport.resolve(Data(), endpoint: Self.endpoint) {
            outcome.record($0)
            completed.fulfill()
        }

        // DoTConnection.resolve uses queue.async, but that does not guarantee the worker waits
        // for this caller to regain control. With the invalid query above, the worker can reject
        // it before the next line under full-suite scheduling, making completion timing an
        // unreliable proxy for transport admission. The pool snapshot is recorded under the
        // transport lock at admission and directly distinguishes this path from refusal.
        let bookkeeping = transport.laneBookkeeping
        XCTAssertFalse(
            bookkeeping.isQuiesced,
            "a resumed transport must remain admitted while its pooled lane processes the query"
        )
        XCTAssertEqual(
            bookkeeping.pooledEndpointCount,
            1,
            "an admitted pooled query must create its endpoint pool before it reaches the lane"
        )
        wait(for: [completed], timeout: 5)
    }

    func testResumeReadmitsIsolatedWork() {
        let observed = ObservedDoTLaneCounts()
        let transport = DoTTransport(
            timeoutSeconds: 30,
            debugLogger: nil,
            isolatedLaneObserver: { observed.record($0) })
        transport.cancel()
        transport.resume()
        defer { transport.cancel() }

        let completed = expectation(description: "isolated query completes")
        transport.resolveIsolated(Data(), endpoint: Self.endpoint) { _ in completed.fulfill() }
        wait(for: [completed], timeout: 5)

        // An admitted empty query can finish on its worker before resolveIsolated
        // returns. Observe admission itself, not a race with that callback.
        XCTAssertEqual(
            observed.counts, [1],
            "a resumed transport must register the isolated lane before processing its query"
        )
        XCTAssertFalse(transport.laneBookkeeping.isQuiesced)
    }

    // MARK: - Isolated lanes are reachable by teardown

    func testAnIsolatedLaneIsRegisteredWhileInFlight() {
        // Observed through the registration seam rather than by reading `laneBookkeeping`
        // afterwards — see the DoQ sibling. Two earlier shapes were racy the same way: an
        // empty query retires its own lane one hop later, and a well-formed query to an
        // unroutable address only *usually* stays in flight (Kilo then Codex, PRs #522/#523).
        let observed = ObservedDoTLaneCounts()
        let transport = DoTTransport(
            timeoutSeconds: 30,
            debugLogger: nil,
            isolatedLaneObserver: { observed.record($0) })
        defer { transport.cancel() }

        let completed = expectation(description: "isolated query completes")
        transport.resolveIsolated(Data(), endpoint: Self.endpoint) { _ in completed.fulfill() }
        wait(for: [completed], timeout: 5)

        XCTAssertEqual(
            observed.counts, [1],
            "an in-flight isolated lane must be tracked, or teardown has nothing to cancel"
        )
    }

    func testAnIsolatedLaneIsRetiredWhenItCompletes() {
        // Must observe a NORMAL completion, not a cancel: `cancel` empties the registry
        // wholesale, so retirement asserted after a cancel would hold even with
        // `forgetIsolatedConnection` deleted. An empty query is right here, and the read
        // happens AFTER the wait, so the race the split exists to remove cannot apply.
        let transport = makeTransport()
        defer { transport.cancel() }

        let completed = expectation(description: "isolated query completes")
        transport.resolveIsolated(Data(), endpoint: Self.endpoint) { _ in completed.fulfill() }
        wait(for: [completed], timeout: 5)

        XCTAssertEqual(
            transport.laneBookkeeping.isolatedLaneCount, 0,
            "a completed isolated lane must be retired — a session-long accumulation of dead "
                + "lanes is resident memory the NE process cannot afford (INV-MEM-1)"
        )
    }

    func testCancelActuallyCancelsAnIsolatedLaneStillInFlight() {
        // The registry assertions prove teardown FORGETS the lane. This proves it CANCELS it:
        // a forgotten-but-running DoT connection holds its socket and TLS session open past
        // the tunnel, and in a QA build keeps appending to the debug log — where those appends
        // are counted against the NEXT session's window.
        //
        // The PASS path is deterministic and network-free, via the registration seam — see
        // the DoQ sibling for why the earlier unroutable-address shape could pass with
        // teardown never touching isolated lanes (Codex P2, PR #523). The observer parks the
        // resolution after the lane is registered and before any query reaches it, so
        // `cancel()` runs against a registered lane and `DoTConnection.resolve` then finds
        // `isCancelled` and completes at once. A completion here can only have been caused by
        // the cancel.
        //
        // The KILL is claimed per mutant, exactly as in the DoQ sibling (Kilo, PR #522): a
        // `cancel()` that no longer reaches the isolated registry fails the count assertions
        // below on any runner, network-free; a `cancel()` that empties the registry but skips
        // cancelling the connections is killed by the completion assertions, whose kill
        // relies on the unroutable fixture not completing inside the wait — the named,
        // environment-dependent residual.
        let registered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let transport = DoTTransport(
            timeoutSeconds: 30,
            debugLogger: nil,
            isolatedLaneObserver: { _ in
                registered.signal()
                release.wait()
            })

        let outcome = DoTOutcome()
        let completed = expectation(description: "isolated query completes")
        DispatchQueue.global().async {
            transport.resolveIsolated(DNSResolverSmokeProbe.query(), endpoint: Self.endpoint) {
                outcome.record($0)
                completed.fulfill()
            }
        }

        registered.wait()
        // The `defer` is the failure path — a failed assertion must not strand the parked
        // observer thread (Kilo, PR #522); the explicit signal below is the normal one.
        defer { release.signal() }
        XCTAssertEqual(
            transport.laneBookkeeping.isolatedLaneCount, 1,
            "precondition: the parked lane is registered and reachable by teardown"
        )
        transport.cancel()
        XCTAssertEqual(
            transport.laneBookkeeping.isolatedLaneCount, 0,
            "cancel() must walk the isolated registry — a parked lane it never reached "
                + "stays registered, and this fails without consulting the network"
        )
        release.signal()

        wait(for: [completed], timeout: 3)
        XCTAssertNil(outcome.response, "a cancelled lane completes with no response")
    }

    func testCancelEmptiesTheIsolatedRegistryAndQuiesces() {
        // Parked like the DoQ sibling: with a live query the lane can retire itself before
        // `cancel()` runs, so a post-cancel count of zero would hold even if teardown never
        // emptied the registry (Codex P2, PR #523).
        let registered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let observed = ObservedDoTLaneCounts()
        let transport = DoTTransport(
            timeoutSeconds: 30,
            debugLogger: nil,
            isolatedLaneObserver: {
                observed.record($0)
                registered.signal()
                release.wait()
            })

        let completed = expectation(description: "isolated query completes")
        DispatchQueue.global().async {
            transport.resolveIsolated(DNSResolverSmokeProbe.query(), endpoint: Self.endpoint) { _ in
                completed.fulfill()
            }
        }

        registered.wait()
        defer { release.signal() }
        XCTAssertEqual(observed.counts, [1], "precondition: the lane was registered")

        transport.cancel()

        XCTAssertEqual(
            transport.laneBookkeeping,
            DoTTransport.LaneBookkeeping(
                isQuiesced: true, isolatedLaneCount: 0, pooledEndpointCount: 0, idleResetIsArmed: false),
            "teardown must leave no lane of either kind and must stay quiesced"
        )

        release.signal()
        wait(for: [completed], timeout: 3)
    }

    // MARK: - The lane's own door, behind the transport's

    func testACancelledLaneRefusesLateWorkInsteadOfReconnecting() {
        // The transport's quiesce closes the front door, not this one. `resolve` releases the
        // transport lock before calling into the lane, so a `cancel` landing in that gap
        // enqueues `cancelLocked` AHEAD of the query's own append — and the append then opened
        // a FRESH TLS connection after teardown, on a lane teardown had just cancelled.
        // `DoQConnection` has always guarded this; DoT did not, and the transport-level fix
        // alone leaves the hole open.
        //
        // The interleaving is reproduced exactly and deterministically rather than raced for:
        // both calls go through the same serial queue, so FIFO puts `cancelLocked` first.
        // What the timing budget buys is the discriminator — 30s lane timeout against a 2s
        // wait, so a completion this fast cannot be the query having run and timed out.
        let connection = DoTConnection(
            endpoint: Self.endpoint, timeoutSeconds: 30, debugLogger: nil)
        connection.cancel()

        let outcome = DoTOutcome()
        let completed = expectation(description: "late query is refused")
        connection.resolve(DNSResolverSmokeProbe.query()) {
            outcome.record($0)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertNil(outcome.response, "a refused lane carries no response")
    }

    /// A QUERY WHOSE DATA PATH WAS REPLACED IS REFUSED AT THE LANE, not sent.
    ///
    /// This lane serialises, so a query can wait behind another query's entire timeout and then
    /// behind a TLS handshake. Both are windows in which the user can change the resolver or the
    /// fallback policy that admitted it, and every gate above the transport has already passed by
    /// then — so the lane itself is the last place the query can be stopped (PR #611).
    ///
    /// REACHED WITHOUT A CONNECTION, deliberately. The dequeue check runs before any connect
    /// attempt, which is what makes this window observable in a test at all; the post-handshake
    /// check covers the other window and needs a live server to reach.
    ///
    /// `.refusedAfterLatchReplaced` rather than `.receiveFailed`: nothing was written, and a
    /// receive failure would put a working resolver on the backoff ladder for a refusal the
    /// device chose.
    func testAQueryWhoseDataPathWasReplacedIsRefusedWithoutBeingSent() {
        let connection = DoTConnection(
            endpoint: Self.endpoint, timeoutSeconds: 30, debugLogger: nil)
        defer { connection.cancel() }

        let outcome = DoTOutcome()
        let completed = expectation(description: "the stale query is refused")
        connection.resolve(
            DNSResolverSmokeProbe.query(), isStillAdmitted: { false }
        ) {
            outcome.record($0)
            completed.fulfill()
        }

        // Well inside the lane's 30s timeout, so a completion this fast cannot be the query
        // having been sent and timed out.
        wait(for: [completed], timeout: 2)
        XCTAssertNil(outcome.response, "a refused query carries no response")
        XCTAssertEqual(
            outcome.recordedOutcome, .refusedAfterLatchReplaced,
            "the refusal must say the data path moved — nothing was written, so `.sendFailed` "
                + "and `.receiveFailed` would both be false and would bench a working resolver")
    }

    /// ...AND A CURRENT ONE IS NOT REFUSED BY THE SAME CHECK.
    ///
    /// The negative. A predicate wired the wrong way round, or one defaulting to false, would
    /// refuse every encrypted query on the device and satisfy the test above.
    func testAQueryOnTheCurrentDataPathIsNotRefusedByTheLatchCheck() {
        let connection = DoTConnection(
            endpoint: Self.endpoint, timeoutSeconds: 1, debugLogger: nil)
        defer { connection.cancel() }

        let outcome = DoTOutcome()
        let completed = expectation(description: "the current query proceeds")
        connection.resolve(
            DNSResolverSmokeProbe.query(), isStillAdmitted: { true }
        ) {
            outcome.record($0)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 8)
        XCTAssertNotEqual(
            outcome.recordedOutcome, .refusedAfterLatchReplaced,
            "an admitted query must reach the connection attempt — this endpoint is unreachable "
                + "in tests, so it fails as a transport error rather than as a refusal")
    }

    // MARK: - The idle reset must not outlive the session that armed it

    func testAQuiescedFailurePathCannotArmTheIdleResetForTheNextSession() {
        let held = HeldDoTLanes(transport: makeTransport(), endpoint: Self.endpoint)
        let transport = held.transport
        defer { held.release() }

        // The straggler shape: a query admitted BEFORE teardown is still outstanding, teardown
        // happens, and only then does the provider's DoT executor answer a nil response by
        // calling this. Reaching it with a nonzero in-flight count is what makes the assertion
        // falsifiable — at zero the deferred branch is never taken and the flag would be
        // cleared again on the way out regardless.
        transport.cancel()
        transport.resetConnectionsWhenIdle()

        XCTAssertFalse(
            transport.laneBookkeeping.idleResetIsArmed,
            "arming after teardown carries the flag into the NEXT tunnel session, whose pool "
                + "is then torn down at its first idle moment — costing it a TLS handshake the "
                + "previous session caused"
        )
    }

    func testARunningSessionStillDefersItsPoolReset() {
        let held = HeldDoTLanes(transport: makeTransport(), endpoint: Self.endpoint)
        let transport = held.transport
        defer { held.release() }

        // Guards the guard. The quiesce check must gate the deferred reset on TEARDOWN, not
        // disable it outright: DoT's whole stale-connection recovery rests on resetting the
        // pool after a failure, and refusing to arm unconditionally would pass the test above
        // while silently removing it.
        transport.resetConnectionsWhenIdle()

        XCTAssertTrue(
            transport.laneBookkeeping.idleResetIsArmed,
            "a running session must still defer its pool reset until queries finish"
        )
    }
}

/// Holds a `DoTTransport` with one query permanently in flight — `activeQueryCount == 1` —
/// without touching the network. See `HeldLanes` in `DoQTransportLifecycleTests` for why the
/// deferred-reset branch cannot be reached any other way; the mechanism is identical (block
/// every lane's serial queue from inside a completion, then issue one more query, which
/// round-robin hands back to an already-blocked lane).
private final class HeldDoTLanes {
    let transport: DoTTransport
    private let blockedLaneEntered = DispatchSemaphore(value: 0)
    private let releaseBlockedLanes = DispatchSemaphore(value: 0)
    private let laneCount = DoTTransport.maxConnectionsPerEndpoint

    init(transport: DoTTransport, endpoint: DNSOverTLSEndpoint) {
        self.transport = transport
        let entered = blockedLaneEntered
        let release = releaseBlockedLanes
        for _ in 0..<laneCount {
            transport.resolve(Data(), endpoint: endpoint) { _ in
                entered.signal()
                release.wait()
            }
        }
        for _ in 0..<laneCount {
            blockedLaneEntered.wait()
        }
        transport.resolve(Data(), endpoint: endpoint) { _ in }
    }

    func release() {
        for _ in 0..<laneCount {
            releaseBlockedLanes.signal()
        }
        transport.cancel()
    }
}

/// Records a transport completion and whether it landed before the call that caused it
/// returned. `@unchecked Sendable` over a lock because the completion is `@Sendable` and may
/// land on the connection's queue.
private final class DoTOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var recordedResponse: Data?
    private var outcome: DNSTransportOutcome?

    func record(_ response: DNSTransportResponse) {
        lock.lock()
        settled = true
        recordedResponse = response.response
        outcome = response.outcome
        lock.unlock()
    }

    /// The classification, not just the bytes. A refusal and a transport failure both carry a nil
    /// response, so asserting on `response` alone cannot tell "we declined to send" from "the send
    /// failed" — and those bench the resolver differently.
    var recordedOutcome: DNSTransportOutcome? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return outcome
    }

    /// True when the completion had already run by the time the caller regained control.
    var settledSynchronously: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return settled
    }

    var response: Data? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recordedResponse
    }
}

/// Collects isolated-lane registration counts reported by the transport's seam, in order.
private final class ObservedDoTLaneCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []

    func record(_ count: Int) {
        lock.lock()
        recorded.append(count)
        lock.unlock()
    }

    var counts: [Int] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recorded
    }
}
