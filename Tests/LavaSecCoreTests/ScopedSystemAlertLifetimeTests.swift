import XCTest
@testable import LavaSecPresentation

final class ScopedSystemAlertLifetimeTests: XCTestCase {
    private let first = ScopedSystemAlertLifetime.Ticket(ownerID: "visit", requestID: "first")
    private let second = ScopedSystemAlertLifetime.Ticket(ownerID: "replacement", requestID: "second")

    func testCancelBeforePresentationPreventsDelayedReappearance() {
        var lifetime = ScopedSystemAlertLifetime()
        XCTAssertFalse(lifetime.cancel(first))
        XCTAssertFalse(lifetime.begin(first))
        XCTAssertNil(lifetime.current)
    }
    func testCompletionIsOnceOnlyAndCannotReplayTheSameRequest() {
        var lifetime = ScopedSystemAlertLifetime()
        XCTAssertTrue(lifetime.begin(first))
        XCTAssertTrue(lifetime.finish(first))
        XCTAssertFalse(lifetime.finish(first))
        XCTAssertFalse(lifetime.begin(first))
    }
    func testOldCleanupAndCallbacksCannotRetireAReplacementDialog() {
        var lifetime = ScopedSystemAlertLifetime()
        XCTAssertTrue(lifetime.begin(first))
        XCTAssertFalse(lifetime.begin(second))
        XCTAssertTrue(lifetime.cancel(first))
        XCTAssertTrue(lifetime.begin(second))
        XCTAssertFalse(lifetime.mayBegin(first))
        XCTAssertFalse(lifetime.cancel(first))
        XCTAssertFalse(lifetime.finish(first))
        XCTAssertEqual(lifetime.current, second)
        XCTAssertTrue(lifetime.finish(second))
    }
    func testPrivacyCancellationRejectsLateUserSelection() {
        var lifetime = ScopedSystemAlertLifetime()
        XCTAssertTrue(lifetime.begin(first))
        XCTAssertTrue(lifetime.cancel(first))
        XCTAssertFalse(lifetime.finish(first))
    }

    func testNewestReservationSurvivesTwoOlderHostsFinishingTheirDetachment() {
        var lifetime = ScopedSystemAlertLifetime()
        let newest = ScopedSystemAlertLifetime.Ticket(ownerID: "latest-visit", requestID: "third")
        XCTAssertTrue(lifetime.begin(first))
        XCTAssertTrue(lifetime.cancel(first))
        XCTAssertTrue(lifetime.begin(second)) // Waiting for the first host.
        XCTAssertTrue(lifetime.cancel(second))
        XCTAssertTrue(lifetime.begin(newest))
        XCTAssertFalse(lifetime.finish(first))
        XCTAssertFalse(lifetime.finish(second))
        XCTAssertFalse(lifetime.cancel(first))
        XCTAssertEqual(lifetime.current, newest)
        XCTAssertTrue(lifetime.finish(newest))
        XCTAssertFalse(lifetime.finish(newest))
    }

    func testCancellationOfAWaitingReplacementPreventsPresentationAfterTheOldHostDetaches() {
        var lifetime = ScopedSystemAlertLifetime()
        XCTAssertTrue(lifetime.begin(first))
        XCTAssertTrue(lifetime.cancel(first))
        XCTAssertTrue(lifetime.begin(second))
        XCTAssertTrue(lifetime.cancel(second))
        XCTAssertFalse(lifetime.finish(first))
        XCTAssertNil(lifetime.current)
        XCTAssertFalse(lifetime.mayBegin(second))
        XCTAssertFalse(lifetime.begin(second))
        XCTAssertFalse(lifetime.finish(second))
    }
}
