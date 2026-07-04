import XCTest

/// Source-level guards for the shareable-filters feature (the app target isn't
/// compiled by `swift test`, so these assert on its source the way the rest of
/// the *SourceTests do).
final class ShareableFiltersSourceTests: XCTestCase {
    // MARK: Filters screen entry points

    func testFiltersScreenOffersShareAndImportRows() throws {
        let filtersSource = try readSource(.filtersView)
        let screen = try sourceBlock(
            in: filtersSource,
            startingAt: "private var filtersScreen: some View",
            endingBefore: "private struct FiltersOverviewPanel"
        )

        // Multi-filter consolidates the active-filter ("Now filtering") row and the
        // library entry under a single conversational "What's filtering?" section.
        XCTAssertTrue(screen.contains("FilterInEffectRow"))
        XCTAssertTrue(screen.contains("LavaSectionGroup(\"What's filtering?\")"))
        XCTAssertTrue(screen.contains("LavaSectionGroup(\"Got a good filter?\")"))
        XCTAssertTrue(screen.contains("title: \"Share my filter\""))
        XCTAssertTrue(screen.contains("title: \"Import a filter\""))
        // Share now opens a "Choose a filter to share" picker that presents the share
        // sheet per chosen filter (was a single ShareFiltersSheet() of the active filter).
        XCTAssertTrue(filtersSource.contains("ChooseFilterToShareView()"))
        XCTAssertTrue(filtersSource.contains("ShareFiltersSheet(code:"))
        XCTAssertTrue(filtersSource.contains("ImportFiltersFlow("))
        XCTAssertTrue(filtersSource.contains("startMode: .chooseMethod"))
        // The in-app import sheet (live QR scanner / preview) is withheld while
        // App Unlock is pending — it presents above the lock overlay, so it must
        // be torn down (camera off), not left readable. Mirrors the deeplink
        // importer's withhold gate.
        XCTAssertTrue(filtersSource.contains("private var importFiltersSheetBinding: Binding<Bool>"))
        // Withheld while the lock overlay OR the app-switcher privacy mask is up
        // (the latter keeps the live scanner out of the .inactive snapshot).
        XCTAssertTrue(filtersSource.contains("isImportingFilters && !(security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible)"))
        XCTAssertTrue(filtersSource.contains(".sheet(isPresented: importFiltersSheetBinding)"))
    }

    // MARK: Share sheet — masked QR + copyable code

    func testShareSheetMasksQRAndOffersCopyableCode() throws {
        let source = try readSource(.shareableFiltersUI)

        // QR is hidden until explicitly revealed.
        XCTAssertTrue(source.contains("@State private var isQRRevealed = false"))
        XCTAssertTrue(source.contains("Show the QR Code"))
        XCTAssertTrue(source.contains(".blur(radius: isQRRevealed ? 0 : 18)"))
        // Copyable setup code (plain-language rename of "config code").
        XCTAssertTrue(source.contains("UIPasteboard.general.string = code"))
        XCTAssertTrue(source.contains("Copy setup code"))
        // Security info panel explaining only the block side is shared.
        XCTAssertTrue(source.contains("Only your block list is shared"))
    }

    // MARK: Import flow — code entry + scanner

    func testImportFlowHasFreeformCodeEntryAndScanner() throws {
        let source = try readSource(.shareableFiltersUI)

        // Freeform scaffold entry with a Continue button and chevron back / skip.
        XCTAssertTrue(source.contains("struct ImportFiltersFlow: View"))
        XCTAssertTrue(source.contains("LavaTextEditorInputRow("))
        XCTAssertTrue(source.contains("Button(\"Continue\")"))
        XCTAssertTrue(source.contains("systemName: \"chevron.left\""))
        XCTAssertTrue(source.contains("Button(\"Skip\", action: onSkip)"))
        // Camera scanner.
        XCTAssertTrue(source.contains("struct QRCodeScannerRepresentable: UIViewControllerRepresentable"))
        XCTAssertTrue(source.contains("output.metadataObjectTypes = [.qr]"))
        // The capture session powers down on resign-active (app switcher), not just
        // on navigation away, so the camera never runs behind the privacy shield —
        // including when App Unlock is off.
        XCTAssertTrue(source.contains("UIApplication.willResignActiveNotification"))
        XCTAssertTrue(source.contains("UIApplication.didBecomeActiveNotification"))
        XCTAssertTrue(source.contains("@objc private func appWillResignActive()"))
        XCTAssertTrue(source.contains("private func stopSession()"))
        // Additive import: the preview offers Add-as-new + Replace (no blanket replace).
        XCTAssertTrue(source.contains("Add as a new filter"))
        XCTAssertTrue(source.contains("Replace a filter instead"))
    }

