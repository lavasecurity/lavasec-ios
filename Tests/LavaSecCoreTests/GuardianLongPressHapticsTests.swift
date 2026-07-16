import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Behavioral tests for the Guard long-press "charge" ramp curve. The ramp reveals the Lava
/// Guard picker after a `holdDuration` hold, with haptics that "balloon up": the floor equals
/// the guardian tap, strength climbs, and the pulses accelerate into the reveal. The UIKit
/// playback (mapping a level to a feedback generator) is thin app-side orchestration; this pins
/// the curve itself, which is pure.
final class GuardianLongPressHapticsTests: XCTestCase {

    func testFloorMatchesGuardianTap() {
        // "Lowest is the same as the current Guard tap": the first/weakest pulse is a light impact
        // at full intensity — identical to `.guardianTapAcknowledged` (a `.light` generator's
        // `impactOccurred()`), so the ramp opens on feedback the user already knows.
        let floor = GuardianLongPressHaptics.step(forProgress: 0)
        XCTAssertEqual(floor.level, .light)
        XCTAssertEqual(floor.intensity, 1.0)
    }

    func testLevelEscalatesLightToHeavyAcrossTheHold() {
        XCTAssertEqual(GuardianLongPressHaptics.step(forProgress: 0.0).level, .light)
        XCTAssertEqual(GuardianLongPressHaptics.step(forProgress: 0.2).level, .light)
        XCTAssertEqual(GuardianLongPressHaptics.step(forProgress: 0.5).level, .medium)
        XCTAssertEqual(GuardianLongPressHaptics.step(forProgress: 0.9).level, .heavy)
        XCTAssertEqual(GuardianLongPressHaptics.step(forProgress: 1.0).level, .heavy)
    }

    func testLevelIsMonotonicAndNeverDipsBelowTheFloor() {
        // No pulse is ever weaker than the one before it (level non-decreasing) and none is
        // quieter than the floor (intensity pinned at full) — the escalation only ever climbs.
        // Absolute end-point anchors so a constant-level regression can't pass vacuously:
        // seeding previousLevel from the function under test only proves non-decrease, not
        // that the ramp actually spans light→heavy. (OCR review on the 1.2.4 sync)
        XCTAssertEqual(GuardianLongPressHaptics.step(forProgress: 0).level, .light)
        XCTAssertEqual(GuardianLongPressHaptics.step(forProgress: 1).level, .heavy)
        var previousLevel = GuardianLongPressHaptics.step(forProgress: 0).level
        for tick in 0...100 {
            let step = GuardianLongPressHaptics.step(forProgress: Double(tick) / 100.0)
            XCTAssertGreaterThanOrEqual(step.level, previousLevel)
            XCTAssertEqual(step.intensity, 1.0)
            previousLevel = step.level
        }
    }

    func testProgressIsClampedOutsideUnitRange() {
        XCTAssertEqual(GuardianLongPressHaptics.step(forProgress: -5).level, .light)
        XCTAssertEqual(GuardianLongPressHaptics.step(forProgress: 5).level, .heavy)
    }

    func testScheduleWaitsForGraceThenStaysWithinTheHold() {
        let schedule = GuardianLongPressHaptics.schedule
        XCTAssertEqual(schedule.count, GuardianLongPressHaptics.pulseCount)
        // The grace period keeps the hold quiet until it is clearly a press, not a tap: no pulse
        // fires before `gracePeriod`, and the first one lands exactly there — still on the tap
        // floor (a light impact), just delayed past the tap window so taps/aborted presses stay
        // silent.
        XCTAssertGreaterThan(GuardianLongPressHaptics.gracePeriod, 0)
        XCTAssertLessThan(GuardianLongPressHaptics.gracePeriod, GuardianLongPressHaptics.holdDuration)
        XCTAssertEqual(schedule.first?.delay, GuardianLongPressHaptics.gracePeriod)
        XCTAssertEqual(schedule.first?.step.level, .light)
        // Every pulse lands in [gracePeriod, holdDuration) — the crescendo owns the reveal.
        for pulse in schedule {
            XCTAssertGreaterThanOrEqual(pulse.delay, GuardianLongPressHaptics.gracePeriod)
            XCTAssertLessThan(pulse.delay, GuardianLongPressHaptics.holdDuration)
        }
    }

    func testScheduleAcceleratesTowardTheReveal() {
        // "Balloon up": delays increase (pulses ordered in time) but the GAP between successive
        // pulses shrinks, so they crowd together into the reveal instead of pacing evenly.
        let delays = GuardianLongPressHaptics.schedule.map(\.delay)
        var previousGap = Double.greatestFiniteMagnitude
        for index in 1..<delays.count {
            let gap = delays[index] - delays[index - 1]
            XCTAssertGreaterThan(gap, 0, "pulses must be strictly ordered in time")
            // Strict decrease, not <= with a tolerance: delay grows as pow(progress,
            // cadenceExponent) with cadenceExponent < 1 (concave), so every successive gap is
            // strictly smaller — a constant/even cadence is a regression the old +1e-9
            // tolerance would have allowed. (OCR review on the 1.2.4 sync)
            XCTAssertLessThan(gap, previousGap, "cadence must strictly accelerate, not merely hold")
            previousGap = gap
        }
    }

    func testRevealCrescendoIsTheStrongestPulse() {
        XCTAssertEqual(GuardianLongPressHaptics.revealStep.level, .heavy)
        XCTAssertEqual(GuardianLongPressHaptics.revealStep.intensity, 1.0)
        // .heavy is independently the ceiling of the level enum, so the "every pulse <=
        // revealStep.level" check below is a real maximum, not a level that merely happens to
        // be the largest one the ramp reaches. (OCR review on the 1.2.4 sync)
        XCTAssertEqual(GuardianLongPressHapticLevel.allCases.max(), .heavy)
        // Nothing during the hold exceeds the crescendo.
        for pulse in GuardianLongPressHaptics.schedule {
            XCTAssertLessThanOrEqual(pulse.step.level, GuardianLongPressHaptics.revealStep.level)
        }
        // Pin the terminal scheduled pulse (index pulseCount-1 → progress 9/10 = 0.9 ≥ 2/3):
        // the ramp actually reaches .heavy before the reveal fires, so the crescendo is a
        // continuation of the top band, not a lone jump from a lower level. (OCR review on the 1.2.4 sync)
        XCTAssertEqual(GuardianLongPressHaptics.schedule.last?.step.level, .heavy)
    }
}
