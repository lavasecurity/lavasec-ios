import XCTest
@testable import LavaSecCore

final class SettingsFeedbackSourceTests: XCTestCase {
    func testRejectPanelUsesLavaOrangeBorderWhileInfoPanelKeepsDefaultBorder() throws {
        let rootSource = try Self.source(named: "LavaComponents.swift", in: "LavaSecApp/LavaDesignSystem")
        let reviewSource = try Self.source(named: "FilterReviewFlowView.swift", in: "LavaSecApp")
        let infoPanelBlock = try Self.sourceBlock(
            in: rootSource,
            startingAt: "struct LavaInfoPanel: View",
            endingBefore: "*** end ***"
        )
        let rejectPanelBlock = try Self.sourceBlock(
            in: reviewSource,
            startingAt: "struct DomainRejectPanel: View",
            endingBefore: "struct FilterConfirmationSheet: View"
        )

        XCTAssertTrue(infoPanelBlock.contains("var borderTint: Color? = nil"))
        XCTAssertTrue(infoPanelBlock.contains("borderTint: borderTint"))
        XCTAssertTrue(rejectPanelBlock.contains("borderTint: LavaStyle.lavaOrange"))
    }

    func testSharedMultilineTextInputAlignsFreeformContentWithRowLabel() throws {
        let rootSource = try Self.source(named: "LavaComponents.swift", in: "LavaSecApp/LavaDesignSystem")
        let editorRowBlock = try Self.sourceBlock(
            in: rootSource,
            startingAt: "struct LavaTextEditorInputRow: View",
            endingBefore: "extension View"
        )

        XCTAssertTrue(editorRowBlock.contains("LavaTextInputRow(title: title)"))
        XCTAssertTrue(editorRowBlock.contains("TextEditor(text: $text)"))
        XCTAssertTrue(editorRowBlock.contains(".padding(.leading, -5)"))
        XCTAssertFalse(editorRowBlock.contains(".padding(.leading, 5)"))
    }

