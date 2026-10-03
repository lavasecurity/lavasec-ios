import XCTest
@testable import LavaSecCore
@testable import LavaSecAppServices
@testable import LavaSecKit

final class OnboardingAnimationTests: XCTestCase {
    func testGuardTravelMovesOnFirstFrameAndSlowsAtArrival() {
        XCTAssertEqual(OnboardingGuardTravel.progress(at: 0), 0)
        XCTAssertEqual(OnboardingGuardTravel.progress(at: OnboardingGuardTravel.duration), 1)
        XCTAssertEqual(OnboardingGuardTravel.progress(at: 3), 1)
        let early = OnboardingGuardTravel.progress(at: OnboardingGuardTravel.duration * 0.25)
        let late = 1 - OnboardingGuardTravel.progress(at: OnboardingGuardTravel.duration * 0.75)
        XCTAssertGreaterThan(early, 0)
        XCTAssertLessThan(early, 1)
        XCTAssertGreaterThan(early, late)
    }

    func testFeatureTransitionStartsFromGuardIntroGeometryWithRowsHidden() {
        let state = OnboardingFeatureTransitionPlan.state(at: 0)

        XCTAssertEqual(state.heroTopSpacer, 36, accuracy: 0.001)
        XCTAssertEqual(state.heroHeight, 280, accuracy: 0.001)
        XCTAssertEqual(state.heroPanelOffsetY, 0, accuracy: 0.001)
        XCTAssertEqual(state.descriptionOpacity, 1, accuracy: 0.001)
        XCTAssertEqual(state.featureRowsOpacity, 0, accuracy: 0.001)
        XCTAssertFalse(state.featureRowsOccupyLayout)
    }

    func testHeroPanelMovesAsOneStableUnit() {
        let start = OnboardingFeatureTransitionPlan.state(at: 0)
        let middle = OnboardingFeatureTransitionPlan.state(
            at: OnboardingFeatureTransitionPlan.heroMoveDuration / 2
        )
        let end = OnboardingFeatureTransitionPlan.state(
            at: OnboardingFeatureTransitionPlan.heroMoveDuration
        )

        XCTAssertEqual(start.heroTopSpacer, middle.heroTopSpacer, accuracy: 0.001)
        XCTAssertEqual(middle.heroTopSpacer, end.heroTopSpacer, accuracy: 0.001)
        XCTAssertEqual(start.heroHeight, middle.heroHeight, accuracy: 0.001)
        XCTAssertEqual(middle.heroHeight, end.heroHeight, accuracy: 0.001)
        XCTAssertEqual(start.heroPanelOffsetY, OnboardingFeatureTransitionPlan.initialHeroPanelOffsetY, accuracy: 0.001)
        XCTAssertLessThan(middle.heroPanelOffsetY, start.heroPanelOffsetY)
        XCTAssertEqual(
            end.heroPanelOffsetY,
            OnboardingFeatureTransitionPlan.finalHeroPanelOffsetY,
            accuracy: 0.001
        )
    }

    func testFeatureRowsStayHiddenUntilHeroMoveCompletes() {
        let state = OnboardingFeatureTransitionPlan.state(
            at: OnboardingFeatureTransitionPlan.heroMoveDuration - 0.01
        )

        XCTAssertLessThan(state.descriptionOpacity, 1)
        XCTAssertGreaterThan(state.descriptionOpacity, 0)
        XCTAssertEqual(state.featureRowsOpacity, 0, accuracy: 0.001)
        XCTAssertFalse(state.featureRowsOccupyLayout)
    }

