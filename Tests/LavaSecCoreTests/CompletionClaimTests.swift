import XCTest
import LavaSecKit

final class CompletionClaimTests: XCTestCase {
    func testExpirySettlesTheClientWhileLateCompletionOnlyRetiresItsSlot() throws {
        let claim = CompletionClaim()
        let owner = BoundedWorkAdmission<CompletionClaim>(bound: 1)
        let now = ContinuousClock().now
        let lease = try XCTUnwrap(owner.submit(claim, retainedBytes: 1,
            deadline: MonotonicDeadline(after: 1, now: now), now: now).started)
        let expired = try XCTUnwrap(owner.expire(now: now.advanced(by: .seconds(1))).first)
        XCTAssertTrue(expired.claim())
        XCTAssertEqual(owner.activeWorkCount, 1)
        XCTAssertFalse(lease.work.claim(), "late work must not reply to the client a second time")
        _ = owner.complete(lease.id)
        XCTAssertEqual(owner.activeWorkCount, 0)
    }

    func testConcurrentExpiryAndCompletionHaveOneWinner() {
        let claim = CompletionClaim()
        let settled = expectation(description: "one client settlement")
        settled.assertForOverFulfill = true
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            if claim.claim() { settled.fulfill() }
        }
        wait(for: [settled], timeout: 1)
        XCTAssertFalse(claim.claim())
    }

    func testCopiedWrappersShareClaimAndCallbackMayReenter() {
        struct Wrapper { let claim = CompletionClaim() }
        let original = Wrapper()
        let copy = original
        XCTAssertTrue(original.claim.claim())
        XCTAssertFalse(copy.claim.claim())
    }
}
