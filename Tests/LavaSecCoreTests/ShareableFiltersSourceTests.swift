import XCTest

/// Source-level guards for the shareable-filters feature (the app target isn't
/// compiled by `swift test`, so these assert on its source the way the rest of
/// the *SourceTests do).
final class ShareableFiltersSourceTests: XCTestCase {
    func testSharedImportAvailabilityDoesNotResurrectBundledOrConfiguredLists() throws {
        let app = try readAppViewModelSource()
        let plan = try sourceBlock(in: app, startingAt: "func importPlan(\n",
            endingBefore: "func applyImportedShareableConfiguration(")
        XCTAssertTrue(plan.contains("let availableCuratedIDs = Set(publishedSources.keys)"))
        XCTAssertTrue(plan.contains("let publishedSources = sharedImportCatalogSourcesByID ?? [:]"))
        XCTAssertFalse(plan.contains("curatedIDs.union(catalogSourcesByID.keys)"))
        XCTAssertFalse(plan.contains("configuration.enabledBlocklistIDs"))
        XCTAssertTrue(plan.contains("knownCatalogSourceIDForSharedImport(source.sourceURL)"))
        XCTAssertTrue(plan.contains("catalogSourceIDsByCustomURL: catalogSourceIDsByCustomURL"))
    }
    func testImportCatalogRefreshDoesNotMutateInstalledFiltersOrCaches() throws {
        let app = try readAppViewModelSource()
        let refresh = try sourceBlock(in: app, startingAt: "func refreshCatalogForSharedImport(",
            endingBefore: "func applyImportedShareableConfiguration(")
        XCTAssertTrue(refresh.contains("fetchPublishedCatalog()"))
        XCTAssertTrue(refresh.contains("dataFetcher: makeBootstrapAwareCatalogDataFetcher()"))
        let fetcher = try sourceBlock(in: app, startingAt: "func makeBootstrapAwareCatalogDataFetcher()",
            endingBefore: "lazy var filterSnapshotPreparationService")
        XCTAssertTrue(fetcher.contains("BlocklistCatalogSynchronizer.bootstrapAwareDataFetcher"))
        XCTAssertTrue(fetcher.contains("resolveBootstrapHostThroughTunnel(hostname)"))
        XCTAssertTrue(refresh.contains("sharedImportCatalogSourcesByID = nil"))
        XCTAssertTrue(refresh.contains("let knownCatalogIDs = Set(DefaultCatalog.curatedSources.map(\\.id)).union(catalogSourcesByID.keys)"))
        XCTAssertTrue(refresh.contains("!shared.enabledBlocklistIDs.isDisjoint(with: knownCatalogIDs)"))
        XCTAssertTrue(refresh.contains("knownCatalogSourceIDForSharedImport($0.sourceURL) != nil"))
        let matcher = try sourceBlock(in: app, startingAt: "private func knownCatalogSourceIDForSharedImport(",
            endingBefore: "func refreshCatalogForSharedImport(")
        XCTAssertTrue(matcher.contains("catalogSourcesByID.values"))
        XCTAssertTrue(matcher.contains("sharedImportCatalogSourcesByID ?? [:]"))
        XCTAssertTrue(matcher.contains("additionalSourceIDsByURL: knownURLs"))
        XCTAssertTrue(matcher.contains("KnownBlocklistURLMatcher.catalogSourceIDForImport(for: url"))
        let currentLookup = try XCTUnwrap(matcher.range(of: "additionalSourceIDsByURL: publishedURLs"))
        let cachedLookup = try XCTUnwrap(matcher.range(of: "additionalSourceIDsByURL: knownURLs"))
        XCTAssertLessThan(currentLookup.lowerBound, cachedLookup.lowerBound)
        XCTAssertTrue(matcher.contains("published.contains(where: { $0.id == currentID })"))
        for mutation in ["configuration =", "library.", "persistSharedState", "applyCatalogSyncResult", "catalogSourcesByID ="] {
            XCTAssertFalse(refresh.contains(mutation), mutation)
        }
        let ui = try readSource(.shareableFiltersUI)
        XCTAssertTrue(ui.contains("try await viewModel.refreshCatalogForSharedImport(configuration)"))
        XCTAssertTrue(ui.contains(".disabled(checkingCatalog || catalogCheckFailed || plan.applied.isEmpty)"))
        XCTAssertTrue(ui.contains("Text(Self.unavailableListsMessage(completion.unavailableListCount))"))
    }

