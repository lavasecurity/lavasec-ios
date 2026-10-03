import XCTest

final class AppPrivacyShieldSourceTests: XCTestCase {
    func testAppEvaluatesLivePrivacyPolicyBeforeBothInactiveSnapshots() throws {
        let appSource = try readSource(.lavaSecApp)

        XCTAssertTrue(appSource.contains("private let privacyShield = LavaPrivacyShield()"))
        XCTAssertTrue(appSource.contains("func applicationWillResignActive"))
        XCTAssertTrue(appSource.contains("func applicationDidEnterBackground"))
        for (start, end) in [("func applicationWillResignActive", "func applicationDidEnterBackground"),
                             ("func applicationDidEnterBackground", "private func updatePrivacyShield")] {
            let callback = try sourceBlock(in: appSource, startingAt: start, endingBefore: end)
            XCTAssertTrue(callback.contains("updatePrivacyShield(in: application)"))
            XCTAssertFalse(callback.contains("privacyShield.show(in: application)"))
        }
        let update = try sourceBlock(in: appSource, startingAt: "private func updatePrivacyShield", endingBefore: "func applicationProtectedDataWillBecomeUnavailable")
        XCTAssertTrue(update.contains("LavaProtectionShortcutRuntime.shared.security.backgroundPrivacyCoverRequired"))
        XCTAssertTrue(update.contains("privacyShield.show(in: application)"))
        XCTAssertTrue(update.contains("privacyShield.hide(from: application)"))
        XCTAssertFalse(update.contains("refreshAuthenticationAvailability"))
    }

    func testPrivacyShieldSettlesCurrentUIBeforeSnapshot() throws {
        let appSource = try readSource(.lavaSecApp)

        XCTAssertTrue(appSource.contains("application.sendAction(#selector(UIResponder.resignFirstResponder)"))
        XCTAssertTrue(appSource.contains("window.layoutIfNeeded()"))
    }

    func testAppRemovesPrivacyShieldWhenActiveAgain() throws {
        let appSource = try readSource(.lavaSecApp)

        XCTAssertTrue(appSource.contains("func applicationDidBecomeActive"))
        XCTAssertTrue(appSource.contains("privacyShield.hide(from: application)"))
        let active = try sourceBlock(in: appSource, startingAt: "func applicationDidBecomeActive", endingBefore: "func userNotificationCenter")
        XCTAssertTrue(active.contains("updateActivePrivacyShield(in: application)"))
        let recovery = try sourceBlock(in: appSource, startingAt: "private func updateActivePrivacyShield", endingBefore: "func applicationWillTerminate")
        XCTAssertTrue(recovery.contains("security.protectedDataIsAvailableForPresentation || !security.backgroundPrivacyCoverRequired"))
        XCTAssertTrue(recovery.contains("privacyShield.show(in: application)"))
        XCTAssertTrue(recovery.contains("privacyShield.hide(from: application)"))
    }

    func testPrivacyShieldCoversWindowsWithBlurredMaterial() throws {
        let appSource = try readSource(.lavaSecApp)

        XCTAssertTrue(appSource.contains("final class LavaPrivacyShield"))
        XCTAssertTrue(appSource.contains("UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))"))
        XCTAssertTrue(appSource.contains("overlay.frame = window.bounds"))
        XCTAssertTrue(appSource.contains("window.addSubview(overlay)"))
    }

    func testControllerAndBothSnapshotFormsUseTheSharedCoverPolicy() throws {
        let controller = try readSource(.securityController)
        let policy = try sourceBlock(in: controller, startingAt: "var backgroundPrivacyCoverRequired: Bool", endingBefore: "private var faceIDUsageDescriptionIsPresent")
        XCTAssertTrue(policy.contains("SecurityPrivacyPolicy.requiresBackgroundCover("))
        XCTAssertTrue(policy.contains("isAuthenticationUnavailable ? .unavailable"))
        XCTAssertTrue(policy.contains("gatesAreAvailable: !didFailGatePublication"))
        XCTAssertTrue(policy.contains("protectedDataIsAvailable: protectedDataIsAvailableForPresentation"))
        XCTAssertTrue(controller.contains("!protectedDataPrivacyBoundaryActive && UIApplication.shared.isProtectedDataAvailable"))
        XCTAssertTrue(controller.contains("guard protectedDataIsAvailableForPresentation else { return false }"))
        XCTAssertTrue(controller.contains("@Published private var protectedDataPrivacyBoundaryActive"))

        let bridge = try readSource(.reactNativeAppBridge)
        let snapshot = try sourceBlock(in: bridge, startingAt: "@objc func snapshot()", endingBefore: "@objc func command(")
        XCTAssertTrue(snapshot.contains("guard canReadPresentation(.appUnlock) else"))
        XCTAssertEqual(snapshot.components(separatedBy: "\"backgroundPrivacyCoverRequired\": security.backgroundPrivacyCoverRequired").count - 1, 2)
    }

    func testProtectedDataLossRevokesAccessAndUsesTheSharedConcealmentChoiceBeforeTheBitChanges() throws {
        let app = try readSource(.lavaSecApp)
        let loss = try sourceBlock(in: app, startingAt: "func applicationProtectedDataWillBecomeUnavailable", endingBefore: "func applicationProtectedDataDidBecomeAvailable")
        XCTAssertTrue(loss.contains("updatePrivacyShield(in: application)"))
        XCTAssertFalse(loss.contains("privacyShield.show(in: application)"))
        XCTAssertTrue(loss.contains("security.protectedDataWillBecomeUnavailable()"))
        let bridge = try readSource(.reactNativeAppBridge)
        let boundary = try sourceBlock(in: bridge, startingAt: "private func publishPrivacyBoundary()", endingBefore: "@objc func observe(")
        XCTAssertTrue(boundary.contains("\"presentationBlocked\": true"))
        XCTAssertTrue(boundary.contains("\"backgroundPrivacyCoverRequired\": security.backgroundPrivacyCoverRequired"))
        XCTAssertFalse(boundary.contains("\"backgroundPrivacyCoverRequired\": true"))
        XCTAssertFalse(boundary.contains("snapshot()"))
        XCTAssertTrue(bridge.contains("self?.publishPrivacyBoundary()"))
        XCTAssertTrue(bridge.contains("self?.security.protectedDataWillBecomeUnavailable()"))
        XCTAssertTrue(bridge.contains("self?.security.protectedDataDidBecomeAvailable()"))
    }

    func testRetainedNativeFlowsPauseInputUntilProtectedDataRecovers() throws {
        let flows = try readSource(.reactNativeAppFlows)
        XCTAssertTrue(flows.contains(".allowsHitTesting(security.protectedDataIsAvailableForPresentation)"))
        XCTAssertTrue(flows.contains(".accessibilityHidden(!security.protectedDataIsAvailableForPresentation)"))
    }
}
