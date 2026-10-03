import Network
import XCTest

@testable import LavaSecChainedUpstream

/// The opener is deliberately thin, so there is exactly one thing about IT worth asserting without
/// a network: that it REFUSES rather than degrades.
///
/// Everything else in `ChainedUpstreamChannel` is `NWConnection` plumbing whose behaviour needs a
/// live socket, and a test that opened one would prove the network's state rather than this
/// type's. The refusal needs no socket at all: it is decided before the connection is built.
///
/// `ChainedUpstreamLivePath` lives in the same file and is not thin in the same way — it owns the
/// one blocking wait in the chained transport, and a wait is exactly the kind of code whose
/// failure modes are invisible until something wakes it at the wrong moment. Those tests need no
/// network either: the monitor is injected, so a test decides when — and whether — a report ever
/// arrives.
final class ChainedUpstreamChannelTests: XCTestCase {

    func testAWakeWithoutAReportDoesNotEndThePrimingWait() {
        // `NSCondition.wait` may return without anyone having signalled it — a spurious wake-up,
        // which every condition-variable API documents and none prevents. The wait was
        // `if !hasReported { wait(until:) }`, so a spurious wake returned the STILL-EMPTY cache and
        // the caller took it for a primed path. An empty interface list matches no binding, the
        // build refuses the socket, and the driver spends a rung it did not need to (or, before the
        // build-failure triage, ended chained mode for the lifecycle). Waiting on a state change
        // and then not re-reading the state is the whole defect.
        //
        // A REAL spurious wake cannot be produced on demand — that is what "spurious" means — so
        // this delivers the thing that is indistinguishable from one to the code under test: a
        // broadcast with `hasReported` still false. It is why the condition is module-internal.
        let sink = RecordingPathSink()
        let path = ChainedUpstreamLivePath(observe: { report in
            sink.capture(report)
            return nil
        })
        let entered = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        // A flag as well as the semaphore, so the mid-test check does not CONSUME the signal the
        // final assertion is waiting for — otherwise one failure reports as two and the second
        // message is a lie.
        let hasReturned = Flag()
        DispatchQueue.global().async {
            entered.signal()
            path.startedAndWaitingForFirstReport(timeoutMilliseconds: 4_000)
            hasReturned.raise()
            returned.signal()
        }
        XCTAssertEqual(
            entered.wait(timeout: .now() + .seconds(5)), .success, "the waiting thread never ran")

        // Wakes, repeatedly, for long enough that one lands while the wait is actually parked.
        // The cap is 4 s, so nothing here can be confused with the timeout expiring.
        for _ in 0..<100 {
            path.state.lock()
            path.state.broadcast()
            path.state.unlock()
            usleep(2_000)
        }

        XCTAssertFalse(
            hasReturned.isRaised,
            "a wake that carried no report ended the wait, so the caller was handed an empty "
                + "cache as a primed path")

        // And a real report still ends it — the loop must be a predicate, not a refusal to return.
        sink.report()
        XCTAssertEqual(
            returned.wait(timeout: .now() + .seconds(3)), .success,
            "the first report did not end the wait")
    }

    func testWakesCannotStretchThePrimingWaitPastItsTimeout() {
        // The other half of a predicate loop, and the one that turns a fix into a worse bug: if the
        // deadline is recomputed on each wake, every wake restores the full cap and the "bounded"
        // wait becomes unbounded. This runs during tunnel setup, which stands still for it.
        //
        // Wakes arrive faster than the cap for far longer than the cap. With one deadline computed
        // up front the wait ends on schedule regardless; with a deadline computed per wake it is
        // still parked when the hammering stops.
        let path = ChainedUpstreamLivePath(observe: { _ in nil })
        let entered = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            entered.signal()
            path.startedAndWaitingForFirstReport(timeoutMilliseconds: 200)
            returned.signal()
        }
        XCTAssertEqual(
            entered.wait(timeout: .now() + .seconds(5)), .success, "the waiting thread never ran")

        let hammerUntil = Date().addingTimeInterval(1.5)
        while Date() < hammerUntil {
            path.state.lock()
            path.state.broadcast()
            path.state.unlock()
            usleep(2_000)
        }

        XCTAssertEqual(
            returned.wait(timeout: .now()), .success,
            "the wait outlived its 200 ms cap by more than 1.3 s while wakes kept arriving — the "
                + "deadline is being recomputed per wake, so nothing bounds it")
    }

    func testAChannelIsNotConstructibleWithoutTheSelectedInterfaceIdentity() throws {
        // Under `INV-CHAIN-1` the tunnel claims `0.0.0.0/0`, so a socket that fell back to a
        // type-only binding could be satisfied by an interface nobody selected — including the
        // tunnel's own path, which is the encapsulation loop rather than a slow degradation.
        //
        // `nil` here is what makes that unreachable: `ChainedUpstreamSessionFactory` turns it
        // into `ChainedSessionBuildFailure.unbindableInterface`, the attempt is spent, and the
        // ladder retries against a fresh path reading. Passing an empty interface list is the
        // only way a test can reach this branch, because `NWInterface` cannot be constructed.
        let endpoint = try XCTUnwrap(ChainedEndpointAddress(literal: "203.0.113.9", port: 51_820))
        let binding = try XCTUnwrap(
            ChainedBindableInterface(ChainedUpstreamInterface(name: "en0", kind: .wifi)))

        XCTAssertNil(
            ChainedUpstreamChannel(
                endpoint: endpoint,
                binding: binding,
                queue: DispatchQueue(label: "com.lavasec.test.channel"),
                liveInterfaces: []),
            "a socket was opened with no interface identity to pin it to")
    }

    /// A one-way flag, readable without consuming anything.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    /// Holds the sink a `ChainedUpstreamLivePath` observation was given, so a test can decide WHEN
    /// the first report arrives — which is the only thing that may end a priming wait early.
    final class RecordingPathSink: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: (@Sendable ([NWInterface]) -> Void)?

        func capture(_ sink: @escaping @Sendable ([NWInterface]) -> Void) {
            lock.withLock { self.sink = sink }
        }

        /// Reports an EMPTY interface list, which is the only list a test can build —
        /// `NWInterface` has no public initialiser. The wait is about arrival, not contents.
        func report() {
            let sink = lock.withLock { self.sink }
            sink?([])
        }
    }
}
