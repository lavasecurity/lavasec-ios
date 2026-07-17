import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Behavioral tests for the Guard long-press "charge" ramp curve. The ramp reveals the Lava
/// Guard picker after a `holdDuration` hold, with a haptic crescendo: the floor equals the
/// guardian tap, and strength climbs at a steady, frequent interval into the reveal. The UIKit
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

    func testScheduleWaitsForGraceThenStaysWithinTheHold() throws {
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
        // Pin the LAST pulse to exactly one interval before the reveal, so the crescendo fills the hold.
        // The `< holdDuration` loop above only catches an OVER-count; without this a silent UNDER-count
        // (e.g. FP rounding in a future holdDuration/pulseInterval tweak dropping pulseCount to 8) would
        // leave a pre-reveal gap yet still pass every assertion above (OCR review on lavasec-ios#69).
        let lastDelay = try XCTUnwrap(schedule.last?.delay)
        XCTAssertEqual(
            lastDelay,
            GuardianLongPressHaptics.holdDuration - GuardianLongPressHaptics.pulseInterval,
            accuracy: 1e-9,
            "the last pulse must land exactly one interval before the reveal so no silent gap precedes it"
        )
    }

    func testScheduleUsesUniformFrequentInterval() {
        // The cadence is CONSTANT (the tightest, most-frequent spacing) — the crescendo is carried
        // by rising strength, not by a changing rhythm — so every gap equals `pulseInterval`. This
        // is the deliberate replacement for the earlier accelerating (shrinking-gap) cadence.
        let delays = GuardianLongPressHaptics.schedule.map(\.delay)
        XCTAssertGreaterThan(delays.count, 1)
        for index in 1..<delays.count {
            XCTAssertEqual(
                delays[index] - delays[index - 1],
                GuardianLongPressHaptics.pulseInterval,
                accuracy: 1e-9,
                "pulses must fire at a constant, frequent interval — no accelerating/uneven cadence"
            )
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
        // Pin the terminal scheduled pulse (index pulseCount-1 → progress 1.0): the ramp actually
        // reaches .heavy before the reveal fires, so the crescendo is a continuation of the top
        // band, not a lone jump from a lower level. (OCR review on the 1.2.4 sync)
        XCTAssertEqual(GuardianLongPressHaptics.schedule.last?.step.level, .heavy)
    }

    // MARK: Continuous ("gradient") ramp — the primary Core-Haptics rendering (PR #404)

    func testContinuousRampOpensAtTheGentleFloor() {
        // The gradient opens gently, below the guardian tap: intensity (and sharpness) at progress 0
        // are the device-tuned floor (softened under `.light`), and nothing is quieter than that floor.
        XCTAssertEqual(
            GuardianLongPressHaptics.continuousIntensity(atProgress: 0),
            GuardianLongPressHaptics.continuousFloorIntensity,
            accuracy: 1e-6
        )
        XCTAssertEqual(
            GuardianLongPressHaptics.continuousSharpness(atProgress: 0),
            GuardianLongPressHaptics.continuousFloorSharpness,
            accuracy: 1e-6
        )
        // The floor is a real, positive feel strictly below the peak — a swell, not a flat buzz.
        XCTAssertGreaterThan(GuardianLongPressHaptics.continuousFloorIntensity, 0)
        XCTAssertLessThan(
            GuardianLongPressHaptics.continuousFloorIntensity,
            GuardianLongPressHaptics.continuousPeakIntensity
        )
    }

    func testContinuousRampSpansGraceToRevealFloorToPeak() throws {
        let ramp = GuardianLongPressHaptics.continuousRamp
        // Silent until the press is deliberate (mirrors the discrete grace period), then the swell
        // runs right up to the reveal: startDelay + duration lands exactly on holdDuration.
        XCTAssertEqual(ramp.startDelay, GuardianLongPressHaptics.gracePeriod)
        XCTAssertEqual(
            ramp.startDelay + ramp.duration,
            GuardianLongPressHaptics.holdDuration,
            accuracy: 1e-9
        )
        // Base parameters honor Core Haptics' control asymmetry so neither curve saturates: the
        // intensity control MULTIPLIES (full base 1.0), the sharpness control ADDS (zero base). A
        // non-zero sharpness base would clamp the whole 0.25…0.9 curve to max sharpness (Codex P2).
        XCTAssertEqual(ramp.baseIntensity, 1.0, accuracy: 1e-6)
        XCTAssertEqual(ramp.baseSharpness, 0.0, accuracy: 1e-6)

        // Each curve carries the configured number of control points, opens at the floor at
        // relativeTime 0, and closes at the peak at relativeTime == duration.
        XCTAssertEqual(ramp.intensityCurve.count, GuardianLongPressHaptics.continuousCurveSampleCount)
        XCTAssertEqual(ramp.sharpnessCurve.count, GuardianLongPressHaptics.continuousCurveSampleCount)

        let firstIntensity = try XCTUnwrap(ramp.intensityCurve.first)
        let lastIntensity = try XCTUnwrap(ramp.intensityCurve.last)
        XCTAssertEqual(firstIntensity.relativeTime, 0)
        XCTAssertEqual(firstIntensity.value, GuardianLongPressHaptics.continuousFloorIntensity, accuracy: 1e-6)
        XCTAssertEqual(lastIntensity.relativeTime, ramp.duration, accuracy: 1e-9)
        XCTAssertEqual(lastIntensity.value, GuardianLongPressHaptics.continuousPeakIntensity, accuracy: 1e-6)

        // Anchor the sharpness curve at BOTH ends too (symmetry with the intensity curve above): a
        // generator bug that dropped the sharpness FLOOR anchor would still pass the per-point range /
        // spacing loop below but is caught here (OCR review on lavasec-ios#69).
        let firstSharpness = try XCTUnwrap(ramp.sharpnessCurve.first)
        let lastSharpness = try XCTUnwrap(ramp.sharpnessCurve.last)
        XCTAssertEqual(firstSharpness.relativeTime, 0)
        XCTAssertEqual(firstSharpness.value, GuardianLongPressHaptics.continuousFloorSharpness, accuracy: 1e-6)
        XCTAssertEqual(lastSharpness.value, GuardianLongPressHaptics.continuousPeakSharpness, accuracy: 1e-6)

        // Every control point stays inside the event window and in the 0…1 CHHapticParameterCurve
        // range, at EVENLY SPACED times: pin the actual spacing (index/(count-1) × duration), not just
        // strict monotonicity — a regression to non-uniform sampling (e.g. pow(progress, 0.5)) would
        // still be strictly increasing and pass a monotonicity-only check while breaking the evenly
        // spaced sampling this asserts (OCR review on lavasec-ios#69).
        for curve in [ramp.intensityCurve, ramp.sharpnessCurve] {
            var previousTime = -1.0
            for (index, point) in curve.enumerated() {
                XCTAssertGreaterThanOrEqual(point.relativeTime, 0)
                XCTAssertLessThanOrEqual(point.relativeTime, ramp.duration)
                XCTAssertGreaterThan(point.relativeTime, previousTime)
                XCTAssertEqual(
                    point.relativeTime,
                    Double(index) / Double(curve.count - 1) * ramp.duration,
                    accuracy: 1e-9,
                    "control points must be evenly spaced across [0, duration]"
                )
                XCTAssertGreaterThanOrEqual(point.value, 0)
                XCTAssertLessThanOrEqual(point.value, 1)
                previousTime = point.relativeTime
            }
        }
    }

    func testContinuousRampIsMonotonicEaseIn() {
        // The swell only ever climbs and never dips below the floor — for BOTH scalars, which the
        // implementation says share the same ease-in shape (the `continuousSharpness` docstring), so a
        // regression in the sharpness scalar's shape is caught here too, not only intensity (OCR review
        // on lavasec-ios#69).
        for (valueAt, floor, peak) in [
            (GuardianLongPressHaptics.continuousIntensity, GuardianLongPressHaptics.continuousFloorIntensity, GuardianLongPressHaptics.continuousPeakIntensity),
            (GuardianLongPressHaptics.continuousSharpness, GuardianLongPressHaptics.continuousFloorSharpness, GuardianLongPressHaptics.continuousPeakSharpness)
        ] {
            var previous = valueAt(0)
            for tick in 0...100 {
                let value = valueAt(Double(tick) / 100.0)
                XCTAssertGreaterThanOrEqual(value, previous)
                XCTAssertGreaterThanOrEqual(value, floor)
                previous = value
            }
            // Ease-IN (漸強): at the midpoint the swell sits BELOW the linear halfway value, so it starts
            // slow and accelerates into the reveal rather than rising flat.
            let linearMidpoint = floor + (peak - floor) * 0.5
            XCTAssertLessThan(valueAt(0.5), linearMidpoint)
            // Clamped outside the unit range.
            XCTAssertEqual(valueAt(-1), floor, accuracy: 1e-6)
            XCTAssertEqual(valueAt(2), peak, accuracy: 1e-6)
        }
    }
}
