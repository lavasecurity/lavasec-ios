import XCTest
import LavaSecKit
import LavaSecPresentation

@MainActor
final class ProtectionActionPresentationTests: XCTestCase {
    func testStartAndStopKeepAcceptedTitleUntilMatchingRelease() {
        for (acceptedTitle, settledTitle) in [("Turn On", "Turn Off"), ("Turn Off", "Turn On"), ("Resume Now", "Turn Off"), ("Reconnect", "Turn Off")] {
            let harness = ActionPresentationHarness(currentTitle: acceptedTitle)
            XCTAssertTrue(harness.gate.claim(.toggle))
            harness.currentTitle = settledTitle
            XCTAssertEqual(harness.presentation.pendingTitle ?? harness.currentTitle, acceptedTitle)
            XCTAssertFalse(harness.gate.claim(.reconnect))
            harness.gate.release(.reconnect)
            XCTAssertEqual(harness.presentation.pendingTitle, acceptedTitle)
            harness.gate.release(.toggle)
            XCTAssertNil(harness.presentation.pendingTitle)
            XCTAssertEqual(harness.presentation.pendingTitle ?? harness.currentTitle, settledTitle)
        }
    }

    func testFailureReleaseClearsLabelAndNextAttemptCapturesFreshTitle() {
        enum Failure: Error { case refused }
        let harness = ActionPresentationHarness(currentTitle: "Turn On")
        do {
            XCTAssertTrue(harness.gate.claim(.turnOn))
            defer { harness.gate.release(.turnOn) }
            harness.currentTitle = "Reconnect"
            XCTAssertEqual(harness.presentation.pendingTitle, "Turn On")
            throw Failure.refused
        } catch {
            XCTAssertNil(harness.presentation.pendingTitle)
        }
        XCTAssertTrue(harness.gate.claim(.reconnect))
        XCTAssertEqual(harness.presentation.pendingTitle, "Reconnect")
        harness.gate.release(.reconnect)
        XCTAssertNil(harness.presentation.pendingTitle)
    }

    func testCancelledOperationReleasesPresentationWithItsGate() async {
        let harness = ActionPresentationHarness(currentTitle: "Turn On")
        let operation = Task { @MainActor in
            await harness.gate.run(.turnOn) {
                XCTAssertTrue(Task.isCancelled)
                harness.currentTitle = "Turn Off"
                XCTAssertEqual(harness.presentation.pendingTitle, "Turn On")
            }
        }
        operation.cancel()
        let started = await operation.value
        XCTAssertTrue(started)
        XCTAssertNil(harness.presentation.pendingTitle)
        XCTAssertFalse(harness.gate.isActionInFlight)
    }
}


@MainActor
private final class ActionPresentationHarness {
    var currentTitle: String
    var presentation = ProtectionActionPresentation()
    lazy var gate = ProtectionActionOrchestrator { [weak self] action in
        guard let self else { return }
        self.presentation.update(action: action, currentTitle: self.currentTitle)
    }

    init(currentTitle: String) {
        self.currentTitle = currentTitle
    }
}
