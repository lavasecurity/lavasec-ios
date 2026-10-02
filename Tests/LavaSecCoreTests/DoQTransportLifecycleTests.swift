import XCTest
import LavaSecKit
@testable import LavaSecDNS

/// DoQ work must not outlive the tunnel lifecycle that started it.
///
/// The defect these cover is a MEASUREMENT one with a behavioural cause. `EnergyCounters`
/// resets every per-session counter in `activate()` (once per `startTunnel`), and the
/// provider counts a fresh QUIC handshake from `DoQTransport`'s `dns-doq-connection-ready`
/// callback. Stop cleanup does not drain in-flight resolver work, so a connection surviving
/// a stop/start recorded the PREVIOUS session's handshake into the NEW session's first
/// window — the class PR #520 fixed for the chained-DNS evidence counters, reaching the
/// counters through the transport rather than through a recorder.
///
/// Two lanes could survive, and they need separate coverage because they survived for
/// different reasons: an isolated lane (the smoke probe's) was never in `connections` for
/// `cancel` to walk, and a pooled lane was cancelled but immediately REBUILT by the failover
/// ladder of the very queries that cancellation failed.
///
/// Every test here is network-free by construction. A refusal completes synchronously on the
/// calling thread; admission is observed through the pool or isolated-lane registration.
/// An empty query is rejected by `resolveCurrentQuery`'s transaction-ID check before any
/// `NWConnection` is built, so "admitted" costs no wire contact and no timeout wait.
final class DoQTransportLifecycleTests: XCTestCase {
    /// TEST-NET-3 (RFC 5737) — documentation space, never routable, so a test that did reach
    /// the network could not reach a real resolver.
    private static let endpoint = DNSOverQUICEndpoint(
        hostname: "203.0.113.1",
        bootstrapIPv4Servers: [],
        bootstrapIPv6Servers: []
    )

