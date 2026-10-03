import XCTest

@testable import LavaSecChainedUpstream

/// The production clock. Small surface, and every property on it is load-bearing for the budget.
final class ChainedUptimeClockTests: XCTestCase {

    func testTheClockNeverGoesBackwardsAcrossManyReads() {
        // A backward reading is not a hypothetical the supervisor absorbs — it SURRENDERS on one,
        // because a time source that moves both ways cannot bound anything. So this conversion
        // must never manufacture one, and the flooring division is where it could: a
        // non-decreasing UInt64 floored is non-decreasing, and the wrapping subtraction is what
        // keeps that true rather than trapping.
        let clock = ChainedUptimeClock()
        var previous = clock.nowSeconds()
        for _ in 0..<20_000 {
            let current = clock.nowSeconds()
            XCTAssertGreaterThanOrEqual(current, previous, "the clock went backwards")
            previous = current
        }
    }

    func testTheClockStartsAtItsOwnOriginRatherThanTheDevicesUptime() {
        // Elapsed seconds are compared against a budget of ~15, so a clock reporting the device's
        // uptime would hand the supervisor a number in the millions on the first reading. That is
        // not merely untidy: `authorizeAttemptStartingNow` computes `now + remaining` and refuses
        // an overflow, so an enormous origin narrows the range the arithmetic stays valid in.
        let clock = ChainedUptimeClock()
        XCTAssertLessThan(clock.nowSeconds(), 5, "the clock is not zero-based at construction")
    }

    func testADeadlineRoundTripsTheSecondItWasAskedFor() {
        // The budget's whole guarantee is that the instant armed is the instant authorized. If
        // `deadline(atSeconds:)` read the clock again instead of using the stored origin, the
        // returned instant would drift by however long the caller took to get here.
        let clock = ChainedUptimeClock()
        let first = clock.deadline(atSeconds: 12)
        let second = clock.deadline(atSeconds: 12)
        XCTAssertEqual(
            first.uptimeNanoseconds, second.uptimeNanoseconds,
            "the same second produced two different instants")

        let later = clock.deadline(atSeconds: 13)
        XCTAssertEqual(
            later.uptimeNanoseconds &- first.uptimeNanoseconds, 1_000_000_000,
            "one second of the driver's clock is not one second of the dispatch clock")
    }

    func testANegativeSecondIsClampedRatherThanWrapped() {
        // `UInt64(negative)` traps, and a trap inside the Network Extension is a tunnel abort.
        // The value itself is nonsense either way; not crashing is the requirement.
        let clock = ChainedUptimeClock()
        XCTAssertEqual(
            clock.deadline(atSeconds: -5).uptimeNanoseconds,
            clock.deadline(atSeconds: 0).uptimeNanoseconds)
    }
}
