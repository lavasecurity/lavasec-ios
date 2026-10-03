import Foundation
import XCTest

@testable import LavaSecChainedUpstream

/// The two provider seam adapters, tested for the properties a direct conformance loses.
///
/// Both exist because the obvious implementation — conforming the provider itself — compiles
/// and is wrong twice over: strongly held by the factory it owns (a cycle inside a ~50 MB
/// ceiling), and serving DNS inline on the engine queue (a blackhole the watchdog cannot
/// bound). Neither failure produces a test failure anywhere else, which is why they are
/// asserted here rather than left to the provider's source pins.
final class ChainedTunnelSeamAdapterTests: XCTestCase {

    /// Records whether the host's work ran on the caller's queue. A class because the
    /// observation happens inside a `@Sendable` closure.
    private final class CallerQueueSighting: @unchecked Sendable {
        private let lock = NSLock()
        private var sawIt = false
        func record(_ value: Bool) { lock.withLock { sawIt = sawIt || value } }
        var didSee: Bool { lock.withLock { sawIt } }
    }

    private final class RecordingHost: ChainedTunnelSeamHost, @unchecked Sendable {
        private let lock = NSLock()
        private var writes: [(packets: [Data], protocols: [NSNumber])] = []
        private var served: [Data] = []
        /// Runs inside `serveClientDNSQuery`, so a test can observe the serving context.
        var onServe: (@Sendable () -> Void)?

        var writeCount: Int { lock.withLock { writes.count } }
        var lastWrite: (packets: [Data], protocols: [NSNumber])? { lock.withLock { writes.last } }
        var servedPackets: [Data] { lock.withLock { served } }
        private var servedTokens: [UInt64] = []
        var tokens: [UInt64] { lock.withLock { servedTokens } }

        func writeDecryptedPackets(_ packets: [Data], protocols: [NSNumber]) {
            lock.withLock { writes.append((packets, protocols)) }
        }

        func serveClientDNSQuery(_ packet: Data, lifecycleToken: UInt64) {
            lock.withLock { onServe }?()
            lock.withLock {
                served.append(packet)
                servedTokens.append(lifecycleToken)
            }
        }
    }

    // MARK: - The retain cycle

    /// The writer must not keep the host alive.
    ///
    /// `ChainedUpstreamSessionFactory` holds its writer strongly and the provider owns the
    /// factory, so a strong reference here closes a cycle that outlives every teardown —
    /// keeping an engine and its buffers resident inside the jetsam ceiling (`INV-MEM-1`).
    func testTheWriterHoldsTheHostWeakly() throws {
        var host: RecordingHost? = RecordingHost()
        weak let observed = host
        let writer = ChainedTunnelWriterAdapter(host: try XCTUnwrap(host))

        host = nil

        XCTAssertNil(
            observed,
            "the writer adapter kept the provider alive, which is the retain cycle the "
                + "adapter exists to avoid")
        // And it stays usable after the host is gone: a late delivery must be a no-op, not a
        // crash — the runner can outlive a teardown by one queued closure.
        writer.write([Data([1])], protocols: [NSNumber(value: 2)])
    }

    func testTheDNSAdapterHoldsTheHostWeakly() throws {
        var host: RecordingHost? = RecordingHost()
        weak let observed = host
        let queue = DispatchQueue(label: "test.serving")
        let server = ChainedDNSServingAdapter(host: try XCTUnwrap(host), queue: queue, lifecycleToken: 7)

        host = nil

        XCTAssertNil(observed, "the DNS adapter kept the provider alive")
        server.serveDNS(Data([1]))
        queue.sync {}  // a late serve on a dead host is a no-op, not a crash
    }

    // MARK: - The writer

    func testTheWriterForwardsBatchesUnchanged() {
        let host = RecordingHost()
        let writer = ChainedTunnelWriterAdapter(host: host)
        let packets = [Data([0xA]), Data([0xB, 0xC])]
        let protocols = [NSNumber(value: 2), NSNumber(value: 2)]

        writer.write(packets, protocols: protocols)

        XCTAssertEqual(host.writeCount, 1)
        XCTAssertEqual(host.lastWrite?.packets, packets)
        XCTAssertEqual(host.lastWrite?.protocols, protocols)
    }

    // MARK: - The queue hop

    /// `serveDNS` must RETURN before the host's work runs, and the work must not run on the
    /// caller's queue.
    ///
    /// The caller is the runner's per-packet loop holding the engine queue, and the host's
    /// DNS path blocks on `dnsStateQueue`. Serving inline — or with a `sync` hop, which
    /// satisfies "different queue" and blocks just as long — is the blackhole the armed
    /// watchdog cannot bound, because its handler is enqueued behind this call on that same
    /// serial queue.
    func testServingReturnsWithoutRunningOnTheCallersQueue() {
        let host = RecordingHost()
        let servingQueue = DispatchQueue(label: "test.serving")
        let callerQueue = DispatchQueue(label: "test.caller")
        let callerKey = DispatchSpecificKey<Bool>()
        callerQueue.setSpecific(key: callerKey, value: true)
        let server = ChainedDNSServingAdapter(host: host, queue: servingQueue, lifecycleToken: 7)

        let sawCallerQueue = CallerQueueSighting()
        host.onServe = {
            sawCallerQueue.record(DispatchQueue.getSpecific(key: callerKey) == true)
        }

        // HOLD the serving queue until the caller's frame has provably exited. Without the
        // gate this test raced its own subject: a normally scheduled system may start the
        // hopped work immediately after submission, concurrently with the caller's next
        // statement, so a CORRECT adapter could intermittently read "served before return"
        // (Codex, PR #501). With the gate, in-frame serving can only mean the serve ran
        // INLINE — the defect — and a `sync` hop deadlocks against the gate, which the
        // expectation timeout converts into a failure rather than a hang.
        let gate = DispatchSemaphore(value: 0)
        servingQueue.async { gate.wait() }

        let servedInsideFrame = CallerQueueSighting()
        let returned = expectation(description: "serveDNS returned")
        callerQueue.async {
            server.serveDNS(Data([0xDE]))
            servedInsideFrame.record(!host.servedPackets.isEmpty)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 5)

        gate.signal()
        servingQueue.sync {}

        XCTAssertFalse(
            servedInsideFrame.didSee,
            "serveDNS ran the host's work before returning, so it blocks the engine queue "
                + "mid-batch — the defect the hop exists to prevent")
        XCTAssertFalse(
            sawCallerQueue.didSee, "the host's DNS work ran on the caller's queue")
        XCTAssertEqual(host.servedPackets, [Data([0xDE])], "the query never reached the host")
    }

