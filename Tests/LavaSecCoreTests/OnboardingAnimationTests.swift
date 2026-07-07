import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class OnboardingAnimationTests: XCTestCase {
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
        let appViewModelSource = try readSource(.appViewModel)
        let defaultsBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "func applyOnboardingRecommendedDefaults(",
            endingBefore: "func selectOnboardingBlocklists"
        )

        XCTAssertTrue(defaultsBlock.contains("startOnboardingDefaultBlocklistSyncIfNeeded()"))
        XCTAssertTrue(defaultsBlock.contains("library = .seededDefaults(active: protectionLevel)"),
                      "Finishing onboarding seeds the three default filters with the chosen level active.")
    }

    func testFeaturePageDoesNotMountRowsUntilTransitionAllowsLayout() throws {
        let onboardingSource = try readSource(.onboardingFlowView)
        let guardScenePage = try sourceBlock(
            in: onboardingSource,
            startingAt: "private var guardScenePage: some View",
            endingBefore: "private var vpnPage"
        )

        XCTAssertTrue(guardScenePage.contains("OnboardingFeatureTransitionPlan.state(at: featureTransitionElapsed)"))
        XCTAssertTrue(guardScenePage.contains("ZStack(alignment: .top)"))
        XCTAssertTrue(guardScenePage.contains(".offset(y: CGFloat(transition.heroPanelOffsetY))"))
        XCTAssertTrue(guardScenePage.contains("if transition.featureRowsOccupyLayout"))
        XCTAssertTrue(guardScenePage.contains(".padding(.top, CGFloat(transition.featureRowsTopOffset))"))
    }

    func testGuardIntroAndFeaturesShareOneSceneViewIdentity() throws {
        let onboardingSource = try readSource(.onboardingFlowView)
        let currentPage = try sourceBlock(
            in: onboardingSource,
            startingAt: "private var currentPage: some View",
            endingBefore: "private var internetIsLavaPage"
        )

        XCTAssertTrue(currentPage.contains("case .guardIntro, .features:"))
        XCTAssertTrue(currentPage.contains("guardScenePage"))
    }

    func testOnboardingTopBarDoesNotRenderCenterTitleAfterFirstPage() throws {
        let onboardingSource = try readSource(.onboardingFlowView)
        let topBar = try sourceBlock(
            in: onboardingSource,
            startingAt: "private var topBar: some View",
            endingBefore: "@ViewBuilder"
        )

        XCTAssertFalse(topBar.contains("Text(\"Lava\")"))
    }

    func testIntroCopyKeepsInternetFocusAndLocalLoggingRowIsDirect() throws {
        let onboardingSource = try readSource(.onboardingFlowView)
        let lavaPage = try sourceBlock(
            in: onboardingSource,
            startingAt: "private var internetIsLavaPage: some View",
            endingBefore: "private var guardScenePage"
        )
        let guardScenePage = try sourceBlock(
            in: onboardingSource,
            startingAt: "private var guardScenePage: some View",
            endingBefore: "private var vpnPage"
        )

        XCTAssertTrue(lavaPage.contains("Text(\"The internet is lava\")"))
        XCTAssertTrue(lavaPage.contains("Malicious domains are the hot spots. Your phone can step around them before apps and websites connect."))
        XCTAssertFalse(lavaPage.contains("Lava helps your phone step around them"))
        XCTAssertTrue(guardScenePage.contains("title: \"You're in full control of what gets logged locally\""))
        XCTAssertFalse(guardScenePage.contains("No silent logging."))
    }

    func testGuardHeroBlinksAfterFeatureUpliftCompletes() throws {
        let onboardingSource = try readSource(.onboardingFlowView)
        let viewStateBlock = try sourceBlock(
            in: onboardingSource,
            startingAt: "struct LavaOnboardingView: View",
            endingBefore: "var body: some View"
        )
        let guardScenePage = try sourceBlock(
            in: onboardingSource,
            startingAt: "private var guardScenePage: some View",
            endingBefore: "private var vpnPage"
        )
        let animationBlock = try sourceBlock(
            in: onboardingSource,
            startingAt: "private func prepareAnimations(for nextPage: OnboardingPage)",
            endingBefore: "private enum OnboardingPage"
        )
        let heroBlock = try sourceBlock(
            in: onboardingSource,
            startingAt: "private struct OnboardingGuardHero: View",
            endingBefore: "private struct OnboardingStepLayout"
        )
        let guardianSource = try readSource(.softShieldGuardian)
        let guardianBlock = try sourceBlock(
            in: guardianSource,
            startingAt: "struct SoftShieldGuardian: View",
            endingBefore: "private struct SoftShieldGuardianContent"
        )

        XCTAssertTrue(viewStateBlock.contains("@State private var guardHeroBlinkTrigger = 0"))
        XCTAssertTrue(guardScenePage.contains("OnboardingGuardHero(blinkTrigger: guardHeroBlinkTrigger)"))
        XCTAssertTrue(animationBlock.contains("guardHeroBlinkTrigger += 1"))
        XCTAssertTrue(animationBlock.contains("0.08 + OnboardingFeatureTransitionPlan.heroMoveDuration"))
        XCTAssertTrue(heroBlock.contains("SoftShieldGuardian(size: 132, state: .awake, animates: true, blinkTrigger: blinkTrigger)"))
        XCTAssertTrue(guardianBlock.contains("let blinkTrigger: Int"))
        XCTAssertTrue(guardianBlock.contains(".onChange(of: blinkTrigger)"))
        XCTAssertTrue(guardianBlock.contains("GuardianMascotAnimationPlan.blink(on: activePlan.endState)"))
    }

    func testPermissionPromptIllustrationsAreCenteredInStepBody() throws {
        let onboardingSource = try readSource(.onboardingFlowView)
        let vpnPage = try sourceBlock(
            in: onboardingSource,
            startingAt: "private var vpnPage: some View",
            endingBefore: "private var notificationsPage"
        )
        let notificationsPage = try sourceBlock(
            in: onboardingSource,
            startingAt: "private var notificationsPage: some View",
            endingBefore: "private var donePage"
        )
        let stepLayout = try sourceBlock(
            in: onboardingSource,
            startingAt: "private struct OnboardingStepLayout<Content: View>: View",
            endingBefore: "private struct OnboardingStepHeading"
        )

        XCTAssertTrue(vpnPage.contains("contentPlacement: .centered"))
        XCTAssertTrue(notificationsPage.contains("contentPlacement: .centered"))
        XCTAssertTrue(stepLayout.contains("let contentPlacement: OnboardingStepContentPlacement"))
        XCTAssertTrue(stepLayout.contains("case .centered"))
        XCTAssertTrue(stepLayout.contains("content.frame(maxWidth: .infinity, alignment: .center)"))
    }

    func testReadyPageAnimatesMascotFromAwakeToGratefulAndBackToAwake() throws {
        let onboardingSource = try readSource(.onboardingFlowView)
        let donePage = try sourceBlock(
            in: onboardingSource,
            startingAt: "private var donePage: some View",
            endingBefore: "private var footer"
        )
        let readyMascot = try sourceBlock(
            in: onboardingSource,
            startingAt: "private struct OnboardingReadyMascot: View",
            endingBefore: "private struct OnboardingStepLayout"
        )

        XCTAssertTrue(donePage.contains("OnboardingReadyMascot()"))
        XCTAssertFalse(donePage.contains("SoftShieldGuardian(size: 124, state: .grateful, animates: false)"))
        XCTAssertTrue(donePage.contains("Text(\"Lava is ready\")"))
        XCTAssertFalse(donePage.contains("Text(\"Lava is ready.\")"))
        XCTAssertTrue(donePage.contains("Text(\"We are happy to serve you!\\nThe setup is complete. You can change everything later in Settings.\")"))
        XCTAssertTrue(readyMascot.contains("@State private var mascotState: GuardianMascotState = .awake"))
        XCTAssertTrue(readyMascot.contains("SoftShieldGuardian(size: 124, state: mascotState)"))
        XCTAssertTrue(readyMascot.contains("Task.sleep(nanoseconds: 500_000_000)"))
        XCTAssertTrue(readyMascot.contains("mascotState = .grateful"))
        XCTAssertTrue(readyMascot.contains("Task.sleep(nanoseconds: 700_000_000)"))
        XCTAssertTrue(readyMascot.contains("guard !Task.isCancelled else {\n                    return\n                }\n                mascotState = .awake"))
    }

    func testOnboardingVPNInstallDoesNotShowIOSPermissionHintMessage() throws {
        let onboardingSource = try readSource(.onboardingFlowView)
        let vpnPage = try sourceBlock(
            in: onboardingSource,
            startingAt: "private var vpnPage: some View",
            endingBefore: "private var notificationsPage"
        )
        let viewModelSource = try readSource(.appViewModel)
        let onboardingInstallBlock = try sourceBlock(
            in: viewModelSource,
            startingAt: "func installLocalVPNProfileForOnboarding() async -> Bool",
            endingBefore: "func requestProtectionNotificationAuthorizationForOnboarding() async -> Bool"
        )

        XCTAssertTrue(vpnPage.contains("if viewModel.vpnMessageIsError, let message = viewModel.vpnMessage"))
        XCTAssertFalse(vpnPage.contains("if let message = viewModel.vpnMessage"))
        XCTAssertFalse(onboardingInstallBlock.contains("vpnMessage = Self.vpnPermissionPromptMessage"))
    }

    func testFeatureNavigationResetsTransitionBeforeShowingFeaturePage() throws {
        let onboardingSource = try readSource(.onboardingFlowView)
        let navigationBlock = try sourceBlock(
            in: onboardingSource,
            startingAt: "private func go(to nextPage: OnboardingPage)",
            endingBefore: "private func goBack"
        )

        let resetRange = try XCTUnwrap(navigationBlock.range(of: "featureTransitionElapsed = 0"))
        let showPageRange = try XCTUnwrap(navigationBlock.range(of: "page = nextPage"))

        XCTAssertLessThan(resetRange.lowerBound, showPageRange.lowerBound)
        XCTAssertTrue(navigationBlock.contains("guard page != .guardIntro || nextPage != .features else"))
    }
}
