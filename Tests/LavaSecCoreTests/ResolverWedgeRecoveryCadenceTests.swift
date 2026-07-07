import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class ResolverWedgeRecoveryCadenceTests: XCTestCase {
    func testDefaultCadenceEscalatesFromTwoSecondsToThirtySecondCap() {
        let cadence = ResolverWedgeRecoveryCadence()
        XCTAssertEqual(cadence.delay(forAttempt: 0), 2)
        XCTAssertEqual(cadence.delay(forAttempt: 1), 4)
        XCTAssertEqual(cadence.delay(forAttempt: 2), 8)
        XCTAssertEqual(cadence.delay(forAttempt: 3), 16)
        // 2 * 2^4 = 32 -> capped at the legacy 30s ceiling.
        XCTAssertEqual(cadence.delay(forAttempt: 4), 30)
        XCTAssertEqual(cadence.delay(forAttempt: 5), 30)
        XCTAssertEqual(cadence.delay(forAttempt: 100), 30)
    }

    func testSteadyStateMatchesLegacyFlatInterval() {
        // Once escalated, the cadence is identical to the old flat 30s behaviour, so a sustained
        // wedge is no more aggressive than before.
        let cadence = ResolverWedgeRecoveryCadence()
        for attempt in 4...50 {
            XCTAssertEqual(cadence.delay(forAttempt: attempt), 30)
        }
    }

    func testNeverExceedsCapAndIsMonotonicNonDecreasing() {
        let cadence = ResolverWedgeRecoveryCadence()
        var previous = cadence.delay(forAttempt: 0)
        for attempt in 1...64 {
            let current = cadence.delay(forAttempt: attempt)
            XCTAssertGreaterThanOrEqual(current, previous, "cadence must never speed up as a wedge persists")
            XCTAssertLessThanOrEqual(current, 30, "cadence must never exceed the ceiling")
            previous = current
        }
    }

    func testNegativeAttemptIsTreatedAsFirstProbe() {
        let cadence = ResolverWedgeRecoveryCadence()
        XCTAssertEqual(cadence.delay(forAttempt: -1), 2)
        XCTAssertEqual(cadence.delay(forAttempt: -1000), 2)
    }

    func testCustomCadenceParameters() {
        let cadence = ResolverWedgeRecoveryCadence(firstInterval: 5, maxInterval: 30)
        XCTAssertEqual(cadence.delay(forAttempt: 0), 5)
        XCTAssertEqual(cadence.delay(forAttempt: 1), 10)
        XCTAssertEqual(cadence.delay(forAttempt: 2), 20)
        XCTAssertEqual(cadence.delay(forAttempt: 3), 30) // 40 capped
        XCTAssertEqual(cadence.delay(forAttempt: 4), 30)
    }

    func testInvertedConfigurationIsClampedSoFirstNeverExceedsCap() {
        // A misconfigured first > max must not defeat the cap: clamp first down to the ceiling so
        // the cadence degrades to the flat ceiling rather than running long.
        let cadence = ResolverWedgeRecoveryCadence(firstInterval: 50, maxInterval: 30)
        XCTAssertEqual(cadence.firstInterval, 30)
        XCTAssertEqual(cadence.delay(forAttempt: 0), 30)
        XCTAssertEqual(cadence.delay(forAttempt: 3), 30)
    }

    func testZeroCapDegradesToZeroWithoutCrashing() {
        let cadence = ResolverWedgeRecoveryCadence(firstInterval: 2, maxInterval: 0)
        XCTAssertEqual(cadence.delay(forAttempt: 0), 0)
        XCTAssertEqual(cadence.delay(forAttempt: 10), 0)
    }
}
