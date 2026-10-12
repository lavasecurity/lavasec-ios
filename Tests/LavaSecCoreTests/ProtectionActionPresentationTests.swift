import XCTest
import LavaSecKit
import LavaSecPresentation

@MainActor
final class ProtectionActionPresentationTests: XCTestCase {
    func testAcceptedStartImmediatelyLeavesOffAndNeverOverridesObservedOutcomes() {
        for action in [ProtectionActionKind.turnOn, .toggle] {
            var presentation = ProtectionActionPresentation()
            presentation.update(action: action, currentTitle: "Turn On", currentStatus: .off)
            XCTAssertEqual(presentation.status(whileObserving: .off), .turningOn)
            for status: ProtectionStatus in [.unavailable, .chainingFailed, .connected(.networkUnavailable),
                .vpnRecovering, .turningOff, .connected(.healthy)] {
                XCTAssertEqual(presentation.status(whileObserving: status), status)
            }
            presentation.update(action: nil, currentTitle: "Turn On")
            XCTAssertEqual(presentation.status(whileObserving: .off), .off)
        }
    }

    func testStopAndUnrelatedActionsCannotClaimStarting() {
        for action in ProtectionActionKind.allCases where action != .turnOn && action != .toggle {
            var presentation = ProtectionActionPresentation()
            presentation.update(action: action, currentTitle: "Turn On", currentStatus: .off)
            XCTAssertEqual(presentation.status(whileObserving: .off), .off)
        }
        var stop = ProtectionActionPresentation()
        stop.update(action: .toggle, currentTitle: "Turn Off", currentStatus: .connected(.healthy))
        XCTAssertEqual(stop.status(whileObserving: .off), .off)
    }

    func testDisconnectAfterIOSBeginsStartupCannotRevivePreparation() {
        var presentation = ProtectionActionPresentation()
        presentation.update(action: .turnOn, currentTitle: "Turn On", currentStatus: .off)
        presentation.observe(lifecycle: .disconnected)
        XCTAssertEqual(presentation.status(whileObserving: .off), .turningOn)
        presentation.observe(lifecycle: .connecting)
        presentation.observe(lifecycle: .disconnected)
        XCTAssertEqual(presentation.status(whileObserving: .off), .off)
        XCTAssertEqual(presentation.pendingTitle, "Turn On", "failure cannot rename the accepted operation")
    }

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
