import XCTest

/// Source guardrails for the shared design-system accessibility retrofit — the WS-F foundation of the
/// iOS assistive-navigation accessibility plan. These pin the accessibility modifiers AS TEXT because
/// the app target sits outside the SPM test target (same regime as the other `*SourceTests`). They
/// assert presence/structure only; runtime VoiceOver focus order and spoken output are covered by the
/// plan's device-QA gates, not here.
final class AccessibilitySourceTests: XCTestCase {

    // MARK: LavaComponents — compact metric/detail blocks read as one VoiceOver element

    func testOverviewMetricBlockCombinesValueAndLabel() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaComponents),
            startingAt: "struct LavaOverviewMetricBlock",
            endingBefore: "struct LavaOverviewBannerRow"
        )
        XCTAssertTrue(
            block.contains(".accessibilityElement(children: .combine)"),
            "LavaOverviewMetricBlock must group its value + label into a single VoiceOver element."
        )
    }

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
            endingBefore: "struct LavaNavigationRow"
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
            endingBefore: "enum LavaToolbarMetrics"
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

    private func protectionStatusPanelSource() throws -> String {
        try sourceBlock(
            in: try readSource(.guardView),
            startingAt: "struct ProtectionStatusPanel",
            endingBefore: "private struct ProtectionPrimaryActionButton"
        )
    }

    func testGuardStatusExposesLabeledSummary() throws {
        let block = try protectionStatusPanelSource()
        XCTAssertTrue(
            block.contains(".accessibilityElement(children: .ignore)"),
            "The Guard status header must collapse into a single VoiceOver summary element."
        )
        // A STABLE label ("Protection status", localized via the app catalog) that does not change
        // with VPN state, with the live state carried in the value.
        XCTAssertTrue(
            block.contains("accessibilityLabel(Text(\"Protection status\"))"),
            "The Guard status summary must use a stable 'Protection status' label, not the mutable state string."
        )
        XCTAssertTrue(
            block.contains(".accessibilityValue(Text(viewModel.protectionTitle.lavaLocalized)"),
            "The Guard status summary must speak the localized protection state as its value."
        )
    }

    func testGuardMascotHiddenFromAccessibility() throws {
        // Pin the hidden modifier to the mascot's own sub-block (up to its tap gesture) so an
        // unrelated .accessibilityHidden elsewhere in the panel (e.g. the message icon) can't
        // satisfy this guardrail.
        let mascot = try sourceBlock(
            in: try readSource(.guardView),
            startingAt: "SoftShieldGuardian(",
            endingBefore: ".onTapGesture"
        )
        XCTAssertTrue(
            mascot.contains(".accessibilityHidden(true)"),
            "The decorative Guard mascot must be hidden from accessibility — its state is already in the summary."
        )
    }

    func testGuardPanelMessageHasNonColorCue() throws {
        let block = try protectionStatusPanelSource()
        XCTAssertTrue(
            block.contains("exclamationmark.triangle.fill"),
            "The Guard panel error message needs a non-color (symbol) cue so error vs info survives grayscale."
        )
    }

    // MARK: OnboardingFlowView — first-run flow (WS-O)

    func testOnboardingStepHeadingIsHeader() throws {
        let block = try sourceBlock(
            in: try readSource(.onboardingFlowView),
            startingAt: "struct OnboardingStepHeading",
            endingBefore: "private extension OnboardingProtectionLevel"
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
            block.contains("of \\(OnboardingPage.allCases.count)"),
            "Progress dots must announce 'Step X of Y', not just the bare step number."
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(dotPage == page ? [.isSelected]"),
            "The current progress dot must expose the selected trait — a non-color cue for the current step."
        )
    }

    func testOnboardingChecklistExposesOnOffValue() throws {
        let block = try sourceBlock(
            in: try readSource(.onboardingFlowView),
            startingAt: "struct OnboardingProtectionLevelPanel",
            endingBefore: "private var segments"
        )
        XCTAssertTrue(
            block.contains(".accessibilityValue(Text(isOn ? \"On\" : \"Off\"))"),
            "Each protection-checklist row must expose an On/Off accessibility value, not glyph + dimming alone."
        )
        XCTAssertTrue(
            block.contains(".accessibilityHidden(true)"),
            "The checklist's decorative checkmark/circle glyph must be hidden — the value carries the state."
        )
    }

    func testOnboardingMockPermissionDialogsHidden() throws {
        let source = try readSource(.onboardingFlowView)
        let vpn = try sourceBlock(
            in: source,
            startingAt: "private var vpnPage",
            endingBefore: "private var notificationsPage"
        )
        XCTAssertTrue(
            vpn.contains("OnboardingVPNPermissionDialogIllustration()") && vpn.contains(".accessibilityHidden(true)"),
            "The mock VPN-permission illustration (fake buttons) must be hidden from assistive tech."
        )
        let notifications = try sourceBlock(
            in: source,
            startingAt: "private var notificationsPage",
            endingBefore: "private var donePage"
        )
        XCTAssertTrue(
            notifications.contains("OnboardingNotificationPromptCard()") && notifications.contains(".accessibilityHidden(true)"),
            "The mock notification-prompt illustration (fake buttons) must be hidden from assistive tech."
        )
    }

    // MARK: FiltersView — connection-preview picker (WS-FL)

    func testFiltersConnectionPickerExposesValueAndSelection() throws {
        let block = try sourceBlock(
            in: try readSource(.filtersView),
            startingAt: "private var connectionSelector",
            endingBefore: "var blockedSecondHop"
        )
        XCTAssertTrue(
            block.contains(".accessibilityValue(Text(preview.label.lavaLocalized))"),
            "The connection-preview chip must expose the current option as its accessibility value."
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(option == preview ? [.isSelected] : [])"),
            "The connection-preview popover must mark the selected option with the selected trait."
        )
    }

    // MARK: SettingsView — feedback + navigation rows (WS-S)

    func testSettingsFeedbackTopicExposesSelectedTrait() throws {
        let source = try readSource(.bugReportSettingsView)
        XCTAssertTrue(
            source.contains(".accessibilityAddTraits(selectedIssueType == type ? [.isSelected] : [])"),
            "The bug-report topic row must expose the selected trait (its checkmark/circle glyph is decorative/hidden)."
        )
    }

    func testSettingsStepProgressHasNonColorCurrentCue() throws {
        let block = try sourceBlock(
            in: try readSource(.bugReportSettingsView),
            startingAt: "private struct BugReportStepProgressView",
            endingBefore: "private struct BugReportPreviewSectionCard"
        )
        XCTAssertTrue(
            block.contains(".font(.caption.weight(step == currentStep ? .heavy : .semibold))"),
            "The current bug-report step needs a non-color weight cue so it survives grayscale, not just the tint swap."
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(step == currentStep ? [.isSelected] : [])"),
            "The current bug-report step must expose the selected trait to VoiceOver."
        )
    }

    func testSettingsNavigationRowHidesDecorativeGlyphs() throws {
        let block = try sourceBlock(
            in: try readSource(.settingsView),
            startingAt: "private struct SettingsNavigationRow",
            endingBefore: "private struct SettingsExternalLinkRow"
        )
        XCTAssertTrue(block.contains("LavaNavigationCardLabel("))
        XCTAssertFalse(block.contains(".accessibilityHidden(true)"),
                       "Decorative hiding belongs to the shared label, not the authenticated wrapper.")
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
