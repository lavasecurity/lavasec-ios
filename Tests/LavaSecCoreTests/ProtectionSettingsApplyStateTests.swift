import XCTest
@testable import LavaSecKit

final class ProtectionSettingsApplyStateTests: XCTestCase {
    private let initialRestart = ProtectionExternalRestartGenerationSnapshot(value: nil)
    private let on = ProtectionRestoreIntentState(isEnabled: true)

    func testRapidChangesRestartTheQuietIntervalAndProduceOneApply() throws {
        var state = ProtectionSettingsApplyState()
        for index in 0..<100 {
            let time = Double(index) * 0.01
            state.recordChange(now: time, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: true)
            XCTAssertNil(state.beginIfReady(now: time + 0.009, intent: on, externalRestartGeneration: initialRestart, lifecycleIsAvailable: true))
        }
        XCTAssertNil(state.beginIfReady(now: 1.489, intent: on, externalRestartGeneration: initialRestart, lifecycleIsAvailable: true))
        let ticket = try XCTUnwrap(state.beginIfReady(now: 1.5, intent: on, externalRestartGeneration: initialRestart, lifecycleIsAvailable: true))
        XCTAssertNil(state.beginIfReady(now: 5, intent: on, externalRestartGeneration: initialRestart, lifecycleIsAvailable: true))
        state.finish(ticket)
        XCTAssertNil(state.pending)
        XCTAssertNil(state.applying)
    }

    func testChangesDuringRestartAreBufferedWithoutCancellingOrOverlappingIt() throws {
        var state = ProtectionSettingsApplyState()
        state.recordChange(now: 0, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: true)
        let first = try XCTUnwrap(state.beginIfReady(now: 0.5, intent: on, externalRestartGeneration: initialRestart, lifecycleIsAvailable: true))
        state.recordChange(now: 0.6, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: false)
        state.recordChange(now: 0.9, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: false)
        XCTAssertTrue(state.mayContinue(first, intent: on, externalRestartGeneration: initialRestart))
        XCTAssertNil(state.beginIfReady(now: 2, intent: on, externalRestartGeneration: initialRestart, lifecycleIsAvailable: true))
        state.finish(first)
        let second = try XCTUnwrap(state.beginIfReady(now: 2, intent: on, externalRestartGeneration: initialRestart, lifecycleIsAvailable: true))
        XCTAssertNotEqual(first, second)
        state.finish(first)
        XCTAssertEqual(state.applying, second, "Late completion cannot release a newer restart.")
        state.finish(second)
        XCTAssertNil(state.pending)
    }

    func testGuardOffDuringTheBufferCancelsRatherThanStartingIt() {
        var state = ProtectionSettingsApplyState()
        state.recordChange(now: 0, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: true)
        var off = on
        off.recordUserIntent(isEnabled: false)
        XCTAssertNil(state.beginIfReady(now: 1, intent: off, externalRestartGeneration: initialRestart, lifecycleIsAvailable: true))
        XCTAssertNil(state.pending)
        XCTAssertNil(state.deadline)
    }

    func testGuardOffInvalidatesInFlightRestartAndQueuedFollowUp() throws {
        var state = ProtectionSettingsApplyState()
        state.recordChange(now: 0, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: true)
        let ticket = try XCTUnwrap(state.beginIfReady(now: 0.5, intent: on, externalRestartGeneration: initialRestart, lifecycleIsAvailable: true))
        state.recordChange(now: 0.6, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: false)
        var off = on
        off.recordUserIntent(isEnabled: false)
        XCTAssertFalse(state.mayContinue(ticket, intent: off, externalRestartGeneration: initialRestart))
        state.discardSuperseded(intent: off, externalRestartGeneration: initialRestart)
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.applying, ticket, "The owner still must drain the real lifecycle operation.")
    }

    func testOffOnAndExplicitReconnectCannotReviveOldPendingWork() {
        for endsEnabled in [false, true] {
            var state = ProtectionSettingsApplyState()
            state.recordChange(now: 0, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: true)
            var newer = on
            newer.recordUserIntent(isEnabled: endsEnabled)
            XCTAssertNil(state.beginIfReady(now: 1, intent: newer, externalRestartGeneration: initialRestart, lifecycleIsAvailable: true))
            XCTAssertNil(state.pending)
        }
    }

    func testOffOrStoppedProtectionNeverSchedulesAnAutomaticStart() {
        var state = ProtectionSettingsApplyState()
        state.recordChange(now: 0, intent: .init(isEnabled: false), externalRestartGeneration: initialRestart, hasRunningProtection: true)
        XCTAssertNil(state.pending)
        state.recordChange(now: 1, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: false)
        XCTAssertNil(state.pending)
    }

    func testBusyLifecycleRetainsOnlyTheLatestSettledChange() throws {
        var state = ProtectionSettingsApplyState()
        state.recordChange(now: 0, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: true)
        XCTAssertNil(state.beginIfReady(now: 1, intent: on, externalRestartGeneration: initialRestart, lifecycleIsAvailable: false))
        state.recordChange(now: 1.2, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: true)
        XCTAssertNil(state.beginIfReady(now: 1.6, intent: on, externalRestartGeneration: initialRestart, lifecycleIsAvailable: true))
        XCTAssertNotNil(state.beginIfReady(now: 1.8, intent: on, externalRestartGeneration: initialRestart, lifecycleIsAvailable: true))
    }

    func testExternalRestartDuringBufferConsumesOlderSettings() {
        var state = ProtectionSettingsApplyState()
        state.recordChange(now: 0, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: true)
        let restarted = ProtectionExternalRestartGenerationSnapshot(value: "live-activity-restart")
        XCTAssertNil(state.beginIfReady(now: 1, intent: on, externalRestartGeneration: restarted, lifecycleIsAvailable: true))
        XCTAssertNil(state.pending)
        XCTAssertNil(state.deadline)
    }

    func testExternalRestartInvalidatesClaimedWorkButAllowsLaterSettings() throws {
        var state = ProtectionSettingsApplyState()
        state.recordChange(now: 0, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: true)
        let old = try XCTUnwrap(state.beginIfReady(now: 0.5, intent: on, externalRestartGeneration: initialRestart, lifecycleIsAvailable: true))
        state.recordChange(now: 0.6, intent: on, externalRestartGeneration: initialRestart, hasRunningProtection: true)
        let restarted = ProtectionExternalRestartGenerationSnapshot(value: "live-activity-restart")
        XCTAssertFalse(state.mayContinue(old, intent: on, externalRestartGeneration: restarted))
        state.discardSuperseded(intent: on, externalRestartGeneration: restarted)
        XCTAssertNil(state.pending)
        state.finish(old)
        state.recordChange(now: 2, intent: on, externalRestartGeneration: restarted, hasRunningProtection: true)
        let latest = try XCTUnwrap(state.beginIfReady(now: 2.5, intent: on, externalRestartGeneration: restarted, lifecycleIsAvailable: true))
        XCTAssertTrue(state.mayContinue(latest, intent: on, externalRestartGeneration: restarted))
    }

}
