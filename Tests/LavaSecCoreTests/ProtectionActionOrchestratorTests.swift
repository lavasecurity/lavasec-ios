import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

@MainActor
final class ProtectionActionOrchestratorTests: XCTestCase {
    func testClaimRejectsConcurrentActionsUntilReleased() {
        let orchestrator = ProtectionActionOrchestrator()

        XCTAssertTrue(orchestrator.claim(.turnOn))
        XCTAssertEqual(orchestrator.inFlightAction, .turnOn)
        XCTAssertFalse(orchestrator.claim(.turnOff), "A second action must be rejected while one is in flight.")
        XCTAssertFalse(orchestrator.claim(.turnOn), "Re-claiming the same kind is still a concurrent action.")

        orchestrator.release(.turnOn)
        XCTAssertNil(orchestrator.inFlightAction)
        XCTAssertTrue(orchestrator.claim(.turnOff))
    }

    func testMismatchedReleaseCannotEndAnotherActionsClaim() {
        let orchestrator = ProtectionActionOrchestrator()

        orchestrator.claim(.resume)
        orchestrator.release(.turnOff)

        XCTAssertEqual(
            orchestrator.inFlightAction,
            .resume,
            "A stale release from an abandoned flow must not end a newer action's claim."
        )
        orchestrator.release(.resume)
        XCTAssertNil(orchestrator.inFlightAction)
    }

    func testInFlightChangeMirrorsClaimAndRelease() {
        var observed: [ProtectionActionKind?] = []
        let orchestrator = ProtectionActionOrchestrator { observed.append($0) }

        orchestrator.claim(.reconnect)
        orchestrator.release(.reconnect)
        orchestrator.release(.reconnect)

        XCTAssertEqual(observed, [.reconnect, nil], "Idempotent releases must not re-notify.")
    }

    func testRunSkipsOperationWhileBusyAndReleasesAfterwards() async {
        let orchestrator = ProtectionActionOrchestrator()
        orchestrator.claim(.turnOn)

        var ran = false
        let started = await orchestrator.run(.resume) { ran = true }

        XCTAssertFalse(started)
        XCTAssertFalse(ran)
        XCTAssertEqual(orchestrator.inFlightAction, .turnOn)

        orchestrator.release(.turnOn)
        let secondStart = await orchestrator.run(.resume) { ran = true }
        XCTAssertTrue(secondStart)
        XCTAssertTrue(ran)
        XCTAssertNil(orchestrator.inFlightAction, "run must release its claim when the operation finishes.")
    }
}
