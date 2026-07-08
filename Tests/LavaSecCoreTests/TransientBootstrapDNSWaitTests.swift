import XCTest
@testable import LavaSecCore
@testable import LavaSecDNS

/// Executable coverage for the INV-DNS-2 transient-bootstrap wait machine
/// (Phase E2): the 64-deep / 4 s bounds and the generation/expired-generation
/// transitions the provider's source pins could only assert as text. Every exit
/// except a committed current-lifecycle snapshot returns the queue for SERVFAIL;
/// queued requests are only ever released for replay through the filter.
final class TransientBootstrapDNSWaitTests: XCTestCase {
    private let queue = DispatchQueue(label: "transient-bootstrap-wait-tests")

    /// Deterministic harness: arming is RECORDED, never auto-fired — tests drive
    /// the 4 s timeout by executing the captured one-shot handle by hand.
    /// `fire` skips cancelled items, matching a real queue's behavior for a
    /// cancelled `asyncAfter` work item.
    private final class TimeoutSpy {
        private(set) var armedIntervals: [TimeInterval] = []
        private(set) var armedItems: [DispatchWorkItem] = []

        func schedule(after interval: TimeInterval, body: @escaping () -> Void) -> DispatchWorkItem {
            let item = DispatchWorkItem(block: body)
            armedIntervals.append(interval)
            armedItems.append(item)
            return item
        }

        func fire(_ index: Int) {
            let item = armedItems[index]
            guard !item.isCancelled else {
                return
            }
            item.perform()
        }
    }

    private func makeWait() -> (TransientBootstrapDNSWait<Int>, TimeoutSpy) {
        let spy = TimeoutSpy()
        let wait = TransientBootstrapDNSWait<Int>(
            queue: queue,
            scheduleAfter: { interval, body in spy.schedule(after: interval, body: body) }
        )
        return (wait, spy)
    }

    private func onQueue<T>(_ body: @escaping () -> T) -> T {
        queue.sync(execute: body)
    }

    // MARK: - Bounds (INV-DNS-2: at most 64-deep, at most 4 s)

    func test65thEnqueueIsRejectedAndTheOverflowSignalFiresExactlyOnce() {
        let (wait, spy) = makeWait()
        onQueue {
            _ = wait.beginWait(generation: 1) { _ in }
            XCTAssertEqual(wait.enqueue(1, generation: 1), .queued(isFirst: true),
                           "the first entry is flagged so the caller logs its -queued marker once")
            for request in 2...64 {
                XCTAssertEqual(wait.enqueue(request, generation: 1), .queued(isFirst: false))
            }
            XCTAssertEqual(wait.enqueue(65, generation: 1),
                           .rejectOverflow(logOnce: true, pendingCount: 64),
                           "the 65th request must overflow — the 64-deep bound is the invariant")
            XCTAssertEqual(wait.enqueue(66, generation: 1),
                           .rejectOverflow(logOnce: false, pendingCount: 64),
                           "the overflow log signal must dedup after the first overflow per wait")
            // Overflow rejects the newcomer but never evicts the held queue.
            XCTAssertEqual(wait.drain(currentGeneration: 1),
                           .replay(Array(1...64), replayGeneration: 1))
        }
        XCTAssertEqual(spy.armedIntervals, [4],
                       "exactly one 4 s timeout is armed by beginWait; appends arm nothing")
    }

    func testTimeoutExpiryDrainsEverythingSERVFAILBound() {
        let (wait, spy) = makeWait()
        var drainedOnTimeout: [Int]?
        onQueue {
            _ = wait.beginWait(generation: 3) { generation in
                // Mirrors the provider's timeout handler: the expiry transition
                // marks the generation expired so latecomers keep SERVFAILing.
                drainedOnTimeout = wait.fail(expectedGeneration: generation, marksGenerationExpired: true)
            }
            _ = wait.enqueue(10, generation: 3)
            _ = wait.enqueue(11, generation: 3)
            _ = wait.enqueue(12, generation: 3)
            spy.fire(0)
        }
        XCTAssertEqual(drainedOnTimeout, [10, 11, 12],
                       "timeout must hand back EVERY held request for SERVFAIL — nothing forwards")
        onQueue {
            XCTAssertEqual(wait.enqueue(13, generation: 3), .rejectExpiredGeneration,
                           "a same-lifecycle latecomer after the timeout is signalled for SERVFAIL")
        }
    }