    func testImportIsAdditiveWithAddNewAndReplacePaths() throws {
        let app = try readSource(.appViewModel)
        let ui = try readSource(.shareableFiltersUI)

        // Add-as-new is library-only (append + persistLibraryOnlyChange), gated on canCreateFilter
        // + a unique name, and never touches the active config / tunnel.
        let addNew = try sourceBlock(
            in: app,
            startingAt: "func addImportedShareableConfigurationAsNewFilter(",
            endingBefore: "func replaceFilterWithImportedShareableConfiguration("
        )
        // Applies the carried (already-previewed) plan — no per-destination re-plan, so what was
        // previewed is what's added.
        XCTAssertTrue(addNew.contains("guard canCreateFilter, !applied.isEmpty else { return nil }"))
        XCTAssertTrue(addNew.contains("guard isFilterNameAvailable(trimmed) else { return nil }"))
        XCTAssertFalse(addNew.contains("importPlan("), "Add must apply the carried plan, not re-plan.")
        XCTAssertTrue(addNew.contains("library.append(newFilter)"))
        XCTAssertTrue(addNew.contains("persistLibraryOnlyChange(rollingBackTo: previousLibrary)"))
        XCTAssertFalse(addNew.contains("prepareFilterSnapshot"), "Add-as-new must not compile.")
        XCTAssertFalse(addNew.contains("persistSharedState"), "Add-as-new must not reload the tunnel.")

        // Replace forks: the active filter uses the full apply path (reload); a non-active filter
        // is replaced library-only (mutateFilter + token invalidation + persistLibraryOnlyChange).
        let replace = try sourceBlock(
            in: app,
            startingAt: "func replaceFilterWithImportedShareableConfiguration(",
            endingBefore: "private static func filterPreparationFailureMessage("
        )
        XCTAssertTrue(replace.contains("if id == library.activeFilterID {"))
        XCTAssertTrue(replace.contains("return await applyImportedShareableConfiguration(applied)"))
        XCTAssertTrue(replace.contains("library.mutateFilter(id: id)"))
        XCTAssertTrue(replace.contains("filter.lastCompiledToken = nil"))
        XCTAssertTrue(replace.contains("guard let target = library.filter(id: id), !isFilterFrozen(id) else {"),
                      "Replace must refuse an unknown or frozen target.")
        // A replace invalidates that filter's per-filter draft (built from the old contents).
        XCTAssertTrue(replace.contains("filterEditDrafts[id] = nil"))

        // Onboarding (library pre-seeded to the cap) makes the import the ACTIVE filter rather than
        // offering "add as new" — a single "Use this filter" action gated by allowsAddingNewFilter.
        XCTAssertTrue(ui.contains("allowsAddingNewFilter"))
        XCTAssertTrue(ui.contains("if allowsAddingNewFilter {"))
        XCTAssertTrue(ui.contains("Use this filter"))
        XCTAssertTrue(ui.contains("func replaceActive("))
        let onboarding = try readSource(.onboardingFlowView)
        XCTAssertEqual(onboarding.components(separatedBy: "allowsAddingNewFilter: false").count - 1, 2,
                       "Both onboarding import entry points (enter/scan) must disable add-as-new.")

        // The UI offers Add (paywall at the cap) + Replace (filter picker), no blanket replace.
        XCTAssertTrue(ui.contains("if viewModel.canCreateFilter {"))
        XCTAssertTrue(ui.contains("showingPaywall = true"))
        XCTAssertTrue(ui.contains("LavaPlusUpgradeSheet()"))
        XCTAssertTrue(ui.contains("struct ImportNameNewFilterView"))
        XCTAssertTrue(ui.contains("struct ImportChooseReplaceTargetView"))
        XCTAssertTrue(ui.contains("case nameNew(ShareableFilterConfiguration)"))
        XCTAssertTrue(ui.contains("case chooseReplace(ShareableFilterConfiguration)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(app.contains("importPlan"))
        XCTAssertTrue(app.contains("prepareFilterSnapshot"))
        XCTAssertTrue(app.contains("persistSharedState"))
    }

    func testFilterNamesAreUniqueAcrossCreateRenameImport() throws {
        let app = try readSource(.appViewModel)

        XCTAssertTrue(app.contains("func isFilterNameAvailable(_ name: String, excluding excludedID: String? = nil) -> Bool"))
        // Create rejects a duplicate explicit name; rename rejects a duplicate (excluding itself).
        let create = try sourceBlock(
            in: app,
            startingAt: "func createFilter(name: String, duplicatingFilterID: String? = nil) -> String? {",
            endingBefore: "private func persistLibraryOnlyChange("
        )
        XCTAssertTrue(create.contains("guard isFilterNameAvailable(trimmed) else { return nil }"))
        let rename = try sourceBlock(
            in: app,
            startingAt: "func renameFilter(id: String, to name: String) {",
            endingBefore: "func deleteFilter("
        )
        XCTAssertTrue(rename.contains("isFilterNameAvailable(trimmed, excluding: id)"))

        // The create/rename sheets disable their confirm action on a duplicate name.
        let filtersView = try readSource(.filtersView)
        XCTAssertTrue(filtersView.contains("viewModel.isFilterNameAvailable($0, excluding: filter.id)"))
        XCTAssertTrue(filtersView.contains("private var isDuplicate: Bool"))
    }

    func testScannerHandlesMultiLensAndAdjustableFocus() throws {
        let source = try readSource(.shareableFiltersUI)

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
        let source = try readSource(.shareableFiltersUI)
        XCTAssertTrue(source.contains("This setup is too large for a QR code"))
    }

    func testCodecCompressesPayload() throws {
        let source = try readSource(.shareableFilterConfiguration)
        XCTAssertTrue(source.contains("compressed(using: .zlib)"))
        XCTAssertTrue(source.contains("boundedInflate("))
    }

    func testCodecBoundsUntrustedPayloadSize() throws {
        let source = try readSource(.shareableFilterConfiguration)
        XCTAssertTrue(source.contains("case payloadTooLarge"))
        XCTAssertTrue(source.contains("maxEncodedCodeLength"))
        XCTAssertTrue(source.contains("maxInflatedPayloadBytes"))
        // Streaming inflate stops once output passes the limit.
        XCTAssertTrue(source.contains("if output.count > limit"))
    }

    func testImportApplyIsGatedBehindFilterEditingAuth() throws {
        let uiSource = try readSource(.shareableFiltersUI)
        XCTAssertTrue(uiSource.contains("var authorizeImport: () async -> Bool"))
        XCTAssertTrue(uiSource.contains("guard await authorizeImport() else"))

        let filtersSource = try readSource(.filtersView)
        XCTAssertTrue(filtersSource.contains("requireFreshAuthentication(for: .filterEditing"))
    }

    func testScannerSurfacesCameraDeniedRecovery() throws {
        let source = try readSource(.shareableFiltersUI)
        XCTAssertTrue(source.contains("onCameraAuthorizationDenied"))
        XCTAssertTrue(source.contains("Camera access is off"))
        XCTAssertTrue(source.contains("UIApplication.openSettingsURLString"))
        // Returning from Settings re-checks authorization so the scanner remounts.
        XCTAssertTrue(source.contains("onChange(of: scenePhase)"))
        XCTAssertTrue(source.contains("AVCaptureDevice.authorizationStatus(for: .video) == .authorized"))
    }

    func testImportPreviewWarnsAndListsUnsupportedEntries() throws {
        let source = try readSource(.shareableFiltersUI)
        let preview = try sourceBlock(
            in: source,
            startingAt: "private struct ImportPreviewView: View",
            endingBefore: "private struct ImportContentRow"
        )

        // Additive import: the preview is neutral (no "replaces your filter" warning) and offers
        // both Add-as-new and Replace.
        XCTAssertTrue(preview.contains("LavaInfoPanel("))
        XCTAssertTrue(preview.contains("Import this filter"))
        XCTAssertFalse(preview.contains("This replaces your filter"))
        XCTAssertTrue(preview.contains("onAddNew"))
        XCTAssertTrue(preview.contains("onReplace"))
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
        XCTAssertTrue(preview.contains("+%lld more"))
        // Unsupported entries get an alert row treatment.
        XCTAssertTrue(preview.contains("if plan.hasUnsupportedEntries"))
        XCTAssertTrue(preview.contains("unsupportedSection(for: plan)"))
        XCTAssertTrue(source.contains("struct ImportAlertRow: View"))
    }

    func testViewModelComputesRobustImportPlan() throws {
        let viewModelSource = try readSource(.appViewModel)
        XCTAssertTrue(viewModelSource.contains("func importPlan(for shared: ShareableFilterConfiguration) -> ShareableFilterImportPlan"))
        XCTAssertTrue(viewModelSource.contains("allowsCustomBlocklists: configuration.limits.allowsCustomBlocklists"))
        XCTAssertTrue(viewModelSource.contains("maxBlockedDomains: configuration.limits.maxBlockedDomains"))
        XCTAssertTrue(viewModelSource.contains("maxFilterRules: configuration.limits.maxFilterRules"))
        XCTAssertTrue(viewModelSource.contains("blocklistRuleCounts:"))
        // The rule budget reserves the DESTINATION filter's allowlist (param), not always the active
        // filter's — so add-as-new (0) and a non-active replace (the target's count) plan correctly.
        XCTAssertTrue(viewModelSource.contains("preservedRuleCount: preservedAllowedDomainCount"))
        XCTAssertTrue(viewModelSource.contains("preservedAllowedDomainCount: Int"))

        // Imported custom lists are treated as untrusted: reserved IDs (curated +
        // guardrail) guard against shadowing, and empty plans can't wipe filters.
        XCTAssertTrue(viewModelSource.contains("reservedBlocklistIDs:"))
        XCTAssertTrue(viewModelSource.contains("DefaultCatalog.guardrailSources"))
        XCTAssertTrue(viewModelSource.contains("guard !applied.isEmpty else"))

        // The import flow carries the EXACT previewed plan (importPlan(for:) convenience) into both
        // apply methods, so the preview and the applied result never diverge.
        let uiSource = try readSource(.shareableFiltersUI)
        XCTAssertTrue(uiSource.contains("let applied = viewModel.importPlan(for: config).applied"))
        XCTAssertTrue(uiSource.contains("addImportedShareableConfigurationAsNewFilter(applied, name: name)"))
        XCTAssertTrue(uiSource.contains("replaceFilterWithImportedShareableConfiguration("))
        XCTAssertTrue(uiSource.contains("id: filter.id,"))
        // The preview uses the same importPlan convenience (worst-case headroom).
        XCTAssertTrue(uiSource.contains("viewModel.importPlan(for: configuration)"))
    }

    func testInfoPlistDeclaresCameraUsage() throws {
        let plist = try readSource(.appInfoPlist)
        XCTAssertTrue(plist.contains("NSCameraUsageDescription"))
    }

    // MARK: Onboarding — fine-tune step removed, additional setup added

    func testOnboardingRemovesCustomizeStep() throws {
        let source = try readSource(.onboardingFlowView)

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
        XCTAssertTrue(source.contains("if nextPage == .done {\n            viewModel.applyOnboardingRecommendedDefaults(protectionLevel: protectionLevel)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("OnboardingPrimaryButton"))
    }

    func testOnboardingDoneOffersGuardAndImportLivesInHeader() throws {
        let source = try readSource(.onboardingFlowView)
        let footer = try sourceBlock(
            in: source,
            startingAt: "private var footerButtons: some View",
            endingBefore: "private var activeDotColor"
        )

        // The done step's footer is just "Open Guard"; the old "Additional setup"
        // secondary button is gone — its import on-ramp moved to a persistent header
        // action ("Import a filter") in the top bar.
        XCTAssertTrue(footer.contains("OnboardingPrimaryButton(title: \"Open Guard\")"))
        XCTAssertFalse(footer.contains("OnboardingSecondaryButton(title: \"Additional setup\")"))

        let topBar = try sourceBlock(
            in: source,
            startingAt: "private var topBar: some View",
            endingBefore: "@ViewBuilder"
        )
        XCTAssertTrue(topBar.contains("Text(\"Import a filter\")"))
        XCTAssertTrue(topBar.contains("isShowingAdditionalSetup = true"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("OnboardingSecondaryButton"))
    }

    func testAdditionalSetupSheetOffersThreeOptionsIncludingSettings() throws {
        let source = try readSource(.onboardingFlowView)
        let sheet = try sourceBlock(
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
        let source = try readSource(.rootView)
        let onboardingSheet = try sourceBlock(
            in: source,
            startingAt: "LavaOnboardingView(",
            endingBefore: ".onAppear"
        )

        // The Go-to-Settings shortcut must go through the auth-gated opener, not
        // select the protected Settings tab directly.
        XCTAssertTrue(onboardingSheet.contains("onRequestOpenSettings:"))
        XCTAssertTrue(onboardingSheet.contains("openSettingsRoot()"))
        XCTAssertFalse(onboardingSheet.contains("selectedRootTab = .settings"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("selectedRootTab"))
    }

    // MARK: View model wiring

    func testViewModelExposesShareAndImportEntryPoints() throws {
        let source = try readSource(.appViewModel)

        XCTAssertTrue(source.contains("var shareableFilterConfigurationCode: String"))
        XCTAssertTrue(source.contains("func applyImportedShareableConfiguration("))
        XCTAssertTrue(source.contains("applyingImportedShareableConfiguration("))
    }

    // MARK: Helpers
}
