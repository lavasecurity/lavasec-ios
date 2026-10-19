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

    func testMyListPullToRefreshUsesCatalogSync() throws {
        let source = try readSource(.reactNativeAppFilters)
        XCTAssertTrue(source.contains("model.syncCatalog()"))
    }

    func testBringYourOwnListSheetGatesFreeUsersAndUsesBackNavigation() throws {
        let source = try readSource(.reactNativeCustomEntryScreen)
        XCTAssertTrue(source.contains("presentation?.allowed===false"))
        XCTAssertTrue(source.contains("<FormPanel>"))
        XCTAssertTrue(source.contains("Blocklist URL"))
        XCTAssertTrue(source.contains("Name (optional)"))
        XCTAssertTrue(source.contains("My blocklist"))
        XCTAssertTrue(source.contains("https://example.com/pi-hole-style-list.txt"))
        XCTAssertTrue(source.contains("Add Blocklist"))
        XCTAssertTrue(source.contains("nav.goBack()"))
        XCTAssertTrue(try readSource(.reactNativeAppFlows).contains("model.configuration.limits.allowsCustomBlocklists"))
    }

    func testCustomBlocklistURLInputStateLivesInDedicatedSubview() throws {
        let source = try readSource(.reactNativeCustomEntryScreen)
        XCTAssertTrue(source.contains("const [name,setName]"))
        XCTAssertTrue(source.contains("const [url,setURL]"))
        XCTAssertTrue(source.contains("const [message,setMessage]"))
        XCTAssertTrue(source.contains("type:'customEntry.save',id:token,name"))
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
}