    func testFeatureRowsFadeInOnlyAfterHeroIsInPlace() {
        let start = OnboardingFeatureTransitionPlan.state(
            at: OnboardingFeatureTransitionPlan.heroMoveDuration
        )
        let middle = OnboardingFeatureTransitionPlan.state(
            at: OnboardingFeatureTransitionPlan.heroMoveDuration
                + OnboardingFeatureTransitionPlan.featureFadeDuration / 2
        )
        let end = OnboardingFeatureTransitionPlan.state(
            at: OnboardingFeatureTransitionPlan.totalDuration
        )

        XCTAssertEqual(start.heroPanelOffsetY, OnboardingFeatureTransitionPlan.finalHeroPanelOffsetY, accuracy: 0.001)
        XCTAssertEqual(start.descriptionOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(start.featureRowsOpacity, 0, accuracy: 0.001)
        XCTAssertTrue(start.featureRowsOccupyLayout)
        XCTAssertEqual(start.featureRowsTopOffset, 250, accuracy: 0.001)

        XCTAssertGreaterThan(middle.featureRowsOpacity, 0)
        XCTAssertLessThan(middle.featureRowsOpacity, 1)
        XCTAssertTrue(middle.featureRowsOccupyLayout)

        XCTAssertEqual(end.featureRowsOpacity, 1, accuracy: 0.001)
        XCTAssertEqual(end.featureRowsOffsetY, 0, accuracy: 0.001)
    }

    func testFeatureRowsStartHighEnoughToAvoidFooterCrowding() {
        let end = OnboardingFeatureTransitionPlan.state(
            at: OnboardingFeatureTransitionPlan.totalDuration
        )

        XCTAssertGreaterThanOrEqual(end.featureRowsTopOffset, 240)
        XCTAssertLessThanOrEqual(end.featureRowsTopOffset, 270)
    }

    func testFeatureRowsSitCloserToHeroTitleOnFinalFeaturePage() {
        let end = OnboardingFeatureTransitionPlan.state(
            at: OnboardingFeatureTransitionPlan.totalDuration
        )

        XCTAssertEqual(end.featureRowsTopOffset, 250, accuracy: 0.001)
    }

    func testLavaWavePhaseIsVisibleImmediatelyAndLoopsCleanly() {
        XCTAssertEqual(OnboardingLavaWaveTimeline.phase(at: 0), 0, accuracy: 0.001)
        XCTAssertEqual(
            OnboardingLavaWaveTimeline.phase(at: OnboardingLavaWaveTimeline.duration),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            OnboardingLavaWaveTimeline.phase(at: OnboardingLavaWaveTimeline.duration * 2),
            0,
            accuracy: 0.001
        )
    }

    func testApplyingOnboardingDefaultsStartsBlocklistSyncWhenRulesAreMissing() throws {
        let appViewModelSource = try readAppViewModelSource()
        let defaultsBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "func applyOnboardingRecommendedDefaults(",
            endingBefore: "func selectOnboardingBlocklists"
        )

        XCTAssertTrue(defaultsBlock.contains("startOnboardingDefaultBlocklistSyncIfNeeded()"))
        XCTAssertTrue(defaultsBlock.contains("library = .seededDefaults(active: protectionLevel)"),
                      "Finishing onboarding seeds the three default filters with the chosen level active.")
    }

    func testSharedMascotStaysOutsideScrollingPagesAndKeepsSleepColor() throws {
        let source = try readSource(.onboardingFlowView)
        let mascot = try XCTUnwrap(source.range(of: "SoftShieldGuardian(size: LavaGuardMetrics.mascotSize"))
        let scroll = try XCTUnwrap(source.range(of: "ScrollView {"))
        XCTAssertLessThan(mascot.lowerBound, scroll.lowerBound)
        XCTAssertEqual(source.components(separatedBy: "SoftShieldGuardian(").count - 1, 1)
        XCTAssertTrue(source.contains(".frame(height: 128)"))
        XCTAssertTrue(source.contains("keepsColorWhenSleeping: !opening"))
        XCTAssertTrue(source.contains("if page == .vpn && (!vpnInstalled || isInstallingVPN) { return .sleeping }"))
        XCTAssertTrue(source.contains("animates: true"))
    }

    func testLavaUsesClockDrivenCanvasAndDrainsDuringReveal() throws {
        let source = try readSource(.onboardingFlowView)
        XCTAssertTrue(source.contains("TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive))"))
        XCTAssertTrue(source.contains("Canvas { context, size in"))
        XCTAssertTrue(source.contains("page == .lava || reduceMotion ? 0 : proxy.size.height * 1.1"))
        XCTAssertTrue(source.contains("reduceMotion ? .easeInOut(duration: 0.25) : .easeInOut(duration: 1.1)"))
        XCTAssertTrue(source.contains(".opacity(reduceMotion && page != .lava ? 0 : 1)"),
                      "Only the reduced-motion curtain fades; normal motion stays opaque.")
        XCTAssertTrue(source.contains("context.clip(to: leadingEdge)"),
                      "The draining layer must have a wave edge instead of a rectangular top.")
        XCTAssertTrue(source.contains(".offset(y: proxy.size.height * 1.1).animation(revealAnimation)"),
                      "Welcome text travels with the curtain.")
    }

    func testSixPagesCombineBenefitsAndPermissions() throws {
        let source = try readSource(.onboardingFlowView)
        XCTAssertTrue(source.contains("case lava, features, vpn, protectionLevel, connectionQuality, done"))
        XCTAssertFalse(source.contains("case guardIntro"))
        XCTAssertFalse(source.contains("case notifications"))
        XCTAssertTrue(source.contains("title: \"You're in full control of what gets logged locally\""))
    }

