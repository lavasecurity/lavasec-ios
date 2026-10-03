import Foundation
import XCTest
@testable import LavaSecKit

/// The retry ladder that makes the fail-closed repair actually reachable.
final class FailClosedReconcileRetryPolicyTests: XCTestCase {

    func testTheFirstRetryOutlastsTheObservedTunnelSettle() {
        // 🔴 THE WHOLE POINT. On device the app's reconcile ran 11s before the tunnel committed
        // fail-closed, so the bootstrap broker refused and — the reconcile being once-per-
        // process — nothing asked again. A first delay at or under that settle would reproduce
        // the bug with extra steps.
        let first = FailClosedReconcileRetryPolicy.delaySeconds(forAttempt: 0)
        XCTAssertNotNil(first)
        XCTAssertGreaterThan(
            first ?? 0, 11,
            "the first retry must clear the measured ~11s tunnel settle")
    }

    func testTheLadderBacksOffAndThenStops() {
        var previous: TimeInterval = 0
        for attempt in 0..<FailClosedReconcileRetryPolicy.maximumRetryCount {
            let delay = FailClosedReconcileRetryPolicy.delaySeconds(forAttempt: attempt)
            XCTAssertNotNil(delay, "attempt \(attempt) must be scheduled")
            XCTAssertGreaterThan(delay ?? 0, previous, "attempt \(attempt) must back off")
            previous = delay ?? 0
        }
        // Bounded: a genuinely unfixable configuration is already reported to the user, and a
        // device that cannot repair itself must stop spending radio on trying.
        XCTAssertNil(
            FailClosedReconcileRetryPolicy.delaySeconds(
                forAttempt: FailClosedReconcileRetryPolicy.maximumRetryCount))
    }

    func testNoRetryIsScheduledWhileProtectionIsOff() {
        // With protection off the tunnel serves nothing, the app's resolver works, and the
        // ordinary catalog refresh repairs the artifact on its own schedule.
        XCTAssertFalse(
            FailClosedReconcileRetryPolicy.shouldScheduleRetry(
                attempt: 0, protectionIsEnabled: false))
        XCTAssertTrue(
            FailClosedReconcileRetryPolicy.shouldScheduleRetry(
                attempt: 0, protectionIsEnabled: true))
    }

    func testAnExhaustedLadderScheduleNothingEvenWithProtectionOn() {
        XCTAssertFalse(
            FailClosedReconcileRetryPolicy.shouldScheduleRetry(
                attempt: FailClosedReconcileRetryPolicy.maximumRetryCount,
                protectionIsEnabled: true))
    }
}
