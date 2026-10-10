import XCTest

final class BlocklistSelectionSourceTests: XCTestCase {
    func testToolbarActionsLetTheNativeBarOwnChrome() throws {
        let source = try readSource(.lavaScaffold)
        for name in ["struct LavaToolbarIconButton: View", "struct NativeToolbarIconButton: View"] {
            let body = try sourceBlock(in: source, startingAt: name, endingBefore: "\n}\n")
            XCTAssertTrue(body.contains("Button(role:"))
            XCTAssertTrue(body.contains("LavaToolbarSymbol(systemName: systemName, role: role"))
            XCTAssertTrue(body.contains(".lavaNativeActionStyle(confirm:"))
            XCTAssertTrue(body.contains(".accessibilityLabel(accessibilityLabel.lavaLocalized)"))
            XCTAssertFalse(body.contains("LavaCircularIconLabel"))
            XCTAssertFalse(body.contains(".buttonStyle(.plain)"))
        }
    }

    func testToolbarSymbolKeepsConfirmationWhiteAndOrdinaryActionsSemantic() throws {
        let source = try readSource(.lavaScaffold)
        let symbol = try sourceBlock(in: source, startingAt: "private struct LavaToolbarSymbol: View", endingBefore: "struct NativeToolbarIconButton: View")
        XCTAssertTrue(symbol.contains("LavaActionRole.isConfirmation(symbol: systemName, role: role)"))
        XCTAssertTrue(symbol.contains("symbol.withTintColor(.white, renderingMode: .alwaysOriginal)"))
        XCTAssertTrue(symbol.contains("Image(systemName: systemName)"))
        XCTAssertTrue(symbol.contains("tint ?? LavaActionRole.foreground(for: systemName, role: role)"))
        XCTAssertFalse(symbol.contains("Circle()"), "Native toolbar chrome owns the circle; the common symbol owner only supplies glyph pixels.")
    }

    func testFilterDraftBlocklistSheetStartsFromCurrentDraftSelection() throws {
        let source = try readSource(.reactNativeFilterScreens)
        XCTAssertTrue(source.contains("const [selected,setSelected]=useRouteViewState(session.blocklists)"))
    }

    func testFilterDraftBlocklistSheetUsesTheSaveAvailabilityPolicy() throws {
        let source = try readSource(.reactNativeAppQueries)
        XCTAssertTrue(source.contains("DefaultCatalog.groupedByCategory(model.blocklists)"))
        XCTAssertFalse(source.contains("DefaultCatalog.curatedSourcesByCategory"))
        XCTAssertTrue(source.contains("model.blocklists.map(\\.id)"))
    }

    func testAvailabilityRetainsOnlyTheEditedFilterBaseline() throws {
        let source = try readAppViewModelSource()
        let availability = try sourceBlock(in: source, startingAt: "var blocklists: [BlocklistSource]", endingBefore: "var blocklistsConfigured")
        XCTAssertTrue(availability.contains("enabledSourceIDs: filterDetailBaseline.enabledBlocklistIDs"))
        XCTAssertFalse(availability.contains("configuration.enabledBlocklistIDs"))
        XCTAssertFalse(availability.contains("filterEditDraft?.enabledBlocklistIDs"))
    }

    func testFilterDraftBlocklistSheetSavesTheFullSelection() throws {
        let source = try readSource(.reactNativeAppFilters)
        XCTAssertTrue(source.contains("model.setDraftBlocklists("))
    }

    func testKnownCustomBlocklistURLsRouteToCatalogSources() throws {
        let appViewModelSource = try readAppViewModelSource()
        let draftBlock = try sourceBlock(
            in: try readSource(.filterDraftController),
            startingAt: "func addCustomBlocklistToDraft(displayName: String, rawURL: String) -> String?",
            endingBefore: "func removeBlocklistFromDraft"
        )
        let immediateBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "func addCustomBlocklist(displayName: String, rawURL: String) -> String?",
            endingBefore: "func removeCustomBlocklist"
        )

