import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class SettingsFeedbackSourceTests: XCTestCase {
    func testTopicSelectionSuppressesOnlyItsStateAndSymbolAnimation() throws {
        let source = try readSource(.bugReportSettingsView)
        let selection = try sourceBlock(in: source, startingAt: "private func selectIssueType(", endingBefore: "private func requestDismiss(")
        XCTAssertTrue(selection.contains("Transaction(animation: nil)"))
        XCTAssertTrue(selection.contains("transaction.disablesAnimations = true"))
        XCTAssertTrue(selection.contains("withTransaction(transaction)"))
        let row = try sourceBlock(in: source, startingAt: "private struct BugReportTopicOptionRow:", endingBefore: "private struct BugReportReviewRow:")
        XCTAssertTrue(row.contains("LavaSelectableRow(state: isSelected ? .selected : .unselected)"))
        XCTAssertTrue(row.contains(".lavaRowTitleText()"))
        XCTAssertFalse(row.contains(".id(isSelected)"))
    }

    func testNetworkPrivacyActionBelongsToTheSharedPanelAndKeepsItsAccessibility() throws {
        let source = try readSource(.lavaComponents)
        let panel = try sourceBlock(in: source, startingAt: "struct LavaInfoPanel: View")
        XCTAssertTrue(panel.contains("@ViewBuilder action: () -> Action"))
        XCTAssertTrue(panel.containsInOrder([".accessibilityElement(children: .combine)", "if let action { action }"]))
    }

    func testRejectPanelUsesLavaOrangeBorderWhileInfoPanelKeepsDefaultBorder() throws {
        let rootSource = try readSource(.lavaComponents)
        let reviewSource = try readSource(.filterReviewFlowView)
        let infoPanelBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct LavaInfoPanel: View"
        )
        let rejectPanelBlock = try sourceBlock(
            in: reviewSource,
            startingAt: "struct DomainRejectPanel: View",
            endingBefore: "struct DiffGroup: View"
        )

        XCTAssertTrue(infoPanelBlock.contains("var borderTint: Color? = nil"))
        XCTAssertTrue(infoPanelBlock.contains("borderTint: borderTint"))
        XCTAssertTrue(rejectPanelBlock.contains("borderTint: LavaStyle.lavaOrange"))
    }

    func testSharedMultilineTextInputAlignsFreeformContentWithRowLabel() throws {
        let rootSource = try readSource(.lavaComponents)
        let editorRowBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct LavaTextEditorInputRow: View",
            endingBefore: "extension View"
        )

        XCTAssertTrue(editorRowBlock.contains("LavaTextInputRow(title: title)"))
        XCTAssertTrue(editorRowBlock.contains("TextEditor(text: $text)"))
        XCTAssertTrue(editorRowBlock.contains(".padding(.leading, -5)"))
        XCTAssertFalse(editorRowBlock.contains(".padding(.leading, 5)"))
    }

    func testSettingsRootIsReactOwnedAndDropsFreeProtectionPanel() throws {
        let source = try readSource(.reactNativeSettingsScreens)
        let rootSource = try readSource(.rootView)
        let settingsBlock = try sourceBlock(
            in: source,
            startingAt: "export function SettingsScreen()",
            endingBefore: "export function AccountScreen()"
        )

        XCTAssertTrue(settingsBlock.contains("return <Screen wide>"))
        XCTAssertTrue(rootSource.contains("LavaAppHost()"))
        XCTAssertFalse(rootSource.contains("TabView(selection: guardedRootTabSelection)"))
        XCTAssertFalse(settingsBlock.contains("Free protection is available without an account."))
    }

    func testSupportRowsUseHelpAndFeedbackCopy() throws {
        let source = try readSource(.reactNativeSettingsScreens)
        let settingsBlock = try sourceBlock(
            in: source,
            startingAt: "<SettingsGroup title=\"Support\">",
            endingBefore: "</SettingsGroup>"
        )

        XCTAssertTrue(settingsBlock.containsInOrder([
            "title=\"Help\"",
            "title=\"Feedback\"",
            "title=\"Legal Notices\""
        ]))
        XCTAssertFalse(settingsBlock.contains("Submit Bug Report"))
        XCTAssertFalse(settingsBlock.contains("Fix a site or learn how Lava works"))
        XCTAssertFalse(settingsBlock.contains("Third-party names and source credits"))
    }

    func testVersionNerdStatsAppSectionUsesTableRowsWithBuildAndPlatform() throws {
        let source = try readSource(.reactNativeAppQueries)
        XCTAssertTrue(source.contains("VersionInfo.appVersion"))
        XCTAssertTrue(source.contains("VersionInfo.platformVersion"))
    }

    func testScreenContentScrollAnchorDoesNotAddTopSpacing() throws {
        let source = try readSource(.lavaScaffold)
        let screenContentBlock = try sourceBlock(
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
        let source = try readSource(.bugReportSettingsView)
        let feedbackBlock = try sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View"
        )

        XCTAssertTrue(feedbackBlock.contains("SettingsSubpageContent(title: \"Feedback\", tier: .calm, spacing: SettingsSubpageLayout.feedbackSpacing)"))
        XCTAssertEqual(feedbackBlock.occurrences(of: "Lava only sends feedback after you review it and tap Submit"), 1)
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
        let source = try readSource(.bugReportSettingsView)
        let feedbackBlock = try sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View"
        )
        let contextPageBlock = try sourceBlock(
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
        // The diagnostic toggle is now a standalone control row, not a LavaPlainCard-wrapped one.
        XCTAssertEqual(contextPageBlock.occurrences(of: "LavaPlainCard"), 0)
        XCTAssertTrue(contextPageBlock.contains(".lavaControlRowCard()"))
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
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("LavaCondensedList"))
    }

    func testFeedbackInputsHaveExplicitDetailsCounterAndImplicitCaps() throws {
        let source = try readSource(.bugReportSettingsView)
        let components = try readSource(.lavaComponents)
        let feedbackBlock = try sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View"
        )
        let contextPageBlock = try sourceBlock(
            in: feedbackBlock,
            startingAt: "private var contextPage: some View",
            endingBefore: "private var reviewPage: some View"
        )

        // Details: explicit live counter wired through the shared input-limit constant.
        XCTAssertTrue(contextPageBlock.contains("characterLimit: BugReportInputLimits.details"))
        // Email + URL: implicit caps enforced on input, no visible counter.
        XCTAssertTrue(contextPageBlock.contains("if newValue.count > BugReportInputLimits.affectedSite"))
        XCTAssertTrue(contextPageBlock.contains("if newValue.count > BugReportInputLimits.contactEmail"))

        let editorRowBlock = try sourceBlock(
            in: components,
            startingAt: "struct LavaTextEditorInputRow: View",
            endingBefore: "extension View"
        )
        XCTAssertTrue(editorRowBlock.contains("var characterLimit: Int? = nil"))
        XCTAssertTrue(editorRowBlock.contains("Text(\"\\(text.count)/\\(characterLimit)\")"))
        XCTAssertTrue(editorRowBlock.contains("text = String(newValue.prefix(characterLimit))"))

        // The review/validation normalized values must be the SAME sanitized values that are
        // sent (BugReportContext), not a trim-only copy — otherwise all-zero-width input could
        // pass validation / show in review but submit empty (Codex P2 on UR-29).
        // Scope to the normalized-property definitions: they must delegate to currentContext
        // (the sanitized values that are sent), not re-trim raw state. isReportDirty elsewhere
        // in the block legitimately uses trimmingCharacters for dirty-detection, so a
        // block-wide negative check would be wrong (Codex P1).
        XCTAssertTrue(feedbackBlock.contains("private var normalizedAffectedSite: String {\n        currentContext.normalizedAffectedSite\n    }"))
        XCTAssertTrue(feedbackBlock.contains("private var normalizedDetails: String {\n        currentContext.normalizedDetails\n    }"))
        XCTAssertTrue(feedbackBlock.contains("private var normalizedContactEmail: String {\n        currentContext.normalizedContactEmail ?? \"\"\n    }"))
    }

    func testFeedbackReviewStepUsesSeparatePanelsAndBackAction() throws {
        let source = try readSource(.bugReportSettingsView)
        let feedbackBlock = try sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View"
        )
        let reviewPageBlock = try sourceBlock(
            in: feedbackBlock,
            startingAt: "private var reviewPage: some View",
            endingBefore: "private var thankYouPage: some View"
        )
        let bottomActionsBlock = try sourceBlock(
            in: feedbackBlock,
            startingAt: "private var feedbackBottomActionButtons: some View",
            endingBefore: "private func goToStep(_ step: BugReportStep)"
        )

        XCTAssertTrue(reviewPageBlock.containsInOrder([
            "LavaSectionGroup(\"Review and submit\")",
            "VStack(spacing: 10)",
            "LavaTextInputPanel",
            "BugReportReviewRow(label: \"Topic\"",
            "Divider()",
            "BugReportReviewRow(label: \"Site or domain\"",
            "Divider()",
            "BugReportReviewRow(label: \"Details\"",
            "Divider()",
            "BugReportReviewRow(label: \"Email\"",
            "Divider()",
            "BugReportReviewRow(label: \"Diagnostics\""
        ]))
        // Review now echoes the "Tell us more" panel: one card, stacked rows, no per-field cards.
        XCTAssertEqual(reviewPageBlock.occurrences(of: "LavaTextInputPanel"), 1)
        XCTAssertEqual(reviewPageBlock.occurrences(of: "LavaPlainCard"), 0)
        XCTAssertFalse(reviewPageBlock.contains("Optional diagnostics"))
        XCTAssertTrue(bottomActionsBlock.containsInOrder([
            "case .review:",
            "Button {",
            "moveBack()",
            "Text(\"Back\".lavaLocalized)",
            ".buttonStyle(LavaSecondaryActionButtonStyle())",
            "Button {",
            "submitReport()"
        ]))
        XCTAssertFalse(bottomActionsBlock.contains("Text(\"Cancel\".lavaLocalized)"))
        XCTAssertFalse(bottomActionsBlock.contains("requestDismiss()"))

        let reviewRowBlock = try sourceBlock(
            in: source,
            startingAt: "private struct BugReportReviewRow: View",
            endingBefore: "private struct BugReportDiagnosticsInfoView"
        )
        XCTAssertTrue(reviewRowBlock.contains("LavaTextInputRow(title: label)"))
        XCTAssertFalse(reviewRowBlock.contains("HStack(alignment: .center, spacing: 12)"))
        XCTAssertFalse(reviewRowBlock.contains(".frame(width: 116"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("lavaLocalized"))
        XCTAssertTrue(source.contains("requestDismiss"))
    }

    func testDeviceDNSPresetOffersSelectableEncryptedFallback() throws {
        let source = try readSource(.dnsResolverSettingsView)
        let resolverBlock = try sourceBlock(
            in: source,
            startingAt: "struct DNSResolverSettingsView: View"
        )

        // The Device DNS preset now exposes a selectable encrypted fallback. A
        // "Fallback to alternative DNS" toggle (bound to setUsesEncryptedDeviceDNSFallback)
        // replaces the old static disclosure copy, and the provider/transport/custom
        // picker is revealed only when that opt-in is on.
        XCTAssertFalse(resolverBlock.contains("static let encryptedFallbackDisclosureText"))
        XCTAssertFalse(resolverBlock.contains("encryptedFallbackDisclosureText"))
        XCTAssertFalse(resolverBlock.contains("Quad9 DNS (DNS over HTTPS)"))

        // The fallback toggle is gated on usesDeviceDNSSetting and drives the opt-in flag.
        XCTAssertTrue(resolverBlock.contains("if usesDeviceDNSSetting {"))
        XCTAssertTrue(resolverBlock.contains("title: \"Fallback to alternative DNS\""))
        XCTAssertTrue(resolverBlock.contains("isOn: usesEncryptedDeviceDNSFallbackBinding"))
        XCTAssertTrue(resolverBlock.contains("viewModel.setUsesEncryptedDeviceDNSFallback(newValue)"))
        XCTAssertTrue(resolverBlock.contains("viewModel.configuration.usesEncryptedDeviceDNSFallback"))

        // The shared picker is revealed only when the encrypted fallback is enabled and
        // is wired to the fallback setters.
        XCTAssertTrue(resolverBlock.contains("if usesDeviceDNSSetting && viewModel.configuration.usesEncryptedDeviceDNSFallback {"))
        XCTAssertTrue(resolverBlock.contains("ResolverPickerSections("))
        XCTAssertTrue(resolverBlock.contains("selectedPreset: viewModel.configuration.fallbackResolverPreset"))
        XCTAssertTrue(resolverBlock.contains("viewModel.setFallbackResolver(preset)"))
        XCTAssertTrue(resolverBlock.contains("viewModel.setFallbackCustomResolverAddresses(primary: primary, secondary: secondary)"))
        XCTAssertTrue(resolverBlock.contains("viewModel.clearFallbackCustomResolver(fallback: fallback)"))

        // Custom DNS for the fallback stays gated by Plus, like the primary.
        XCTAssertTrue(resolverBlock.contains("allowsCustomDNS: viewModel.configuration.limits.allowsCustomDNS"))
    }

    func testClearingCustomDoQFallbackKeepsEncryptedDefault() throws {
        let source = try readSource(.dnsResolverSettingsView)
        // The fallback picker's clear preset uses a Quad9 base (the primary section's
        // uses Google), so this start marker uniquely targets the fallback clear path.
        let clearBlock = try sourceBlock(
            in: source,
            startingAt: "DNSResolverPreset.customID ? DNSResolverPreset.quad9Unfiltered : selectedBaseResolver",
            endingBefore: "private var customResolverHasChanges"
        )

        // Clearing a Custom DoQ fallback must stay encrypted: Quad9 has no QUIC
        // variant, so resolverVariant(.dnsOverQUIC) degrades to plain IP — coerce that
        // unsupported case to the DoH default instead of silently dropping encryption.
        XCTAssertTrue(clearBlock.contains("selectedMenuTransport == .dnsOverQUIC"))
        XCTAssertTrue(clearBlock.contains("variant.transport != .dnsOverQUIC"))
        XCTAssertTrue(clearBlock.contains("return .quad9UnfilteredDoH"))
    }

    func testFeedbackSubmittingStateStaysInsideSubmitButton() throws {
        let source = try readSource(.bugReportSettingsView)
        let feedbackBlock = try sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View"
        )
        let statusBlock = try sourceBlock(
            in: feedbackBlock,
            startingAt: "private var bugReportStatusView: some View",
            endingBefore: "private func selectIssueType(_ type: BugReportIssueType)"
        )

        XCTAssertTrue(statusBlock.contains("case .idle, .sent, .sending:"))
        XCTAssertTrue(feedbackBlock.contains("case .sending:\n            \"Submitting\""))
        XCTAssertFalse(statusBlock.contains("case .sending:\n            LavaPlainCard"))
        XCTAssertFalse(feedbackBlock.contains("Sending feedback..."))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("LavaPlainCard"))
    }

    func testFeedbackThankYouPageUsesSharedSuccessAndRetainsCopyID() throws {
        let source = try readSource(.bugReportSettingsView)
        let thankYouBlock = try sourceBlock(in: source,
            startingAt: "private var thankYouPage: some View",
            endingBefore: "private var feedbackBottomActionBar: some View")
        XCTAssertTrue(thankYouBlock.contains("LavaSuccessScreen(title: \"Feedback sent\""))
        XCTAssertTrue(thankYouBlock.contains("done: dismissAfterSubmit"))
        XCTAssertTrue(thankYouBlock.contains("copySubmittedReportID"))
        XCTAssertTrue(thankYouBlock.contains("Text(submittedReportID)"))
        XCTAssertTrue(source.contains("isPresented: onDismissRequested != nil && !usesPageNavigation && !isShowingThankYou"))
        XCTAssertFalse(source.contains("FeedbackThankYouMascot"))
        XCTAssertTrue(source.contains("UIPasteboard.general.string = submittedReportID"))
        XCTAssertTrue(source.contains("transaction.disablesAnimations = true"))
        XCTAssertTrue(source.contains("didCopySubmittedReportID = UIPasteboard.general.string == submittedReportID"))
    }

    func testFeedbackStepActionsArePinnedAndUseExpectedSecondaryButtons() throws {
        let source = try readSource(.bugReportSettingsView)
        let components = try readSource(.lavaComponents)
        let feedbackBlock = try sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View"
        )

        XCTAssertTrue(feedbackBlock.contains(".safeAreaInset(edge: .bottom)"))
        XCTAssertTrue(feedbackBlock.contains("private var feedbackBottomActionBar: some View"))
        XCTAssertTrue(feedbackBlock.contains("private var feedbackBottomActionButtons: some View"))
        XCTAssertFalse(feedbackBlock.contains("FeedbackSecondaryActionButtonStyle"))
        let secondaryStyle = try sourceBlock(in: components,
                                             startingAt: "struct LavaSecondaryActionButtonStyle:",
                                             endingBefore: "struct LavaToggleRow:")
        XCTAssertTrue(secondaryStyle.contains("struct LavaSecondaryActionButtonStyle: PrimitiveButtonStyle"))
        XCTAssertFalse(secondaryStyle.contains("let disabledOpacity: Double"))
        XCTAssertTrue(secondaryStyle.contains("LavaFullWidthActionPrimitiveStyle(role: .secondary"))
        XCTAssertTrue(secondaryStyle.contains(".makeBody(configuration: configuration)"))
        XCTAssertTrue(feedbackBlock.contains("Text(\"Back\".lavaLocalized)"))
        XCTAssertEqual(
            feedbackBlock.occurrences(
                of: ".buttonStyle(LavaSecondaryActionButtonStyle())"
            ),
            2
        )
        XCTAssertTrue(feedbackBlock.contains(".buttonStyle(LavaPanelActionButtonStyle())"))
    }

    func testFeedbackTypingReusesPreparedDiagnosticsInsteadOfRebuildingPerKeystroke() throws {
        let settingsSource = try readSource(.bugReportSettingsView)
        // The draft lifecycle (prepare/refresh-context + the prepared-inputs cache)
        // lives on DiagnosticsController since the Phase D4 peel.
        let diagnosticsControllerSource = try readSource(.diagnosticsController)
        let feedbackBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "struct BugReportSettingsView: View"
        )
        let inputChangedBlock = try sourceBlock(
            in: feedbackBlock,
            startingAt: "private func reportInputChanged()",
            endingBefore: "private func submitReport()"
        )

        // Per-keystroke text changes take the cheap context-only refresh, never
        // the heavy prepare that re-reads files and rebuilds the blocklist union.
        XCTAssertTrue(inputChangedBlock.contains("refreshDraftContext()"))
        XCTAssertFalse(inputChangedBlock.contains("refreshDraft()"))
        XCTAssertTrue(feedbackBlock.contains("private func refreshDraftContext()"))
        XCTAssertTrue(feedbackBlock.contains("reports.refreshBugReportDraftContext(context: currentContext)"))
        XCTAssertTrue(feedbackBlock.contains(".onChange(of: details) { _, _ in reportInputChanged() }"))
        XCTAssertTrue(feedbackBlock.contains(".onChange(of: affectedSite) { _, _ in reportInputChanged() }"))

        // The controller captures the heavy inputs once in prepareBugReport and
        // the cheap path reuses them without another refreshReports()/file read.
        let prepareBlock = try sourceBlock(
            in: diagnosticsControllerSource,
            startingAt: "func prepareBugReport(context: BugReportContext)",
            endingBefore: "func refreshBugReportDraftContext(context: BugReportContext)"
        )
        let refreshContextBlock = try sourceBlock(
            in: diagnosticsControllerSource,
            startingAt: "func refreshBugReportDraftContext(context: BugReportContext)",
            endingBefore: "func sendBugReport(context: BugReportContext) async"
        )
        XCTAssertTrue(prepareBlock.contains("refreshReports()"))
        XCTAssertTrue(prepareBlock.contains("preparedBugReportInputs = inputs"))
        XCTAssertTrue(prepareBlock.contains("makeBugReportBundle(context: context, inputs: inputs)"))
        XCTAssertTrue(refreshContextBlock.contains("guard let inputs = preparedBugReportInputs, let draft = bugReportDraft else"))
        XCTAssertTrue(refreshContextBlock.contains("draft.updatingContext(context, affectedSiteDecision: decision)"))
        XCTAssertFalse(refreshContextBlock.contains("makeBugReportBundle("))
        XCTAssertFalse(refreshContextBlock.contains("refreshReports()"))
        XCTAssertTrue(diagnosticsControllerSource.contains("private struct PreparedBugReportInputs"))
        XCTAssertTrue(diagnosticsControllerSource.contains("debugLogEntries: inputs.debugLogEntries"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(settingsSource.contains("refreshDraft"))
    }

    func testFeedbackStepProgressUsesClickableSimpleNumberText() throws {
        let source = try readSource(.bugReportSettingsView)
        let feedbackBlock = try sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View"
        )
        let stepProgressBlock = try sourceBlock(
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
        XCTAssertTrue(feedbackBlock.contains("furthestVisitedStep: BugReportStep = .topic"))
        XCTAssertTrue(stepProgressBlock.contains("let furthestVisitedStep: BugReportStep"))
        XCTAssertTrue(stepProgressBlock.contains("let selectStep: (BugReportStep) -> Void"))
        XCTAssertTrue(stepProgressBlock.contains("LavaStepNavigation("))
        XCTAssertTrue(stepProgressBlock.contains("$0.displayNumber"))
        XCTAssertTrue(stepProgressBlock.contains("isUnavailableStep"))
        XCTAssertTrue(stepProgressBlock.contains("step.rawValue > furthestVisitedStep.rawValue"))
        XCTAssertFalse(source.contains("\"①\""))
        XCTAssertFalse(source.contains("\"②\""))
        XCTAssertFalse(source.contains("\"③\""))
        XCTAssertFalse(stepProgressBlock.contains(".background(stepFillColor"))
        XCTAssertFalse(stepProgressBlock.contains("Circle()"))
        XCTAssertFalse(stepProgressBlock.contains("isFutureStep"))
        let owner = try sourceBlock(in: readSource(.lavaComponents), startingAt: "struct LavaStepNavigation<",
                                   endingBefore: "struct LavaDiagnosticValueRow: View")
        XCTAssertTrue(owner.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(owner.contains("VStack(spacing: 8)"))
        XCTAssertTrue(owner.contains("minWidth: 44, maxWidth: .infinity, minHeight: 44"))
        XCTAssertTrue(owner.contains(".disabled(!isEnabled(step))"))
        XCTAssertTrue(owner.contains(".accessibilityAddTraits(isSelected(step) ? [.isSelected] : [])"))
        XCTAssertFalse(owner.contains("minimumScaleFactor"))
        XCTAssertFalse(owner.contains("lineLimit(1)"))
    }

    func testFeedbackDiagnosticsUseAdaptiveSharedLabelAndValueRoles() throws {
        let source = try readSource(.bugReportSettingsView)
        let preview = try sourceBlock(in: source, startingAt: "private struct BugReportPreviewSectionCard: View")
        XCTAssertTrue(preview.contains("LavaDiagnosticValueRow(title: item.label, value: item.value)"))
        XCTAssertFalse(preview.contains(".frame(width: 110"))
        let owner = try sourceBlock(in: readSource(.lavaComponents), startingAt: "struct LavaDiagnosticValueRow: View")
        XCTAssertTrue(owner.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(owner.contains("VStack(alignment: .leading, spacing: 4)"))
        XCTAssertTrue(owner.contains(".font(LavaTypography.rowTitle)"))
        XCTAssertTrue(owner.contains("Text(verbatim: value)"))
        XCTAssertTrue(owner.contains(".font(LavaTypography.rowMetadata)"))
        XCTAssertTrue(owner.contains(".accessibilityElement(children: .combine)"))
        XCTAssertFalse(owner.contains("lineLimit"))
        XCTAssertFalse(owner.contains("minimumScaleFactor"))
    }

    func testFeedbackFlowGuardsDirtyDismissalInSettingsAndRageShakeSheet() throws {
        let settingsSource = try readSource(.bugReportSettingsView)
        let rootSource = try readSource(.rootView)
        let feedbackBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "struct BugReportSettingsView: View"
        )
        let rageShakeSheetBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct BugReportSheetView: View",
            endingBefore: "#Preview"
        )

        XCTAssertTrue(feedbackBlock.contains("onDismissRequested"))
        XCTAssertTrue(feedbackBlock.contains("isReportDirty"))
        XCTAssertTrue(feedbackBlock.contains(".alert(\"Discard feedback?\""))
        XCTAssertTrue(feedbackBlock.contains("Button(\"Cancel\", role: .cancel)"))
        XCTAssertTrue(feedbackBlock.contains("Button(\"Discard\", role: .destructive)"))
        XCTAssertTrue(feedbackBlock.contains("usesPageNavigation: Bool = false"))
        XCTAssertTrue(feedbackBlock.contains("usesPageNavigation || (isReportDirty && onDismissRequested == nil)"))
        XCTAssertTrue(feedbackBlock.contains("onDismissRequested != nil && !usesPageNavigation && !isShowingThankYou"))
        XCTAssertTrue(rageShakeSheetBlock.contains("canRequestDismiss"))
        XCTAssertTrue(rageShakeSheetBlock.contains(".interactiveDismissDisabled(isReportDirty"))

        // The bug-report sheet stays MOUNTED across an App Unlock lock so the
        // in-progress draft (local @State) survives; its content is hidden by an
        // opaque, hit-blocking, modal in-sheet mask while App Unlock is pending OR
        // the app-switcher privacy mask is up, and the diagnostics sampling task
        // is gated off while masked. The sheet is presented from RootView with a
        // raw binding (no withhold), and the importer's withhold gate is untouched.
        XCTAssertTrue(rootSource.contains("private func forwardReactRageShake()"))
        XCTAssertTrue(feedbackBlock.contains("security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible"))
        XCTAssertTrue(feedbackBlock.contains("LavaSheetLockMask("))
        XCTAssertTrue(feedbackBlock.contains("security.authenticateAppUnlockIfNeeded()"))
        XCTAssertTrue(feedbackBlock.contains(".task(id: isAppUnlockMaskVisible)"))
        XCTAssertTrue(feedbackBlock.contains("guard !isAppUnlockMaskVisible else { return }"))
        // Re-check after the non-cancellation-aware sampleReports() await so a
        // lock that lands mid-sample can't refresh the draft above the lock.
        XCTAssertTrue(feedbackBlock.contains("guard !Task.isCancelled, !isDismissed, !isAppUnlockMaskVisible else { return }"))
        // BOTH capture points force the health sample, not just sheet appearance. The point of
        // leaving Feedback open is to reproduce the failure with the sheet up, and the tunnel
        // holds repeated failures in a 30 s suppressor until a flush — which this sample is —
        // so a submit inside the poll window would send a report of the reproduction with the
        // reproduction's own tail missing (Codex P2, PR #620). Forced because a one-shot capture
        // is not the 5 s poll the throttle was written for.
        XCTAssertEqual(
            sourceOccurrenceCount(of: "await viewModel.sampleReports(force: true)", in: feedbackBlock), 2,
            "sheet appearance AND submit both re-sample before the draft is built")
        let submitBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "private func submitReport()",
            endingBefore: "private var currentContext: BugReportContext"
        )
        XCTAssertTrue(submitBlock.containsInOrder([
            "guard !isPreparingSubmission else {",
            "isPreparingSubmission = true",
            "let reviewedContext = currentContext",
            "submissionTask = Task {",
            "await viewModel.sampleReports(force: true)",
            "guard !Task.isCancelled else {",
            "refreshDraft(context: reviewedContext)",
            "await reports.sendBugReport(context: reviewedContext)"
        ]), "guarded, snapshotted, sampled, re-checked, rebuilt from the snapshot, then sent")
        // WHAT WAS REVIEWED IS WHAT IS SENT. Back and the step progress stay live while
        // preparing, so the fields can change during the flush await; reading `currentContext`
        // after it would submit content that never passed Review or `canContinueFromContext`.
        XCTAssertFalse(
            submitBlock.contains("sendBugReport(context: currentContext)"),
            "the send must use the snapshot taken at the tap, not the live fields")
        // AND THE DRAFT IS FROZEN while preparing, exactly as it already was while `.sending`:
        // preparation is part of submitting, and `sendBugReport` overwrites `bugReportDraft`
        // with the bundle it sent, so an edit made in that window could not be honoured and was
        // silently lost (Codex P2, PR #620).
        XCTAssertTrue(
            feedbackBlock.contains(
                ".disabled(isPreparingSubmission || reports.bugReportSendState.isSending)"),
            "Back is disabled through the preparation await, not only the send")
        let stepBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "private func goToStep(_ step: BugReportStep)",
            endingBefore: "private func markStepVisited("
        )
        XCTAssertTrue(
            stepBlock.contains("guard !isPreparingSubmission, !reports.bugReportSendState.isSending else {"),
            "step navigation is frozen for the whole submission, not just the send")
        // ...and so is the dismissal path, or the toolbar Cancel would open the discard alert
        // over a submission that keeps running underneath it and can POST before the user
        // answers — a report explicitly discarded and sent anyway.
        let dismissBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "private func requestDismiss()",
            endingBefore: "private func discardAndDismiss()"
        )
        XCTAssertTrue(
            dismissBlock.contains("guard !isPreparingSubmission, !reports.bugReportSendState.isSending else {"),
            "the sheet cannot be dismissed while a submission is under way")

        // A DISCARD DURING THE FLUSH must not send the report the user just threw away. The
        // submission is an unstructured task, so the sheet's own `.task` cancellation does not
        // reach it — the handle is retained and cancelled, and cancelled BEFORE clearing the draft
        // so the task cannot resume against the cleared draft. `sampleReports` is not
        // cancellation-aware, which is why the task also re-checks after its await above.
        let discardBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "private func discardAndDismiss()",
            endingBefore: "private func dismissAfterSubmit()"
        )
        XCTAssertTrue(discardBlock.containsInOrder([
            "cancelAnyPreparingSubmission()",
            "reports.discardBugReportDraft()"
        ]), "the in-flight submission is cancelled before the draft is cleared")

        let maskBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "struct LavaSheetLockMask",
            endingBefore: "private struct BugReportTopicOptionRow"
        )
        // OPAQUE fill, never translucent material (which would leak the draft
        // through the blur), and it must swallow hits + be a modal a11y element.
        XCTAssertTrue(maskBlock.contains(".fill(LavaStyle.groupedBackground)"))
        XCTAssertFalse(maskBlock.contains(".regularMaterial"))
        XCTAssertTrue(maskBlock.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(maskBlock.contains(".accessibilityAddTraits(.isModal)"))
        // Must carry its own unlock affordance: the root lock overlay is behind
        // this window-level sheet, so a cancelled passcode prompt would otherwise
        // strand the user (forced to discard the draft) — see the P2 on 3d1f492.
        XCTAssertTrue(maskBlock.contains("Button(\"Unlock Lava\", action: unlock)"))
    }

    func testAccountPageRemovesFreeAccountInfoPanelAndUsesStandardAccountSheetChrome() throws {
        let source = try readSource(.accountBackupSettingsView)
        XCTAssertTrue(source.contains("struct AccountSheet: View"))
        XCTAssertTrue(source.contains("LavaSheetScaffold"))
    }

    func testSettingsModalSingleGlyphToolbarsUseNativeActions() throws {
        let source = try [readSource(.privacySecuritySettingsView), readSource(.bugReportSettingsView)].joined(separator: "\n")
        let passcodeBlock = try sourceBlock(
            in: source,
            startingAt: "struct SecurityPasscodeSetupView: View",
            endingBefore: "enum LocalLogSetting"
        )
        let feedbackBlock = try sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View",
            endingBefore: "struct LavaSheetLockMask"
        )

        XCTAssertTrue(passcodeBlock.contains("ToolbarItem(placement: .cancellationAction)"))
        XCTAssertTrue(passcodeBlock.contains("NativeToolbarIconButton(systemName: \"xmark\", accessibilityLabel: \"Cancel\", role: .cancel, action: dismiss.callAsFunction)"))
        XCTAssertFalse(passcodeBlock.contains("LavaToolbarIconButton("))

        XCTAssertFalse(feedbackBlock.contains("NativeToolbarIconButton(systemName: \"chevron.left\", accessibilityLabel: \"Back\", action: requestDismiss)"))
        XCTAssertTrue(feedbackBlock.contains(".lavaFullSheetHeader(\"Feedback\""))
        XCTAssertTrue(feedbackBlock.contains("NativeToolbarIconButton(systemName: \"xmark\", accessibilityLabel: \"Cancel\", role: .cancel, action: requestDismiss)"))
        XCTAssertFalse(feedbackBlock.contains("LavaToolbarIconButton("))
    }

    func testEncryptedBackupStateRecordsLastUploadAndSchedulesAutomaticBackupAfterChanges() throws {
        // The backup cluster lives in BackupController since the Phase D1 peel; the hub's
        // persist funnels still schedule through it (pinned in the app source below).
        let source = try readSource(.backupController)
        let appSource = try readAppViewModelSource()
        // EncryptedBackupState moved to LavaSecCore (its copy + state derivation
        // are now covered behaviorally by EncryptedBackupStateTests); pin the
        // synced-case shape and timestamp formatting against the core file.
        let stateSource = try readSource(.encryptedBackupState)
        let preferenceBlock = try sourceBlock(
            in: source,
            startingAt: "func setAutomaticBackupEnabled",
            endingBefore: "func loadAutomaticBackupPreference()"
        )
        let uploadBlock = try sourceBlock(
            in: source,
            startingAt: "private func uploadEncryptedBackup(",
            endingBefore: "func uploadPendingEncryptedBackupIfPossible()"
        )

        XCTAssertTrue(stateSource.contains("case synced(estimatedByteSize: Int, uploadedAt: Date)"))
        XCTAssertTrue(stateSource.contains("LocalLogTimestampFormatter.string(from: uploadedAt)"))
        XCTAssertTrue(source.contains("@Published private(set) var isAutomaticBackupEnabled"))
        XCTAssertTrue(source.contains("private var automaticBackupTask: Task<Void, Never>?"))
        XCTAssertTrue(source.contains("private let automaticBackupDelay: UInt64 = 5 * 60 * 1_000_000_000"))
        XCTAssertTrue(appSource.contains("backup.scheduleAutomaticBackupAfterConfigurationChange()"))
        XCTAssertTrue(source.contains("try? await Task.sleep(nanoseconds: automaticBackupDelay)"))
        XCTAssertTrue(preferenceBlock.contains("UserDefaults.standard.set(isEnabled, forKey: automaticBackupEnabledDefaultsKeyName)"))
        XCTAssertFalse(preferenceBlock.contains("scheduleAutomaticBackupAfterConfigurationChange()"))
        // The marker is recorded through the version-checked store helper
        // (BackupEnvelopeStore.recordUploadIfCurrent — executable in BackupEnvelopeStoreTests
        // since the Phase D1 peel), so a re-seal during an in-flight upload can't leave a
        // stale "uploaded" marker for the older envelope.
        XCTAssertTrue(uploadBlock.contains("backupEnvelopeStore.recordUploadIfCurrent(envelope, at:"))
    }

    func testBugReportUsesGenericResolverNameInsteadOfCustomDisplayName() throws {
        // The bundle ASSEMBLY stayed hub-side with the Phase D4 peel, as the
        // DiagnosticsHubBridging conformance's makeBugReportBundle (the last member
        // of the last extension, so the block runs to end-of-file).
        let source = try readAppViewModelSource()
        let bugReportBlock = try sourceBlock(
            in: source,
            startingAt: "func makeBugReportBundle("
        )

        XCTAssertTrue(bugReportBlock.contains("resolverPreset: configuration.resolverDiagnosticDisplayName"))
        XCTAssertFalse(bugReportBlock.contains("resolverPreset: configuration.resolverPreset.displayName"))
    }

    func testPrivacyDataSettingsSummaryNamesEnabledLocalLogs() throws {
        let source = try readAppViewModelSource()
        let localLogsBlock = try sourceBlock(
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
        XCTAssertTrue(localLogsBlock.contains("return \"%@ on\".lavaLocalizedFormat(displayedSummary)"))
        XCTAssertFalse(localLogsBlock.contains("return \"Local logs on\""))
    }

    func testDNSResolverSettingsShowsBaseResolversAndTransportSelectorOnly() throws {
        let source = try readSource(.dnsResolverSettingsView)
        let resolverBlock = try sourceBlock(
            in: source,
            startingAt: "struct DNSResolverSettingsView: View"
        )

        XCTAssertTrue(resolverBlock.contains("LavaSectionGroup(\"Device DNS\") {"))
        XCTAssertTrue(resolverBlock.contains("LavaToggleRow(title: \"Use Device DNS Setting\", isOn: useDeviceDNSBinding,"))
        XCTAssertTrue(resolverBlock.contains("viewModel.deviceDNSResolverDetailText"))
        XCTAssertTrue(resolverBlock.contains("if !usesDeviceDNSSetting"))
        XCTAssertTrue(resolverBlock.contains("DNSResolverPreset.settingsPresets.filter { $0.id != DNSResolverPreset.device.id }"))
        XCTAssertTrue(resolverBlock.contains("isSelected: isCustomResolverSelected"))
        XCTAssertTrue(resolverBlock.contains("isEditingCustomResolver || viewModel.configuration.resolverPresetID == DNSResolverPreset.customID"))
        XCTAssertTrue(resolverBlock.contains(".onDisappear(perform: resetCustomResolverDrafts)"))
        XCTAssertTrue(resolverBlock.contains("LavaSectionGroup(\"DNS Providers\", footer:"))
        XCTAssertTrue(resolverBlock.contains("@Environment(\\.dismiss) private var dismiss"))
        XCTAssertTrue(resolverBlock.contains("@FocusState private var focusedCustomResolverField: CustomResolverFocusField?"))
        XCTAssertTrue(resolverBlock.contains("@State private var customResolverSecondaryDraft = \"\""))
        XCTAssertTrue(resolverBlock.contains("@State private var showingCustomResolverDiscardConfirmation = false"))
        XCTAssertTrue(resolverBlock.contains("@State private var pendingCustomResolverDiscardAction: CustomResolverDiscardAction?"))
        XCTAssertTrue(resolverBlock.contains("@State private var customResolverValidationMessage: String?"))
        XCTAssertTrue(resolverBlock.contains("if showsResolverOptions"))
        XCTAssertTrue(resolverBlock.contains("DNS Transport"))
        XCTAssertTrue(resolverBlock.contains("LavaSectionGroup(\"DNS Transport\")"))
        XCTAssertTrue(resolverBlock.contains("LavaSegmentedPicker(label: \"DNS Transport\""))
        XCTAssertTrue(resolverBlock.contains("options: selectedBaseResolver.availableTransports"))
        XCTAssertTrue(resolverBlock.contains("resolverTransportBinding"))
        XCTAssertFalse(resolverBlock.contains("transportDetailText"))
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
        // The "DNS Fallback" section wrapper was removed; the fallback toggle now sits
        // directly under the Device DNS detail text inside the "Device DNS" group.
        XCTAssertFalse(resolverBlock.contains("LavaSectionGroup(\"DNS Fallback\")"))
        XCTAssertTrue(resolverBlock.contains("Fallback to Device DNS"))
        XCTAssertTrue(resolverBlock.contains("Same transport as Primary"))
        XCTAssertTrue(resolverBlock.contains("fallbackToDeviceDNSBinding"))
        XCTAssertTrue(resolverBlock.contains("ResolverOptionControl("))
        XCTAssertTrue(resolverBlock.contains("ResolverTransportControl("))
        XCTAssertTrue(resolverBlock.contains(".lavaQuietNoteText()"))
        XCTAssertTrue(resolverBlock.contains("selectedBaseResolver.availableTransports.contains(.dnsOverQUIC)"))
        XCTAssertTrue(resolverBlock.contains("DoQ (DNS over QUIC)"))
        XCTAssertTrue(resolverBlock.containsInOrder([
            "LavaSectionGroup(\"Device DNS\") {",
            "title: \"Fallback to Device DNS\"",
            "detail: viewModel.deviceDNSFallbackDetailText",
            "if !usesDeviceDNSSetting",
            "LavaSectionGroup(\"DNS Providers\", footer:",
            "LavaSectionGroup(\"Custom Resolver\")",
            "LavaSectionGroup(\"DNS Transport\")",
            "ResolverTransportControl("
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

        let customTextFieldBlock = try sourceBlock(
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

        let resolverSummaryBlock = try sourceBlock(
            in: resolverBlock,
            startingAt: "private func resolverAddressSummary",
            endingBefore: "private enum CustomResolverDiscardAction"
        )
        XCTAssertTrue(resolverSummaryBlock.contains("let doqEndpointAddresses = preset.doqEndpoints.map(\\.displayAddress)"))
        XCTAssertTrue(resolverSummaryBlock.contains("return doqEndpointAddresses.joined(separator: \", \")"))

        let canSaveBlock = try sourceBlock(
            in: resolverBlock,
            startingAt: "private var canSaveCustomResolver: Bool",
            endingBefore: "private var canClearCustomResolver: Bool"
        )
        XCTAssertTrue(canSaveBlock.contains("customResolverDraftIsCleared"))
        XCTAssertFalse(canSaveBlock.contains("customResolverDraftIsValid"))

        let clearDraftsBlock = try sourceBlock(
            in: resolverBlock,
            startingAt: "private func clearCustomResolverDrafts()",
            endingBefore: "private func requestCustomResolverDismiss()"
        )
        XCTAssertFalse(clearDraftsBlock.contains("focusedCustomResolverField = nil"))

        let toggleRowBlock = try sourceBlock(
            in: try readSource(.lavaComponents),
            startingAt: "struct LavaToggleRow: View",
            endingBefore: "extension View {"
        )
        XCTAssertTrue(toggleRowBlock.contains(".lavaRowTitleText()"))
        XCTAssertTrue(toggleRowBlock.contains(".lavaRow()"))
        XCTAssertFalse(toggleRowBlock.contains("Text(detail)"))

        let optionControlBlock = try sourceBlock(
            in: source,
            startingAt: "private struct ResolverOptionControl: View"
        )
        XCTAssertTrue(optionControlBlock.containsInOrder([
            "LavaSettingsRow(footer: detail)",
            "LavaToggleRow(title: title, isOn: $isOn, accessibilityHint: detail)"
        ]))

        let transportControlBlock = try sourceBlock(
            in: source,
            startingAt: "private struct ResolverTransportControl: View",
            endingBefore: "private struct ResolverOptionControl: View"
        )
        XCTAssertTrue(transportControlBlock.contains("LavaSegmentedPicker(label: \"DNS Transport\""))
        XCTAssertTrue(transportControlBlock.contains("$0.menuTitle.lavaLocalized"))
        XCTAssertFalse(transportControlBlock.contains("Text(detail.lavaLocalized)"))
        XCTAssertTrue(transportControlBlock.contains(".lavaQuietNoteText()"))
        XCTAssertFalse(transportControlBlock.contains(".lavaControlRowCard()"), "The shared transport selector must not be nested in another filled control surface.")
        XCTAssertFalse(transportControlBlock.contains("Text(title)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("customResolverDraft"))
        XCTAssertTrue(source.contains("configuredValue"))
        XCTAssertTrue(source.contains("customResolverDraftIsValid"))
    }

    func testCustomResolverNameChangesPersistWithoutReloadingTunnel() throws {
        let source = try readAppViewModelSource()
        let nameBlock = try sourceBlock(
            in: source,
            startingAt: "func setCustomResolverName(_ rawValue: String)",
            endingBefore: "func persistResolverSettings"
        )

        XCTAssertTrue(nameBlock.contains("try persistConfigurationOnly()"))
        XCTAssertFalse(nameBlock.contains("persistResolverSettings(activity: .changeResolver)"))
        XCTAssertFalse(nameBlock.contains("sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("LavaSecAppGroup"))
        XCTAssertTrue(source.contains("reloadConfigurationMessage"))
        XCTAssertTrue(source.contains("sendTunnelMessage"))
    }

    func testDNSResolverSummaryUsesShortFallbackCopy() throws {
        let source = try readAppViewModelSource()
        let summaryBlock = try sourceBlock(
            in: source,
            startingAt: "var dnsResolverSummaryText: String",
            endingBefore: "var deviceDNSFallbackDetailText: String"
        )

        XCTAssertTrue(summaryBlock.contains("+ Fallback"))
        XCTAssertFalse(summaryBlock.contains("+ Device fallback"))
        XCTAssertFalse(summaryBlock.contains("+ Device Fallback"))
    }

    func testDNSResolverCatalogAddsQuad9BaseAndEncryptedVariants() throws {
        XCTAssertEqual(DNSResolverPreset.settingsPresets.map(\.id), [
            "device-dns",
            "quad9-unfiltered",
            "cloudflare-1111",
            "hagezi-root",
            "google-public-dns"
        ])
        XCTAssertEqual(DNSResolverPreset.quad9Unfiltered.ipv4Servers, ["9.9.9.10"])
        XCTAssertEqual(DNSResolverPreset.quad9Unfiltered.ipv6Servers, ["2620:fe::10"])
        XCTAssertEqual(DNSResolverPreset.quad9UnfilteredDoH.dohEndpoint?.url.absoluteString, "https://dns10.quad9.net/dns-query")
        XCTAssertEqual(DNSResolverPreset.quad9UnfilteredDoT.dotEndpoint?.hostname, "dns10.quad9.net")
        XCTAssertEqual(DNSResolverPreset.hagezi.ipv4Servers, ["188.34.161.210"])
        XCTAssertEqual(DNSResolverPreset.hagezi.ipv6Servers, ["2a01:4f8:c17:1c66::1"])
        XCTAssertEqual(DNSResolverPreset.hageziDoH.dohEndpoint?.url.absoluteString, "https://root.hagezi.org/dns-query")
        XCTAssertEqual(DNSResolverPreset.hageziDoT.dotEndpoint?.hostname, "root.hagezi.org")
    }

    func testResolverPresetMapsTransportSelectorToBaseSelection() throws {
        XCTAssertEqual(DNSResolverPreset.googleDoH.settingsBasePreset, .google)
        XCTAssertEqual(DNSResolverPreset.cloudflareDoH.settingsBasePreset, .cloudflare)
        XCTAssertEqual(DNSResolverPreset.quad9SecureDoH.settingsBasePreset, .quad9Secure)
        XCTAssertEqual(DNSResolverPreset.quad9UnfilteredDoH.settingsBasePreset, .quad9Unfiltered)
        XCTAssertEqual(DNSResolverPreset.googleDoT.settingsBasePreset, .google)
        XCTAssertEqual(DNSResolverPreset.cloudflareDoT.settingsBasePreset, .cloudflare)
        XCTAssertEqual(DNSResolverPreset.quad9SecureDoT.settingsBasePreset, .quad9Secure)
        XCTAssertEqual(DNSResolverPreset.quad9UnfilteredDoT.settingsBasePreset, .quad9Unfiltered)
        XCTAssertEqual(DNSResolverPreset.hageziDoH.settingsBasePreset, .hagezi)
        XCTAssertEqual(DNSResolverPreset.hageziDoT.settingsBasePreset, .hagezi)
        XCTAssertEqual(DNSResolverPreset.quad9Unfiltered.dnsOverHTTPSVariant, .quad9UnfilteredDoH)
        XCTAssertEqual(DNSResolverPreset.quad9Unfiltered.dnsOverTLSVariant, .quad9UnfilteredDoT)
        XCTAssertEqual(DNSResolverPreset.quad9UnfilteredDoH.plainDNSVariant, .quad9Unfiltered)
        XCTAssertEqual(DNSResolverPreset.quad9Unfiltered.resolverVariant(for: .plainDNS), .quad9Unfiltered)
        XCTAssertEqual(DNSResolverPreset.quad9Unfiltered.resolverVariant(for: .dnsOverHTTPS), .quad9UnfilteredDoH)
        XCTAssertEqual(DNSResolverPreset.quad9Unfiltered.resolverVariant(for: .dnsOverTLS), .quad9UnfilteredDoT)
        XCTAssertEqual(DNSResolverPreset.quad9Unfiltered.availableTransports, [.plainDNS, .dnsOverHTTPS, .dnsOverTLS])
        XCTAssertEqual(DNSResolverPreset.hagezi.dnsOverHTTPSVariant, .hageziDoH)
        XCTAssertEqual(DNSResolverPreset.hagezi.dnsOverTLSVariant, .hageziDoT)
        XCTAssertEqual(DNSResolverPreset.hagezi.resolverVariant(for: .dnsOverHTTPS), .hageziDoH)
        XCTAssertEqual(DNSResolverPreset.hagezi.resolverVariant(for: .dnsOverTLS), .hageziDoT)
        XCTAssertEqual(DNSResolverPreset.hagezi.availableTransports, [.plainDNS, .dnsOverHTTPS, .dnsOverTLS])
        // Root cause for the Custom-DoQ clear coercion: Quad9 has no QUIC variant, so
        // resolverVariant(.dnsOverQUIC) degrades to the plain preset (transport != DoQ).
        XCTAssertEqual(DNSResolverPreset.quad9Unfiltered.resolverVariant(for: .dnsOverQUIC), .quad9Unfiltered)
        XCTAssertNotEqual(DNSResolverPreset.quad9Unfiltered.resolverVariant(for: .dnsOverQUIC).transport, .dnsOverQUIC)
    }

    func testDomainHistoryPullToRefreshUsesAuthorizedLocalDiagnostics() throws {
        let source = try readSource(.reactNativeAppQueries)
        XCTAssertFalse(source.contains("await model.sampleReports()"))
        XCTAssertTrue(source.contains("AuthorizedLocalReportRead.run"))
        XCTAssertTrue(source.contains("model.reports.refreshDiagnostics()"))
    }

    func testNerdStatsResolverTierUsesTheBaseResolverName() throws {
        // Nerd stats prints the transport on its own line and the System DNS row names
        // the same installer through settingsBasePreset, so tier rows must not repeat
        // the transport in the name ("Quad9 (DoH)" beside "Quad9").
        let source = try readSource(.reactNativeAppQueries)
        let tierBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolverTier(",
            endingBefore: "return rows.map"
        )
        XCTAssertTrue(tierBlock.contains("[preset.settingsBasePreset.displayName]"))
        XCTAssertFalse(tierBlock.contains("[preset.displayName]"))
    }

    func testScreenContentUsesNativeRefreshableInsteadOfCustomPullRefresh() throws {
        let source = try readSource(.lavaScaffold)
        let screenContentBlock = try sourceBlock(
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
        let source = try readSource(.dnsResolverSettingsView)
        let resolverBlock = try sourceBlock(
            in: source,
            startingAt: "struct DNSResolverSettingsView: View",
            endingBefore: "private struct ResolverTransportControl: View"
        )
        let customRowBlock = try sourceBlock(
            in: source,
            startingAt: "private struct CustomDNSResolverRow: View",
            endingBefore: "private struct ResolverTransportControl: View"
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

    func testFeedbackReviewStepLocalizesPlaceholderAndDiagnosticsValues() throws {
        let source = try readSource(.bugReportSettingsView)
        let feedbackBlock = try sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View"
        )
        let reviewPageBlock = try sourceBlock(
            in: feedbackBlock,
            startingAt: "private var reviewPage: some View",
            endingBefore: "private var thankYouPage: some View"
        )

        // The placeholder/status VALUES flow straight into BugReportReviewRow (which renders
        // them verbatim), so they must be localized AT THE CALL SITE — a bare "Not provided"
        // would render English in every locale. Both Details and Email echo the same placeholder.
        XCTAssertEqual(reviewPageBlock.occurrences(of: "\"Not provided\".lavaLocalized"), 2)
        XCTAssertTrue(reviewPageBlock.contains("\"Sent\".lavaLocalized"))
        XCTAssertTrue(reviewPageBlock.contains("\"Not sent\".lavaLocalized"))
        // No untranslated copies of these literals remain in the review echo.
        XCTAssertFalse(reviewPageBlock.contains("? \"Not provided\" :"))
        XCTAssertFalse(reviewPageBlock.contains("? \"Sent\" : \"Not sent\""))
    }

    func testFeedbackSubmitButtonLocalizesSubmitAndRetryCatalogKeys() throws {
        let source = try readSource(.bugReportSettingsView)
        let feedbackBlock = try sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View"
        )
        let submitTitleBlock = try sourceBlock(
            in: feedbackBlock,
            startingAt: "private var submitButtonTitle: String",
            endingBefore: "private func refreshDraft("
        )

        // The submit button title is a dynamic String piped through .lavaLocalized, so the
        // idle ("Submit") and failed ("Retry") labels must be catalog keys — "Submitting" was
        // already present, but the other two shipped English-only and rendered verbatim.
        XCTAssertTrue(submitTitleBlock.contains("\"Submit\""))
        XCTAssertTrue(submitTitleBlock.contains("\"Retry\""))
        XCTAssertTrue(submitTitleBlock.contains("\"Submitting\""))
        XCTAssertTrue(feedbackBlock.contains("Text(submitButtonTitle.lavaLocalized)"))

        let catalog = try readSource(.localizableStringsCatalog)
        for key in ["Submit", "Retry", "Submitting"] {
            XCTAssertTrue(catalog.contains("\"\(key)\": {"), "Missing localization catalog key: \(key)")
        }
    }

    func testFeedbackTopicSelectionReusesPreparedDiagnosticsInsteadOfRebuilding() throws {
        let source = try readSource(.bugReportSettingsView)
        let feedbackBlock = try sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View"
        )
        let topicChangeBlock = try sourceBlock(
            in: feedbackBlock,
            startingAt: ".onChange(of: selectedIssueType)",
            endingBefore: ".onChange(of: affectedSite)"
        )

        // Tapping a topic radio button only changes user-entered context (issue type /
        // affected site), never the device diagnostics — so it must take the cheap
        // context-only refresh that reuses the snapshot captured on appear, not the full
        // prepareBugReport that re-reads files and rebuilds the blocklist union on the main
        // thread (the lag that made the radio buttons feel slow; same class as UR-5 typing).
        XCTAssertTrue(topicChangeBlock.contains("refreshDraftContext()"))
        XCTAssertFalse(topicChangeBlock.contains("refreshDraft()"))
        XCTAssertTrue(feedbackBlock.contains("private func refreshDraftContext()"))
        XCTAssertTrue(feedbackBlock.contains("reports.refreshBugReportDraftContext(context: currentContext)"))
    }

    func testFeedbackTopicOptionRowSkipsRedundantReRenderViaEquatable() throws {
        let source = try readSource(.bugReportSettingsView)
        let feedbackBlock = try sourceBlock(
            in: source,
            startingAt: "struct BugReportSettingsView: View"
        )
        let topicPageBlock = try sourceBlock(
            in: feedbackBlock,
            startingAt: "private var topicPage: some View",
            endingBefore: "private var contextPage: some View"
        )

        // Fixing the on-tap rebuild (refreshDraftContext, above) removes the main-thread
        // lag, but SwiftUI still re-evaluates every unchanged row's body when a sibling's
        // `isSelected` flips unless the row opts out of diffing. `EquatableView` makes that
        // wrapper explicit so the optimization is not mistaken for a project-local modifier.
        XCTAssertTrue(topicPageBlock.contains("EquatableView(content: BugReportTopicOptionRow("))
        XCTAssertFalse(topicPageBlock.contains(".equatable()"))
        XCTAssertTrue(feedbackBlock.contains("private struct BugReportTopicOptionRow: View, Equatable"))
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