    func testBlinkFollowsFilterAndGratitudeFollowsCompletionWithoutGatingControls() throws {
        let source = try readSource(.onboardingFlowView)
        XCTAssertTrue(source.contains("let shouldBlink = page == .protectionLevel && nextPage == .connectionQuality"))
        XCTAssertTrue(source.contains("else if shouldBlink { blinkTrigger += 1 }"))
        XCTAssertTrue(source.contains("handoff.setPhase(\"arriving\"); playGratitude()"))
        let busy = try sourceBlock(in: source, startingAt: "private var isBusy:", endingBefore: "private var mascotState:")
        XCTAssertFalse(busy.contains("expressionBusy"))
        XCTAssertTrue(source.contains("page == .done && travelStarted != nil && !isSmiling ? 1 : 0"),
                      "Panel fade begins with the grateful-to-awake return, not its completion.")
        XCTAssertTrue(source.contains("let progress = opening ? 1 :"),
                      "Open Guard completes any remaining travel before the sleep transition.")
        XCTAssertTrue(source.contains("ProtectionHapticFeedback.play(.actionSucceeded)"))
        XCTAssertTrue(source.contains("isMock ? 2080 : 80"))
        XCTAssertTrue(source.contains("GuardianMascotAnimationPlan.stateChangeDuration + 0.65"))
        XCTAssertTrue(source.contains("return isSmiling ? .grateful : .awake"))
    }

    func testVPNInstallRemainsInstallOnlyAndDoesNotAdvance() throws {
        let source = try readSource(.onboardingFlowView)
        let install = try sourceBlock(in: source, startingAt: "private func installVPN()", endingBefore: "private func requestNotifications()")
        XCTAssertTrue(install.contains("await viewModel.installLocalVPNProfileForOnboarding()"))
        XCTAssertFalse(install.contains("goForward()"))
        XCTAssertFalse(install.contains("wakeDuration"))
        XCTAssertTrue(source.contains("isDisabled: !vpnInstalled || isBusy"))
        XCTAssertTrue(source.contains("nextPage.rawValue <= OnboardingPage.vpn.rawValue || vpnInstalled"))
        let model = try readAppViewModelSource()
        let action = try sourceBlock(in: model, startingAt: "func installLocalVPNProfileForOnboarding()", endingBefore: "func requestProtectionNotificationAuthorizationForOnboarding()")
        XCTAssertFalse(action.contains("enableProtection"))
        XCTAssertFalse(action.contains("startVPNTunnel"))
    }

    func testDNSSetupDefaultsOnUsesAuthoritativeServiceAndDoesNotResetDiscoveries() throws {
        let source = try readSource(.onboardingFlowView)
        let root = try readSource(.rootView)
        XCTAssertTrue(source.contains("@State private var useEncryptedFallback = true"))
        XCTAssertTrue(source.contains("@State private var useDNSProfile = true"))
        XCTAssertTrue(source.contains("try await installDNSProfile()"))
        XCTAssertTrue(source.contains("Button(\"Set up later\") { goForward() }"))
        XCTAssertFalse(source.contains("configuration.dnsPatchEnabled ="))
        XCTAssertTrue(root.contains("LavaAppBridge.shared.updateManagedDNSPatch(create: true)"))
        XCTAssertFalse(source.contains("LavaDiscovery."))
        XCTAssertFalse(source.contains("Additional setup"))
    }

    func testMockOnboardingGuardsEveryProductionBoundary() throws {
        let source = try readSource(.onboardingFlowView)
        XCTAssertTrue(source.contains("if isMock { return didInstallVPN }"))
        XCTAssertTrue(source.contains("if !isMock && !hasLoadedConnectionChoice"))
        XCTAssertTrue(source.contains("guard !isMock, scenePhase == .active else { return }"))
        XCTAssertTrue(source.contains("if !isMock, viewModel.vpnMessageIsError"))
        XCTAssertTrue(source.contains("if !isMock && nextPage == .done"))
        let persist = try sourceBlock(in: source, startingAt: "private func applyCurrentStepChoiceIfNeeded", endingBefore: "private func installVPN()")
        XCTAssertTrue(persist.contains("guard !isMock else { return }"))
        for productionCall in ["didInstallVPN = await viewModel.installLocalVPNProfileForOnboarding()",
                               "notificationsEnabled = await viewModel.requestProtectionNotificationAuthorizationForOnboarding()"] {
            XCTAssertTrue(source.contains("} else {\n                \(productionCall)"))
        }
        XCTAssertTrue(source.contains("else { try await installDNSProfile() }"))
        XCTAssertTrue(source.contains("if isMock { dismiss() } else { hasSeenOnboarding = true }"))
    }
}
