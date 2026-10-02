import XCTest

@testable import LavaSecChainedUpstream

/// The bound between the engine queue and securityd: the watchdog's worst-case deferral
/// is the timeout, never the read.
final class ChainedBoundedCredentialReadTests: XCTestCase {
    private func credentials() -> ChainedSessionCredentials {
        ChainedSessionCredentials(
            privateKey: [UInt8](repeating: 7, count: 32),
            peerPublicKey: [UInt8](1...32),
            keepaliveSeconds: 25)
    }

    func testAFastReadPassesStraightThrough() throws {
        let value = credentials()
        let returned = try ChainedBoundedCredentialRead.perform { value }
        XCTAssertTrue(returned === value, "a healthy read must hand back the store's value")
        XCTAssertFalse(returned.hasBeenScrubbed)
    }

    func testAThrowingReadKeepsItsOwnError() {
        struct StoreDown: Error {}
        XCTAssertThrowsError(
            try ChainedBoundedCredentialRead.perform { throw StoreDown() }
        ) { error in
            XCTAssertTrue(
                error is StoreDown,
                "a read that answered with an error must keep that error — the transient "
                    + "mapping is the reader's job, not this bound's")
        }
    }

    /// A wedged securityd must cost the engine queue the BOUND, not the wedge: the
    /// attempt fails into the transient lane (one rung), and the watchdog whose deadline
    /// is the outage deadline fires at most the bound late.
    func testAWedgedReadTimesOutIntoTheTransientLane() {
        let hold = DispatchSemaphore(value: 0)
        defer { hold.signal() }
        let wedged = credentials()

        let began = Date()
        XCTAssertThrowsError(
            try ChainedBoundedCredentialRead.perform(timeoutMilliseconds: 50) {
                hold.wait()
                return wedged
            }
        ) { error in
            XCTAssertEqual(
                error as? ChainedSessionBuildFailure, .credentialsUnavailable,
                "a timed-out read must land in the transient lane — spending a rung, "
                    + "never surrendering the lifecycle for securityd's health")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(began), 1.5,
            "the wait must be the bound, not the wedge")
    }

    /// The late result of a timed-out read has no consumer: its key material is scrubbed
    /// rather than left to linger in a box nobody will drain.
    func testALateReadIsScrubbedAndDiscarded() {
        let hold = DispatchSemaphore(value: 0)
        let late = credentials()

        XCTAssertThrowsError(
            try ChainedBoundedCredentialRead.perform(timeoutMilliseconds: 50) {
                hold.wait()
                return late
            })

        hold.signal()
        // The reader thread scrubs after delivery is refused; give it a bounded moment.
        let deadline = Date().addingTimeInterval(2)
        while !late.hasBeenScrubbed, Date() < deadline {
            usleep(10_000)
        }
        XCTAssertTrue(
            late.hasBeenScrubbed,
            "a late read's key material must be scrubbed — its attempt already failed and "
                + "nothing will ever consume it")
    }
}
