import XCTest

/// Source-level guards for the shareable-filters feature (the app target isn't
/// compiled by `swift test`, so these assert on its source the way the rest of
/// the *SourceTests do).
final class ShareableFiltersSourceTests: XCTestCase {
    // MARK: Filters screen entry points

    func testFiltersScreenOffersShareAndImportRows() throws {
        let filtersSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let screen = try Self.sourceBlock(
            in: filtersSource,
            startingAt: "private var filtersScreen: some View",
            endingBefore: "private struct FiltersOverviewPanel"
        )

        XCTAssertTrue(screen.contains("LavaSectionGroup(\"My filter\")"))
        XCTAssertTrue(screen.contains("LavaSectionGroup(\"Got a good filter?\")"))
        XCTAssertTrue(screen.contains("title: \"Share my filter\""))
        XCTAssertTrue(screen.contains("title: \"Import a filter\""))
        XCTAssertTrue(filtersSource.contains("ShareFiltersSheet()"))
        XCTAssertTrue(filtersSource.contains("ImportFiltersFlow("))
        XCTAssertTrue(filtersSource.contains("startMode: .chooseMethod"))
    }

    // MARK: Share sheet — masked QR + copyable code

    func testShareSheetMasksQRAndOffersCopyableCode() throws {
        let source = try Self.source(named: "ShareableFiltersUI.swift", in: "LavaSecApp")

        // QR is hidden until explicitly revealed.
        XCTAssertTrue(source.contains("@State private var isQRRevealed = false"))
        XCTAssertTrue(source.contains("Show the QR Code"))
        XCTAssertTrue(source.contains(".blur(radius: isQRRevealed ? 0 : 18)"))
        // Copyable config code.
        XCTAssertTrue(source.contains("UIPasteboard.general.string = code"))
        XCTAssertTrue(source.contains("Copy config code"))
        // Security info panel explaining only the block side is shared.
        XCTAssertTrue(source.contains("Only your block list is shared"))
    }

    // MARK: Import flow — code entry + scanner

    func testImportFlowHasFreeformCodeEntryAndScanner() throws {
        let source = try Self.source(named: "ShareableFiltersUI.swift", in: "LavaSecApp")

        // Freeform scaffold entry with a Continue button and chevron back / skip.
        XCTAssertTrue(source.contains("struct ImportFiltersFlow: View"))
        XCTAssertTrue(source.contains("LavaTextEditorInputRow("))
        XCTAssertTrue(source.contains("Button(\"Continue\")"))
        XCTAssertTrue(source.contains("systemName: \"chevron.left\""))
        XCTAssertTrue(source.contains("Button(\"Skip\", action: onSkip)"))
        // Camera scanner.
        XCTAssertTrue(source.contains("struct QRCodeScannerRepresentable: UIViewControllerRepresentable"))
        XCTAssertTrue(source.contains("output.metadataObjectTypes = [.qr]"))
        // Replace confirmation.
        XCTAssertTrue(source.contains("Replace my filter"))
    }

    func testScannerHandlesMultiLensAndAdjustableFocus() throws {
        let source = try Self.source(named: "ShareableFiltersUI.swift", in: "LavaSecApp")

        // Multi-lens virtual device so the system can switch lenses for close focus.
        XCTAssertTrue(source.contains("AVCaptureDevice.DiscoverySession"))
        XCTAssertTrue(source.contains(".builtInTripleCamera"))
        XCTAssertTrue(source.contains(".builtInDualWideCamera"))
        // Higher resolution for dense codes.
        XCTAssertTrue(source.contains(".hd1920x1080"))
        // Continuous + near-range autofocus, plus tap-to-focus.
        XCTAssertTrue(source.contains(".continuousAutoFocus"))
        XCTAssertTrue(source.contains("autoFocusRangeRestriction = .near"))
        XCTAssertTrue(source.contains("func handleTapToFocus"))
        XCTAssertTrue(source.contains("focusPointOfInterest = focusPoint"))
    }

    func testShareSheetGuardsOversizedQRCodes() throws {
        let source = try Self.source(named: "ShareableFiltersUI.swift", in: "LavaSecApp")
        XCTAssertTrue(source.contains("This setup is too large for a QR code"))
    }

    func testCodecCompressesPayload() throws {
        let source = try Self.source(named: "ShareableFilterConfiguration.swift", in: "Sources/LavaSecCore")
        XCTAssertTrue(source.contains("compressed(using: .zlib)"))
        XCTAssertTrue(source.contains("boundedInflate("))
    }

