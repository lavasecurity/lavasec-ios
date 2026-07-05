import XCTest
@testable import LavaSecCore

final class ProtectionLifecyclePolicyTests: XCTestCase {
    func testEnabledStatusesMatchNetworkExtensionRunningStates() {
        XCTAssertTrue(ProtectionLifecyclePolicy.isProtectionEnabled(.connected))
        XCTAssertTrue(ProtectionLifecyclePolicy.isProtectionEnabled(.connecting))
        XCTAssertTrue(ProtectionLifecyclePolicy.isProtectionEnabled(.reasserting))

        XCTAssertFalse(ProtectionLifecyclePolicy.isProtectionEnabled(.invalid))
        XCTAssertFalse(ProtectionLifecyclePolicy.isProtectionEnabled(.disconnected))
        XCTAssertFalse(ProtectionLifecyclePolicy.isProtectionEnabled(.disconnecting))
    }

    func testStopPendingIncludesStatesThatCanStillEmitDisconnectTransitions() {
        XCTAssertTrue(ProtectionLifecyclePolicy.isStopPending(.connected))
        XCTAssertTrue(ProtectionLifecyclePolicy.isStopPending(.connecting))
        XCTAssertTrue(ProtectionLifecyclePolicy.isStopPending(.reasserting))
        XCTAssertTrue(ProtectionLifecyclePolicy.isStopPending(.disconnecting))

        XCTAssertFalse(ProtectionLifecyclePolicy.isStopPending(.invalid))
        XCTAssertFalse(ProtectionLifecyclePolicy.isStopPending(.disconnected))
    }

    func testPrimaryActionDisabledOnlyWhileConfiguring() {
        XCTAssertTrue(ProtectionLifecyclePolicy.shouldDisablePrimaryAction(status: .connected, isConfiguring: true))
        XCTAssertFalse(ProtectionLifecyclePolicy.shouldDisablePrimaryAction(status: .disconnecting, isConfiguring: false))
        XCTAssertFalse(ProtectionLifecyclePolicy.shouldDisablePrimaryAction(status: .connected, isConfiguring: false))
        XCTAssertFalse(ProtectionLifecyclePolicy.shouldDisablePrimaryAction(status: .disconnected, isConfiguring: false))
    }

    func testUptimeOnlyCountsActivelyProtectingStatuses() {
        XCTAssertTrue(ProtectionLifecyclePolicy.isUptimeActive(.connected))
        XCTAssertTrue(ProtectionLifecyclePolicy.isUptimeActive(.reasserting))

        XCTAssertFalse(ProtectionLifecyclePolicy.isUptimeActive(.connecting))
        XCTAssertFalse(ProtectionLifecyclePolicy.isUptimeActive(.disconnecting))
        XCTAssertFalse(ProtectionLifecyclePolicy.isUptimeActive(.disconnected))
        XCTAssertFalse(ProtectionLifecyclePolicy.isUptimeActive(.invalid))
    }

    func testAwaitingOnDemandReconnectOnlyWhenDisconnectedAndArmed() {
        // The elevator case: the tunnel dropped (.disconnected) but Connect-On-Demand is armed, so
        // iOS will reconnect once the network returns — surface it as reconnecting, not fully off.
        XCTAssertTrue(ProtectionLifecyclePolicy.isAwaitingOnDemandReconnect(
            status: .disconnected, onDemandConfirmedEnabled: true))

        // Not armed ⇒ a genuine off state (the user turned it off; on-demand was disabled first).
        XCTAssertFalse(ProtectionLifecyclePolicy.isAwaitingOnDemandReconnect(
            status: .disconnected, onDemandConfirmedEnabled: false))

        // Every non-disconnected status is either up, transitioning, or has no loaded profile — none
        // of them is an armed-but-down reconnect wait, regardless of the confirmed bit.
        for status in [ProtectionLifecycleStatus.invalid, .connecting, .connected, .reasserting, .disconnecting] {
            XCTAssertFalse(ProtectionLifecyclePolicy.isAwaitingOnDemandReconnect(
                status: status, onDemandConfirmedEnabled: true),
                "\(status) must never read as awaiting on-demand reconnect.")
        }
    }
}
