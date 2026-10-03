import XCTest

@testable import LavaSecChainedUpstream

/// The bound the downgrade and the surrender persist share: a wedged security daemon costs
/// the caller the timeout, never the wedge.
final class ChainedBoundedKeychainWorkTests: XCTestCase {
    func testWorkThatAnswersPassesStraightThrough() throws {
        let ran = RanFlag()
        try ChainedBoundedKeychainWork.perform { _ in ran.set() }
        XCTAssertTrue(ran.value)
    }

    private final class RanFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        func set() { lock.withLock { stored = true } }
        var value: Bool { lock.withLock { stored } }
    }

    func testTheWorksOwnErrorTravelsUnchanged() {
        struct KeychainRefused: Error {}
        XCTAssertThrowsError(
            try ChainedBoundedKeychainWork.perform { _ in throw KeychainRefused() }
        ) { error in
            XCTAssertTrue(
                error is KeychainRefused,
                "a store that ANSWERED with a refusal must keep its own error — only a "
                    + "non-answer becomes the timeout")
        }
    }

    /// The property both callers depend on: a store that never answers throws promptly, so
    /// the downgrade still reaches its relatch and the surrender still reaches its restart.
    func testAWedgedStoreTimesOutInsteadOfBlockingTheCaller() {
        let hold = DispatchSemaphore(value: 0)
        defer { hold.signal() }

        let began = Date()
        XCTAssertThrowsError(
            try ChainedBoundedKeychainWork.perform(timeoutMilliseconds: 50) { _ in hold.wait() }
        ) { error in
            XCTAssertTrue(
                error is ChainedBoundedKeychainWork.TimedOut,
                "a non-answering store must time out — the caller's safe action (relatch, "
                    + "restart) is what a throw already triggers")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(began), 1.5,
            "the wait must be the bound, not the wedge")
    }

    /// A timed-out operation must be TOLD to stand down before it mutates. The caller has
    /// already moved on: a late settle would clear a marker the next lifecycle wrote, and a
    /// late surrender would restore a suppression the user just Reset — the states the
    /// single-record shape exists to make unrepresentable.
    func testATimedOutWorkIsToldToStandDownBeforeItWrites() {
        let hold = DispatchSemaphore(value: 0)
        let wanted = WantedProbe()

        XCTAssertThrowsError(
            try ChainedBoundedKeychainWork.perform(timeoutMilliseconds: 50) { isStillWanted in
                hold.wait()
                wanted.record(isStillWanted())
            })

        hold.signal()
        let deadline = Date().addingTimeInterval(2)
        while wanted.observed == nil, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(
            wanted.observed, false,
            "a timed-out operation was still told it was wanted — its write would land "
                + "after the caller moved on")
    }

    private final class WantedProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        func record(_ value: Bool) { lock.withLock { stored = value } }
        var observed: Bool? { lock.withLock { stored } }
    }
}
