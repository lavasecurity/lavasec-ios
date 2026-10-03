import XCTest

/// Source guardrails for the shared design-system accessibility retrofit — the WS-F foundation of the
/// iOS assistive-navigation accessibility plan. These pin the accessibility modifiers AS TEXT because
/// the app target sits outside the SPM test target (same regime as the other `*SourceTests`). They
/// assert presence/structure only; runtime VoiceOver focus order and spoken output are covered by the
/// plan's device-QA gates, not here.
final class AccessibilitySourceTests: XCTestCase {

    // MARK: LavaComponents — compact metric/detail blocks read as one VoiceOver element

    func testDetailRowHidesIconAndCombines() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaComponents),
            startingAt: "struct LavaDetailRow",
            endingBefore: "struct LavaInfoCard"
        )
        XCTAssertTrue(
            block.contains(".accessibilityHidden(true)"),
            "LavaDetailRow's decorative leading glyph must be hidden from accessibility."
        )
        XCTAssertTrue(
            block.contains(".accessibilityElement(children: .combine)"),
            "LavaDetailRow must read its title + subtitle as a single VoiceOver element."
        )
    }

    // MARK: Navigation-card label — decorative glyphs hidden; wrappers keep their own controls

    func testNavigationRowHidesDecorativeGlyphs() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaComponents),
            startingAt: "struct LavaNavigationCardLabel",
            endingBefore: "struct LavaNavigationCardButton<Label: View>: View"
        )
        let hiddenCount = block.components(separatedBy: ".accessibilityHidden(true)").count - 1
        XCTAssertGreaterThanOrEqual(
            hiddenCount, 2,
            "The shared navigation-card label must hide both its leading badge and trailing accessory from accessibility."
        )
        XCTAssertFalse(
            block.contains(".accessibilityElement(children: .combine)"),
            "The shared label must NOT .combine — wrappers retain their own interactive controls."
        )
    }

    // MARK: LavaScaffold — shared section/screen titles expose VoiceOver headers

    func testSectionGroupTitleIsHeader() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaScaffold),
            startingAt: "struct LavaSectionGroup",
            endingBefore: "struct LavaToolbarIconButton"
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isHeader)"),
            "LavaSectionGroup's title must carry the VoiceOver header trait so the rotor can jump between sections."
        )
    }

    func testScreenContentTitleIsHeader() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaScaffold),
            startingAt: "private var paddedContent",
            endingBefore: "private func scrollToTop"
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isHeader)"),
            "LavaScreenContent's large title must carry the VoiceOver header trait."
        )
    }

    // MARK: GuardView — protection status surfaces (WS-G)

    // MARK: OnboardingFlowView — first-run flow (WS-O)

    func testOnboardingStepHeadingIsHeader() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaScaffold),
            startingAt: "struct LavaSetupStepHeading",
            endingBefore: "struct LavaSetupChoiceRow"
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isHeader)"),
            "Each onboarding step page's title must be announced as a VoiceOver header."
        )
    }

    func testOnboardingProgressAnnouncesStepOfTotalAndSelection() throws {
        let block = try sourceBlock(
            in: try readSource(.onboardingFlowView),
            startingAt: "private var pageDots",
            endingBefore: "private var footerButtons"
        )
        XCTAssertTrue(
            block.contains("\"Step %lld of %lld\".lavaLocalizedFormat(dotPage.rawValue + 1, OnboardingPage.allCases.count)"),
            "Progress dots must announce the localized current step and total, not just the bare step number."
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(dotPage == page ? [.isSelected]"),
            "The current progress dot must expose the selected trait — a non-color cue for the current step."
        )
    }

    func testOnboardingChoicesExposeTheirStateAndFullRowAction() throws {
        let source = try readSource(.onboardingFlowView)
        let choices = try sourceBlock(in: source, startingAt: "private struct OnboardingProtectionLevelPanel", endingBefore: "private struct OnboardingConnectionPanel")
        XCTAssertTrue(choices.contains("ForEach(OnboardingProtectionLevel.allCases"))
        XCTAssertTrue(choices.contains("isSelected: selection == level"))
        XCTAssertTrue(choices.contains("selection = level"))
        XCTAssertTrue(choices.contains(".accessibilityValue(Text(selection == level ? \"On\" : \"Off\"))"))
        XCTAssertTrue(choices.contains(".accessibilityAddTraits(selection == level ? .isSelected : [])"))
        let connections = try sourceBlock(in: source, startingAt: "private struct OnboardingConnectionPanel", endingBefore: "private struct OnboardingPermissionButton")
        XCTAssertTrue(connections.contains("Button { updateOnboardingSelection { isOn.wrappedValue.toggle() } }"))
        XCTAssertTrue(connections.contains(".accessibilityValue(Text(isOn.wrappedValue ? \"On\" : \"Off\"))"))
        XCTAssertTrue(connections.contains(".accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])"))
        let row = try sourceBlock(in: source, startingAt: "private struct OnboardingSelectionLabel", endingBefore: "private struct OnboardingRowGlyph")
        XCTAssertTrue(row.contains(".contentShape(RoundedRectangle("))
        XCTAssertTrue(row.contains(".accessibilityElement(children: .combine)"))
        XCTAssertFalse(row.contains(".lineLimit("), "Instructions must expand at accessibility sizes.")
    }

    func testOnboardingPermissionsAreAccessibleCardsWithVPNOnlyGate() throws {
        let source = try readSource(.onboardingFlowView)
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"onboarding.install-vpn\")"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"onboarding.notifications\")"))
        XCTAssertTrue(source.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(source.contains("Enable notifications (optional)"))
        XCTAssertTrue(source.contains("isDisabled: !vpnInstalled || isBusy"))
        let install = try sourceBlock(in: source, startingAt: "private func installVPN()", endingBefore: "private func requestNotifications()")
        XCTAssertTrue(install.contains("guard !isBusy, isMock || !viewModel.isConfiguringVPN"))
        XCTAssertFalse(install.contains("goForward()"))
    }

    // MARK: FiltersView — connection-preview picker (WS-FL)

    // MARK: SettingsView — feedback + navigation rows (WS-S)

    func testSettingsFeedbackTopicExposesSelectedTrait() throws {
        let source = try readSource(.bugReportSettingsView)
        XCTAssertTrue(
            source.contains(".accessibilityAddTraits(selectedIssueType == type ? [.isSelected] : [])"),
            "The bug-report topic row must expose the selected trait (its checkmark/circle glyph is decorative/hidden)."
        )
    }

    func testSettingsStepProgressHasNonColorCurrentCue() throws {
        let adopter = try sourceBlock(
            in: try readSource(.bugReportSettingsView),
            startingAt: "private struct BugReportStepProgressView",
            endingBefore: "private struct BugReportPreviewSectionCard"
        )
        let block = try sourceBlock(
            in: try readSource(.lavaComponents),
            startingAt: "struct LavaStepNavigation<Step: Identifiable>: View",
            endingBefore: "struct LavaDiagnosticValueRow: View"
        )
        XCTAssertTrue(adopter.contains("LavaStepNavigation("))
        XCTAssertTrue(adopter.contains("isSelected: { $0 == currentStep }"))
        XCTAssertTrue(
            block.contains(".fontWeight(isSelected(step) ? .heavy : .semibold)"),
            "The current bug-report step needs a non-color weight cue so it survives grayscale, not just the tint swap."
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(isSelected(step) ? [.isSelected] : [])"),
            "The current bug-report step must expose the selected trait to VoiceOver."
        )
    }

    func testRetiredSettingsNavigationRowIsAbsent() throws {
        let source = try readSource(.settingsView)
        XCTAssertFalse(source.contains("private struct SettingsNavigationRow"))
        XCTAssertTrue(try readSource(.reactNativeSettingsScreens).contains("export function SettingsScreen()"))
    }

    // MARK: SecurityController — full-screen security overlays (WS-R)

    func testSecurityLockOverlayIsModal() throws {
        let block = try sourceBlock(
            in: try readSource(.securityController),
            startingAt: "struct SecurityLockOverlay",
            endingBefore: "struct SecurityPrivacyMaskOverlay"
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isModal)"),
            "The app-unlock lock overlay must be a modal accessibility container so VoiceOver can't reach the masked content behind it."
        )
    }

    func testSecurityPrivacyMaskOverlayIsModal() throws {
        let block = try sourceBlock(
            in: try readSource(.securityController),
            startingAt: "struct SecurityPrivacyMaskOverlay",
            endingBefore: "struct SecurityPasscodeAuthenticationView"
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isModal)"),
            "The privacy-mask overlay must be a modal accessibility container."
        )
    }
}
