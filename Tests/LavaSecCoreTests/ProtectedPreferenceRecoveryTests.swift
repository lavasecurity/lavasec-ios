import XCTest
@testable import LavaSecCore

final class ProtectedPreferenceRecoveryTests: XCTestCase {
    func testLockedStartupCannotLoadOrWriteEvenWithReadableControlPlane() {
        let recovery = ProtectedPreferenceRecovery()
        XCTAssertFalse(recovery.shouldLoad(protectedDataIsAvailable: false, sharedStateIsAvailable: true))
        XCTAssertFalse(recovery.canUsePreferences(sharedStateIsAvailable: true))
    }

    func testUnlockWaitsForRealConfigurationBeforeLoadingOrWriting() {
        let recovery = ProtectedPreferenceRecovery()
        XCTAssertFalse(recovery.shouldLoad(protectedDataIsAvailable: true, sharedStateIsAvailable: false))
        XCTAssertFalse(recovery.canUsePreferences(sharedStateIsAvailable: true))
        XCTAssertTrue(recovery.shouldLoad(protectedDataIsAvailable: true, sharedStateIsAvailable: true))
    }

    func testRecoveryLoadsOnceAndDoesNotOverwriteLaterEditsOnForeground() {
        var recovery = ProtectedPreferenceRecovery()
        XCTAssertTrue(recovery.shouldLoad(protectedDataIsAvailable: true, sharedStateIsAvailable: true))
        recovery.didLoad()
        XCTAssertTrue(recovery.canUsePreferences(sharedStateIsAvailable: true))
        XCTAssertFalse(recovery.shouldLoad(protectedDataIsAvailable: true, sharedStateIsAvailable: true))
    }

    func testLaterScreenLockPreservesClassCAccessAndUnavailableConfigurationStillBlocksEffects() {
        var recovery = ProtectedPreferenceRecovery()
        recovery.didLoad()
        XCTAssertFalse(recovery.shouldLoad(protectedDataIsAvailable: false, sharedStateIsAvailable: true))
        XCTAssertTrue(recovery.canUsePreferences(sharedStateIsAvailable: true))
        XCTAssertFalse(recovery.canUsePreferences(sharedStateIsAvailable: false))
        XCTAssertTrue(recovery.hasLoaded)
        XCTAssertFalse(recovery.shouldLoad(protectedDataIsAvailable: true, sharedStateIsAvailable: true))
        XCTAssertTrue(recovery.canUsePreferences(sharedStateIsAvailable: true))
    }
}
