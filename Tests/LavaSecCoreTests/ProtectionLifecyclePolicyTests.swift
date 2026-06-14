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
}