    func testSettingsRootUsesNativeLargeTitleScrollAndDropsFreeProtectionPanel() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let rootSource = try Self.source(named: "LavaScaffold.swift", in: "LavaSecApp/LavaDesignSystem")
        let settingsBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct SettingsView: View",
            endingBefore: "private struct AccountSettingsView: View"
        )

        XCTAssertTrue(settingsBlock.contains("LavaPrimaryTabScreenContent("))
        XCTAssertTrue(settingsBlock.contains("title: \"Settings\""))
        XCTAssertFalse(settingsBlock.contains("scrolls: false"))
        XCTAssertFalse(settingsBlock.contains("collapsesTitleWhenScrolled"))
        XCTAssertFalse(settingsBlock.contains(".navigationTitle(\"Settings\")"))
        XCTAssertFalse(settingsBlock.contains(".navigationBarTitleDisplayMode(.large)"))
        XCTAssertTrue(rootSource.contains(".navigationTitle(title.lavaLocalized)"))
        XCTAssertTrue(rootSource.contains(".navigationBarTitleDisplayMode(.large)"))
        XCTAssertFalse(rootSource.contains("LavaCollapsedTabTitle"))
        XCTAssertFalse(rootSource.contains("scrollTrackedPaddedContent"))
        XCTAssertFalse(settingsBlock.contains("Free protection is available without an account."))
    }

    func testSupportRowsUseHelpAndFeedbackCopy() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let settingsBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct SettingsView: View",
            endingBefore: "private struct AccountSettingsView: View"
        )

        XCTAssertTrue(settingsBlock.containsInOrder([
            "title: \"Help\"",
            "summary: \"Learn how Lava works\"",
            "title: \"Feedback\"",
            "summary: \"Voluntary and anonymized\"",
            "title: \"Legal Notices\"",
            "summary: \"Credits and licenses\""
        ]))
        XCTAssertFalse(settingsBlock.contains("Submit Bug Report"))
        XCTAssertFalse(settingsBlock.contains("Fix a site or learn how Lava works"))
        XCTAssertFalse(settingsBlock.contains("Third-party names and source credits"))
    }

    func testVersionNerdStatsAppSectionUsesTableRowsWithBuildAndPlatform() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let versionInfoBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private enum VersionInfo",
            endingBefore: "private struct PhoneQASettingsView: View"
        )
        let nerdStatsBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct VersionNerdStatsView: View",
            endingBefore: "private func refreshTunnelHealthSample() async"
        )
        let appSectionBlock = try Self.sourceBlock(
            in: nerdStatsBlock,
            startingAt: "LavaSectionGroup(\"App\")",
            endingBefore: "LavaSectionGroup(\n                \"Tunnel Health\""
        )

        XCTAssertTrue(versionInfoBlock.contains("static let appVersion = infoValue(\"CFBundleShortVersionString\")"))
        XCTAssertFalse(versionInfoBlock.contains("static let appBuild = infoValue(\"CFBundleVersion\")"))
        XCTAssertTrue(versionInfoBlock.contains("static let platformVersion = \"\\(UIDevice.current.systemName) \\(UIDevice.current.systemVersion)\""))
        XCTAssertTrue(appSectionBlock.containsInOrder([
            "LavaPlainCard",
            "LabeledContent(\"Version\", value: VersionInfo.appVersion)",
            "LabeledContent(\"Platform\", value: VersionInfo.platformVersion)"
        ]))
        XCTAssertFalse(appSectionBlock.contains("VersionNerdStatRow"))
        XCTAssertFalse(versionInfoBlock.contains("appBuild"))
        XCTAssertFalse(appSectionBlock.contains("systemImage: \"app.badge\""))
    }

    func testSettingsSubpagesUseSharedSubpageScaffold() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")

        XCTAssertTrue(source.contains("private struct SettingsSubpageContent<Content: View>: View"))
        XCTAssertTrue(source.contains("private enum SettingsSubpageLayout"))
        XCTAssertEqual(
            source.occurrences(of: "SettingsSubpageContent {")
                + source.occurrences(of: "SettingsSubpageContent(spacing:"),
            10
        )
        XCTAssertFalse(source.contains("LavaScreenContent(spacing: 22)"))
        XCTAssertFalse(source.contains("LavaScreenContent(\n            spacing: 24"))
        XCTAssertTrue(source.contains("SettingsSubpageContent(spacing: SettingsSubpageLayout.feedbackSpacing, scrolls: !isShowingThankYou)"))
    }

    func testScreenContentScrollAnchorDoesNotAddTopSpacing() throws {
        let source = try Self.source(named: "LavaScaffold.swift", in: "LavaSecApp/LavaDesignSystem")
        let screenContentBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct LavaScreenContent<Content: View>: View",
            endingBefore: "struct LavaSheetScaffold"
        )

        XCTAssertTrue(screenContentBlock.contains(".background(alignment: .topLeading)"))
        XCTAssertFalse(screenContentBlock.containsInOrder([
            "VStack(alignment: .leading, spacing: spacing) {",
            "Color.clear",
            ".id(Self.scrollTopAnchorID)",
            "if let title"
        ]))
    }

    func testFeedbackFlowUsesThreeStepsAndPrivacyFirstCopy() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let feedbackBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View",
            endingBefore: "private struct LegalNoticesView: View"
        )

        XCTAssertTrue(feedbackBlock.contains(".navigationTitle(\"Feedback\")"))
        XCTAssertEqual(feedbackBlock.occurrences(of: "No silent telemetry"), 1)
        XCTAssertTrue(feedbackBlock.containsInOrder([
            "Choose a topic",
            "BugReportIssueType.allCases.enumerated()",
            "BugReportTopicOptionRow(",
            "Tell us more",
            "Include optional diagnostic",
            "See what information is sent",
            "Review and submit",
            "Thank you, Lava will look into this"
        ]))
        XCTAssertTrue(source.contains("case .context:\n            \"2.\""))
        XCTAssertTrue(source.contains("case .context:\n            \"Details\""))
        XCTAssertTrue(feedbackBlock.contains("Optional diagnostics include anonymized Lava Data like VPN status, network logs, and filter snapshot. They help the Lava team better investigate what went wrong."))
        XCTAssertFalse(feedbackBlock.contains("Provide context"))
        XCTAssertFalse(feedbackBlock.contains("\"Context\""))
        XCTAssertFalse(feedbackBlock.contains("Optional diagnostics include App & Device"))
        XCTAssertFalse(feedbackBlock.contains("better visualize what went wrong"))
        XCTAssertFalse(feedbackBlock.contains("Continue to Preview"))
        XCTAssertFalse(feedbackBlock.contains("Confirm Send"))
    }

    func testFeedbackDetailsStepUsesFlatRowsAndTextOnlyActions() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let feedbackBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View",
            endingBefore: "private struct LegalNoticesView: View"
        )
        let contextPageBlock = try Self.sourceBlock(
            in: feedbackBlock,
            startingAt: "private var contextPage: some View",
            endingBefore: "private var reviewPage: some View"
        )

        XCTAssertTrue(contextPageBlock.containsInOrder([
            "LavaSectionGroup(\"Tell us more\")",
            "VStack(spacing: 10)",
            "LavaTextInputPanel",
            "LavaTextInputRow(title: \"Site or domain\")",
            "Divider()",
            "LavaTextEditorInputRow(",
            "title: \"Details\"",
            "Divider()",
            "LavaTextInputRow(title: \"Email for follow-up (optional)\")",
            "Toggle(\"Include optional diagnostic\", isOn: $includeDiagnostics)"
        ]))
        XCTAssertEqual(contextPageBlock.occurrences(of: "LavaTextInputPanel"), 1)
        XCTAssertEqual(contextPageBlock.occurrences(of: "LavaPlainCard"), 1)
        XCTAssertFalse(contextPageBlock.contains("LavaCondensedList"))
        XCTAssertFalse(contextPageBlock.contains("BugReportDetailsTextEditor"))
        XCTAssertFalse(contextPageBlock.contains("Label(\"See what information is sent\""))
        XCTAssertFalse(contextPageBlock.contains("contextValidationMessage"))
        XCTAssertFalse(contextPageBlock.contains("Add a few details before reviewing."))
        XCTAssertTrue(contextPageBlock.containsInOrder([
            "NavigationLink {",
            "BugReportDiagnosticsInfoView(sections: diagnosticPreviewSections)",
            "Text(\"See what information is sent\".lavaLocalized)",
            ".frame(maxWidth: .infinity, alignment: .leading)",
            ".buttonStyle(.plain)"
        ]))
        XCTAssertFalse(contextPageBlock.contains("See what information is sent."))
        XCTAssertTrue(feedbackBlock.contains("Text(\"Back\".lavaLocalized)"))
        XCTAssertTrue(feedbackBlock.contains("Text(\"Review\".lavaLocalized)"))
        XCTAssertFalse(feedbackBlock.contains("Label(\""))
        XCTAssertFalse(feedbackBlock.contains("nextSystemImage"))
    }

    func testFeedbackReviewStepUsesSeparatePanelsAndBackAction() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let feedbackBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View",
            endingBefore: "private struct LegalNoticesView: View"
        )
        let reviewPageBlock = try Self.sourceBlock(
            in: feedbackBlock,
            startingAt: "private var reviewPage: some View",
            endingBefore: "private var thankYouPage: some View"
        )
        let bottomActionsBlock = try Self.sourceBlock(
            in: feedbackBlock,
            startingAt: "private var feedbackBottomActionButtons: some View",
            endingBefore: "private func goToStep(_ step: BugReportStep)"
        )

        XCTAssertTrue(reviewPageBlock.containsInOrder([
            "LavaSectionGroup(\"Review and submit\")",
            "VStack(spacing: 10)",
            "BugReportReviewRow(label: \"Topic\"",
            "BugReportReviewRow(label: \"Site or domain\"",
            "BugReportReviewRow(label: \"Details\"",
            "BugReportReviewRow(label: \"Email\"",
            "BugReportReviewRow(label: \"Diagnostics\""
        ]))
        XCTAssertEqual(reviewPageBlock.occurrences(of: "LavaPlainCard"), 5)
        XCTAssertFalse(reviewPageBlock.contains("Divider()"))
        XCTAssertFalse(reviewPageBlock.contains("Optional diagnostics"))
        XCTAssertTrue(bottomActionsBlock.containsInOrder([
            "case .review:",
            "Button {",
            "moveBack()",
            "Text(\"Back\".lavaLocalized)",
            ".buttonStyle(FeedbackSecondaryActionButtonStyle())",
            "Button {",
            "submitReport()"
        ]))
        XCTAssertFalse(bottomActionsBlock.contains("Text(\"Cancel\".lavaLocalized)"))
        XCTAssertFalse(bottomActionsBlock.contains("requestDismiss()"))

        let reviewRowBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct BugReportReviewRow: View",
            endingBefore: "private struct BugReportDiagnosticsInfoView"
        )
        XCTAssertTrue(reviewRowBlock.contains("HStack(alignment: .center, spacing: 12)"))
    }

    func testFeedbackSubmittingStateStaysInsideSubmitButton() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let feedbackBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View",
            endingBefore: "private struct LegalNoticesView: View"
        )
        let statusBlock = try Self.sourceBlock(
            in: feedbackBlock,
            startingAt: "private var bugReportStatusView: some View",
            endingBefore: "private func selectIssueType(_ type: BugReportIssueType)"
        )

        XCTAssertTrue(statusBlock.contains("case .idle, .sent, .sending:"))
        XCTAssertTrue(feedbackBlock.contains("case .sending:\n            \"Submitting\""))
        XCTAssertFalse(statusBlock.contains("case .sending:\n            LavaPlainCard"))
        XCTAssertFalse(feedbackBlock.contains("Sending feedback..."))
    }

    func testFeedbackThankYouPageUsesMascotCopyIDAndNoClose() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let feedbackBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View",
            endingBefore: "private struct LegalNoticesView: View"
        )
        let thankYouBlock = try Self.sourceBlock(
            in: feedbackBlock,
            startingAt: "private var thankYouPage: some View",
            endingBefore: "private var feedbackBottomActionBar: some View"
        )
        let thankYouMascotBlock = try Self.sourceBlock(
            in: feedbackBlock,
            startingAt: "private struct FeedbackThankYouMascot: View",
            endingBefore: "private struct FeedbackSecondaryActionButtonStyle"
        )

        XCTAssertTrue(feedbackBlock.contains("SettingsSubpageContent(spacing: SettingsSubpageLayout.feedbackSpacing, scrolls: !isShowingThankYou)"))
        XCTAssertTrue(feedbackBlock.contains("if onDismissRequested != nil && !isShowingThankYou"))
        XCTAssertTrue(feedbackBlock.contains("if isShowingThankYou {\n                thankYouBottomActionBar"))
        XCTAssertTrue(thankYouBlock.contains("FeedbackThankYouMascot()"))
        XCTAssertFalse(thankYouBlock.contains("SoftShieldGuardian(size: 96, state: .grateful, animates: false)"))
        XCTAssertTrue(thankYouMascotBlock.contains("@EnvironmentObject private var viewModel: AppViewModel"))
        XCTAssertTrue(thankYouMascotBlock.contains("@State private var mascotState: GuardianMascotState = .awake"))
        XCTAssertTrue(thankYouMascotBlock.contains("SoftShieldGuardian(size: 96, state: mascotState, shieldStyle: viewModel.lavaGuardLook)"))
        XCTAssertTrue(thankYouMascotBlock.contains("mascotState = .awake"))
        XCTAssertTrue(thankYouMascotBlock.contains("mascotState = .grateful"))
        XCTAssertTrue(thankYouMascotBlock.contains("Task.sleep(nanoseconds: 700_000_000)"))
        XCTAssertFalse(thankYouMascotBlock.contains("mascotState = .paused"))
        XCTAssertTrue(thankYouBlock.contains("Text(thankYouTitle.lavaLocalized)"))
        XCTAssertTrue(thankYouBlock.contains("Text(\"Report ID:\".lavaLocalized)"))
        XCTAssertTrue(thankYouBlock.contains("Text(submittedReportID)"))
        XCTAssertTrue(thankYouBlock.contains("frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)"))
        XCTAssertTrue(feedbackBlock.contains("\"Thank you, Lava will look into this and reach out if needed\""))
        XCTAssertTrue(feedbackBlock.contains("normalizedContactEmail.isEmpty"))
        XCTAssertTrue(feedbackBlock.contains("private var thankYouBottomActionBar: some View"))
        XCTAssertTrue(feedbackBlock.contains("@State private var didCopySubmittedReportID = false"))
        XCTAssertTrue(feedbackBlock.contains("Text((didCopySubmittedReportID ? \"Copied!\" : \"Copy ID\").lavaLocalized)"))
        XCTAssertTrue(feedbackBlock.contains(".contentTransition(.identity)"))
        XCTAssertTrue(feedbackBlock.contains(".buttonStyle(LavaPanelActionButtonStyle(height: 44, cornerRadius: 12))"))
        XCTAssertTrue(feedbackBlock.contains("copySubmittedReportID()"))
        XCTAssertTrue(feedbackBlock.contains("UIPasteboard.general.string = submittedReportID"))
        XCTAssertTrue(feedbackBlock.contains("transaction.disablesAnimations = true"))
        XCTAssertTrue(feedbackBlock.contains("withTransaction(transaction)"))
        XCTAssertTrue(feedbackBlock.contains("didCopySubmittedReportID = UIPasteboard.general.string == submittedReportID"))
        XCTAssertFalse(thankYouBlock.contains("LavaInfoPanel("))
    }

    func testFeedbackStepActionsArePinnedAndUseExpectedSecondaryButtons() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let feedbackBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View",
            endingBefore: "private struct LegalNoticesView: View"
        )

        XCTAssertTrue(feedbackBlock.contains(".safeAreaInset(edge: .bottom)"))
        XCTAssertTrue(feedbackBlock.contains("private var feedbackBottomActionBar: some View"))
        XCTAssertTrue(feedbackBlock.contains("private var feedbackBottomActionButtons: some View"))
        XCTAssertTrue(feedbackBlock.contains("private struct FeedbackSecondaryActionButtonStyle: ButtonStyle"))
        XCTAssertTrue(feedbackBlock.contains("Color(uiColor: .secondarySystemFill)"))
        XCTAssertTrue(feedbackBlock.contains("Text(\"Back\".lavaLocalized)"))
        XCTAssertEqual(feedbackBlock.occurrences(of: ".buttonStyle(FeedbackSecondaryActionButtonStyle())"), 2)
        XCTAssertTrue(feedbackBlock.contains(".buttonStyle(LavaPanelActionButtonStyle(height: 44, cornerRadius: 12))"))
    }

    func testFeedbackStepProgressUsesClickableSimpleNumberText() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let feedbackBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View",
            endingBefore: "private struct LegalNoticesView: View"
        )
        let stepProgressBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct BugReportStepProgressView: View",
            endingBefore: "private struct BugReportPreviewSectionCard: View"
        )

        XCTAssertTrue(source.contains("\"1.\""))
        XCTAssertTrue(source.contains("\"2.\""))
        XCTAssertTrue(source.contains("\"3.\""))
        XCTAssertTrue(feedbackBlock.contains("@State private var furthestVisitedStep: BugReportStep = .topic"))
        XCTAssertTrue(feedbackBlock.contains("furthestVisitedStep: furthestVisitedStep"))
        XCTAssertTrue(feedbackBlock.contains("markStepVisited(.context)"))
        XCTAssertTrue(feedbackBlock.contains("markStepVisited(.review)"))
        XCTAssertTrue(feedbackBlock.contains("step.rawValue <= furthestVisitedStep.rawValue"))
        XCTAssertTrue(feedbackBlock.contains("furthestVisitedStep = .topic"))
        XCTAssertTrue(stepProgressBlock.contains("let furthestVisitedStep: BugReportStep"))
        XCTAssertTrue(stepProgressBlock.contains("let selectStep: (BugReportStep) -> Void"))
        XCTAssertTrue(stepProgressBlock.contains("Button {"))
        XCTAssertTrue(stepProgressBlock.contains("step.displayNumber"))
        XCTAssertTrue(stepProgressBlock.contains("isUnavailableStep"))
        XCTAssertTrue(stepProgressBlock.contains("step.rawValue > furthestVisitedStep.rawValue"))
        XCTAssertFalse(source.contains("\"①\""))
        XCTAssertFalse(source.contains("\"②\""))
        XCTAssertFalse(source.contains("\"③\""))
        XCTAssertFalse(stepProgressBlock.contains(".background(stepFillColor"))
        XCTAssertFalse(stepProgressBlock.contains("Circle()"))
        XCTAssertFalse(stepProgressBlock.contains("isFutureStep"))
    }

    func testFeedbackFlowGuardsDirtyDismissalInSettingsAndRageShakeSheet() throws {
        let settingsSource = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let rootSource = try Self.source(named: "RootView.swift", in: "LavaSecApp")
        let feedbackBlock = try Self.sourceBlock(
            in: settingsSource,
            startingAt: "struct BugReportSettingsView: View",
            endingBefore: "private struct LegalNoticesView: View"
        )
        let rageShakeSheetBlock = try Self.sourceBlock(
            in: rootSource,
            startingAt: "private struct BugReportSheetView: View",
            endingBefore: "#Preview"
        )

        XCTAssertTrue(feedbackBlock.contains("onDismissRequested"))
        XCTAssertTrue(feedbackBlock.contains("isReportDirty"))
        XCTAssertTrue(feedbackBlock.contains(".alert(\"Discard feedback?\""))
        XCTAssertTrue(feedbackBlock.contains("Button(\"Cancel\", role: .cancel)"))
        XCTAssertTrue(feedbackBlock.contains("Button(\"Discard\", role: .destructive)"))
        XCTAssertTrue(rageShakeSheetBlock.contains("canRequestDismiss"))
        XCTAssertTrue(rageShakeSheetBlock.contains(".interactiveDismissDisabled(isReportDirty"))
    }

    func testAccountPageRemovesFreeAccountInfoPanelAndUsesStandardAccountSheetChrome() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let accountBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct AccountSettingsView: View",
            endingBefore: "private struct AppleSignInStatusIcon: View"
        )
        let sheetBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct AccountSheet: View",
            endingBefore: "private struct AccountConnectionRow: View"
        )

        XCTAssertFalse(accountBlock.contains("title: \"Free is good - an account is only needed for online backup.\""))
        XCTAssertFalse(accountBlock.contains("title: \"An account is only needed when you want to use the online backup.\""))
        XCTAssertTrue(sheetBlock.contains("NavigationStack"))
        XCTAssertTrue(sheetBlock.contains(".navigationTitle(\"Account\")"))
        XCTAssertTrue(sheetBlock.contains(".navigationBarTitleDisplayMode(.inline)"))
        XCTAssertTrue(sheetBlock.contains("ToolbarItem(placement: .cancellationAction)"))
        XCTAssertTrue(sheetBlock.contains("NativeToolbarIconButton(systemName: \"xmark\", accessibilityLabel: \"Close\", action: dismiss.callAsFunction)"))
        XCTAssertFalse(sheetBlock.contains("LavaToolbarIconButton("))
        XCTAssertFalse(sheetBlock.contains("Text(\"Account\")"))
    }

    func testSettingsModalSingleGlyphToolbarsUseNativeActions() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let passcodeBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct SecurityPasscodeSetupView: View",
            endingBefore: "private enum LocalLogSetting"
        )
        let feedbackBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View",
            endingBefore: "private struct FeedbackThankYouMascot"
        )

        XCTAssertTrue(passcodeBlock.contains("ToolbarItem(placement: .cancellationAction)"))
        XCTAssertTrue(passcodeBlock.contains("NativeToolbarIconButton(systemName: \"xmark\", accessibilityLabel: \"Cancel\", action: dismiss.callAsFunction)"))
        XCTAssertFalse(passcodeBlock.contains("LavaToolbarIconButton("))

        XCTAssertTrue(feedbackBlock.contains("NativeToolbarIconButton(systemName: \"chevron.left\", accessibilityLabel: \"Back\", action: requestDismiss)"))
        XCTAssertTrue(feedbackBlock.contains("ToolbarItem(placement: .cancellationAction)"))
        XCTAssertTrue(feedbackBlock.contains("NativeToolbarIconButton(systemName: \"xmark\", accessibilityLabel: \"Close\", action: requestDismiss)"))
        XCTAssertFalse(feedbackBlock.contains("LavaToolbarIconButton("))
    }

    func testEncryptedBackupSectionUsesInfoPanelAndAutomaticBackupToggle() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let accountBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct AccountSettingsView: View",
            endingBefore: "private struct AppleSignInStatusIcon: View"
        )

        XCTAssertTrue(accountBlock.contains("LavaInfoPanel("))
        XCTAssertTrue(accountBlock.contains("title: viewModel.encryptedBackupInfoTitle"))
        XCTAssertFalse(accountBlock.contains("description: viewModel.encryptedBackupInfoDescription"))
        XCTAssertFalse(accountBlock.contains("Latest encrypted settings backup size"))
        XCTAssertTrue(accountBlock.contains("BackupOptionControl("))
        XCTAssertTrue(accountBlock.contains("title: \"Automatic Backup\""))
        XCTAssertTrue(accountBlock.contains("detail: \"Lava waits 30 minutes after your last settings change before it tries an automatic upload.\""))
        XCTAssertTrue(accountBlock.containsInOrder([
            "SettingsActionRow(title: \"Restore Backup\")",
            "BackupOptionControl(",
            "title: \"Automatic Backup\""
        ]))
        XCTAssertFalse(accountBlock.contains("Toggle(\"Automatic Backup\", isOn: automaticBackupBinding)"))
        XCTAssertTrue(accountBlock.contains("Lava waits 30 minutes after your last settings change before it tries an automatic upload."))
        XCTAssertFalse(accountBlock.contains("LavaDetailRow(\n                            systemImage: \"lock.shield\""))

        // Clear/Disable backup maintenance panel: a destructive pair styled like
        // "Delete Local Logs" (trash glyph + red), gated behind a confirmation
        // dialog, placed after the Automatic Backup control.
        XCTAssertTrue(accountBlock.contains("backupMaintenanceButton(.clear)"))
        XCTAssertTrue(accountBlock.contains("backupMaintenanceButton(.disable)"))
        XCTAssertTrue(accountBlock.contains("iconTint: .red, titleTint: .red"))
        XCTAssertTrue(accountBlock.contains("Image(systemName: \"trash\")"))
        XCTAssertTrue(accountBlock.contains("Disabling backup also permanently deletes the copy stored for your account."))
        XCTAssertTrue(accountBlock.containsInOrder([
            "title: \"Automatic Backup\"",
            "backupMaintenanceButton(.clear)",
            "backupMaintenanceButton(.disable)"
        ]))

        let optionControlBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct BackupOptionControl: View",
            endingBefore: "private struct AppleSignInStatusIcon: View"
        )
        XCTAssertTrue(optionControlBlock.containsInOrder([
            "LavaPlainCard",
            "Toggle(title, isOn: isOn)",
            "Text(detail)",
            ".lavaQuietNoteText()"
        ]))
    }

    func testEncryptedBackupStateRecordsLastUploadAndSchedulesAutomaticBackupAfterChanges() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        // EncryptedBackupState moved to LavaSecCore (its copy + state derivation
        // are now covered behaviorally by EncryptedBackupStateTests); pin the
        // synced-case shape and timestamp formatting against the core file.
        let stateSource = try Self.source(named: "EncryptedBackupState.swift", in: "Sources/LavaSecCore")
        let preferenceBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func setAutomaticBackupEnabled",
            endingBefore: "var dnsResolverSummaryText: String"
        )
        let uploadBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func uploadEncryptedBackup(",
            endingBefore: "private func uploadPendingEncryptedBackupIfPossible()"
        )

        XCTAssertTrue(stateSource.contains("case synced(estimatedByteSize: Int, uploadedAt: Date)"))
        XCTAssertTrue(stateSource.contains("LocalLogTimestampFormatter.string(from: uploadedAt)"))
        XCTAssertTrue(source.contains("@Published private(set) var isAutomaticBackupEnabled"))
        XCTAssertTrue(source.contains("private var automaticBackupTask: Task<Void, Never>?"))
        XCTAssertTrue(source.contains("private let automaticBackupDelay: UInt64 = 30 * 60 * 1_000_000_000"))
        XCTAssertTrue(source.contains("scheduleAutomaticBackupAfterConfigurationChange()"))
        XCTAssertTrue(source.contains("try? await Task.sleep(nanoseconds: automaticBackupDelay)"))
        XCTAssertTrue(preferenceBlock.contains("UserDefaults.standard.set(isEnabled, forKey: automaticBackupEnabledDefaultsKey)"))
        XCTAssertFalse(preferenceBlock.contains("scheduleAutomaticBackupAfterConfigurationChange()"))
        XCTAssertTrue(uploadBlock.contains("recordEncryptedBackupUpload(uploadedAt:"))
    }

    func testBugReportUsesGenericResolverNameInsteadOfCustomDisplayName() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let bugReportBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func makeBugReportBundle(context: BugReportContext) -> BugReportBundle",
            endingBefore: "private func submitBugReport"
        )

        XCTAssertTrue(bugReportBlock.contains("resolverPreset: configuration.resolverDiagnosticDisplayName"))
        XCTAssertFalse(bugReportBlock.contains("resolverPreset: configuration.resolverPreset.displayName"))
    }

    func testPrivacyDataShowsKeepLocalLogsSectionAndInfoPanel() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let privacyBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct PrivacyDataSettingsView: View",
            endingBefore: "private enum LocalLogSetting"
        )

        XCTAssertTrue(privacyBlock.contains("LavaSectionGroup(\"Local Logs\")"))
        XCTAssertTrue(privacyBlock.contains("title: \"All local logs stay on this iPhone\""))
        XCTAssertTrue(privacyBlock.contains("description: \"Counts, domain history, network activity and Lava Guard progress can be kept or cleared independently\""))
        XCTAssertTrue(privacyBlock.contains("localLogToggle(\"Filtering Counts\", isOn: keepFilteringCountsBinding)"))
        XCTAssertTrue(privacyBlock.contains("localLogToggle(\"Domain History\", isOn: keepDomainHistoryBinding)"))
        XCTAssertTrue(privacyBlock.contains("localLogToggle(\"Network Activity\", isOn: keepNetworkActivityBinding)"))
        XCTAssertTrue(privacyBlock.contains("localLogToggle(\"Lava Guard Progress\", isOn: keepLavaGuardProgressBinding)"))
        XCTAssertTrue(privacyBlock.contains("ExportLocalLogsRow()"))
        XCTAssertTrue(privacyBlock.contains("Text(\"Export Local Logs\".lavaLocalized)"))
        XCTAssertTrue(privacyBlock.contains("Image(systemName: \"square.and.arrow.up\")"))
        XCTAssertTrue(privacyBlock.contains(".font(.headline.weight(.semibold))"))
        XCTAssertTrue(privacyBlock.contains(".foregroundStyle(.tertiary)"))
        XCTAssertFalse(privacyBlock.contains("SettingsActionRow(title: \"Export local logs\")"))
        XCTAssertTrue(privacyBlock.contains(".fileExporter("))
        XCTAssertTrue(privacyBlock.contains("contentType: .zip"))
        XCTAssertFalse(privacyBlock.contains("Button(\"Download\")"))
        XCTAssertFalse(privacyBlock.contains("Toggle(\"Keep local filtering counts\""))
        XCTAssertFalse(privacyBlock.contains("Toggle(\"Keep local domain history\""))
        XCTAssertFalse(privacyBlock.contains("Toggle(\"Keep local network activity\""))
        XCTAssertFalse(privacyBlock.contains("\"Privacy Promise\""))
        XCTAssertFalse(privacyBlock.contains("privacyPromiseFooter"))
        XCTAssertFalse(privacyBlock.contains("title: \"Filtering happens locally\""))
    }

    func testPrivacyDataShowsInlineClearOptionsBehindToggle() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let privacyBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct PrivacyDataSettingsView: View",
            endingBefore: "private enum LocalLogSetting"
        )

        XCTAssertTrue(privacyBlock.contains("LavaSectionGroup(\"Delete Local Logs\")"))
        XCTAssertTrue(privacyBlock.contains("Toggle(\"Show Delete Options\", isOn: $showsClearOptions)"))
        XCTAssertTrue(privacyBlock.contains("VStack(spacing: 10)"))
        XCTAssertTrue(privacyBlock.contains("if showsClearOptions {\n                        VStack(spacing: 10) {"))
        XCTAssertTrue(privacyBlock.contains("if showsClearOptions"))
        XCTAssertTrue(source.contains("private enum LocalLogSettingsRowMetrics"))
        XCTAssertTrue(source.contains("static let groupedRowSpacing: CGFloat = 14"))
        XCTAssertTrue(source.contains("static let rowMinHeight: CGFloat = 32"))
        XCTAssertTrue(privacyBlock.contains("VStack(spacing: LocalLogSettingsRowMetrics.groupedRowSpacing)"))
        XCTAssertTrue(privacyBlock.contains("localLogToggle(\"Filtering Counts\", isOn: keepFilteringCountsBinding)"))
        XCTAssertTrue(privacyBlock.containsInOrder([
            "localLogClearButton(.filteringCounts)",
            "localLogClearButton(.domainHistory)",
            "localLogClearButton(.networkActivity)",
            "localLogClearButton(.lavaGuardProgress)",
            "localLogClearButton(.all)"
        ]))
        XCTAssertTrue(privacyBlock.contains("localLogClearButton(.all)"))
        XCTAssertTrue(privacyBlock.contains(".frame(minHeight: LocalLogSettingsRowMetrics.rowMinHeight)"))
        XCTAssertFalse(privacyBlock.contains("topPadding:"))
        XCTAssertFalse(privacyBlock.contains("bottomPadding:"))
        XCTAssertTrue(source.contains("return \"Clear filtering counts\""))
        XCTAssertTrue(source.contains("return \"Clear domain history\""))
        XCTAssertTrue(source.contains("return \"Clear network activity\""))
        XCTAssertTrue(source.contains("return \"Clear all logs\""))
        XCTAssertTrue(source.contains("return \"Clear filtering counts?\""))
        XCTAssertTrue(source.contains("return \"Clear domain history?\""))
        XCTAssertTrue(source.contains("return \"Clear network activity?\""))
        XCTAssertTrue(source.contains("return \"Clear all logs?\""))
        XCTAssertFalse(source.contains("return \"Clear local filtering counts\""))
        XCTAssertFalse(source.contains("return \"Clear local domain history\""))
        XCTAssertFalse(source.contains("return \"Clear local network activity\""))
        XCTAssertFalse(source.contains("return \"Clear all local logs\""))
        XCTAssertFalse(privacyBlock.contains("SettingsNavigationRow("))
        XCTAssertFalse(privacyBlock.contains("route: .clearLocalLogs"))
        XCTAssertFalse(source.contains("private struct ClearLocalLogsSettingsView"))
        XCTAssertFalse(source.contains("case clearLocalLogs"))
    }

    func testPrivacyDataSettingsSummaryNamesEnabledLocalLogs() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let localLogsBlock = try Self.sourceBlock(
            in: source,
            startingAt: "var localLogsStatusText: String",
            endingBefore: "var planStatusText: String"
        )

        XCTAssertTrue(localLogsBlock.contains("return \"All local logs on\""))
        XCTAssertTrue(localLogsBlock.contains("let enabledLogNames"))
        XCTAssertTrue(localLogsBlock.contains("\"counts\""))
        XCTAssertTrue(localLogsBlock.contains("\"domain history\""))
        XCTAssertTrue(localLogsBlock.contains("\"network activity\""))
        XCTAssertTrue(localLogsBlock.contains("\"Lava Guard progress\""))
        XCTAssertTrue(localLogsBlock.contains("let totalCount = 4"))
        XCTAssertTrue(localLogsBlock.contains("let displayedSummary = enabledSummary.prefix(1).uppercased() + enabledSummary.dropFirst()"))
        XCTAssertTrue(localLogsBlock.contains("return \"\\(displayedSummary) on\""))
        XCTAssertFalse(localLogsBlock.contains("return \"Local logs on\""))
    }

    func testDNSResolverSettingsShowsBaseResolversAndTransportSelectorOnly() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let resolverBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct DNSResolverSettingsView: View",
            endingBefore: "private struct ResolverSelectionIndicator: View"
        )

        XCTAssertTrue(resolverBlock.contains("LavaSectionGroup(\"Device DNS\")"))
        XCTAssertTrue(resolverBlock.contains("Toggle(\"Use Device DNS Setting\", isOn: useDeviceDNSBinding)"))
        XCTAssertTrue(resolverBlock.contains("viewModel.deviceDNSResolverDetailText"))
        XCTAssertTrue(resolverBlock.contains("if !usesDeviceDNSSetting"))
        XCTAssertTrue(resolverBlock.contains("DNSResolverPreset.settingsPresets.filter { $0.id != DNSResolverPreset.device.id }"))
        XCTAssertTrue(resolverBlock.contains("isSelected: isCustomResolverSelected"))
        XCTAssertTrue(resolverBlock.contains("isEditingCustomResolver || viewModel.configuration.resolverPresetID == DNSResolverPreset.customID"))
        XCTAssertTrue(resolverBlock.contains(".onDisappear(perform: resetCustomResolverDrafts)"))
        XCTAssertTrue(resolverBlock.contains("LavaSectionGroup(\"DNS Providers\")"))
        XCTAssertTrue(resolverBlock.contains("@Environment(\\.dismiss) private var dismiss"))
        XCTAssertTrue(resolverBlock.contains("@FocusState private var focusedCustomResolverField: CustomResolverFocusField?"))
        XCTAssertTrue(resolverBlock.contains("@State private var customResolverSecondaryDraft = \"\""))
        XCTAssertTrue(resolverBlock.contains("@State private var showingCustomResolverDiscardConfirmation = false"))
        XCTAssertTrue(resolverBlock.contains("@State private var pendingCustomResolverDiscardAction: CustomResolverDiscardAction?"))
        XCTAssertTrue(resolverBlock.contains("@State private var customResolverValidationMessage: String?"))
        XCTAssertTrue(resolverBlock.contains("if showsResolverOptions"))
        XCTAssertTrue(resolverBlock.contains("DNS Transport"))
        XCTAssertTrue(resolverBlock.contains("LavaSectionGroup(\"DNS Transport\")"))
        XCTAssertTrue(resolverBlock.contains("Picker(\"DNS Transport\""))
        XCTAssertTrue(resolverBlock.contains("ForEach(selectedBaseResolver.availableTransports"))
        XCTAssertTrue(resolverBlock.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(resolverBlock.contains("resolverTransportBinding"))
        XCTAssertTrue(resolverBlock.contains("transportDetailText"))
        XCTAssertTrue(resolverBlock.contains("LavaSectionGroup(\"Custom Resolver\")"))
        XCTAssertFalse(resolverBlock.contains("LavaSectionGroup(\"Custom DNS\")"))
        XCTAssertTrue(resolverBlock.contains("CustomResolverTextField("))
        XCTAssertTrue(resolverBlock.contains("title: \"Name (optional)\""))
        XCTAssertTrue(resolverBlock.contains("focus: $focusedCustomResolverField"))
        XCTAssertTrue(resolverBlock.contains("focusField: .name"))
        XCTAssertTrue(resolverBlock.contains("title: \"Primary DNS\""))
        XCTAssertTrue(resolverBlock.contains("placeholder: \"IPv4/6, https://, tls://, doq://, quic://, or sdns://\""))
        XCTAssertTrue(resolverBlock.containsInOrder([
            "title: \"Primary DNS\"",
            "placeholder: \"IPv4/6, https://, tls://, doq://, quic://, or sdns://\"",
            "text: $customResolverDraft",
            "keyboardType: .URL",
            "axis: .vertical",
            "focus: $focusedCustomResolverField",
            "focusField: .primaryAddress"
        ]))
        XCTAssertTrue(resolverBlock.contains("focusField: .primaryAddress"))
        XCTAssertTrue(resolverBlock.contains("title: \"Secondary DNS (optional)\""))
        XCTAssertTrue(resolverBlock.contains("placeholder: \"Same transport as Primary\""))
        XCTAssertTrue(resolverBlock.containsInOrder([
            "title: \"Secondary DNS (optional)\"",
            "placeholder: \"Same transport as Primary\"",
            "text: $customResolverSecondaryDraft",
            "keyboardType: .URL",
            "axis: .vertical",
            "focus: $focusedCustomResolverField",
            "focusField: .secondaryAddress"
        ]))
        XCTAssertTrue(resolverBlock.contains("focusField: .secondaryAddress"))
        XCTAssertTrue(resolverBlock.contains("axis: .vertical"))
        XCTAssertTrue(resolverBlock.contains(".lineLimit(1...3)"))
        XCTAssertTrue(resolverBlock.contains("onChange: updateCustomResolverNameDraft"))
        XCTAssertTrue(resolverBlock.contains("onChange: updateCustomResolverDraft"))
        XCTAssertTrue(resolverBlock.contains("onChange: updateCustomResolverSecondaryDraft"))
        XCTAssertTrue(resolverBlock.contains("HStack(spacing: 12)"))
        XCTAssertTrue(resolverBlock.contains("Button(action: clearCustomResolverDrafts)"))
        XCTAssertTrue(resolverBlock.contains("Text(\"Clear\".lavaLocalized)"))
        XCTAssertTrue(resolverBlock.contains("Button(action: saveCustomResolver)"))
        XCTAssertTrue(resolverBlock.contains("Text(customResolverSaveButtonTitle.lavaLocalized)"))
        XCTAssertTrue(resolverBlock.contains(".buttonStyle(CustomResolverSaveButtonStyle(isSaved: customResolverSaveButtonTitle == \"Saved\"))"))
        XCTAssertTrue(resolverBlock.contains(".disabled(!canSaveCustomResolver)"))
        XCTAssertTrue(resolverBlock.contains(".navigationBarBackButtonHidden(customResolverBackButtonIsVisible)"))
        XCTAssertTrue(resolverBlock.contains("if customResolverBackButtonIsVisible"))
        XCTAssertTrue(resolverBlock.contains("NativeToolbarIconButton(systemName: \"chevron.left\", accessibilityLabel: \"Back\", action: requestCustomResolverDismiss)"))
        XCTAssertTrue(resolverBlock.contains(".alert(\"Discard custom DNS changes?\", isPresented: $showingCustomResolverDiscardConfirmation)"))
        XCTAssertTrue(resolverBlock.contains("Button(\"Cancel\", role: .cancel)"))
        XCTAssertTrue(resolverBlock.contains("Button(\"Discard\", role: .destructive)"))
        XCTAssertTrue(resolverBlock.contains("Text(\"Your custom DNS draft will be removed.\")"))
        XCTAssertTrue(resolverBlock.contains("private enum CustomResolverDiscardAction"))
        XCTAssertTrue(resolverBlock.contains("private var customResolverBackButtonIsVisible: Bool"))
        XCTAssertTrue(resolverBlock.contains("private var customResolverDraftMatchesSavedEntry: Bool"))
        XCTAssertTrue(resolverBlock.contains("private var customResolverHasUnsavedDraft: Bool"))
        XCTAssertTrue(resolverBlock.contains("if let customResolverValidationMessage"))
        XCTAssertTrue(resolverBlock.contains("DomainRejectPanel(title: \"Custom DNS cannot be saved\", message: customResolverValidationMessage)"))
        XCTAssertTrue(resolverBlock.contains("private var trimmedCustomResolverSecondaryDraft: String"))
        XCTAssertTrue(resolverBlock.contains("private var normalizedConfiguredCustomResolverSecondaryAddress: String"))
        XCTAssertTrue(resolverBlock.contains("private var customResolverSaveButtonTitle: String"))
        XCTAssertTrue(resolverBlock.contains("private var customResolverDraftIsCleared: Bool"))
        XCTAssertTrue(resolverBlock.contains("private var customResolverClearFallbackPreset: DNSResolverPreset"))
        XCTAssertFalse(resolverBlock.contains("return \"Unsupported URL\""))
        XCTAssertTrue(resolverBlock.contains("return \"Saved\""))
        XCTAssertTrue(resolverBlock.contains("private func saveCustomResolver()"))
        XCTAssertTrue(resolverBlock.contains("DNSResolverPreset.customValidationMessage("))
        XCTAssertTrue(resolverBlock.contains("primaryRawValue: trimmedCustomResolverDraft"))
        XCTAssertTrue(resolverBlock.contains("secondaryRawValue: trimmedCustomResolverSecondaryDraft"))
        XCTAssertTrue(resolverBlock.contains("supportsDNSOverQUIC: viewModel.supportsDNSOverQUIC"))
        XCTAssertTrue(resolverBlock.contains("customResolverValidationMessage = validationMessage"))
        XCTAssertTrue(resolverBlock.contains("customResolverValidationMessage = nil"))
        XCTAssertTrue(resolverBlock.contains("viewModel.setCustomResolverAddresses(primary: trimmedValue, secondary: trimmedSecondaryValue)"))
        XCTAssertTrue(resolverBlock.contains("viewModel.clearCustomResolver(fallback: customResolverClearFallbackPreset)"))
        XCTAssertTrue(resolverBlock.contains("private func clearCustomResolverDrafts()"))
        XCTAssertTrue(resolverBlock.contains("private func requestCustomResolverDiscard(for action: CustomResolverDiscardAction)"))
        XCTAssertTrue(resolverBlock.contains("requestCustomResolverDiscard(for: .selectResolver(preset))"))
        XCTAssertTrue(resolverBlock.contains("private func discardPendingCustomResolverDraft()"))
        XCTAssertTrue(resolverBlock.contains("focusedCustomResolverField = nil"))
        XCTAssertTrue(resolverBlock.contains(".onSubmit {"))
        XCTAssertTrue(resolverBlock.contains("focus.wrappedValue = nil"))
        XCTAssertTrue(resolverBlock.contains("private struct CustomResolverSaveButtonStyle: ButtonStyle"))
        XCTAssertTrue(resolverBlock.contains("LavaStyle.quietControl"))
        XCTAssertTrue(resolverBlock.contains("LavaSectionGroup(\"DNS Fallback\")"))
        XCTAssertTrue(resolverBlock.contains("Fallback to Device DNS"))
        XCTAssertTrue(resolverBlock.contains("Same transport as Primary"))
        XCTAssertTrue(resolverBlock.contains("fallbackToDeviceDNSBinding"))
        XCTAssertTrue(resolverBlock.contains("ResolverOptionControl("))
        XCTAssertTrue(resolverBlock.contains("ResolverTransportControl("))
        XCTAssertTrue(resolverBlock.contains(".lavaQuietNoteText()"))
        XCTAssertTrue(resolverBlock.contains("IP uses standard DNS. DNS over HTTPS (DoH), TLS (DoT), and QUIC (DoQ) encrypt allowed lookups to the resolver."))
        XCTAssertTrue(resolverBlock.containsInOrder([
            "LavaSectionGroup(\"Device DNS\")",
            "if !usesDeviceDNSSetting",
            "LavaSectionGroup(\"DNS Providers\")",
            "LavaSectionGroup(\"Custom Resolver\")",
            "LavaSectionGroup(\"DNS Transport\")",
            "detail: transportDetailText",
            "LavaSectionGroup(\"DNS Fallback\")",
            "title: \"Fallback to Device DNS\"",
            "detail: viewModel.deviceDNSFallbackDetailText"
        ]))
        XCTAssertFalse(resolverBlock.contains("Use DNS over HTTPS"))
        XCTAssertFalse(resolverBlock.contains("dnsOverHTTPSBinding"))
        XCTAssertFalse(resolverBlock.contains("onChange: applyCustomResolverName"))
        XCTAssertFalse(resolverBlock.contains("onChange: applyCustomResolverIfValid"))
        XCTAssertFalse(resolverBlock.contains(".onDisappear(perform: commitCustomResolverDrafts)"))
        XCTAssertFalse(resolverBlock.contains("commitCustomResolverDrafts"))
        XCTAssertFalse(resolverBlock.contains("applyCustomResolverIfValid"))
        XCTAssertFalse(resolverBlock.contains("applyCustomResolverName"))
        XCTAssertFalse(resolverBlock.contains("let draftValue = customResolverDraft.isEmpty ? configuredValue : customResolverDraft"))
        XCTAssertFalse(resolverBlock.contains("if preset.id == DNSResolverPreset.device.id"))
        XCTAssertFalse(resolverBlock.contains("if !trimmedCustomResolverDraft.isEmpty && !customResolverDraftIsValid"))
        XCTAssertFalse(resolverBlock.contains("title: \"Custom IP/URL\""))
        XCTAssertFalse(resolverBlock.contains("LavaSectionGroup(\n                \"Resolver\""))
        XCTAssertFalse(resolverBlock.contains("Lava makes block decisions locally."))
        XCTAssertFalse(resolverBlock.contains("Rows marked (DoH)"))

        let customTextFieldBlock = try Self.sourceBlock(
            in: resolverBlock,
            startingAt: "private struct CustomResolverTextField: View",
            endingBefore: "private struct ResolverTransportControl: View"
        )
        XCTAssertTrue(customTextFieldBlock.contains("var axis: Axis = .horizontal"))
        XCTAssertTrue(customTextFieldBlock.contains("TextField(placeholder.lavaLocalized, text: $text, axis: axis)"))
        XCTAssertTrue(customTextFieldBlock.contains(".lavaTextInputBody(keyboardType: keyboardType, axis: axis)"))
        XCTAssertTrue(customTextFieldBlock.contains(".lineLimit(1...3)"))
        XCTAssertFalse(customTextFieldBlock.contains("isMultiline"))
        XCTAssertFalse(customTextFieldBlock.contains("TextEditor(text: $text)"))

        let resolverSummaryBlock = try Self.sourceBlock(
            in: resolverBlock,
            startingAt: "private func resolverAddressSummary",
            endingBefore: "private enum CustomResolverDiscardAction"
        )
        XCTAssertTrue(resolverSummaryBlock.contains("let doqEndpointAddresses = preset.doqEndpoints.map(\\.displayAddress)"))
        XCTAssertTrue(resolverSummaryBlock.contains("return doqEndpointAddresses.joined(separator: \", \")"))

        let canSaveBlock = try Self.sourceBlock(
            in: resolverBlock,
            startingAt: "private var canSaveCustomResolver: Bool",
            endingBefore: "private var canClearCustomResolver: Bool"
        )
        XCTAssertTrue(canSaveBlock.contains("customResolverDraftIsCleared"))
        XCTAssertFalse(canSaveBlock.contains("customResolverDraftIsValid"))

        let clearDraftsBlock = try Self.sourceBlock(
            in: resolverBlock,
            startingAt: "private func clearCustomResolverDrafts()",
            endingBefore: "private func requestCustomResolverDismiss()"
        )
        XCTAssertFalse(clearDraftsBlock.contains("focusedCustomResolverField = nil"))

        let toggleRowBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct ResolverToggleRow: View",
            endingBefore: "private struct ResolverOptionControl: View"
        )
        XCTAssertFalse(toggleRowBlock.contains("let detail: String"))
        XCTAssertFalse(toggleRowBlock.contains("Text(detail)"))

        let optionControlBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct ResolverOptionControl: View",
            endingBefore: "private struct ResolverSelectionIndicator: View"
        )
        XCTAssertTrue(optionControlBlock.containsInOrder([
            "LavaPlainCard",
            "ResolverToggleRow",
            "Text(detail)",
            ".lavaQuietNoteText()"
        ]))

        let transportControlBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct ResolverTransportControl: View",
            endingBefore: "private struct ResolverOptionControl: View"
        )
        XCTAssertTrue(transportControlBlock.contains("Picker(\"DNS Transport\""))
        XCTAssertTrue(transportControlBlock.contains("Text(transport.menuTitle.lavaLocalized)"))
        XCTAssertTrue(transportControlBlock.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(transportControlBlock.contains("Text(detail)"))
        XCTAssertTrue(transportControlBlock.contains(".lavaQuietNoteText()"))
        XCTAssertFalse(transportControlBlock.contains("Text(title)"))
    }

    func testCustomResolverNameChangesPersistWithoutReloadingTunnel() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let nameBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func setCustomResolverName(_ rawValue: String)",
            endingBefore: "private func persistResolverSettings"
        )

        XCTAssertTrue(nameBlock.contains("try persistConfigurationOnly()"))
        XCTAssertFalse(nameBlock.contains("persistResolverSettings(activity: .changeResolver)"))
        XCTAssertFalse(nameBlock.contains("sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)"))
    }

    func testDNSResolverSummaryUsesShortFallbackCopy() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let summaryBlock = try Self.sourceBlock(
            in: source,
            startingAt: "var dnsResolverSummaryText: String",
            endingBefore: "var deviceDNSFallbackDetailText: String"
        )

        XCTAssertTrue(summaryBlock.contains("+ Fallback"))
        XCTAssertFalse(summaryBlock.contains("+ Device fallback"))
        XCTAssertFalse(summaryBlock.contains("+ Device Fallback"))
    }

    func testDNSResolverCatalogAddsDNSSBBaseAndEncryptedVariants() throws {
        XCTAssertEqual(DNSResolverPreset.settingsPresets.map(\.id), [
            "device-dns",
            "google-public-dns",
            "cloudflare-1111",
            "quad9-secure",
            "dns-sb"
        ])
        XCTAssertEqual(DNSResolverPreset.dnsSB.ipv4Servers, ["185.222.222.222", "45.11.45.11"])
        XCTAssertEqual(DNSResolverPreset.dnsSB.ipv6Servers, ["2a09::", "2a11::"])
        XCTAssertEqual(DNSResolverPreset.dnsSBDoH.dohEndpoint?.url.absoluteString, "https://doh.dns.sb/dns-query")
        XCTAssertEqual(DNSResolverPreset.dnsSBDoT.dotEndpoint?.hostname, "dot.sb")
    }

    func testResolverPresetMapsTransportSelectorToBaseSelection() throws {
        XCTAssertEqual(DNSResolverPreset.googleDoH.settingsBasePreset, .google)
        XCTAssertEqual(DNSResolverPreset.cloudflareDoH.settingsBasePreset, .cloudflare)
        XCTAssertEqual(DNSResolverPreset.quad9SecureDoH.settingsBasePreset, .quad9Secure)
        XCTAssertEqual(DNSResolverPreset.dnsSBDoH.settingsBasePreset, .dnsSB)
        XCTAssertEqual(DNSResolverPreset.googleDoT.settingsBasePreset, .google)
        XCTAssertEqual(DNSResolverPreset.cloudflareDoT.settingsBasePreset, .cloudflare)
        XCTAssertEqual(DNSResolverPreset.quad9SecureDoT.settingsBasePreset, .quad9Secure)
        XCTAssertEqual(DNSResolverPreset.dnsSBDoT.settingsBasePreset, .dnsSB)
        XCTAssertEqual(DNSResolverPreset.dnsSB.dnsOverHTTPSVariant, .dnsSBDoH)
        XCTAssertEqual(DNSResolverPreset.dnsSB.dnsOverTLSVariant, .dnsSBDoT)
        XCTAssertEqual(DNSResolverPreset.dnsSBDoH.plainDNSVariant, .dnsSB)
        XCTAssertEqual(DNSResolverPreset.dnsSB.resolverVariant(for: .plainDNS), .dnsSB)
        XCTAssertEqual(DNSResolverPreset.dnsSB.resolverVariant(for: .dnsOverHTTPS), .dnsSBDoH)
        XCTAssertEqual(DNSResolverPreset.dnsSB.resolverVariant(for: .dnsOverTLS), .dnsSBDoT)
        XCTAssertEqual(DNSResolverPreset.dnsSB.availableTransports, [.plainDNS, .dnsOverHTTPS, .dnsOverTLS])
    }

    func testDomainHistoryAddsPullToRefreshUsingActivitySampling() throws {
        let source = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let domainBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        XCTAssertTrue(domainBlock.contains("refreshAction: {"))
        XCTAssertTrue(domainBlock.contains("await viewModel.sampleReports()"))
        XCTAssertFalse(domainBlock.contains("refreshCopy:"))
    }

    func testScreenContentUsesNativeRefreshableInsteadOfCustomPullRefresh() throws {
        let source = try Self.source(named: "LavaScaffold.swift", in: "LavaSecApp/LavaDesignSystem")
        let screenContentBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct LavaScreenContent<Content: View>: View",
            endingBefore: "struct LavaSheetScaffold"
        )

        XCTAssertTrue(screenContentBlock.contains(".refreshable {"))
        XCTAssertTrue(screenContentBlock.contains("await refreshAction()"))
        XCTAssertTrue(screenContentBlock.contains(".scrollBounceBehavior(.always, axes: .vertical)"))
        XCTAssertTrue(screenContentBlock.contains(".scrollDismissesKeyboard(.interactively)"))
        XCTAssertFalse(screenContentBlock.contains(".scrollBounceBehavior(.basedOnSize, axes: .vertical)"))
        XCTAssertFalse(source.contains("LavaPullRefreshCopy"))
        XCTAssertFalse(source.contains("LavaPullRefreshScrollView"))
        XCTAssertFalse(source.contains("LavaFixedPullRefreshSurface"))
        XCTAssertFalse(source.contains("LavaPullRefreshIndicator"))
        XCTAssertFalse(source.contains("copy.completedText"))
        XCTAssertFalse(source.contains("DragGesture(minimumDistance: 8)"))
        XCTAssertFalse(source.contains("DragGesture(minimumDistance: 0)"))
    }

    func testDNSResolverRowsUseTransportAddressesAndCondensedCustomRow() throws {
        let source = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let resolverBlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct DNSResolverSettingsView: View",
            endingBefore: "private struct ResolverToggleRow: View"
        )
        let customRowBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct CustomDNSResolverRow: View",
            endingBefore: "private struct ResolverToggleRow: View"
        )

        XCTAssertTrue(resolverBlock.contains("metadata: metadata(for: preset)"))
        XCTAssertTrue(resolverBlock.contains("private func displayPreset(for preset: DNSResolverPreset) -> DNSResolverPreset"))
        XCTAssertTrue(resolverBlock.contains("private func resolverAddressSummary(for preset: DNSResolverPreset) -> String"))
        XCTAssertTrue(resolverBlock.contains("private var selectedTransport: DNSResolverTransport"))
        XCTAssertTrue(resolverBlock.contains("let dohEndpointAddresses = preset.dohEndpoints.map { $0.url.absoluteString }"))
        XCTAssertTrue(resolverBlock.contains("return dohEndpointAddresses.joined(separator: \", \")"))
        XCTAssertTrue(resolverBlock.contains("let dotEndpointAddresses = preset.dotEndpoints.map(\\.displayAddress)"))
        XCTAssertTrue(resolverBlock.contains("return dotEndpointAddresses.joined(separator: \", \")"))
        XCTAssertTrue(resolverBlock.contains("let servers = preset.allServers"))
        XCTAssertTrue(resolverBlock.contains("return servers.joined(separator: \", \")"))
        XCTAssertTrue(resolverBlock.contains("return \"Supports DNS over IP, HTTPS, TLS and QUIC\""))
        XCTAssertFalse(resolverBlock.contains("return \"DNS over IP, HTTPS, TLS or QUIC\""))
        XCTAssertFalse(resolverBlock.contains("return \"Use your own resolver\""))
        XCTAssertFalse(resolverBlock.contains("return preset.notes"))
        XCTAssertTrue(customRowBlock.contains("Text(\"Custom DNS\".lavaLocalized)"))
        XCTAssertTrue(customRowBlock.contains("if isEnabled"))
        XCTAssertTrue(customRowBlock.contains("Text(metadata.lavaLocalized)"))
        XCTAssertTrue(customRowBlock.contains("Text(\"Upgrade\".lavaLocalized)"))
        XCTAssertTrue(customRowBlock.contains(".font(.caption.weight(.bold))"))
        XCTAssertTrue(customRowBlock.contains(".foregroundStyle(LavaStyle.safeGreen)"))
        XCTAssertTrue(customRowBlock.contains("Text(\" to use DNS over HTTPS, TLS and QUIC\".lavaLocalized)"))
        XCTAssertFalse(customRowBlock.contains("metadata: metadata"))
        XCTAssertFalse(customRowBlock.contains("isInactive: !isEnabled"))
        XCTAssertFalse(customRowBlock.contains(".font(.subheadline.weight(.semibold))"))
        XCTAssertFalse(customRowBlock.contains("Text(\"Use your own resolver.\")"))
    }

    private static func source(named fileName: String, in directoryName: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL
            .appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func sourceBlock(
        in source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        guard endMarker != "*** end ***" else {
            return String(suffix)
        }
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)

        return String(suffix[..<end])
    }
}

private extension String {
    func containsInOrder(_ needles: [String]) -> Bool {
        var searchRange = startIndex..<endIndex

        for needle in needles {
            guard let range = range(of: needle, range: searchRange) else {
                return false
            }
            searchRange = range.upperBound..<endIndex
        }

        return true
    }

    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