    // MARK: - The backlog bound

    /// A stalled serve drops beyond the ceiling instead of accumulating, and recovers.
    ///
    /// The runner's own admission charge is released the moment `serveDNS` returns, so this
    /// backlog is under no other bound — client DNS at line rate against a stalled
    /// `dnsStateQueue` would otherwise retain a closure and a full `Data` per query inside
    /// the ~50 MB ceiling (Codex P1, PR #501). Dropping is UDP resolver semantics; the
    /// recovery half proves admissions are RELEASED, so the ceiling bounds the backlog
    /// rather than the adapter's lifetime throughput.
    func testAStalledServeDropsBeyondTheBacklogCeilingAndRecovers() {
        let host = RecordingHost()
        let servingQueue = DispatchQueue(label: "test.serving")
        let server = ChainedDNSServingAdapter(host: host, queue: servingQueue, lifecycleToken: 7)
        let limits = ChainedDNSServingAdapter.backlogLimits

        let gate = DispatchSemaphore(value: 0)
        servingQueue.async { gate.wait() }

        let flood = limits.maximumCount + 10
        for index in 0..<flood {
            server.serveDNS(Data([UInt8(index % 251)]))
        }
        XCTAssertEqual(
            server.droppedQueryCount(), 10,
            "everything past the count ceiling must be dropped at admission, on the "
                + "caller's thread — a closure waiting for the queue is visible to no bound "
                + "that lives on it")

        gate.signal()
        servingQueue.sync {}
        XCTAssertEqual(
            host.servedPackets.count, limits.maximumCount,
            "the admitted backlog must drain in full — dropping is for the flood, not the "
                + "queue")

        // Recovery: a drained backlog admits again. This is the half a missing `release`
        // fails — the gauge would stay saturated and the adapter would drop every query for
        // the rest of the session.
        server.serveDNS(Data([0xEE]))
        servingQueue.sync {}
        XCTAssertEqual(host.servedPackets.count, limits.maximumCount + 1)
        XCTAssertEqual(server.droppedQueryCount(), 10, "the post-drain query must not be dropped")
    }

    /// The byte ceiling sees the real payload sizes.
    ///
    /// Distinct from the count test because it dies to a different mutation: an adapter that
    /// admits `bytes: 0` keeps the count bound and loses the byte bound entirely, so a few
    /// hundred maximal queries would retain what thousands of minimal ones could not.
    func testTheByteCeilingCountsRealQueryBytes() {
        let host = RecordingHost()
        let servingQueue = DispatchQueue(label: "test.serving")
        let server = ChainedDNSServingAdapter(host: host, queue: servingQueue, lifecycleToken: 7)
        let limits = ChainedDNSServingAdapter.backlogLimits

        let gate = DispatchSemaphore(value: 0)
        servingQueue.async { gate.wait() }

        // Two crossing admissions, then refusal: admit-then-saturate allows one arrival past
        // the ceiling, and the third must be refused on bytes alone — the count ceiling is
        // nowhere near.
        let big = Data(repeating: 0x61, count: limits.maximumBytes / 2 + 1)
        for _ in 0..<3 { server.serveDNS(big) }
        XCTAssertEqual(
            server.droppedQueryCount(), 1,
            "the byte ceiling did not bind, so the adapter is not admitting real sizes")

        gate.signal()
        servingQueue.sync {}
        XCTAssertEqual(host.servedPackets.count, 2)

        // And the released bytes really come back: a further big query admits after drain.
        server.serveDNS(big)
        servingQueue.sync {}
        XCTAssertEqual(host.servedPackets.count, 3)
    }

    /// Order is preserved, which is why the queue must be SERIAL.
    ///
    /// The DNS path's fragment table and query coalescing both assume queries arrive in the
    /// order the tunnel read them; a concurrent queue here would reorder them invisibly, and
    /// only under load.
    func testQueriesAreServedInArrivalOrder() {
        let host = RecordingHost()
        let servingQueue = ChainedDNSServingAdapter.makeServingQueue()
        let server = ChainedDNSServingAdapter(host: host, queue: servingQueue, lifecycleToken: 7)
        let queries = (0..<64).map { Data([UInt8($0)]) }

        for query in queries { server.serveDNS(query) }
        servingQueue.sync {}

        XCTAssertEqual(
            host.servedPackets, queries,
            "queries were reordered, so the serving queue is not serial — the DNS path's "
                + "fragment table and coalescing both assume arrival order")
    }
}