    func testCodecBoundsUntrustedPayloadSize() throws {
        let source = try Self.source(named: "ShareableFilterConfiguration.swift", in: "Sources/LavaSecCore")
        XCTAssertTrue(source.contains("case payloadTooLarge"))
        XCTAssertTrue(source.contains("maxEncodedCodeLength"))
        XCTAssertTrue(source.contains("maxInflatedPayloadBytes"))
        // Streaming inflate stops once output passes the limit.
        XCTAssertTrue(source.contains("if output.count > limit"))
    }

    func testImportApplyIsGatedBehindFilterEditingAuth() throws {
        let uiSource = try Self.source(named: "ShareableFiltersUI.swift", in: "LavaSecApp")
        XCTAssertTrue(uiSource.contains("var authorizeImport: () async -> Bool"))
        XCTAssertTrue(uiSource.contains("guard await authorizeImport() else"))

        let filtersSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        XCTAssertTrue(filtersSource.contains("requireFreshAuthentication(for: .filterEditing"))
    }

    func testScannerSurfacesCameraDeniedRecovery() throws {
        let source = try Self.source(named: "ShareableFiltersUI.swift", in: "LavaSecApp")
        XCTAssertTrue(source.contains("onCameraAuthorizationDenied"))
        XCTAssertTrue(source.contains("Camera access is off"))
        XCTAssertTrue(source.contains("UIApplication.openSettingsURLString"))
        // Returning from Settings re-checks authorization so the scanner remounts.
        XCTAssertTrue(source.contains("onChange(of: scenePhase)"))
        XCTAssertTrue(source.contains("AVCaptureDevice.authorizationStatus(for: .video) == .authorized"))
    }

    func testImportPreviewWarnsAndListsUnsupportedEntries() throws {
        let source = try Self.source(named: "ShareableFiltersUI.swift", in: "LavaSecApp")
        let preview = try Self.sourceBlock(
            in: source,
            startingAt: "private struct ImportPreviewView: View",
            endingBefore: "private struct ImportContentRow"
        )

        // Override warning uses the shared info-panel scaffold.
        XCTAssertTrue(preview.contains("LavaInfoPanel("))
        XCTAssertTrue(preview.contains("This replaces your filter"))
        // The preview breaks down the actual content being imported (resolved
        // names + domains), not bare counts — and reflects the planned subset.
        XCTAssertTrue(preview.contains("LavaSectionGroup(\"Curated blocklists\")"))
        XCTAssertTrue(preview.contains("LavaSectionGroup(\"Custom blocklists\")"))
        XCTAssertTrue(preview.contains("LavaSectionGroup(\"Blocked domains\")"))
        XCTAssertTrue(preview.contains("viewModel.blocklistName(for:"))
        XCTAssertTrue(preview.contains("plan.applied.customBlocklists"))
        XCTAssertTrue(preview.contains("plan.applied.blockedDomains"))
        // Long domain lists collapse into a "+N more" note.
        XCTAssertTrue(preview.contains("blockedDomainPreviewLimit"))
        XCTAssertTrue(preview.contains("+\\(hiddenDomainCount) more"))
        // Unsupported entries get an alert row treatment.
        XCTAssertTrue(preview.contains("if plan.hasUnsupportedEntries"))
        XCTAssertTrue(preview.contains("unsupportedSection(for: plan)"))
        XCTAssertTrue(source.contains("struct ImportAlertRow: View"))
    }

    func testViewModelComputesRobustImportPlan() throws {
        let viewModelSource = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        XCTAssertTrue(viewModelSource.contains("func importPlan(for shared: ShareableFilterConfiguration) -> ShareableFilterImportPlan"))
        XCTAssertTrue(viewModelSource.contains("allowsCustomBlocklists: configuration.limits.allowsCustomBlocklists"))
        XCTAssertTrue(viewModelSource.contains("maxBlockedDomains: configuration.limits.maxBlockedDomains"))
        XCTAssertTrue(viewModelSource.contains("maxFilterRules: configuration.limits.maxFilterRules"))
        XCTAssertTrue(viewModelSource.contains("blocklistRuleCounts:"))
        XCTAssertTrue(viewModelSource.contains("preservedRuleCount: configuration.allowedDomains.count"))

        // Imported custom lists are treated as untrusted: reserved IDs (curated +
        // guardrail) guard against shadowing, and empty plans can't wipe filters.
        XCTAssertTrue(viewModelSource.contains("reservedBlocklistIDs:"))
        XCTAssertTrue(viewModelSource.contains("DefaultCatalog.guardrailSources"))
        XCTAssertTrue(viewModelSource.contains("guard !applied.isEmpty else"))

        // The import flow applies the *planned* subset, not the raw decoded config.
        let uiSource = try Self.source(named: "ShareableFiltersUI.swift", in: "LavaSecApp")
        XCTAssertTrue(uiSource.contains("let plan = viewModel.importPlan(for: config)"))
        XCTAssertTrue(uiSource.contains("applyImportedShareableConfiguration(plan.applied)"))
    }

