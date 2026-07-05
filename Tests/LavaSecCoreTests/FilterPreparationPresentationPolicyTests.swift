import XCTest
@testable import LavaSecCore

final class FilterPreparationPresentationPolicyTests: XCTestCase {
    func testPhasesAreStableCodableStates() {
        // User copy moved app-side (FilterPreparationPresentation); the core enum is a
        // stable Codable contract.
        XCTAssertEqual(FilterPreparationPhase.downloading.rawValue, "downloading")
        XCTAssertEqual(FilterPreparationPhase.compiling.rawValue, "compiling")
        XCTAssertEqual(FilterPreparationPhase.saving.rawValue, "saving")
    }

    func testDefaultMinimumDurationKeepsFastPhasesReadable() {
        let policy = FilterPreparationPresentationPolicy()

        XCTAssertEqual(policy.minimumPhaseDuration, 0.85, accuracy: 0.001)
    }

    func testChangingPhaseBeforeMinimumDisplayRequiresRemainingHold() {
        let policy = FilterPreparationPresentationPolicy(minimumPhaseDuration: 0.65)
        let startedAt = Date(timeIntervalSinceReferenceDate: 10)
        let now = Date(timeIntervalSinceReferenceDate: 10.2)

        let holdDuration = policy.holdDurationBeforePresenting(
            currentPhase: .downloading,
            phaseStartedAt: startedAt,
            nextPhase: .compiling,
            now: now
        )

        XCTAssertEqual(holdDuration, 0.45, accuracy: 0.001)
    }

    func testChangingPhaseAfterMinimumDisplayDoesNotHold() {
        let policy = FilterPreparationPresentationPolicy(minimumPhaseDuration: 0.65)
        let startedAt = Date(timeIntervalSinceReferenceDate: 10)
        let now = Date(timeIntervalSinceReferenceDate: 10.8)

        let holdDuration = policy.holdDurationBeforePresenting(
            currentPhase: .compiling,
            phaseStartedAt: startedAt,
            nextPhase: .saving,
            now: now
        )

        XCTAssertEqual(holdDuration, 0, accuracy: 0.001)
    }

    func testEqualStepsProgressGivesEachStepAnEqualQuarter() {
        typealias Policy = FilterPreparationPresentationPolicy

        // Four equal steps: the three phases plus the terminal Success step.
        XCTAssertEqual(Policy.stepCount, 4.0, accuracy: 0.001)

        // Each phase begins at its quarter boundary...
        XCTAssertEqual(Policy.equalStepsProgress(phase: .downloading, rawProgress: 0.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(Policy.equalStepsProgress(phase: .compiling, rawProgress: 0.42), 1.0 / 4, accuracy: 0.001)
        XCTAssertEqual(Policy.equalStepsProgress(phase: .saving, rawProgress: 0.86), 2.0 / 4, accuracy: 0.001)

        // ...and fills to the next boundary at the top of its raw range.
        XCTAssertEqual(Policy.equalStepsProgress(phase: .downloading, rawProgress: 0.42), 1.0 / 4, accuracy: 0.001)
        XCTAssertEqual(Policy.equalStepsProgress(phase: .compiling, rawProgress: 0.86), 2.0 / 4, accuracy: 0.001)

        // Saving now tops out at 3/4 — the terminal Success step (set by the caller as progress 1)
        // owns the final quarter 3/4 → 1, so the Success fill is a clean quarter, not a jump.
        XCTAssertEqual(Policy.equalStepsProgress(phase: .saving, rawProgress: 1.0), 3.0 / 4, accuracy: 0.001)

        // A mid-phase checkpoint stays inside that phase's own quarter.
        let downloadMid = Policy.equalStepsProgress(phase: .downloading, rawProgress: 0.2)
        XCTAssertGreaterThan(downloadMid, 0)
        XCTAssertLessThan(downloadMid, 1.0 / 4)

        // Out-of-range raw values clamp into the phase band.
        XCTAssertEqual(Policy.equalStepsProgress(phase: .compiling, rawProgress: 0.0), 1.0 / 4, accuracy: 0.001)
        XCTAssertEqual(Policy.equalStepsProgress(phase: .saving, rawProgress: 2.0), 3.0 / 4, accuracy: 0.001)
    }

    func testSamePhaseAndInitialPhaseDoNotHold() {
        let policy = FilterPreparationPresentationPolicy(minimumPhaseDuration: 0.65)
        let startedAt = Date(timeIntervalSinceReferenceDate: 10)
        let now = Date(timeIntervalSinceReferenceDate: 10.1)

        XCTAssertEqual(
            policy.holdDurationBeforePresenting(
                currentPhase: .downloading,
                phaseStartedAt: startedAt,
                nextPhase: .downloading,
                now: now
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            policy.holdDurationBeforePresenting(
                currentPhase: nil,
                phaseStartedAt: nil,
                nextPhase: .downloading,
                now: now
            ),
            0,
            accuracy: 0.001
        )
    }
}
