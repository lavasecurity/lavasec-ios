import XCTest
import LavaSecKit

final class BoundedWorkAdmissionTests: XCTestCase {
    private let now = ContinuousClock().now

    func testBurstBoundsActivePendingCountAndBytes() throws {
        let owner = BoundedWorkAdmission<Int>(bound: 2, maximumPendingCount: 3, maximumPendingBytes: 10)
        let deadline = MonotonicDeadline(after: 10, now: now)
        var accepted = 0
        for id in 0..<10_000 {
            if owner.submit(id, retainedBytes: 4, deadline: deadline, now: now).accepted { accepted += 1 }
        }
        XCTAssertEqual(accepted, 4)
        XCTAssertEqual(owner.activeWorkCount, 2)
        XCTAssertEqual(owner.pendingWorkCount, 2)
        XCTAssertEqual(owner.pendingByteCount, 8)
        XCTAssertFalse(owner.submit(-1, retainedBytes: Int.max, deadline: deadline, now: now).accepted)
        let countBound = BoundedWorkAdmission<Int>(bound: 1, maximumPendingCount: 2, maximumPendingBytes: 100)
        for id in 0..<20 { _ = countBound.submit(id, retainedBytes: 1, deadline: deadline, now: now) }
        XCTAssertEqual(countBound.pendingWorkCount, 2)
    }

    func testCompletionPromotesFIFOAndRejectsDuplicateRetirement() throws {
        let owner = BoundedWorkAdmission<Int>(bound: 1)
        let deadline = MonotonicDeadline(after: 10, now: now)
        let first = try XCTUnwrap(owner.submit(1, retainedBytes: 3, deadline: deadline, now: now).started)
        XCTAssertTrue(owner.submit(2, retainedBytes: 3, deadline: deadline, now: now).accepted)
        XCTAssertTrue(owner.submit(3, retainedBytes: 3, deadline: deadline, now: now).accepted)
        let second = try XCTUnwrap(owner.complete(first.id, now: now).started)
        XCTAssertEqual(second.work, 2)
        XCTAssertNil(owner.complete(first.id, now: now).started)
        XCTAssertEqual(owner.activeWorkCount, 1)
        let third = try XCTUnwrap(owner.complete(second.id, now: now).started)
        XCTAssertEqual(third.work, 3)
        XCTAssertNil(owner.complete(third.id, now: now).started)
        XCTAssertEqual(owner.activeWorkCount, 0)
        XCTAssertEqual(owner.pendingByteCount, 0)
    }

    func testClientExpiryDoesNotReleaseAnActiveSocketSlot() throws {
        let owner = BoundedWorkAdmission<Int>(bound: 1)
        let soon = MonotonicDeadline(after: 1, now: now)
        let later = MonotonicDeadline(after: 10, now: now)
        let first = try XCTUnwrap(owner.submit(1, retainedBytes: 1, deadline: soon, now: now).started)
        _ = owner.submit(2, retainedBytes: 1, deadline: soon, now: now)
        _ = owner.submit(3, retainedBytes: 1, deadline: later, now: now)
        let expiredAt = now.advanced(by: .seconds(1))
        XCTAssertEqual(Set(owner.expire(now: expiredAt)), [1, 2])
        XCTAssertEqual(owner.activeWorkCount, 1, "client completion is not socket retirement")
        XCTAssertEqual(owner.pendingWorkCount, 1)
        XCTAssertEqual(owner.pendingByteCount, 1)
        XCTAssertEqual(owner.nextDeadline, later)
        XCTAssertEqual(owner.expire(now: expiredAt), [])
        XCTAssertFalse(owner.submit(4, retainedBytes: 1, deadline: soon, now: expiredAt).accepted)
        XCTAssertEqual(owner.complete(first.id, now: expiredAt).started?.work, 3)
    }

    func testRuntimeInvalidationPurgesPendingButRetainsActiveOwnership() throws {
        let owner = BoundedWorkAdmission<Int>(bound: 1)
        let deadline = MonotonicDeadline(after: 10, now: now)
        let active = try XCTUnwrap(owner.submit(1, retainedBytes: 1, deadline: deadline, now: now).started)
        _ = owner.submit(2, retainedBytes: 2, deadline: deadline, now: now)
        _ = owner.submit(3, retainedBytes: 3, deadline: deadline, now: now)
        XCTAssertEqual(owner.discardPending(), [2, 3])
        XCTAssertEqual(owner.pendingWorkCount, 0)
        XCTAssertEqual(owner.pendingByteCount, 0)
        XCTAssertEqual(owner.activeWorkCount, 1)
        XCTAssertEqual(owner.discardPending(), [])
        _ = owner.submit(4, retainedBytes: 1, deadline: deadline, now: now)
        XCTAssertEqual(owner.complete(active.id, now: now).started?.work, 4)
    }

    func testNeverExceedsBoundAndRunsEveryAcceptedItemOnce() throws {
        let owner = BoundedWorkAdmission<Int>(bound: 8)
        let deadline = MonotonicDeadline(after: 10, now: now)
        var running: [BoundedWorkAdmission<Int>.Lease] = []
        var started: [Int] = []
        for id in 0..<50 {
            let submission = owner.submit(id, retainedBytes: 1, deadline: deadline, now: now)
            XCTAssertTrue(submission.accepted)
            if let lease = submission.started { running.append(lease); started.append(lease.work) }
        }
        while let lease = running.first {
            running.removeFirst()
            if let next = owner.complete(lease.id, now: now).started {
                running.append(next)
                started.append(next.work)
            }
            XCTAssertLessThanOrEqual(owner.activeWorkCount, 8)
            XCTAssertEqual(owner.activeWorkCount, running.count)
        }
        XCTAssertEqual(started, Array(0..<50))
        XCTAssertEqual(owner.pendingByteCount, 0)
    }

    func testNonPositiveLimitsCannotCreateExtraCapacity() {
        let owner = BoundedWorkAdmission<Int>(bound: 0, maximumPendingCount: -1, maximumPendingBytes: -1)
        let deadline = MonotonicDeadline(after: 1, now: now)
        XCTAssertEqual(owner.bound, 1)
        XCTAssertTrue(owner.submit(1, retainedBytes: 1, deadline: deadline, now: now).accepted)
        XCTAssertFalse(owner.submit(2, retainedBytes: 1, deadline: deadline, now: now).accepted)
        XCTAssertEqual(deadline.remainingSeconds(now: now), 1, accuracy: 0.000_001)
        XCTAssertTrue(deadline.hasExpired(now: now.advanced(by: .seconds(2))))
    }
}