    func testInfoPlistDeclaresCameraUsage() throws {
        let plist = try Self.source(named: "Info.plist", in: "LavaSecApp")
        XCTAssertTrue(plist.contains("NSCameraUsageDescription"))
    }

    // MARK: Onboarding — fine-tune step removed, additional setup added

    func testOnboardingRemovesCustomizeStep() throws {
        let source = try Self.source(named: "OnboardingFlowView.swift", in: "LavaSecApp")

        XCTAssertFalse(source.contains("case customize"))
        XCTAssertFalse(source.contains("private var customizePage"))
        XCTAssertFalse(source.contains("title: \"Customize Lava\""))
        XCTAssertFalse(source.contains("OnboardingPrimaryButton(title: \"Finish Setup\")"))

        // The standalone "Decide how Lava works" step is gone entirely.
        XCTAssertFalse(source.contains("title: \"Decide how Lava works\""))
        XCTAssertFalse(source.contains("private var settingsPage"))
        XCTAssertFalse(source.contains("case settings"))
        XCTAssertFalse(source.contains("OnboardingPrimaryButton(title: \"Use These Settings\")"))
        // Its recommended defaults are now applied silently as setup wraps up.
        XCTAssertTrue(source.contains("if nextPage == .done {\n            viewModel.applyOnboardingRecommendedDefaults()"))
    }

    func testOnboardingDoneStepOffersGuardAndAdditionalSetup() throws {
        let source = try Self.source(named: "OnboardingFlowView.swift", in: "LavaSecApp")
        let footer = try Self.sourceBlock(
            in: source,
            startingAt: "private var footerButtons: some View",
            endingBefore: "private var activeDotColor"
        )

        XCTAssertTrue(footer.contains("OnboardingPrimaryButton(title: \"Open Guard\")"))
        XCTAssertTrue(footer.contains("OnboardingSecondaryButton(title: \"Additional setup\")"))
    }

    func testAdditionalSetupSheetOffersThreeOptionsIncludingSettings() throws {
        let source = try Self.source(named: "OnboardingFlowView.swift", in: "LavaSecApp")
        let sheet = try Self.sourceBlock(
            in: source,
            startingAt: "private struct OnboardingAdditionalSetupSheet: View",
            endingBefore: "private struct OnboardingLavaFloor"
        )

        XCTAssertTrue(sheet.contains("title: \"Scan a QR code\""))
        XCTAssertTrue(sheet.contains("title: \"Enter a code\""))
        XCTAssertTrue(sheet.contains("title: \"Go to Settings\""))
        XCTAssertTrue(sheet.contains("onGoToSettings()"))
        XCTAssertTrue(sheet.contains("ImportFiltersFlow("))
    }

    func testRootViewRoutesGoToSettingsThroughAuthGatedOpener() throws {
        let source = try Self.source(named: "RootView.swift", in: "LavaSecApp")
        let onboardingSheet = try Self.sourceBlock(
            in: source,
            startingAt: "LavaOnboardingView(",
            endingBefore: ".onAppear"
        )

        // The Go-to-Settings shortcut must go through the auth-gated opener, not
        // select the protected Settings tab directly.
        XCTAssertTrue(onboardingSheet.contains("onRequestOpenSettings:"))
        XCTAssertTrue(onboardingSheet.contains("openSettingsRoot()"))
        XCTAssertFalse(onboardingSheet.contains("selectedRootTab = .settings"))
    }

    // MARK: View model wiring

    func testViewModelExposesShareAndImportEntryPoints() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")

        XCTAssertTrue(source.contains("var shareableFilterConfigurationCode: String"))
        XCTAssertTrue(source.contains("func applyImportedShareableConfiguration("))
        XCTAssertTrue(source.contains("applyingImportedShareableConfiguration("))
    }

    // MARK: Helpers

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
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)

        return String(suffix[..<end])
    }
}