    // MARK: Filters screen entry points

    func testFiltersScreenOffersToolbarImportAndContextualSharing() throws {
        let source = try readSource(.reactNativeFilterScreens)
        XCTAssertTrue(source.contains("Share my filter"))
        XCTAssertTrue(source.contains("Import a filter"))
        XCTAssertTrue(source.contains("nav.navigate('ShareDetail'"))
    }

    // MARK: Share sheet — masked QR + copyable code

    func testShareSheetMasksQRAndOffersCopyableCode() throws {
        let source = try readSource(.reactNativeFilterScreens)
        XCTAssertTrue(source.contains("PrivateQRCode"))
        XCTAssertTrue(source.contains("useState(false)"))
        XCTAssertTrue(source.contains("type:'share.copy'"))
        XCTAssertTrue(source.contains("Copy setup code"))
    }

    func testNativeShareSheetUsesTheSharedConcealmentChoiceAndExposesTheStableQRPane() throws {
        let source = try readSource(.reactNativeFilterScreens)
        XCTAssertTrue(source.contains("mayRetainPresentationFrame(displayPolicy.current)"))
        XCTAssertTrue(source.contains("displayPolicy.current=live"))
        XCTAssertTrue(source.contains("<PrivateQRCode"))
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
        let app = try readAppViewModelSource()
        let ui = try readSource(.shareableFiltersUI)

        // Add-as-new is library-only (append + persistLibraryOnlyChange), gated on canCreateFilter,
        // and never touches the active config / tunnel.
        let addNew = try sourceBlock(
            in: app,
            startingAt: "func addImportedShareableConfigurationAsNewFilter(",
            endingBefore: "func replaceFilterWithImportedShareableConfiguration("
        )
        // Applies the carried (already-previewed) plan — no per-destination re-plan, so what was
        // previewed is what's added.
        XCTAssertTrue(addNew.contains("guard canCreateFilter, !applied.isEmpty,"))
        // The name is derived locally, never supplied by a caller — a sender must not be able to
        // choose text that lands in the recipient's filter list.
        XCTAssertTrue(addNew.contains("name: nextSharedFilterName()"),
                      "Add must name the filter from the local Shared filter base.")
        XCTAssertFalse(addNew.contains("name: String"),
                       "Add must not accept a caller-supplied name.")
        // An added filter is INACTIVE: importing must never change what is protecting the device.
        XCTAssertFalse(addNew.contains("activeFilterID ="),
                       "Add must not activate the imported filter.")
        XCTAssertTrue(addNew.contains("allowedDomains: applied.allowedDomains ?? []"),
                      "V2 adds the reviewed exceptions; legacy v1 has none.")
        XCTAssertTrue(addNew.contains("importPlan(for: applied"), "Add revalidates the reviewed plan before saving.")
        XCTAssertTrue(addNew.contains("library.append(newFilter)"))
        XCTAssertTrue(addNew.contains("persistLibraryOnlyChange(rollingBackTo: previousLibrary)"))
        XCTAssertFalse(addNew.contains("prepareFilterSnapshot"), "Add-as-new must not compile.")
        XCTAssertFalse(addNew.contains("persistSharedState"), "Add-as-new must not reload the tunnel.")

        // Replace forks: the active filter uses the full apply path (reload); a non-active filter
        // is replaced library-only (mutateFilter + token invalidation + persistLibraryOnlyChange).
        let replace = try sourceBlock(
            in: app,
            startingAt: "func replaceFilterWithImportedShareableConfiguration(",
            endingBefore: "static func filterPreparationFailureMessage("
        )
        XCTAssertTrue(replace.contains("if id == library.activeFilterID {"))
        // The rename rides inside the active apply transaction rather than being a second,
        // separate write — so a filter can never display a name for contents it doesn't hold.
        XCTAssertTrue(replace.contains("return await applyImportedShareableConfiguration(applied)"))
        // Replacement keeps the target's identity/name while replacing reviewed fields.
        XCTAssertFalse(replace.contains("filter.name ="))
        XCTAssertTrue(replace.contains("library.mutateFilter(id: id)"))
        XCTAssertTrue(replace.contains("filter.lastCompiledToken = nil"))
        XCTAssertTrue(replace.contains("if let allowed = applied.allowedDomains { filter.allowedDomains = allowed }"),
                      "V2 replaces recipient exceptions; legacy v1 preserves them.")
        XCTAssertTrue(replace.contains("guard let target = library.filter(id: id), !isFilterFrozen(id) else {"),
                      "Replace must refuse an unknown or frozen target.")
        // A replace invalidates that filter's per-filter draft (built from the old contents).
        XCTAssertTrue(replace.contains("filterDrafts.setDraft(nil, for: id)"))

        // Onboarding no longer imports at all: setup must be the user's own choice,
        // so a shared configuration can neither complete it nor stand in for it.
        let onboarding = try readSource(.onboardingFlowView)
        XCTAssertFalse(onboarding.contains("ImportFiltersFlow"),
                       "Onboarding must not embed the importer.")
        XCTAssertFalse(onboarding.contains("allowsAddingNewFilter"),
                       "The onboarding-only add-as-new suppression is gone with the route.")

        // The UI offers Add (paywall at the cap) + Replace (filter picker), no blanket replace.
        XCTAssertTrue(ui.contains("if viewModel.canCreateFilter {"))
        XCTAssertTrue(ui.contains("showingPaywall = true"))
        XCTAssertTrue(ui.contains("LavaPlusUpgradeSheet()"))
        XCTAssertTrue(ui.contains("struct ImportChooseReplaceTargetView"))
        XCTAssertFalse(ui.contains("case nameNew("),
                       "The naming stage is gone: imported filters are named by AppViewModel.")
        XCTAssertTrue(ui.contains("case chooseReplace(ShareableFilterConfiguration)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(app.contains("importPlan"))
        XCTAssertTrue(app.contains("prepareFilterSnapshot"))
        XCTAssertTrue(app.contains("persistSharedState"))
    }

    func testFilterNamesAreUniqueAcrossCreateRenameImport() throws {
        let app = try readAppViewModelSource()

        XCTAssertTrue(app.contains("func isFilterNameAvailable(_ name: String, excluding excludedID: String? = nil) -> Bool"))
        // Create rejects a duplicate explicit name; rename rejects a duplicate (excluding itself).
        let create = try sourceBlock(
            in: app,
            startingAt: "func createFilter(name: String, duplicatingFilterID: String? = nil) -> String? {",
            endingBefore: "func persistLibraryOnlyChange("
        )
        XCTAssertTrue(create.contains("guard FilterIdentityPolicy.isValidName(name), isFilterNameAvailable(trimmed) else { return nil }"))
        let rename = try sourceBlock(
            in: app,
            startingAt: "func renameFilter(id: String, to name: String, emoji: String? = nil) -> Bool {",
            endingBefore: "func deleteFilter("
        )
        XCTAssertTrue(rename.contains("isFilterNameAvailable(resolvedName, excluding: id)"))
        XCTAssertTrue(rename.contains("FilterIdentityPolicy.nameForEdit(name, savedName: saved.name)"))
        XCTAssertTrue(rename.contains("$0.name = resolvedName"))

        // The create/rename sheets disable their confirm action on a duplicate name.
        let filtersView = try readSource(.filterLibraryView)
        XCTAssertTrue((try readSource(.reactNativeAppFlows)).contains("library.isFilterNameAvailable($0, excluding: id)"))
        XCTAssertTrue(filtersView.contains("private var isDuplicate: Bool"))
        XCTAssertTrue(filtersView.contains("FilterIdentityPolicy.nameForEdit(name, savedName: savedName)"))
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
        let source = try readSource(.reactNativeAppQueries)
        XCTAssertTrue(source.contains("ShareableFilterCardRenderer.qrImage(for: url.absoluteString)"))
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
        let source = try readSource(.reactNativeAppFlows)
        XCTAssertTrue(source.contains("authorizeImport: { await security.requireFreshAuthentication(for: .filterEditing, reason: \"Import filter\") }"))
    }

    func testRetainedScannerOwnsOneVisibleAttemptAndRefreshesCallbacks() throws {
        let source = try readSource(.shareableFiltersUI)
        let scanner = try sourceBlock(in: source, startingAt: "struct QRCodeScannerRepresentable:", endingBefore: "// MARK: Preview / confirm")
        XCTAssertFalse(scanner.contains("lastValue"))
        XCTAssertFalse(source.contains("@State private var hasHandledMatch"))
        XCTAssertTrue(scanner.contains("controller.onScan = onScan"))
        XCTAssertTrue(scanner.contains("controller.onAttemptBegan = onAttemptBegan"))
        XCTAssertTrue(scanner.contains("attempt.appear(active:"))
        XCTAssertTrue(scanner.contains("attempt.disappear()"))
        XCTAssertTrue(scanner.contains("attempt.setActive(false)"))
        XCTAssertTrue(scanner.contains("self.attempt.permitsDelivery(generation: generation)"))
        XCTAssertTrue(scanner.contains("MainActor.assumeIsolated"))
        XCTAssertTrue(scanner.contains("if attempt.generation == generation { attempt = next }"))
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
            endingBefore: "private struct ImportReplacementReviewView"
        )

        // Additive import: the preview is neutral (no "replaces your filter" warning) and offers
        // both Add-as-new and Replace.
        XCTAssertFalse(preview.contains("LavaInfoPanel("))
        XCTAssertFalse(preview.contains("Import this filter"))
        XCTAssertFalse(preview.contains("This replaces your filter"))
        XCTAssertTrue(preview.contains("onAddNew"))
        XCTAssertTrue(preview.contains("onReplace"))
        // The preview breaks down the actual content being imported (resolved
        // names + domains), not bare counts — and reflects the planned subset.
        XCTAssertTrue(preview.contains("LavaSectionGroup(\"Lava blocks these\")"))
        XCTAssertTrue(preview.contains("LavaCondensedList {"))
        XCTAssertEqual(preview.components(separatedBy: "LazyVStack(alignment: .leading, spacing: 0)").count - 1, 2,
                       "Both full domain lists must build rows lazily inside the sheet scroll view")
        XCTAssertTrue(preview.contains("LavaFilterContentRow(title: row.title"))
        // Each preview row leads with its outcome's stroke-only mark.
        XCTAssertTrue(preview.contains("outcome: .blocked"))
        XCTAssertTrue(preview.contains("outcome: .allowed"))
        XCTAssertTrue(preview.contains("LavaCondensedDivider()"))
        XCTAssertFalse(preview.contains("LavaSectionGroup(\"Curated blocklists\")"))
        XCTAssertFalse(preview.contains("LavaSectionGroup(\"Custom blocklists\")"))
        XCTAssertTrue(preview.contains("Lava lets these through"))
        XCTAssertTrue(preview.contains("No allowed exceptions"))
        XCTAssertTrue(preview.contains("viewModel.blocklistName(for:"))
        XCTAssertTrue(preview.contains("plan.applied.customBlocklists"))
        XCTAssertTrue(preview.contains("plan.applied.blockedDomains"))
        // Every domain remains visible in the review.
        XCTAssertFalse(preview.contains("blockedDomainPreviewLimit"))
        XCTAssertTrue(preview.contains("blockedDomains.map"))
        // Unsupported entries get an alert row treatment.
        XCTAssertTrue(preview.contains("if plan.hasUnsupportedEntries"))
        XCTAssertTrue(preview.contains("unsupportedSection(for: plan)"))
        XCTAssertTrue(source.contains("struct ImportAlertRow: View"))
        XCTAssertTrue(preview.contains(".buttonStyle(LavaSecondaryActionButtonStyle())"))
        XCTAssertFalse(source.contains("private struct ImportContentRow"))
    }

    func testImportPreviewReadsOnlyKnownWarmCountsAndKeepsCustomIdentity() throws {
        let preview = try sourceBlock(in: readSource(.shareableFiltersUI),
            startingAt: "private struct ImportPreviewView: View", endingBefore: "private struct ImportReplacementReviewView")
        XCTAssertTrue(preview.contains("source.entryCount > 0"))
        XCTAssertTrue(preview.contains("viewModel.cachedBlockRuleSets[sourceID]?.count"))
        XCTAssertTrue(preview.contains("$0.sourceURL == customSource.sourceURL"))
        XCTAssertTrue(preview.contains("$0.parseFormat == customSource.parseFormat"))
        XCTAssertTrue(preview.contains("else { return nil }"))
        XCTAssertTrue(preview.contains("return count.map"))
        XCTAssertTrue(preview.contains("verbatimTitle: true"))
        XCTAssertTrue(preview.contains("verbatimMetadata: true"))
        // The preview checks metadata publication; it still never downloads list payloads to count them.
        let counts = try sourceBlock(in: preview, startingAt: "private func warmRuleCountText(",
            endingBefore: "private struct ImportDisplayEntry")
        XCTAssertFalse(counts.contains("await"))
        XCTAssertTrue(preview.contains("refreshCatalogForSharedImport(configuration)"))
        XCTAssertFalse(preview.contains("catalog.sync"))
        XCTAssertFalse(preview.contains("refreshable"))
        XCTAssertFalse(preview.contains("Pending refresh"))
    }

    func testViewModelComputesRobustImportPlan() throws {
        let viewModelSource = try readAppViewModelSource()
        XCTAssertTrue(viewModelSource.contains("func importPlan(for shared: ShareableFilterConfiguration) -> ShareableFilterImportPlan"))
        XCTAssertTrue(viewModelSource.contains("allowsCustomBlocklists: configuration.limits.allowsCustomBlocklists"))
        XCTAssertTrue(viewModelSource.contains("maxBlockedDomains: configuration.limits.maxBlockedDomains"))
        XCTAssertTrue(viewModelSource.contains("maxFilterRules: configuration.limits.maxFilterRules"))
        XCTAssertTrue(viewModelSource.contains("blocklistRuleCounts:"))
        // The rule budget reserves the DESTINATION filter's allowlist (param), not always the active
        // filter's — so add-as-new (0) and a non-active replace (the target's count) plan correctly.
        XCTAssertTrue(viewModelSource.contains("preservedRuleCount: shared.allowedDomains == nil ? preservedAllowedDomainCount : 0"))
        XCTAssertTrue(viewModelSource.contains("preservedAllowedDomainCount: Int"))

        // Imported custom lists are treated as untrusted: reserved IDs (curated +
        // guardrail) guard against shadowing, and empty plans can't wipe filters.
        XCTAssertTrue(viewModelSource.contains("reservedBlocklistIDs:"))
        XCTAssertTrue(viewModelSource.contains("DefaultCatalog.guardrailSources"))
        XCTAssertTrue(viewModelSource.contains("guard !applied.isEmpty,"))

        // The import flow carries the EXACT previewed plan (importPlan(for:) convenience) into both
        // apply methods, so the preview and the applied result never diverge.
        let uiSource = try readSource(.shareableFiltersUI)
        XCTAssertTrue(uiSource.contains("viewModel.importPlan(for: config).applied"))
        XCTAssertTrue(uiSource.contains("addImportedShareableConfigurationAsNewFilter(applied)"))
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
        XCTAssertTrue(source.contains("if !isMock && nextPage == .done {\n            viewModel.applyOnboardingRecommendedDefaults(protectionLevel: protectionLevel)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("OnboardingPrimaryButton"))
    }

    func testOnboardingCompletionOffersOnlyGuard() throws {
        let source = try readSource(.onboardingFlowView)
        XCTAssertTrue(source.contains("Button(action: openGuard)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Open Guard\")"))
        XCTAssertFalse(source.contains("OnboardingAdditionalSetupSheet"))
        XCTAssertFalse(source.contains("Additional setup"))
        XCTAssertFalse(source.contains("ImportFiltersFlow"))
        let root = try readSource(.rootView)
        XCTAssertFalse(root.contains("onRequestOpenSettings:"))
    }

    // MARK: View model wiring

    func testViewModelExposesShareAndImportEntryPoints() throws {
        let source = try readAppViewModelSource()

        XCTAssertTrue(source.contains("var shareableFilterConfigurationCode: String"))
        XCTAssertTrue(source.contains("func applyImportedShareableConfiguration("))
        XCTAssertTrue(source.contains("applyingImportedShareableConfiguration("))
    }

    // MARK: Helpers
}