    // MARK: - Generation dance

    func testStaleGenerationEnqueueIsRejected() {
        let (wait, _) = makeWait()
        onQueue {
            XCTAssertEqual(wait.enqueue(1, generation: 5), .notHandled,
                           "no wait armed — the caller answers via its normal fail-closed path")
            _ = wait.beginWait(generation: 5) { _ in }
            XCTAssertEqual(wait.enqueue(2, generation: 6), .notHandled,
                           "a wait armed under another lifecycle generation must be invisible")
            XCTAssertEqual(wait.drain(currentGeneration: 5), .replay([], replayGeneration: 5),
                           "the stale-generation request must not have been queued")
        }
    }

    func testExpiredGenerationLatecomerIsScopedToItsLifecycle() {
        let (wait, spy) = makeWait()
        onQueue {
            _ = wait.beginWait(generation: 2) { generation in
                _ = wait.fail(expectedGeneration: generation, marksGenerationExpired: true)
            }
            _ = wait.enqueue(1, generation: 2)
            spy.fire(0)
            XCTAssertEqual(wait.enqueue(2, generation: 2), .rejectExpiredGeneration,
                           "same-lifecycle latecomers after the timeout SERVFAIL")
            XCTAssertEqual(wait.enqueue(3, generation: 9), .notHandled,
                           "the expired marker never leaks into another lifecycle")
        }
    }

    func testSnapshotUnavailableFailDrainsWithoutMarkingTheGenerationExpired() {
        let (wait, _) = makeWait()
        onQueue {
            _ = wait.beginWait(generation: 4) { _ in }
            _ = wait.enqueue(1, generation: 4)
            // The async load itself failed closed: no expectedGeneration, no marker.
            XCTAssertEqual(wait.fail(expectedGeneration: nil, marksGenerationExpired: false), [1],
                           "a failed snapshot load hands the queue back for SERVFAIL")
            XCTAssertEqual(wait.enqueue(2, generation: 4), .notHandled,
                           "no expired marker — latecomers take the normal immediate fail-closed answer")
            XCTAssertEqual(wait.fail(expectedGeneration: nil, marksGenerationExpired: false), [],
                           "fail while inactive is a no-op")
        }
    }

    func testStaleTimeoutForAReplacedWaitIsANoOp() {
        let (wait, _) = makeWait()
        onQueue {
            _ = wait.beginWait(generation: 1) { _ in }
            _ = wait.beginWait(generation: 2) { _ in }
            _ = wait.enqueue(7, generation: 2)
            XCTAssertEqual(wait.fail(expectedGeneration: 1, marksGenerationExpired: true), [],
                           "an old wait's timeout must not kill the wait that replaced it")
            XCTAssertEqual(wait.enqueue(8, generation: 2), .queued(isFirst: false),
                           "the replacement wait stays armed — and no expired marker was stamped")
        }
    }

    // MARK: - Commit drains

    func testCommitWithMatchingGenerationDrainsForReplayAndDisarmsTheTimeout() {
        let (wait, spy) = makeWait()
        var timedOut = false
        onQueue {
            _ = wait.beginWait(generation: 6) { _ in timedOut = true }
            _ = wait.enqueue(20, generation: 6)
            _ = wait.enqueue(21, generation: 6)
            XCTAssertEqual(wait.drain(currentGeneration: 6),
                           .replay([20, 21], replayGeneration: 6),
                           "a committed current-lifecycle snapshot is the ONE exit that replays — through the filter")
            XCTAssertEqual(wait.drain(currentGeneration: 6), .idle,
                           "exactly one drain per wait")
            spy.fire(0)
        }
        XCTAssertFalse(timedOut, "the commit drain must cancel the pending timeout")
    }