        XCTAssertTrue(draftBlock.contains("KnownBlocklistURLMatcher.catalogSourceID(for: source.sourceURL)"))
        XCTAssertTrue(draftBlock.contains("guard context.blocklists.contains(where: { $0.id == catalogSourceID }) else"))
        XCTAssertTrue(draftBlock.contains("draft.enabledBlocklistIDs.insert(catalogSourceID)"))
        XCTAssertTrue(draftBlock.contains("draft.customBlocklists.removeAll"))
        XCTAssertTrue(immediateBlock.contains("KnownBlocklistURLMatcher.catalogSourceID(for: source.sourceURL)"))
        XCTAssertTrue(immediateBlock.contains("guard catalogSourcesByID[catalogSourceID] != nil || configuration.enabledBlocklistIDs.contains(catalogSourceID) else"))
        XCTAssertTrue(immediateBlock.contains("configuration.enabledBlocklistIDs.insert(catalogSourceID)"))
        XCTAssertTrue(immediateBlock.contains("let updatedIDs = configuration.enabledBlocklistIDs.union([source.id])"))
        XCTAssertTrue(immediateBlock.contains("configuration.customBlocklists.append(source)"))
        XCTAssertTrue(immediateBlock.contains("configuration.enabledBlocklistIDs = updatedIDs"))
    }

    func testPreparationTitleTransitionKeepsUpwardMotionWithoutStackingTitles() throws {
        let reviewFlowSource = try readSource(.filterReviewFlowView)
        let start = try XCTUnwrap(reviewFlowSource.range(of: "struct PreparationTickerTitle: View")?.lowerBound)
        let titleBlock = String(reviewFlowSource[start...])

        XCTAssertTrue(titleBlock.contains("@State private var titleOffset"))
        XCTAssertTrue(titleBlock.contains("titleOffset = -18"))
        XCTAssertTrue(titleBlock.contains("titleOffset = 18"))
        XCTAssertFalse(titleBlock.contains("ZStack"))
    }

    func testMyListPullToRefreshUsesCatalogSync() throws {
        let source = try readSource(.reactNativeAppFilters)
        XCTAssertTrue(source.contains("model.syncCatalog()"))
    }

    func testBringYourOwnListSheetGatesFreeUsersAndUsesBackNavigation() throws {
        let filtersViewSource = try readSource(.blocklistPickerView)
        let byolBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "struct BringYourOwnListView: View"
        )
        let customListFormBlock = try sourceBlock(
            in: byolBlock,
            startingAt: "private var customListForm: some View",
            endingBefore: "private var upgradeRow"
        )

        XCTAssertTrue(byolBlock.contains(".navigationTitle(\"Bring your own list\".lavaLocalized)"))
        XCTAssertTrue(byolBlock.contains("@Environment(\\.dismiss) private var dismiss"))
        XCTAssertFalse(byolBlock.contains(".navigationBarBackButtonHidden(true)"))
        XCTAssertFalse(byolBlock.contains("NativeToolbarIconButton(systemName: \"chevron.left\""))
        XCTAssertFalse(byolBlock.contains("let goBack"))
        XCTAssertTrue(byolBlock.contains("if allowsCustomBlocklists"))
        XCTAssertTrue(byolBlock.contains("LavaCustomEntryForm("))
        XCTAssertTrue(byolBlock.contains("LavaTextInputRow(title: \"Name (optional)\")"))
        XCTAssertTrue(byolBlock.contains("LavaTextInputRow(title: \"Blocklist URL\")"))
        XCTAssertTrue(byolBlock.contains("TextField(\"My blocklist\".lavaLocalized, text: $customDisplayName)"))
        XCTAssertTrue(byolBlock.contains("TextField(\"https://example.com/pi-hole-style-list.txt\", text: $customURL)"))
        XCTAssertTrue(byolBlock.contains("LavaCustomEntryForm(actionTitle: \"Add Blocklist\", actionSymbol: \"plus\", enabled: canAddCustomSource, submit: submit)"))
        XCTAssertTrue(byolBlock.contains("LavaNavigationCardLabel("))
        XCTAssertTrue(byolBlock.contains("badge: .custom(LavaSecurityPlusGlyph())"))
        XCTAssertTrue(byolBlock.contains("title: \"Upgrade\""))
        XCTAssertTrue(byolBlock.contains("summary: .standardLocalized(\"Bring your own list\")"))
        XCTAssertTrue(byolBlock.contains("accessory: upgradeAccessory"))
        XCTAssertFalse(byolBlock.contains("Text(\"Upgrade to Lava Security Plus to bring your own list\".lavaLocalized)"))
        XCTAssertFalse(byolBlock.contains(".underline()"))
        XCTAssertTrue(byolBlock.contains("Button(action: showUpgrade)"))
        XCTAssertFalse(byolBlock.contains("Button(allowsCustomBlocklists ? \"Add Custom Blocklist\" : \"Upgrade\""))
        let sharedForm = try sourceBlock(in: readSource(.lavaScaffold), startingAt: "struct LavaCustomEntryForm")
        XCTAssertTrue(sharedForm.contains("VStack(spacing: 12)"))
        XCTAssertTrue(sharedForm.contains("LavaTextInputPanel { fields() }"))
        XCTAssertTrue(sharedForm.contains("Button(action: submit)"))
        XCTAssertTrue(sharedForm.contains(".disabled(!enabled)"))
        XCTAssertTrue(customListFormBlock.contains("Divider()"))
        XCTAssertFalse(customListFormBlock.contains("CustomBlocklistTextField"))
        XCTAssertFalse(customListFormBlock.contains("LavaNavigationCardLabel"))
        XCTAssertTrue(byolBlock.contains("dismiss()"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(filtersViewSource.contains("LavaNavigationCardLabel"))
    }

    func testCustomBlocklistURLInputStateLivesInDedicatedSubview() throws {
        let filtersViewSource = try readSource(.blocklistPickerView)
        let bringYourOwnListBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "struct BringYourOwnListView: View"
        )

        XCTAssertTrue(bringYourOwnListBlock.contains("@State private var customDisplayName"))
        XCTAssertTrue(bringYourOwnListBlock.contains("@State private var customURL"))
        XCTAssertTrue(bringYourOwnListBlock.contains("@State private var customMessage"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(filtersViewSource.contains("customDisplayName"))
        XCTAssertTrue(filtersViewSource.contains("customURL"))
        XCTAssertTrue(filtersViewSource.contains("customMessage"))
    }

    func testCatalogAndPreparationCopyAvoidsRawFreshAndChecksumLanguage() throws {
        let appViewModelSource = try readAppViewModelSource()
        let freshnessTitleBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "var blocklistCatalogFreshnessTitle: String",
            endingBefore: "var blocklistCatalogFreshnessDescription: String"
        )
        let preparationBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "func prepareAndApplyFilterDraft(",
            endingBefore: "func retryFilterPreparation()"
        )

        XCTAssertFalse(freshnessTitleBlock.contains("Blocklists are fresh"))
        XCTAssertFalse(freshnessTitleBlock.contains("\"Catalog checked\""))
        XCTAssertFalse(freshnessTitleBlock.contains("\"Catalog needs a refresh\""))
        XCTAssertTrue(freshnessTitleBlock.contains("Filter up to date"))
        XCTAssertTrue(appViewModelSource.contains("static func filterPreparationFailureMessage(for error: Error) -> String"))
        XCTAssertTrue(preparationBlock.contains("Self.filterPreparationFailureMessage(for: error)"))
        XCTAssertTrue(appViewModelSource.contains("Lava is still preparing an update for this blocklist source."))
    }

    func testReviewSheetUsesCompactAlignedChangeRows() throws {
        let reviewFlowSource = try readSource(.filterReviewFlowView)
        let diffGroupBlock = try sourceBlock(
            in: reviewFlowSource,
            startingAt: "struct DiffGroup: View",
            endingBefore: "struct FilterPreparationScreen: View"
        )

        XCTAssertTrue(diffGroupBlock.contains("FilterReviewChangeRow("))
        XCTAssertFalse(diffGroupBlock.contains("LavaCondensedListItem("))
        guard reviewFlowSource.contains("struct FilterReviewChangeRow: View") else {
            return
        }

        let rowBlock = try sourceBlock(
            in: reviewFlowSource,
            startingAt: "struct FilterReviewChangeRow: View",
            endingBefore: "struct FilterPreparationScreen: View"
        )

        XCTAssertTrue(rowBlock.contains(".frame(width: LavaToolbarMetrics.iconFrameSize, height: LavaToolbarMetrics.iconFrameSize)"))
        XCTAssertTrue(rowBlock.contains(".font(.body.weight(.semibold))"))
        XCTAssertTrue(rowBlock.contains("LavaTableRow {"))
    }
}
