import Foundation
import LavaSecCore
import XCTest

final class LiveActivityPauseConfirmationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)

    func testConfirmationAcceptsOnlyItsTokenInsideFiveSecondWindow() {
        let confirmation = LiveActivityPauseConfirmation(now: start, token: "rendered")
        XCTAssertTrue(confirmation.accepts(token: "rendered", now: start))
        XCTAssertTrue(confirmation.accepts(token: "rendered", now: start.addingTimeInterval(4.999)))
        XCTAssertFalse(confirmation.accepts(token: "rendered", now: start.addingTimeInterval(5)))
        XCTAssertFalse(confirmation.accepts(token: "rendered", now: start.addingTimeInterval(6)))
        XCTAssertFalse(confirmation.accepts(token: "old", now: start.addingTimeInterval(1)))
        XCTAssertFalse(confirmation.accepts(token: "rendered", now: start.addingTimeInterval(-1)))
    }

    func testCodingRetainsDeadlineWithoutExtendingIt() throws {
        let original = LiveActivityPauseConfirmation(now: start)
        let restored = try JSONDecoder().decode(
            LiveActivityPauseConfirmation.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(restored, original)
        XCTAssertFalse(restored.accepts(token: original.token, now: start.addingTimeInterval(5)))
    }

    func testGateRejectsReplayAndWrongActivityWithoutConsumingValidPermission() {
        var gate = LiveActivityPauseConfirmationGate()
        let first = gate.arm(activityID: "one", now: start)
        XCTAssertFalse(gate.consume(activityID: "two", token: first.token, now: start))
        XCTAssertTrue(gate.consume(activityID: "one", token: first.token, now: start))
        XCTAssertFalse(gate.consume(activityID: "one", token: first.token, now: start))
    }

    func testRearmRevokesOldButtonAndExpiredPermissionCannotBeConsumed() {
        var gate = LiveActivityPauseConfirmationGate()
        let first = gate.arm(activityID: "one", now: start)
        let second = gate.arm(activityID: "one", now: start.addingTimeInterval(1))
        XCTAssertFalse(gate.consume(activityID: "one", token: first.token, now: start.addingTimeInterval(2)))
        XCTAssertFalse(gate.consume(activityID: "one", token: second.token, now: start.addingTimeInterval(6)))
        var restarted = LiveActivityPauseConfirmationGate()
        XCTAssertFalse(restarted.consume(activityID: "one", token: second.token, now: start.addingTimeInterval(2)))
    }

    func testReconcileChecksActualActivityContent() throws {
        let source = try readSource(.lavaLiveActivityController)
        let reconcile = try sourceBlock(
            in: source,
            startingAt: "if let activity = adoptedActivity",
            endingBefore: "await activity.update(content)"
        )
        XCTAssertTrue(reconcile.contains("activity.content.state != state"))
        XCTAssertTrue(reconcile.contains("activity.content.staleDate != content.staleDate"))
    }

    func testIntentArmsWithoutPausingAndConsumesBeforeCommand() throws {
        let source = try readSource(.lavaLiveActivityIntents)
        let arm = try sourceBlock(in: source, startingAt: "func arm(activityID: String) async", endingBefore: "func confirm(")
        XCTAssertFalse(arm.contains("LavaProtectionCommandService.perform"))
        XCTAssertTrue(arm.contains("$0.id == activityID"))
        XCTAssertTrue(arm.contains("state.effectiveProtectionState(now: Date()) == .on"))
        XCTAssertTrue(arm.contains("ActivityContent(state: state, staleDate: nil)"))
        XCTAssertFalse(arm.contains("staleDate: confirmation.expiresAt"))
        let confirm = try XCTUnwrap(source.range(of: "func confirm(token:"))
        let block = String(source[confirm.lowerBound...])
        let consume = try XCTUnwrap(block.range(of: "confirmationGate.consume(activityID: activityID, token: token, now: Date())"))
        let command = try XCTUnwrap(block.range(of: "LavaProtectionCommandService.perform(.pauseConfigured)"))
        XCTAssertLessThan(consume.lowerBound, command.lowerBound)
        XCTAssertTrue(block.contains("activity.content.state.pauseConfirmation?.token == token"))
        XCTAssertTrue(block.contains("state.effectiveProtectionState(now: Date()) == .on"))
    }
    func testTheWindowConstantIsTheDeadlineTheConfirmationIsBuiltFrom() {
        // The app process schedules the revert against `window`; if it ever drifted from
        // the deadline the button would clear early or linger.
        let confirmation = LiveActivityPauseConfirmation(now: start, token: "rendered")
        XCTAssertEqual(confirmation.expiresAt, start.addingTimeInterval(LiveActivityPauseConfirmation.window))
        XCTAssertTrue(confirmation.accepts(token: "rendered", now: start.addingTimeInterval(LiveActivityPauseConfirmation.window - 0.001)))
        XCTAssertFalse(confirmation.accepts(token: "rendered", now: start.addingTimeInterval(LiveActivityPauseConfirmation.window)))
    }

    // The widget re-evaluates the deadline on every render it is GIVEN. What the pause
    // confirmation lacked was a guaranteed render once it expired: unlike paused and
    // restarting, it is published with `staleDate: nil`, so nothing scheduled one and
    // Confirm could sit there indefinitely. The app process supplies that revert
    // instead (PR #731). Best effort — see the coordinator rationale.
    func testArmingSchedulesTheRevertThatClearsTheRenderedConfirmation() throws {
        let source = try readSource(.lavaLiveActivityIntents)
        let arm = try sourceBlock(in: source, startingAt: "func arm(activityID: String) async", endingBefore: "func confirm(")
        XCTAssertTrue(arm.contains("scheduleExpiry(activityID: activity.id, token: confirmation.token)"))

        let schedule = try sourceBlock(in: source, startingAt: "private func scheduleExpiry(", endingBefore: "private func retireExpiry(")
        // Re-arming must retire the previous window, so an older one cannot clear a newer button.
        XCTAssertTrue(schedule.contains("expiry[activityID]?.task.cancel()"))
        // Relative sleep only: a wall-clock change must not strand the button on screen.
        XCTAssertTrue(schedule.contains("Task.sleep"))
        XCTAssertTrue(schedule.contains("LiveActivityPauseConfirmation.window"))
        XCTAssertTrue(schedule.contains("guard !Task.isCancelled else { return }"))
        XCTAssertTrue(schedule.contains("clearRenderedConfirmation(activityID: activityID, token: token)"))

        // A superseded window must not retire a newer window's handle: the actor suspends
        // across `activity.update`, so a re-arm can land between an old window's wake and
        // its cleanup. Retirement is therefore gated on the token that scheduled it.
        let retire = try sourceBlock(in: source, startingAt: "private func retireExpiry(", endingBefore: "private func clearRenderedConfirmation(")
        XCTAssertTrue(retire.contains("guard expiry[activityID]?.token == token else { return }"))

        let clear = String(source[try XCTUnwrap(source.range(of: "private func clearRenderedConfirmation(")).lowerBound...])
        XCTAssertTrue(clear.contains("retireExpiry(activityID: activityID, token: token)"))
        XCTAssertTrue(clear.contains("activity.content.state.pauseConfirmation?.token == token"))
        XCTAssertTrue(clear.contains("state.pauseConfirmation = nil"))
        // The confirmation expires; the activity's own staleness is not touched.
        XCTAssertTrue(clear.contains("ActivityContent(state: state, staleDate: nil)"))
    }

    func testALateTapRepairsTheRenderedControlWithoutPausing() throws {
        let source = try readSource(.lavaLiveActivityIntents)
        let confirm = try sourceBlock(in: source, startingAt: "func confirm(token: String, activityID: String) async throws", endingBefore: "private func scheduleExpiry(")
        // Pin the REJECTED BRANCH BODY, not an ordering. Hoisting the repair onto the
        // accepted path would keep "guard < repair < command" true while the late tap
        // stopped repairing anything — the exact regression this test is named for.
        let rejectedBranch = try sourceBlock(
            in: confirm,
            startingAt: "guard confirmationGate.consume(activityID: activityID, token: token, now: Date()) else {",
            endingBefore: "// The window is spent"
        )
        XCTAssertTrue(rejectedBranch.contains("clearRenderedConfirmation(activityID: activityID, token: token)"))
        XCTAssertTrue(rejectedBranch.contains("return"))
        // A late tap must never pause: the branch returns before the command service.
        XCTAssertFalse(rejectedBranch.contains("LavaProtectionCommandService.perform"))
        let repair = try XCTUnwrap(confirm.range(of: "clearRenderedConfirmation(activityID: activityID, token: token)"))
        let command = try XCTUnwrap(confirm.range(of: "LavaProtectionCommandService.perform(.pauseConfigured)"))
        XCTAssertLessThan(repair.lowerBound, command.lowerBound)
    }

}
