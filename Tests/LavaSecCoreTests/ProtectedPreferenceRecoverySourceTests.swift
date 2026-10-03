import XCTest
@testable import LavaSecCore

/// Platform wiring for the executable policy and native locked-storage regressions.
final class ProtectedPreferenceRecoverySourceTests: XCTestCase {
    func testLaunchUnlockAndForegroundUseTheSameRecovery() throws {
        let source = try readSource(.appViewModelCore)
        let launch = try sourceBlock(in: source, startingAt: "if !headless {\n            plus.startLavaSecurityPlusStore()",
                                     endingBefore: "if loadVPNState {")
        XCTAssertTrue(launch.contains("loadProtectedPreferencesIfAvailable()"))
        XCTAssertFalse(launch.contains("customization.loadCustomizationPreferences()"))
        let unlock = try sourceBlock(in: source, startingAt: "protectedDataAvailableObserver = NotificationCenter",
                                     endingBefore: "if loadVPNState {")
        let reload = try XCTUnwrap(unlock.range(of: "reloadSharedStateIfBlockedByDataProtection()")?.lowerBound)
        let preferences = try XCTUnwrap(unlock.range(of: "loadProtectedPreferencesIfAvailable()")?.lowerBound)
        XCTAssertLessThan(reload, preferences)
        let foreground = try sourceBlock(in: readSource(.appViewModelFocusAutoSwitch),
                                         startingAt: "func setAppForegroundActive(_ active: Bool)",
                                         endingBefore: "let defaults = LavaSecAppGroup.sharedDefaults")
        XCTAssertTrue(foreground.contains("loadProtectedPreferencesIfAvailable()"))
        let load = try sourceBlock(in: readSource(.appViewModelPersistence),
                                  startingAt: "func loadProtectedPreferencesIfAvailable()", endingBefore: "var canUseProtectedPreferences")
        XCTAssertTrue(load.contains("guard !isHeadless"))
        XCTAssertTrue(load.contains("protectedPreferenceRecovery.shouldLoad("))
        XCTAssertTrue(load.contains("sharedStateIsAvailable: !sharedStateUnavailableAtLoad"))
        XCTAssertTrue(load.contains("protectedDataIsAvailable: UIApplication.shared.isProtectedDataAvailable"))
        for call in ["customization.loadCustomizationPreferences()", "loadLavaGuardProgress()", "loadSudokuGameState()"] {
            let callIndex = try XCTUnwrap(load.range(of: call)?.lowerBound)
            let gateIndex = try XCTUnwrap(load.range(of: "protectedPreferenceRecovery.shouldLoad(")?.lowerBound)
            XCTAssertLessThan(gateIndex, callIndex)
        }
    }

    func testCustomizationLoadDefersBeforeAnyReadOrWrite() throws {
        let load = try sourceBlock(in: readSource(.customizationController),
                                  startingAt: "func loadCustomizationPreferences()", endingBefore: "func setNotificationCategoryEnabled(")
        let guardIndex = try XCTUnwrap(load.range(of: "guard UIApplication.shared.isProtectedDataAvailable")?.lowerBound)
        let readIndex = try XCTUnwrap(load.range(of: "appearancePreferences.refresh()")?.lowerBound)
        XCTAssertLessThan(guardIndex, readIndex)
    }

    func testUsageAndLiveActivityCannotConsumeProvisionalPreferences() throws {
        let source = try readSource(.appViewModelLavaGuardProgress)
        for signature in ["func synchronizeLavaGuardProgress(", "func refreshLavaGuardProgressFromDiagnostics()", "private func applyLavaGuardProgress("] {
            let start = try XCTUnwrap(source.range(of: signature)?.lowerBound)
            let tail = String(source[start...])
            XCTAssertTrue(tail.contains("guard canUseProtectedPreferences"))
            XCTAssertLessThan(try XCTUnwrap(tail.range(of: "guard canUseProtectedPreferences")?.lowerBound),
                              try XCTUnwrap(tail.range(of: "var nextProgress = lavaGuardProgress")?.lowerBound
                                ?? tail.range(of: "let progressChanged =")?.lowerBound))
        }
        let activity = try sourceBlock(in: readSource(.appViewModelLiveActivity),
                                      startingAt: "func reconcileLiveActivity()", endingBefore: "func handleTunnelHealthNudge()")
        XCTAssertTrue(activity.contains("guard canUseProtectedPreferences else { return }"))
        let task = try XCTUnwrap(activity.range(of: "Task {")?.lowerBound)
        XCTAssertTrue(activity[task...].contains("guard canUseProtectedPreferences else { return }"))
    }

    func testCIExecutesTheNativeProtectedPreferenceRegression() throws {
        XCTAssertTrue(try readSource(.iosWorkflow).contains(
            "ci/run-with-maintenance-lock.sh -- python3 Tests/NativeProtectedPreferenceRecoveryTests.py"))
    }
}
