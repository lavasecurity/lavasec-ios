import XCTest
@testable import LavaSecCore

final class BoundedWorkAdmissionTests: XCTestCase {
    func testAdmitsUpToBoundImmediately() {
        let admission = BoundedWorkAdmission<Int>(bound: 3)

        XCTAssertEqual(admission.admit(1), 1)
        XCTAssertEqual(admission.admit(2), 2)
        XCTAssertEqual(admission.admit(3), 3)
        XCTAssertEqual(admission.activeWorkCount, 3)
        XCTAssertEqual(admission.pendingWorkCount, 0)
    }

    func testOverBoundSubmissionsWaitInFifo() {
        let admission = BoundedWorkAdmission<Int>(bound: 2)
        _ = admission.admit(1)
        _ = admission.admit(2)

        XCTAssertNil(admission.admit(3), "A submission over the bound must wait, not run immediately.")
        XCTAssertNil(admission.admit(4))
        XCTAssertEqual(admission.activeWorkCount, 2, "The bound never rises while work is pending.")
        XCTAssertEqual(admission.pendingWorkCount, 2)
    }

    func testReleaseStartsNextPendingInFifoOrder() {
        let admission = BoundedWorkAdmission<Int>(bound: 1)
        XCTAssertEqual(admission.admit(1), 1)
        XCTAssertNil(admission.admit(2))
        XCTAssertNil(admission.admit(3))

        // First release hands back the oldest waiter and keeps the slot claimed.
        XCTAssertEqual(admission.release(), 2)
        XCTAssertEqual(admission.activeWorkCount, 1, "One out, one in — the bound holds exactly.")
        XCTAssertEqual(admission.pendingWorkCount, 1)

        XCTAssertEqual(admission.release(), 3, "FIFO order: 3 follows 2.")
        XCTAssertEqual(admission.activeWorkCount, 1)
        XCTAssertEqual(admission.pendingWorkCount, 0)
    }

    func testReleaseWithoutPendingDropsTheActiveCount() {
        let admission = BoundedWorkAdmission<Int>(bound: 2)
        _ = admission.admit(1)
        _ = admission.admit(2)

        XCTAssertNil(admission.release(), "Nothing waiting — release frees the slot and starts nothing.")
        XCTAssertEqual(admission.activeWorkCount, 1)
        XCTAssertNil(admission.release())
        XCTAssertEqual(admission.activeWorkCount, 0)
    }

    func testFreedSlotAdmitsANewSubmissionImmediately() {
        let admission = BoundedWorkAdmission<Int>(bound: 1)
        XCTAssertEqual(admission.admit(1), 1)
        XCTAssertNil(admission.admit(2))

        // Drain the pending item first, then the slot re-opens for a brand-new submission.
        XCTAssertEqual(admission.release(), 2)
        XCTAssertNil(admission.release(), "2 completes with an empty FIFO — the slot frees.")
        XCTAssertEqual(admission.admit(3), 3, "A fresh submission is admitted immediately once under the bound.")
    }

    func testNeverExceedsBoundAcrossAnInterleavedBurst() {
        // Simulate an outage-style burst: 50 submissions against a bound of 8, interleaving
        // releases. The invariant is that activeWorkCount never exceeds the bound and every
        // submission is eventually run exactly once, in FIFO order.
        let bound = 8
        let admission = BoundedWorkAdmission<Int>(bound: bound)
        let total = 50

        var running: [Int] = []
        var started: [Int] = []

        func begin(_ work: Int?) {
            guard let work else { return }
            running.append(work)
            started.append(work)
            XCTAssertLessThanOrEqual(admission.activeWorkCount, bound, "The concurrency bound must never be exceeded.")
            XCTAssertLessThanOrEqual(running.count, bound)
        }

        // Submit everything; only the first `bound` start, the rest queue.
        for id in 0..<total {
            begin(admission.admit(id))
        }
        XCTAssertEqual(running.count, bound)
        XCTAssertEqual(admission.pendingWorkCount, total - bound)

        // Complete work items one at a time; each release starts the next FIFO waiter until
        // the backlog drains, then simply retires the running items.
        while !running.isEmpty {
            running.removeFirst()
            begin(admission.release())
        }

        XCTAssertEqual(started.sorted(), Array(0..<total), "Every submission runs exactly once.")
        XCTAssertEqual(started, Array(0..<total), "Submissions start in strict FIFO order.")
        XCTAssertEqual(admission.activeWorkCount, 0)
        XCTAssertEqual(admission.pendingWorkCount, 0)
    }

    func testNonPositiveBoundIsClampedToOne() {
        let zero = BoundedWorkAdmission<Int>(bound: 0)
        XCTAssertEqual(zero.bound, 1)
        XCTAssertEqual(zero.admit(1), 1)
        XCTAssertNil(zero.admit(2), "Clamped to a serial lane — the second submission waits.")

        let negative = BoundedWorkAdmission<Int>(bound: -5)
        XCTAssertEqual(negative.bound, 1)
    }
}
