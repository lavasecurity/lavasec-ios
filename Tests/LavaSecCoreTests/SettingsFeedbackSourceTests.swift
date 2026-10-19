import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class SettingsFeedbackSourceTests: XCTestCase {
    func testNetworkPrivacyActionBelongsToTheSharedPanelAndKeepsItsAccessibility() throws {
        let source = try readSource(.lavaComponents)
        let panel = try sourceBlock(in: source, startingAt: "struct LavaInfoPanel: View")
        XCTAssertTrue(panel.contains("@ViewBuilder action: () -> Action"))
        XCTAssertTrue(panel.containsInOrder([".accessibilityElement(children: .combine)", "if let action { action }"]))
    }

    func testNativeInfoPanelKeepsConfigurableBorderForRemainingAtoms() throws {
        let rootSource = try readSource(.lavaComponents)
        let infoPanelBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct LavaInfoPanel: View"
        )
        XCTAssertTrue(infoPanelBlock.contains("var borderTint: Color? = nil"))
        XCTAssertTrue(infoPanelBlock.contains("borderTint: borderTint"))
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

    func testDeviceDNSPresetOffersSelectableEncryptedFallback() throws {
        let source = try readSource(.reactNativeDNSScreen)
        XCTAssertTrue(source.contains("Resolution tiers in Lava"))
        XCTAssertTrue(source.contains("Add fallback DNS"))
        XCTAssertTrue(source.contains("target:'tier',index:tiers.length"))
        XCTAssertTrue(source.contains("type:'dns.tiers'"))
        XCTAssertTrue(source.contains("draft.tiers"))
    }

    func testClearingCustomDoQFallbackKeepsEncryptedDefault() throws {
        let source = try readSource(.reactNativeAppSettings)
        let clear = try sourceBlock(in: source, startingAt: "if cleared {", endingBefore: "        } else if fallback {")
        XCTAssertTrue(clear.contains("fallback, selected.transport == .dnsOverQUIC, replacement.transport != .dnsOverQUIC"))
        XCTAssertTrue(clear.contains("replacement = .quad9UnfilteredDoH"))
    }

    func testFeedbackTypingReusesPreparedDiagnosticsInsteadOfRebuildingPerKeystroke() throws {
        let source = try readSource(.reactNativeAppFeedback)
        let changes = try sourceBlock(in: source,
            startingAt: "switch action {",
            endingBefore: "return feedbackProjection(flow)")
        XCTAssertTrue(changes.contains("visit.draft.change(field, to: value)"))
        XCTAssertTrue(changes.contains("reports.refreshBugReportDraftContext(context: visit.draft.context)"))
        XCTAssertFalse(changes.contains("sampleReports("))
        XCTAssertFalse(changes.contains("prepareBugReport("))
        XCTAssertTrue(try readSource(.diagnosticsController).contains("debugLogEntries: inputs.debugLogEntries"))
    }


    func testFeedbackFlowGuardsDirtyDismissalAndRevalidatesBeforeSending() throws {
        let feedback = try readSource(.reactNativeAppFeedback)
        let submit = try sourceBlock(in: feedback, startingAt: "if action == \"feedback.submit\"",
                                     endingBefore: "guard visit.draft.phase == .editing, !reports.bugReportSendState.isSending")
        XCTAssertTrue(submit.containsInOrder([
            "let reviewed = visit.draft.beginSubmission(review: review)",
            "let authorization = security.viewAuthenticationRevision",
            "await model.sampleReports(force: true)",
            "guard feedbackVisit === visit, self.flow?.id == flow.id, canReadPresentation(.appUnlock),",
            "security.viewAuthenticationRevision == authorization, visit.draft.beginSending()",
            "reports.prepareBugReport(context: reviewed)",
            "await reports.sendBugReport(context: reviewed)"
        ]))
        XCTAssertFalse(submit.contains("sendBugReport(context: visit.draft.context)"))
        let flows = try readSource(.reactNativeAppFlows)
        XCTAssertTrue(flows.contains("guard feedbackOwner(flow.id).draft.canDismiss, !model.reports.bugReportSendState.isSending else { return false }"))
        XCTAssertTrue(flows.contains("retireFeedback(flow.id)"))
        XCTAssertTrue(try readSource(.rootView).contains("LavaAppNativeFlow(name: \"feedback\", onDismiss: dismiss)"))
        let mask = try readSource(.lavaSheetLockMask)
        XCTAssertTrue(mask.contains(".fill(LavaStyle.groupedBackground)"))
        XCTAssertTrue(mask.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(mask.contains(".accessibilityAddTraits(.isModal)"))
        XCTAssertTrue(mask.contains("Button(\"Unlock Lava\", action: unlock)"))
        XCTAssertFalse(mask.contains(".regularMaterial"))
        XCTAssertTrue(flows.contains("if security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible"))
        XCTAssertTrue(flows.contains("LavaSheetLockMask { Task { await security.authenticateAppUnlockIfNeeded() } }"))
    }

    func testFeedbackReceiptCopyRequiresTheSentVisit() throws {
        let source = try readSource(.reactNativeAppFeedback)
        let copy = try sourceBlock(in: source, startingAt: "if action == \"feedback.copy\"",
                                   endingBefore: "if action == \"feedback.submit\"")
        XCTAssertTrue(copy.contains("guard visit.draft.phase == .sent, !visit.receipt.isEmpty else { return false }"))
        XCTAssertTrue(copy.contains("UIPasteboard.general.string = visit.receipt"))
        XCTAssertTrue(copy.contains("visit.copied = UIPasteboard.general.string == visit.receipt"))
    }

    func testAccountPageRemovesFreeAccountInfoPanelAndUsesStandardAccountSheetChrome() throws {
        let source = try readSource(.reactNativeAccountBackupFlow)
        XCTAssertTrue(source.contains("if(s.kind==='account')return <FlowSheet>"))
        XCTAssertFalse(try readSource(.accountBackupSettingsView).contains("struct AccountSheet: View"))
    }

    func testNativePasscodeToolbarUsesNativeActions() throws {
        let adapter = try readSource(.reactNativePasscodeFlowAdapter)
        XCTAssertTrue(adapter.contains("toolbarAction('Cancel','close',cancel)"))
        XCTAssertTrue(adapter.contains("type:'passcode.command',id:state.id,action:'cancel'"))
        XCTAssertFalse(try readSource(.privacySecuritySettingsView).contains("struct SecurityPasscodeSetupView"))
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
        let source = try readSource(.reactNativeDNSScreen)
        XCTAssertTrue(source.contains("const choices=target==='profile'?live?.dnsPatch?.choices??[]"))
        XCTAssertTrue(source.contains("live?.dns.choices"))
        XCTAssertTrue(source.contains("['Device','DoH','DoT','IP','DoQ']"))
        XCTAssertTrue(source.contains("<CatalogSheet"))
        XCTAssertTrue(source.contains("title={choice.name} metadata={choice.metadata}"))
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
            endingBefore: "return rows.joined"
        )
        XCTAssertTrue(tierBlock.contains("dnsResolverDisplayName(preset.settingsBasePreset, customName: customName)"))
        XCTAssertTrue(tierBlock.contains("rows.append(preset.transport.displayName.lavaLocalized)"))
        XCTAssertFalse(tierBlock.contains("[preset.displayName]"))
        XCTAssertFalse(tierBlock.contains("rows.map"), "Provider and authored names must stay intact after composition.")
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
        let source = try readSource(.reactNativeDNSScreen)
        XCTAssertTrue(source.contains("[choice?.transport,choice?.metadata].filter(Boolean).join(' · ')"))
        XCTAssertTrue(source.contains("Add custom DNS"))
        XCTAssertTrue(source.contains("type:'dns.customDraft'"))
        XCTAssertTrue(source.contains("nav.navigate('CustomEntry',{id,kind:'dns'})"))
        XCTAssertTrue(try readSource(.reactNativeAppQueries).contains("func resolverMetadata(_ preset: DNSResolverPreset)"))
    }

    func testFeedbackEntryPreparesOnlyAfterTheCurrentAuthorizedSample() throws {
        let source = try readSource(.reactNativeAppFeedback)
        let enter = try sourceBlock(in: source, startingAt: "if action == \"feedback.enter\"",
                                    endingBefore: "if action == \"feedback.preview\"")
        XCTAssertTrue(enter.containsInOrder([
            "let authorization = security.viewAuthenticationRevision",
            "await model.sampleReports(force: true)",
            "guard self.flow?.id == flow.id, feedbackVisit === visit, visit.sampleRevision == sampling,",
            "canReadPresentation(.appUnlock), security.viewAuthenticationRevision == authorization,",
            "reports.prepareBugReport(context: visit.draft.context)"
        ]))
        let changes = try sourceBlock(in: source, startingAt: "case \"feedback.topic\":",
                                     endingBefore: "case \"feedback.change\":")
        XCTAssertTrue(changes.contains("visit.draft.selectTopic(topic)"))
        XCTAssertFalse(changes.contains("prepareBugReport("))
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