    func testAnExpiredQueuedLookupFinishesWithoutOpeningAConnection() {
        let connection = DoQConnection(endpoint: Self.endpoint, timeoutSeconds: 30, debugLogger: nil)
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

    private func makeTransport() -> DoQTransport {
        DoQTransport(timeoutSeconds: 30)
    }

    // MARK: - Refusal after teardown

    func testACancelledTransportRefusesPooledWork() {
        let transport = makeTransport()
        transport.cancel()

        let outcome = Outcome()
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

        let outcome = Outcome()
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

        let completed = expectation(description: "pooled query completes")
        transport.resolve(Data(), endpoint: Self.endpoint) { _ in completed.fulfill() }

        XCTAssertEqual(
            transport.laneBookkeeping.pooledEndpointCount, 1,
            "a resumed transport must build a pool for the next tunnel session"
        )
        wait(for: [completed], timeout: 5)
    }

    func testResumeReadmitsIsolatedWork() {
        let observed = ObservedLaneCounts()
        let transport = DoQTransport(timeoutSeconds: 30, debugLogger: nil,
            isolatedLaneObserver: { observed.record($0) })
        transport.cancel()
        transport.resume()
        defer { transport.cancel() }

        let completed = expectation(description: "isolated query completes")
        transport.resolveIsolated(Data(), endpoint: Self.endpoint) { _ in completed.fulfill() }

        XCTAssertEqual(
            observed.counts, [1],
            "a resumed transport must register the next session's isolated smoke-probe lane"
        )
        wait(for: [completed], timeout: 5)
    }

    // MARK: - Isolated lanes are reachable by teardown

    func testAnIsolatedLaneIsRegisteredWhileInFlight() {
        // Observed through the registration seam rather than by reading `laneBookkeeping`
        // afterwards. Two earlier shapes were each racy in the same way: an empty query
        // retires its own lane one hop later, and a well-formed query to an unroutable
        // address only *usually* stays in flight — an environment can report the route
        // unreachable immediately, and then the assertion reads zero for a reason unrelated
        // to the code under test (Kilo then Codex, PR #522). The seam reports the count while
        // the registration is still current, so there is nothing left to race.
        let observed = ObservedLaneCounts()
        let transport = DoQTransport(
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
        // The other half, and the one that must observe a NORMAL completion rather than a
        // cancel: `cancel` empties the registry wholesale, so retirement asserted after a
        // cancel would hold even with `forgetIsolatedConnection` deleted. An empty query is
        // right here — it completes on its own — and the read happens AFTER the wait, so the
        // race the split exists to remove cannot apply.
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
        // The registry assertions prove teardown FORGETS the lane. This proves it CANCELS
        // it, which is the property that matters: a forgotten-but-running connection still
        // completes its QUIC handshake, still fires `dns-doq-connection-ready`, and still
        // lands that handshake in the next session's energy window.
        //
        // The PASS path is deterministic and network-free, which two earlier versions were
        // not. Using an unroutable address left the completion able to arrive on its own
        // either side of the cancel, so the test could pass with teardown never touching
        // isolated lanes at all; checking `settledSynchronously` only excluded completion
        // before `resolveIsolated` RETURNED, not before `cancel()` ran (Codex P2, PR #522).
        //
        // The registration seam closes it. The observer runs after the lane is registered and
        // BEFORE the query is handed to that lane's queue, so blocking there parks the
        // resolution at exactly the interesting instant: the lane exists and is reachable by
        // teardown, but has no query on it yet. `cancel()` then runs against a registered
        // lane, and when the block is released `DoQConnection.resolve` finds `isCancelled`
        // and completes at once. A completion here can only have been caused by the cancel.
        //
        // The KILL is claimed per mutant, not blanket (Kilo, PR #522). A `cancel()` that no
        // longer reaches the isolated registry leaves the parked lane registered — the count
        // assertions below fail on any runner, network-free. A `cancel()` that still empties
        // the registry but skips cancelling the connections is killed by the completion
        // assertions instead, and that kill relies on the unroutable fixture not completing
        // inside the wait: the released `resolve` would find `isCancelled == false` and open
        // a real connection, so a runner that fails TEST-NET-3 fast enough could pass for
        // the wrong reason. Named residual — no assertion visible to this test can observe
        // "the connection was cancelled" without the network's opinion.
        let registered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let transport = DoQTransport(
            timeoutSeconds: 30,
            debugLogger: nil,
            isolatedLaneObserver: { _ in
                registered.signal()
                release.wait()
            })

        let outcome = Outcome()
        let completed = expectation(description: "isolated query completes")
        DispatchQueue.global().async {
            transport.resolveIsolated(DNSResolverSmokeProbe.query(), endpoint: Self.endpoint) {
                outcome.record($0)
                completed.fulfill()
            }
        }

        registered.wait()
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
        // Parked the same way as the cancellation test above, and for the same reason: with a
        // live query the lane can retire itself before `cancel()` runs, so a post-cancel count
        // of zero would hold even if teardown never emptied the registry (Codex P2, PR #522).
        // Blocking the observer keeps the lane registered and query-free until the cancel has
        // happened, which is the only state in which "the registry was emptied BY teardown"
        // is what the count is reporting.
        let registered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let observed = ObservedLaneCounts()
        let transport = DoQTransport(
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
        // Released from a `defer` so a failed assertion below cannot strand the parked
        // observer thread — the test would then fail AND hang (Kilo, PR #522).
        defer { release.signal() }
        XCTAssertEqual(observed.counts, [1], "precondition: the lane was registered")

        transport.cancel()

        XCTAssertEqual(
            transport.laneBookkeeping,
            DoQTransport.LaneBookkeeping(
                isQuiesced: true, isolatedLaneCount: 0, pooledEndpointCount: 0, idleResetIsArmed: false),
            "teardown must leave no lane of either kind and must stay quiesced"
        )

        // Released before the wait; the `defer` above is the failure path, not this one.
        release.signal()
        wait(for: [completed], timeout: 3)
    }

    // MARK: - The idle reset must not outlive the session that armed it

    func testAQuiescedFailurePathCannotArmTheIdleResetForTheNextSession() {
        let held = HeldLanes(transport: makeTransport(), endpoint: Self.endpoint)
        let transport = held.transport
        defer { held.release() }

        // The straggler shape exactly: a query admitted BEFORE teardown is still outstanding
        // (`activeQueryCount > 0`), teardown happens, and only then does the provider's DoQ
        // executor answer a nil response by calling this. Reaching it with a nonzero count is
        // what makes the assertion falsifiable — at zero the deferred branch is never taken
        // and `shouldResetWhenIdle` would be cleared again on the way out regardless.
        transport.cancel()
        transport.resetConnectionsWhenIdle()

        XCTAssertFalse(
            transport.laneBookkeeping.idleResetIsArmed,
            "arming after teardown carries the flag into the NEXT tunnel session, whose "
                + "freshly built pool is then torn down at its first idle moment — charging "
                + "that session an extra QUIC handshake the previous one caused"
        )
    }

    func testARunningSessionStillDefersItsSharedLaneReset() {
        let held = HeldLanes(transport: makeTransport(), endpoint: Self.endpoint)
        let transport = held.transport
        defer { held.release() }

        // Guards the guard. The quiesce check must gate the deferred reset on TEARDOWN, not
        // disable it outright: without this, refusing to arm unconditionally would pass the
        // test above while breaking the reset-on-failure behaviour the flag exists for.
        transport.resetConnectionsWhenIdle()

        XCTAssertTrue(
            transport.laneBookkeeping.idleResetIsArmed,
            "a running session must still defer its shared-lane reset until queries finish"
        )
    }
}

/// Holds a `DoQTransport` with one query permanently in flight — `activeQueryCount == 1` —
/// without touching the network.
///
/// The DoQ lanes are serial queues, so a completion that blocks blocks its whole lane. This
/// blocks every lane in the endpoint's pool, then issues one more query: round-robin hands it
/// back to an already-blocked lane, where its `queue.async` body never runs, so the count
/// increment `DoQTransport.resolve` made synchronously is never matched by a `finishQuery`.
///
/// Needed because the deferred-reset branch is only reachable at a nonzero in-flight count,
/// and every query that can complete does so within one queue hop (an empty query is rejected
/// by the transaction-ID check before any `NWConnection` is built). A real in-flight query
/// would mean a real resolver and a real timeout — a flaky test standing in for a
/// deterministic one.
private final class HeldLanes {
    let transport: DoQTransport
    private let blockedLaneEntered = DispatchSemaphore(value: 0)
    private let releaseBlockedLanes = DispatchSemaphore(value: 0)
    private let laneCount = DoQTransport.maxConnectionsPerEndpoint

    init(transport: DoQTransport, endpoint: DNSOverQUICEndpoint) {
        self.transport = transport
        let entered = blockedLaneEntered
        let release = releaseBlockedLanes
        for _ in 0..<laneCount {
            transport.resolve(Data(), endpoint: endpoint) { _ in
                entered.signal()
                release.wait()
            }
        }
        // Every lane is inside its completion before the held query is issued, so the count
        // this leaves behind is exactly the held query's.
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
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var recordedResponse: Data?

    func record(_ response: DNSTransportResponse) {
        lock.lock()
        settled = true
        recordedResponse = response.response
        lock.unlock()
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
private final class ObservedLaneCounts: @unchecked Sendable {
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
