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
        let ui = try readSource(.reactNativeAppImport)
        XCTAssertTrue(ui.contains("try await viewModel.refreshCatalogForSharedImport(configuration)"))
        XCTAssertTrue(ui.contains("!checkingCatalog, !catalogCheckFailed"))
        XCTAssertTrue(ui.contains("importUnavailableMessage(owner.completion.unavailableListCount)"))
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
        XCTAssertTrue(source.contains("AppState.addEventListener('change',state=>{setExportActive(state==='active');if(state!=='active'&&!mayRetainPresentationFrame(displayPolicy.current)){setRevealed(false);setCopied(false);}})"))
        XCTAssertTrue(source.contains("content?.card&&exportActive&&focused&&<FilterShareCard"))
        XCTAssertTrue(source.contains("mayRetainPresentationFrame(displayPolicy.current)"))
        XCTAssertTrue(source.contains("displayPolicy.current=live"))
        XCTAssertTrue(source.contains("<PrivateQRCode"))
        XCTAssertTrue(source.contains("revealed={revealed}"))
        let bridge = try readSource(.reactNativeAppBridge)
        XCTAssertTrue(bridge.contains("selector: #selector(shareCardForegroundEnded)"))
        XCTAssertTrue(bridge.contains("name: UIApplication.willResignActiveNotification"))
        let native = try readSource(.reactNativeAppShareCard)
        let retirement = try XCTUnwrap(native.range(of: "@objc func shareCardForegroundEnded()"))
        let ending = String(native[retirement.lowerBound...])
        XCTAssertTrue(ending.contains("shareCardForegroundEpoch &+= 1"))
        XCTAssertTrue(ending.contains("shareCardAuthority.retire()"))
        XCTAssertTrue(ending.contains("LavaShareCardSurfaceRegistry.shared.retire()"))
        XCTAssertTrue(native.contains("canReadPresentation(.appUnlock) && canReadPresentation(.filterEditing)"))
        let account = try XCTUnwrap(bridge.range(of: "model.account.objectWillChange.sink"))
        let library = try XCTUnwrap(bridge.range(of: "model.$library.removeDuplicates()", range: account.upperBound..<bridge.endIndex))
        XCTAssertTrue(bridge[account.lowerBound..<library.lowerBound].contains("shareCardPrivacyChanged(isBlocked: true)"))
        let unavailable = try XCTUnwrap(bridge.range(of: "NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)"))
        let available = try XCTUnwrap(bridge.range(of: "NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)"))
        XCTAssertTrue(bridge[unavailable.lowerBound..<available.lowerBound].contains("shareCardPrivacyChanged(isBlocked: true)"))
    }

    /// A biometric prompt resigns the app active while it is displayed, so the
    /// foreground epoch legitimately advances across a successful authorization.
    /// Pinning it before the prompt made protected-action users always fail.
    func testShareCardQueryEstablishesForegroundAuthorityAfterBiometricAuthorization() throws {
        let native = try readSource(.reactNativeAppShareCard)
        let query = sourceWithoutCommentLines(try sourceBlock(in: native,
            startingAt: "func shareCardQuery(", endingBefore: "func shareMountedCard("))
        let module = try XCTUnwrap(query.range(of: "let module = shareCardModuleEpoch"))
        let authorize = try XCTUnwrap(query.range(of: "try await authorize(.filterEditing"))
        XCTAssertLessThan(module.lowerBound, authorize.lowerBound,
                          "The module retirement epoch must be pinned across the suspension")
        XCTAssertFalse(query[query.startIndex..<authorize.lowerBound].contains("shareCardForegroundEpoch"),
                       "The foreground epoch must not be snapshotted before biometric authorization")
        XCTAssertTrue(query[authorize.upperBound...].contains("let basis = try shareCardBasis(for: id)"),
                      "The foreground authority must be established after authorization returns")
    }

    /// A protected `.filterEditing` prompt resigns the app active, which invalidates
    /// the presentation cache and rotates its generation. Authorizing it after the
    /// read ticket opens made a successful share authorization look like a revoked
    /// read, so `share.query` never loaded the card.
    func testShareQueryAuthorizesFilterEditingBeforeOpeningItsReadTicket() throws {
        let bridge = try readSource(.reactNativeAppQueries)
        let query = try sourceBlock(in: bridge, startingAt: "func query(_ name: String",
                                    endingBefore: "func canReadPresentation(")
        let epoch = try XCTUnwrap(query.range(of: "let shareModuleEpoch = policy == .share || policy == .activityShare ? shareCardModuleEpoch : nil"))
        let shareAuth = try XCTUnwrap(query.range(of: "try await authorize(.filterEditing, \"Share Filter\", fresh: false)"))
        let revalidate = try XCTUnwrap(query.range(of: "guard shareModuleEpoch == shareCardModuleEpoch"))
        let ticket = try XCTUnwrap(query.range(of: "let ticket = try presentationCache.beginRead("))
        XCTAssertLessThan(epoch.lowerBound, shareAuth.lowerBound,
                          "The module retirement epoch must be pinned across the share authorization")
        XCTAssertLessThan(shareAuth.lowerBound, revalidate.lowerBound,
                          "The module retirement must be revalidated after the share authorization")
        XCTAssertLessThan(revalidate.lowerBound, ticket.lowerBound,
                          "The .filterEditing authorization must precede the presentation read ticket")
    }

    // MARK: Import flow — code entry + scanner

    func testImportFlowHasFreeformCodeEntryAndScanner() throws {
        let ui = try readSource(.reactNativeImportFlow)
        XCTAssertTrue(ui.contains("export function ImportFlow("))
        XCTAssertTrue(ui.contains("FormField title=\"Setup code\""))
        XCTAssertTrue(ui.contains("button('Continue'"))
        XCTAssertTrue(ui.contains("Add as a new filter"))
        XCTAssertTrue(ui.contains("Replace a filter instead"))
        let native = try readSource(.shareableFiltersUI)
        XCTAssertTrue(native.contains("output.metadataObjectTypes = [.qr]"))
        XCTAssertTrue(native.contains("UIApplication.willResignActiveNotification"))
        XCTAssertTrue(native.contains("private func stopSession()"))
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
        let onboarding = try [readSource(.reactNativeOnboardingFlow), readSource(.reactNativeAppOnboarding)].joined(separator: "\n")
        XCTAssertTrue(onboarding.contains("export function OnboardingFlow()"))
        XCTAssertFalse(onboarding.contains("ImportFiltersFlow"),
                       "Onboarding must not embed the importer.")
        XCTAssertFalse(onboarding.contains("allowsAddingNewFilter"),
                       "The onboarding-only add-as-new suppression is gone with the route.")

        let session = try readSource(.reactNativeAppImport)
        XCTAssertTrue(session.contains("if viewModel.canCreateFilter { addNew(configuration) }"))
        XCTAssertTrue(session.contains("LavaPlusUpgradeSheet(context: \"fullImport\")"))
        XCTAssertTrue(session.contains("case chooseReplace(ShareableFilterConfiguration)"))
        XCTAssertFalse(ui.contains("case nameNew("))
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

        // RN identity commands validate the current native library session.
        let flows = try readSource(.reactNativeAppFlows)
        XCTAssertTrue(flows.contains("flow.library.map { $0.isFilterNameAvailable(FilterIdentityPolicy.normalizedName(name), excluding: flow.filterID) }"))
        XCTAssertTrue(flows.contains("FilterIdentityPolicy.nameForEdit(name, savedName: flow.filterName"))
        XCTAssertTrue(flows.contains("library.renameFilter(id: id, to: name, emoji: emoji)"))

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
        let source = try readSource(.reactNativeAppShareCard)
        XCTAssertTrue(source.contains("ShareableFilterCardRenderer.qrImage(for: basis.payload)"))
        XCTAssertTrue(source.contains("if let matrix = LavaShareQrMatrix.encode(basis.payload)"))
        XCTAssertTrue(source.contains("var card: Any = NSNull()"))
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
        let source = try readSource(.reactNativeAppImport)
        XCTAssertTrue(source.contains("security.requireFreshAuthentication(for: .filterEditing, reason: \"Import filter\")"))
    }

    func testRetainedScannerOwnsOneVisibleAttemptAndRefreshesCallbacks() throws {
        let scanner = try readSource(.shareableFiltersUI)
        let adapter = try readSource(.reactNativeAppImport)
        XCTAssertTrue(adapter.contains("camera.onScan ="))
        XCTAssertTrue(adapter.contains("camera.onAttemptBegan ="))
        XCTAssertTrue(scanner.contains("attempt.appear(active:"))
        XCTAssertTrue(scanner.contains("attempt.disappear()"))
        XCTAssertTrue(scanner.contains("attempt.setActive(false)"))
        XCTAssertTrue(scanner.contains("self.attempt.permitsDelivery(generation: generation)"))
        XCTAssertTrue(scanner.contains("if attempt.generation == generation { attempt = next }"))
    }

    func testScannerSurfacesCameraDeniedRecovery() throws {
        let source = try readSource(.reactNativeAppImport)
        XCTAssertTrue(source.contains("onCameraAuthorizationDenied"))
        XCTAssertTrue(source.contains("UIApplication.openSettingsURLString"))
        XCTAssertTrue(source.contains("AVCaptureDevice.authorizationStatus(for: .video) == .authorized"))
        XCTAssertTrue(try readSource(.reactNativeImportFlow).contains("Camera access is off"))
    }

    func testImportPreviewWarnsAndListsUnsupportedEntries() throws {
        let ui = try readSource(.reactNativeImportFlow)
        let native = try readSource(.reactNativeAppImport)
        for copy in ["Lava blocks these", "Lava lets these through", "No allowed exceptions", "Not imported on this device"] { XCTAssertTrue(ui.contains(copy)) }
        XCTAssertTrue(ui.contains("outcome=\"blocked\""))
        XCTAssertTrue(ui.contains("outcome=\"allowed\""))
        XCTAssertTrue(native.contains("plan.applied.customBlocklists"))
        XCTAssertTrue(native.contains("plan.applied.blockedDomains.sorted().map"))
        XCTAssertFalse(native.contains("blockedDomainPreviewLimit"))
        XCTAssertTrue(ui.contains("review.warnings.map"))
    }

    func testImportPreviewReadsOnlyKnownWarmCountsAndKeepsCustomIdentity() throws {
        let native = try readSource(.reactNativeAppImport)
        let counts = try sourceBlock(in: native, startingAt: "func count(_ id:", endingBefore: "var rows:")
        XCTAssertTrue(counts.contains("source.entryCount > 0"))
        XCTAssertTrue(counts.contains("model.cachedBlockRuleSets[id]?.count"))
        XCTAssertTrue(counts.contains("$0.sourceURL == custom.sourceURL"))
        XCTAssertTrue(counts.contains("$0.parseFormat == custom.parseFormat"))
        XCTAssertFalse(counts.contains("await"))
        XCTAssertTrue(native.contains("refreshCatalogForSharedImport(configuration)"))
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
        let uiSource = try readSource(.reactNativeAppImport)
        XCTAssertTrue(uiSource.contains("viewModel.importPlan(for: config).applied"))
        XCTAssertTrue(uiSource.contains("addImportedShareableConfigurationAsNewFilter(applied)"))
        XCTAssertTrue(uiSource.contains("replaceFilterWithImportedShareableConfiguration("))
        XCTAssertTrue(uiSource.contains("id: filter.id,"))
        // The preview uses the same importPlan convenience (worst-case headroom).
        XCTAssertTrue(uiSource.contains("model.importPlan(for: configuration)"))
    }

    func testInfoPlistDeclaresCameraUsage() throws {
        let plist = try readSource(.appInfoPlist)
        XCTAssertTrue(plist.contains("NSCameraUsageDescription"))
    }

    // MARK: Onboarding — fine-tune step removed, additional setup added

    func testViewModelExposesShareAndImportEntryPoints() throws {
        let source = try readAppViewModelSource()

        XCTAssertTrue(source.contains("var shareableFilterConfigurationCode: String"))
        XCTAssertTrue(source.contains("func applyImportedShareableConfiguration("))
        XCTAssertTrue(source.contains("applyingImportedShareableConfiguration("))
    }

    // MARK: Helpers
}
