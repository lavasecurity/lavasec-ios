import XCTest

/// Rendering, motion and accessibility are exercised by the executable RN
/// onboarding suites. These pins cover native setup authority across that bridge.
final class OnboardingWiringSourceTests: XCTestCase {
    func testApplyingOnboardingDefaultsSeedsFiltersAndStartsMissingRuleSync() throws {
        let defaults = try sourceBlock(in: readAppViewModelSource(),
            startingAt: "func applyOnboardingRecommendedDefaults(",
            endingBefore: "func selectOnboardingBlocklists")
        XCTAssertTrue(defaults.contains("startOnboardingDefaultBlocklistSyncIfNeeded()"))
        XCTAssertTrue(defaults.contains("library = .seededDefaults(active: protectionLevel)"))
    }

    func testRootAndQAStartTheSameReactOnboardingVisit() throws {
        let root = try readSource(.rootView)
        let host = try readSource(.reactNativeAppHost)
        let qa = try readSource(.reactNativeAppQA)
        XCTAssertTrue(root.contains("if !completed { LavaAppBridge.shared.beginOnboarding(mock: false) }"))
        XCTAssertTrue(host.contains("bridge.beginOnboarding(mock: onboardingPreview, onDismiss:"))
        XCTAssertTrue(qa.contains("LavaAppHost(onboardingPreview: true)"))
        for source in [root, host, qa] { XCTAssertFalse(source.contains("LavaOnboardingView(")) }
    }

    func testVPNInstallStaysInstallOnlyWithoutAdvancingTheVisit() throws {
        let native = try readSource(.reactNativeAppOnboarding)
        let commands = try sourceBlock(in: native, startingAt: "case \"onboarding.vpn\", \"onboarding.notifications\":",
                                       endingBefore: "case \"onboarding.ready\":")
        XCTAssertTrue(commands.contains("await model.installLocalVPNProfileForOnboarding()"))
        XCTAssertTrue(commands.contains("visit.didInstallVPN = result"))
        XCTAssertFalse(commands.contains("visit.navigate("))
        let install = try sourceBlock(in: readAppViewModelSource(),
            startingAt: "func installLocalVPNProfileForOnboarding()",
            endingBefore: "func requestProtectionNotificationAuthorizationForOnboarding()")
        XCTAssertFalse(install.contains("enableProtection"))
        XCTAssertFalse(install.contains("startVPNTunnel"))
    }

    func testDNSSetupUsesTheAuthoritativeServiceAndRevalidatesItsVisit() throws {
        let native = try readSource(.reactNativeAppOnboarding)
        let navigate = try sourceBlock(in: native, startingAt: "func navigate(to page:", endingBefore: "func back()")
        XCTAssertTrue(navigate.contains("else { try await bridge.updateManagedDNSPatch(create: true) }"))
        XCTAssertTrue(navigate.contains("guard bridge.onboardingVisit === self, bridge.security.viewAuthenticationRevision == authorization,"))
        XCTAssertTrue(navigate.contains("bridge.canReadPresentation(.appUnlock), !Task.isCancelled"))
        XCTAssertTrue(navigate.contains("state.canNavigate(to: page, vpnInstalled: vpnInstalled"))
        XCTAssertTrue(navigate.contains("nextState.move(to: page, vpnInstalled: vpnInstalled"))
        XCTAssertFalse(navigate.contains("configuration.dnsPatchEnabled ="))
    }

    func testMockOnboardingCannotPersistOrInvokeSetupServices() throws {
        let native = try readSource(.reactNativeAppOnboarding)
        let choices = try sourceBlock(in: native, startingAt: "private func applyCurrentChoice(", endingBefore: "func navigate(to page:")
        XCTAssertTrue(choices.contains("guard !mock else { return }"))
        XCTAssertTrue(native.contains("if mock { try await Task.sleep(for: .milliseconds(500)) }\n                else { try await bridge.updateManagedDNSPatch(create: true) }"))
        XCTAssertTrue(native.contains("if !mock && page == .done { bridge.model.applyOnboardingRecommendedDefaults"))
        XCTAssertTrue(native.contains("let result = visit.mock ? true : action == \"onboarding.vpn\" ? await model.installLocalVPNProfileForOnboarding() : await model.requestProtectionNotificationAuthorizationForOnboarding()"))
        XCTAssertTrue(native.contains("if !visit.mock { UserDefaults.standard.set(true, forKey: \"hasSeenLavaOnboarding\") }"))
    }
}