    func testCommitWithWrongGenerationDrainsNothingForReplay() {
        let (wait, _) = makeWait()
        onQueue {
            _ = wait.beginWait(generation: 1) { _ in }
            _ = wait.enqueue(30, generation: 1)
            XCTAssertEqual(wait.drain(currentGeneration: 2), .staleLifecycle([30]),
                           "a snapshot committed under a different lifecycle must SERVFAIL the queue, never replay it")
            XCTAssertEqual(wait.drain(currentGeneration: 2), .idle)
        }
    }

    func testCommitAfterTimeoutConsumesTheExpiredMarker() {
        let (wait, spy) = makeWait()
        onQueue {
            _ = wait.beginWait(generation: 3) { generation in
                _ = wait.fail(expectedGeneration: generation, marksGenerationExpired: true)
            }
            _ = wait.enqueue(1, generation: 3)
            spy.fire(0)
            XCTAssertEqual(wait.drain(currentGeneration: 3), .replay([], replayGeneration: 3),
                           "the timeout already SERVFAILed the queue; the commit drains empty")
            XCTAssertEqual(wait.enqueue(2, generation: 3), .notHandled,
                           "the commit consumed the expired marker — latecomers stop being timeout-tagged")
        }
    }

    // MARK: - Teardown & replacement

    func testTeardownReturnsTheQueueForSERVFAILAndResetsForTheNextLifecycle() {
        let (wait, spy) = makeWait()
        onQueue {
            XCTAssertEqual(wait.cancelWait(), [], "teardown with nothing armed is a no-op")
            _ = wait.beginWait(generation: 1) { _ in }
            for request in 1...65 {
                _ = wait.enqueue(request, generation: 1) // 65th overflows; 64 stay held
            }
            XCTAssertEqual(wait.cancelWait(), Array(1...64),
                           "teardown hands the whole queue back for SERVFAIL — nothing forwards")
            XCTAssertEqual(wait.enqueue(99, generation: 1), .notHandled,
                           "after teardown the wait is gone; requests take the normal fail-closed path")

            // The next lifecycle starts clean: depth and the overflow-log dedup reset.
            XCTAssertEqual(wait.beginWait(generation: 2) { _ in }, [],
                           "teardown left nothing behind to replace")
            XCTAssertEqual(wait.enqueue(1, generation: 2), .queued(isFirst: true))
            for request in 2...64 {
                _ = wait.enqueue(request, generation: 2)
            }
            XCTAssertEqual(wait.enqueue(65, generation: 2),
                           .rejectOverflow(logOnce: true, pendingCount: 64),
                           "the overflow-log dedup is per-wait, so the fresh wait signals once again")
            spy.fire(0) // the torn-down wait's timeout was cancelled — must be inert
            XCTAssertEqual(wait.drain(currentGeneration: 2),
                           .replay(Array(1...64), replayGeneration: 2))
        }
    }

    func testBeginWaitReplacesAPriorWaitAndReturnsItsQueueForSERVFAIL() {
        let (wait, spy) = makeWait()
        onQueue {
            _ = wait.beginWait(generation: 1) { _ in }
            _ = wait.enqueue(1, generation: 1)
            _ = wait.enqueue(2, generation: 1)
            let replaced = wait.beginWait(generation: 2) { _ in }
            XCTAssertEqual(replaced, [1, 2],
                           "a replaced wait's queue is handed back for SERVFAIL, never dropped or replayed")
            spy.fire(0) // the replaced wait's timeout was cancelled with it
            XCTAssertEqual(wait.enqueue(3, generation: 2), .queued(isFirst: true),
                           "the replacement wait is live for its own generation")
        }
        XCTAssertEqual(spy.armedIntervals, [4, 4], "each beginWait arms exactly one timeout")
    }
}
