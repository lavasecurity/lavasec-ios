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
