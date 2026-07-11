import XCTest

final class BlocklistSelectionSourceTests: XCTestCase {
    func testFilterDraftBlocklistSheetStartsFromCurrentDraftSelection() throws {
        let filtersViewSource = try readSource(.filterMyListView)
        let blockedDomainsSheetBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "case .blocklist:",
            endingBefore: "case .blockedDomain:"
        )

        XCTAssertTrue(
            blockedDomainsSheetBlock.contains("initialSelection: viewModel.filterEditDraft?.enabledBlocklistIDs ?? viewModel.configuration.enabledBlocklistIDs"),
            "The add blocklist sheet should open with already-enabled draft lists checked."
        )
    }

    func testFilterDraftBlocklistSheetShowsAllCuratedLists() throws {
        let filtersViewSource = try readSource(.blocklistPickerView)
        let availableBlocklistsBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private var availableBlocklists: [BlocklistSource]",
            endingBefore: "private var filterRuleBudgetStatus: AppViewModel.FilterRuleBudgetStatus"
        )

        XCTAssertTrue(
            availableBlocklistsBlock.contains("viewModel.blocklists"),
            "The sheet needs to render existing curated lists so their checked state is visible."
        )
        XCTAssertFalse(
            availableBlocklistsBlock.contains("!draftIDs.contains($0.id)"),
            "Existing enabled lists should not be filtered out of the picker."
        )
    }

    func testFilterDraftBlocklistSheetSavesTheFullSelection() throws {
        let filtersViewSource = try readSource(.blocklistPickerView)
        let appViewModelSource = try readSource(.appViewModel)
        let addSelectionBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private func addSelection()",
            endingBefore: "private func addCustomSource(displayName: String, rawURL: String) -> String?"
        )

        XCTAssertTrue(appViewModelSource.contains("func setDraftBlocklists(_ sourceIDs: Set<String>) -> String?"))
        XCTAssertTrue(
            addSelectionBlock.contains("viewModel.setDraftBlocklists(selectedIDs)"),
            "Once the sheet shows existing checks, confirmation should save the visible full selection."
        )
    }

    func testKnownCustomBlocklistURLsRouteToCatalogSources() throws {
        let appViewModelSource = try readSource(.appViewModel)
        let draftBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "func addCustomBlocklistToDraft(displayName: String, rawURL: String) -> String?",
            endingBefore: "func removeBlocklistFromDraft"
        )
        let immediateBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "func addCustomBlocklist(displayName: String, rawURL: String) -> String?",
            endingBefore: "func removeCustomBlocklist"
        )

        XCTAssertTrue(draftBlock.contains("KnownBlocklistURLMatcher.catalogSourceID(for: source.sourceURL)"))
        XCTAssertTrue(draftBlock.contains("draft.enabledBlocklistIDs.insert(catalogSourceID)"))
        XCTAssertTrue(draftBlock.contains("draft.customBlocklists.removeAll"))
        XCTAssertTrue(immediateBlock.contains("KnownBlocklistURLMatcher.catalogSourceID(for: source.sourceURL)"))
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

    func testFilterEditToolbarUsesIconOnlyNativeActions() throws {
        let filtersViewSource = try readSource(.filterMyListView)
        let toolbarBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct FilterEditToolbar: ToolbarContent",
            endingBefore: "private struct BlocklistEffectRow: View"
        )
        let viewingToolbarBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "ToolbarItemGroup(placement: .primaryAction)",
            endingBefore: "// NOTE: teardown (endViewingFilterDetail)"
        )

        XCTAssertTrue(toolbarBlock.contains("NativeToolbarIconButton(systemName: \"checkmark\", accessibilityLabel: \"Save\", role: .confirm, action: save)"))
        XCTAssertFalse(toolbarBlock.contains("square.and.pencil"))
        let compactViewingToolbar = viewingToolbarBlock
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        XCTAssertTrue(compactViewingToolbar.contains(
            "NativeToolbarIconButton( systemName: \"square.and.pencil\", accessibilityLabel: \"Edit\", action: beginEditing )"
        ))
        XCTAssertFalse(toolbarBlock.contains("Button(\"Save\""))
        XCTAssertFalse(toolbarBlock.contains("Button(\"Edit\""))
    }

    func testFilterDiscardUsesPopupDialogWithStandardActions() throws {
        let filtersViewSource = try readSource(.filterMyListView)
        let myListBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "struct MyListCover: View",
            endingBefore: "private enum BlockedDomainSheet"
        )

        XCTAssertTrue(myListBlock.contains(".alert(\"Discard changes?\", isPresented: $showingDiscardConfirmation)"))
        XCTAssertTrue(myListBlock.contains("Button(\"Cancel\", role: .cancel)"))
        XCTAssertTrue(myListBlock.contains("Button(\"Discard\", role: .destructive)"))
        XCTAssertTrue(myListBlock.contains("Text(\"Your draft changes will be removed. The current saved filter will stay active.\")"))
        XCTAssertFalse(myListBlock.contains(".sheet(isPresented: $showingDiscardConfirmation)"))
        XCTAssertFalse(myListBlock.contains("DiscardFilterChangesSheet"))
        XCTAssertFalse(myListBlock.contains("Discard Changes"))

        XCTAssertFalse(filtersViewSource.contains("private struct DiscardFilterChangesSheet: View"))
    }

    func testMyListPanelShowsActiveRuleCountNotRawDisplayCountsOrBudgetBar() throws {
        let filtersViewSource = try readSource(.filterMyListView)
        let pickerSource = try readSource(.blocklistPickerView)
        let myListBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "struct MyListCover: View",
            endingBefore: "private enum BlockedDomainSheet"
        )

        XCTAssertTrue(myListBlock.contains("viewModel.configuredProtectedDomainNumberText"))
        XCTAssertFalse(myListBlock.contains("viewModel.stagedBlocklistIDsForDisplay().count"))
        XCTAssertFalse(myListBlock.contains("viewModel.stagedBlockedDomainsForDisplay().count"))
        // The budget meter lives only in the add-a-blocklist picker — not duplicated on the cover.
        XCTAssertFalse(myListBlock.contains("FilterRuleBudgetBar("))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(pickerSource.contains("FilterRuleBudgetBar"))
    }

    func testMyListPullToRefreshUsesCatalogSync() throws {
        let filtersViewSource = try readSource(.filterMyListView)
        let myListBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "struct MyListCover: View",
            endingBefore: "private enum BlockedDomainSheet"
        )

        // Pull-to-refresh syncs the catalog — but only for the active filter; a non-active
        // "View" target passes a nil refreshAction (it isn't loaded, nothing to refresh).
        XCTAssertTrue(myListBlock.contains("refreshAction: viewModel.isViewingNonActiveFilter ? nil : {"))
        XCTAssertTrue(myListBlock.contains("await catalog.sync()"))
        XCTAssertFalse(
            filtersViewSource.contains("private struct CatalogSyncPanel: View"),
            "The catalog refresh panel is replaced by pull-to-refresh on the My list cover."
        )
    }

    func testFilterActionButtonsUseLeadingGlyphsWithStableLabelSpacing() throws {
        let filtersViewSource = try readSource(.filterMyListView)
        let sharedSource = try readSource(.filterSharedViews)
        let myListBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "struct MyListCover: View",
            endingBefore: "private enum BlockedDomainSheet"
        )
        let filterAddButtonBlock = try sourceBlock(
            in: sharedSource,
            startingAt: "struct FilterAddButton: View"
        )

        XCTAssertTrue(myListBlock.contains("FilterAddButton(title: \"Add a blocklist\", systemImage: \"plus\")"))
        XCTAssertTrue(myListBlock.contains("FilterAddButton(title: \"Block a domain\", systemImage: \"plus\")"))
        XCTAssertTrue(myListBlock.contains("FilterAddButton(title: \"Add an exception\", systemImage: \"plus\")"))
        XCTAssertTrue(filterAddButtonBlock.contains("private enum FilterActionLabelMetrics"))
        XCTAssertTrue(filterAddButtonBlock.contains("static let iconFrameSize: CGFloat = 16"))
        XCTAssertTrue(filterAddButtonBlock.contains("static let iconPointSize: CGFloat = LavaIconSize.inline"))
        XCTAssertTrue(filterAddButtonBlock.contains("static let iconTextSpacing: CGFloat = 7"))
        XCTAssertTrue(filterAddButtonBlock.contains("FilterActionLabel(title: title, systemImage: systemImage)"))
        XCTAssertTrue(filterAddButtonBlock.contains("HStack(spacing: FilterActionLabelMetrics.iconTextSpacing)"))
        XCTAssertTrue(filterAddButtonBlock.contains("width: FilterActionLabelMetrics.iconFrameSize"))
        XCTAssertTrue(filterAddButtonBlock.contains("height: FilterActionLabelMetrics.iconFrameSize"))
        XCTAssertFalse(filterAddButtonBlock.contains("Label(title.lavaLocalized"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(sharedSource.contains("lavaLocalized"))
    }

    func testBlocklistEditRowsUseStrikethroughInsteadOfPendingStatusPills() throws {
        let filtersViewSource = try readSource(.filterMyListView)
        let blocklistRowBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct BlocklistEffectRow: View",
            endingBefore: "private struct DomainEffectRow: View"
        )

        XCTAssertTrue(blocklistRowBlock.contains("Text(viewModel.blocklistName(for: sourceID).lavaLocalized)"))
        XCTAssertTrue(blocklistRowBlock.contains(".strikethrough(pendingRemoval"))
        XCTAssertTrue(blocklistRowBlock.contains("viewModel.blocklistMetadataText(for: sourceID)"))
        XCTAssertFalse(blocklistRowBlock.contains("status:"))
        XCTAssertFalse(blocklistRowBlock.contains("private var status"))
        XCTAssertFalse(blocklistRowBlock.contains(".pendingRemoval"))
        XCTAssertFalse(blocklistRowBlock.contains(".newlyAdded"))
    }

    func testDomainEditRowsUseStrikethroughInsteadOfPendingStatusPills() throws {
        let filtersViewSource = try readSource(.filterMyListView)
        let domainRowBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct DomainEffectRow: View"
        )

        XCTAssertTrue(domainRowBlock.contains("Text(domain.lavaLocalized)"))
        XCTAssertTrue(domainRowBlock.contains(".strikethrough(isPendingRemoval"))
        // Matches BlocklistEffectRow's floor so the row keeps one height across view
        // and edit (the 44pt edit-mode delete button + 18pt padding = 62 must clear it).
        XCTAssertTrue(domainRowBlock.contains(".frame(minHeight: 64)"))
        XCTAssertFalse(domainRowBlock.contains("status:"))
        XCTAssertFalse(domainRowBlock.contains("private var status"))
        XCTAssertFalse(domainRowBlock.contains(".pendingRemoval"))
        XCTAssertFalse(domainRowBlock.contains(".newlyAdded"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(filtersViewSource.contains("pendingRemoval"))
    }

    func testStandaloneToolbarIconButtonsUseFullTapAreas() throws {
        let filtersViewSource = try readSource(.filterMyListView)
        let rootViewSource = try readSource(.lavaScaffold)
        let toolbarBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "struct LavaToolbarIconButton: View",
            endingBefore: "struct NativeToolbarIconButton: View"
        )
        let nativeToolbarBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "struct NativeToolbarIconButton: View",
            endingBefore: "private struct LavaToolbarIconSymbol: View"
        )
        let blocklistRowBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct BlocklistEffectRow: View",
            endingBefore: "private struct DomainEffectRow: View"
        )
        let domainRowBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct DomainEffectRow: View"
        )

        XCTAssertTrue(toolbarBlock.contains(".frame(width: LavaToolbarMetrics.buttonSize, height: LavaToolbarMetrics.buttonSize)"))
        XCTAssertTrue(toolbarBlock.contains(".contentShape(Circle())"))
        XCTAssertFalse(toolbarBlock.contains(".fixedSize()"))
        XCTAssertTrue(nativeToolbarBlock.contains(".frame(width: LavaToolbarMetrics.iconFrameSize, height: LavaToolbarMetrics.iconFrameSize)"))
        XCTAssertFalse(nativeToolbarBlock.contains(".frame(width: LavaToolbarMetrics.buttonSize"))
        XCTAssertFalse(nativeToolbarBlock.contains(".buttonStyle("))
        XCTAssertTrue(blocklistRowBlock.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(domainRowBlock.contains(".frame(width: 44, height: 44)"))
    }

    func testBlocklistPickerUsesFlatRowsInsteadOfCondensedCard() throws {
        let addBlocklistSheetBlock = try sourceBlock(
            in: try readSource(.blocklistPickerView),
            startingAt: "struct AddBlocklistSheet: View",
            endingBefore: "private enum CustomBlocklistFocusField"
        )
        let flatListBlock = try sourceBlock(
            in: addBlocklistSheetBlock,
            startingAt: "private struct BlocklistPickerList: View",
            endingBefore: "private struct BlocklistPickerRow: View"
        )
        let rowBlock = try sourceBlock(
            in: addBlocklistSheetBlock,
            startingAt: "private struct BlocklistPickerRow: View"
        )

        XCTAssertTrue(addBlocklistSheetBlock.contains("BlocklistPickerList("))
        XCTAssertTrue(flatListBlock.contains("BlocklistPickerRow("))
        XCTAssertTrue(flatListBlock.contains("Divider()"))
        XCTAssertTrue(rowBlock.contains("Button {"))
        XCTAssertTrue(rowBlock.contains("toggle(blocklist.id)"))
        XCTAssertTrue(rowBlock.contains(".contentShape(Rectangle())"))
        // Rows route through the shared selectable-row scaffold (trailing checkmark)
        // rather than a bespoke leading selection glyph.
        XCTAssertTrue(rowBlock.contains("LavaSelectableRow("))
        XCTAssertFalse(rowBlock.contains("BlocklistPickerSelectionGlyph("))
        // The DATA rows stay flat — no condensed card in the flat list or its rows. The one
        // condensed card allowed in the sheet is the empty-state wrapper, so the picker's
        // empty placeholder sits on the same card scaffold (shared LavaEmptyListRow) as
        // every other empty list.
        XCTAssertFalse(flatListBlock.contains("LavaCondensedList"))
        XCTAssertFalse(rowBlock.contains("LavaCondensedList"))
        XCTAssertFalse(addBlocklistSheetBlock.contains("LavaCondensedListItem("))
        XCTAssertEqual(
            addBlocklistSheetBlock.components(separatedBy: "LavaCondensedList {").count - 1, 1,
            "the empty-state wrapper is the only condensed card allowed in the picker sheet"
        )
        XCTAssertTrue(
            addBlocklistSheetBlock.components(separatedBy: .whitespacesAndNewlines).joined()
                .contains("LavaCondensedList{LavaEmptyListRow("),
            "the sheet's sole condensed card must be the shared empty-state row"
        )

        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(try readSource(.lavaCondensedList).contains("LavaCondensedList"))
    }

    func testBlocklistPickerUsesAllBlocklistsSearchAndCustomListRoute() throws {
        let filtersViewSource = try readSource(.blocklistPickerView)
        let addBlocklistSheetBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "struct AddBlocklistSheet: View",
            endingBefore: "private struct BlocklistSearchField: View"
        )

        XCTAssertTrue(addBlocklistSheetBlock.contains("@State private var navigationPath: [AddBlocklistRoute] = []"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("@State private var searchText = \"\""))
        XCTAssertTrue(addBlocklistSheetBlock.contains("BlocklistSearchField(text: $searchText)"))
        // The single "All blocklists" section is replaced by category sections plus a
        // row of jump-pills under the search box. The pills are hosted by `BlocklistJumpPillBar`,
        // which reads the scaffold's published scroll proxy (`hostsScrollProxy`) so the pinned
        // header can drive the list without an external `ScrollViewReader` wrapping — and
        // collapsing — the scaffold (which floated the footer; lavasec-ios#326 follow-up).
        XCTAssertTrue(addBlocklistSheetBlock.contains("BlocklistJumpPillBar("))
        XCTAssertFalse(
            addBlocklistSheetBlock.contains("ScrollViewReader {"),
            "The picker must not wrap the scaffold in its own reader; the scaffold hosts one internally."
        )
        XCTAssertTrue(addBlocklistSheetBlock.contains("private var visibleSections: [BlocklistPickerSection]"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("ForEach(visibleSections)"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("LavaSectionGroup(section.title)"))
        // The jump-pills scroll to a section via an anchor placed slightly above it (so
        // the section title clears the pinned header) rather than the section's own `.id`.
        XCTAssertTrue(addBlocklistSheetBlock.contains(".blocklistJumpAnchor(id: section.id, pinnedHeaderHeight: pinnedHeaderHeight)"))
        XCTAssertFalse(addBlocklistSheetBlock.contains("LavaSectionGroup(\"All blocklists\")"))
        XCTAssertFalse(addBlocklistSheetBlock.contains("LavaSectionGroup(\"Third-party blocklists\")"))
        XCTAssertFalse(addBlocklistSheetBlock.contains("LavaSectionGroup(\"Bring your own list\")"))
        XCTAssertFalse(addBlocklistSheetBlock.contains("BringYourOwnListEntryRow"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("NativeToolbarIconButton("))
        XCTAssertTrue(addBlocklistSheetBlock.contains("systemName: \"plus\""))
        XCTAssertTrue(addBlocklistSheetBlock.contains("accessibilityLabel: \"Bring your own list\""))
        XCTAssertTrue(addBlocklistSheetBlock.contains("private func openBringYourOwnList()"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("navigationPath.append(.bringYourOwnList)"))
        XCTAssertTrue(addBlocklistSheetBlock.contains(".navigationDestination(for: AddBlocklistRoute.self)"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("case .bringYourOwnList:"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("BringYourOwnListView("))
        XCTAssertTrue(addBlocklistSheetBlock.contains("private var filteredPickerItems: [BlocklistPickerItem]"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("viewModel.stagedCustomBlocklistsForPicker()"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("item.matchesSearch(searchText)"))
    }

    func testCategoryJumpInsetTracksMeasuredHeaderHeightNotAFixedConstant() throws {
        // Regression: a fixed pill-jump inset left the section title tucked under the pinned
        // header ("still too high") — worst in `.filterDraft`, whose header carries the search
        // field the shorter `.onboardingSelection` header omits. The landing inset must be
        // sized from the LIVE header height, so the header is measured and threaded through.
        let filtersViewSource = try readSource(.blocklistPickerView)
        let addBlocklistSheetBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "struct AddBlocklistSheet: View",
            endingBefore: "private struct BlocklistSearchField: View"
        )
        let jumpMetricsBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private enum BlocklistJumpMetrics",
            endingBefore: "extension View"
        )

        XCTAssertTrue(addBlocklistSheetBlock.contains("@State private var pinnedHeaderHeight: CGFloat = 0"))
        XCTAssertTrue(addBlocklistSheetBlock.contains(".onGeometryChange(for: CGFloat.self)"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("pinnedHeaderHeight = newHeight"))
        XCTAssertTrue(jumpMetricsBlock.contains("static func topInset(pinnedHeaderHeight: CGFloat) -> CGFloat"))
        XCTAssertTrue(jumpMetricsBlock.contains("pinnedHeaderHeight + scaffoldHeaderVerticalPadding + headerBottomGap"))
        // The old fixed inset is gone.
        XCTAssertFalse(jumpMetricsBlock.contains("static let topInset: CGFloat"))
    }

    func testBlocklistSearchFieldMatchesDomainHistorySearchDesign() throws {
        let filtersViewSource = try readSource(.blocklistPickerView)
        let searchFieldBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct BlocklistSearchField: View",
            endingBefore: "private enum BlocklistPickerItem"
        )

        XCTAssertTrue(searchFieldBlock.contains("Image(systemName: \"magnifyingglass\")"))
        XCTAssertTrue(searchFieldBlock.contains("TextField(\"Search lists or categories\", text: $text)"))
        XCTAssertTrue(searchFieldBlock.contains("Image(systemName: \"xmark.circle.fill\")"))
        XCTAssertTrue(searchFieldBlock.contains(".frame(height: 48)"))
        XCTAssertTrue(searchFieldBlock.contains(".lavaSurface(.panel, cornerRadius: LavaSurface.compactCornerRadius, borderTint: LavaSurface.panelStroke.opacity(0.65))"))
        XCTAssertFalse(searchFieldBlock.contains(".fill(LavaStyle.panelBackground)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(filtersViewSource.contains("LavaStyle"))
    }

    func testBringYourOwnListSheetGatesFreeUsersAndUsesBackNavigation() throws {
        let filtersViewSource = try readSource(.blocklistPickerView)
        let byolBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct BringYourOwnListView: View"
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
        XCTAssertTrue(byolBlock.contains("LavaTextInputPanel"))
        XCTAssertTrue(byolBlock.contains("LavaTextInputRow(title: \"Name (optional)\")"))
        XCTAssertTrue(byolBlock.contains("LavaTextInputRow(title: \"Blocklist URL\")"))
        XCTAssertTrue(byolBlock.contains("TextField(\"My blocklist\".lavaLocalized, text: $customDisplayName)"))
        XCTAssertTrue(byolBlock.contains("TextField(\"https://example.com/pi-hole-style-list.txt\", text: $customURL)"))
        XCTAssertTrue(byolBlock.contains("FilterActionLabel(title: \"Add Blocklist\", systemImage: \"plus\")"))
        XCTAssertTrue(byolBlock.contains("Text(\"Upgrade\".lavaLocalized)"))
        XCTAssertTrue(byolBlock.contains(".font(.footnote.weight(.bold))"))
        XCTAssertTrue(byolBlock.contains(".foregroundStyle(LavaStyle.safeGreen)"))
        XCTAssertTrue(byolBlock.contains("Text(\" to Lava Security Plus to bring your own list\".lavaLocalized)"))
        XCTAssertTrue(byolBlock.contains(".foregroundStyle(LavaStyle.secondaryText)"))
        XCTAssertFalse(byolBlock.contains("Text(\"Upgrade to Lava Security Plus to bring your own list\".lavaLocalized)"))
        XCTAssertFalse(byolBlock.contains(".underline()"))
        XCTAssertTrue(byolBlock.contains("showUpgrade()"))
        XCTAssertFalse(byolBlock.contains("Button(allowsCustomBlocklists ? \"Add Custom Blocklist\" : \"Upgrade\""))
        XCTAssertTrue(customListFormBlock.contains("VStack(spacing: 12)"))
        XCTAssertTrue(customListFormBlock.contains("LavaTextInputPanel"))
        XCTAssertTrue(customListFormBlock.contains("Divider()"))
        XCTAssertFalse(customListFormBlock.contains("CustomBlocklistTextField"))
        XCTAssertFalse(customListFormBlock.contains("LavaPlainCard"))
        XCTAssertTrue(byolBlock.contains("dismiss()"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(filtersViewSource.contains("NativeToolbarIconButton"))
        XCTAssertTrue(filtersViewSource.contains("LavaPlainCard"))
    }

    func testCustomBlocklistRowsUsePendingRefreshAndTrashConfirmation() throws {
        let filtersViewSource = try readSource(.blocklistPickerView)
        let customRowBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct CustomBlocklistPickerRow: View",
            endingBefore: "private struct BlocklistPickerStatusPill"
        )
        let addBlocklistSheetBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "struct AddBlocklistSheet: View",
            endingBefore: "private struct BlocklistSearchField: View"
        )

        XCTAssertTrue(customRowBlock.contains("Text(title.lavaLocalized)"))
        XCTAssertTrue(customRowBlock.contains(".truncationMode(.middle)"))
        XCTAssertTrue(customRowBlock.contains("Text(\"Custom List\".lavaLocalized)"))
        XCTAssertTrue(customRowBlock.contains("metadataPrefixStatus"))
        XCTAssertTrue(customRowBlock.contains("metadataText"))
        XCTAssertTrue(customRowBlock.contains("\"Pending refresh\""))
        XCTAssertTrue(customRowBlock.contains("Image(systemName: \"trash\")"))
        XCTAssertTrue(customRowBlock.contains("accessibilityLabel(\"Delete custom blocklist\")"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("@State private var customDeleteConfirmation: CustomBlocklistSource?"))
        XCTAssertTrue(addBlocklistSheetBlock.contains(".alert(\"Delete custom list?\""))
        XCTAssertTrue(addBlocklistSheetBlock.contains("Button(\"Delete\", role: .destructive)"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("deleteCustomSource(id: source.id)"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("This removes the custom blocklist from your saved lists."))
    }

    func testDomainEntrySheetsAutoFocusAndKeepStableKeyboardFriendlyLayout() throws {
        let filtersViewSource = try readSource(.filterDomainSheets)
        let formBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct DomainEntryForm: View",
            endingBefore: "private struct DomainTextField: View"
        )
        let fieldBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct DomainTextField: View",
            endingBefore: "struct AddBlockedDomainSheet: View"
        )
        let blockedSheetBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "struct AddBlockedDomainSheet: View",
            endingBefore: "struct AddAllowedExceptionSheet: View"
        )
        let allowedSheetBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "struct AddAllowedExceptionSheet: View"
        )

        XCTAssertTrue(formBlock.contains("@FocusState private var isDomainFieldFocused"))
        XCTAssertTrue(formBlock.contains("isFocused: $isDomainFieldFocused"))
        XCTAssertTrue(formBlock.contains("isDomainFieldFocused = true"))
        XCTAssertTrue(fieldBlock.contains("let isFocused: FocusState<Bool>.Binding"))
        XCTAssertTrue(fieldBlock.contains("LavaTextInputPanel"))
        XCTAssertTrue(fieldBlock.contains("LavaTextInputRow(title: \"Domain\")"))
        XCTAssertTrue(fieldBlock.contains("TextField(placeholder.lavaLocalized, text: $text)"))
        XCTAssertTrue(fieldBlock.contains(".lavaTextInputBody(keyboardType: .URL)"))
        XCTAssertTrue(fieldBlock.contains(".focused(isFocused)"))
        XCTAssertFalse(fieldBlock.contains("RoundedRectangle(cornerRadius: 12"))
        XCTAssertFalse(fieldBlock.contains("secondarySystemGroupedBackground"))
        XCTAssertTrue(blockedSheetBlock.contains("LavaSheetScaffold(spacing: 18, scrolls: true)"))
        XCTAssertTrue(allowedSheetBlock.contains("LavaSheetScaffold(spacing: 18, scrolls: true)"))
        XCTAssertFalse(blockedSheetBlock.contains("scrolls: result?.isAccepted == false"))
        XCTAssertFalse(allowedSheetBlock.contains("scrolls: result?.isAccepted == false"))
        XCTAssertFalse(blockedSheetBlock.contains("result?.isAccepted == false ?"))
        XCTAssertFalse(allowedSheetBlock.contains("result?.isAccepted == false ?"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(filtersViewSource.contains("isAccepted"))
    }

    func testCustomBlocklistURLInputStateLivesInDedicatedSubview() throws {
        let filtersViewSource = try readSource(.blocklistPickerView)
        let addBlocklistSheetBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "struct AddBlocklistSheet: View",
            endingBefore: "private enum CustomBlocklistFocusField"
        )
        let bringYourOwnListBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct BringYourOwnListView: View"
        )

        XCTAssertTrue(addBlocklistSheetBlock.contains("BringYourOwnListView("))
        XCTAssertFalse(addBlocklistSheetBlock.contains("@State private var customDisplayName"))
        XCTAssertFalse(addBlocklistSheetBlock.contains("@State private var customURL"))
        XCTAssertFalse(addBlocklistSheetBlock.contains("@State private var customMessage"))
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
        let appViewModelSource = try readSource(.appViewModel)
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
        XCTAssertTrue(appViewModelSource.contains("private static func filterPreparationFailureMessage(for error: Error) -> String"))
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

        XCTAssertTrue(rowBlock.contains(".frame(width: 28, height: 28)"))
        XCTAssertTrue(rowBlock.contains(".font(.body.weight(.semibold))"))
        XCTAssertTrue(rowBlock.contains(".padding(.horizontal, 16)"))
        XCTAssertTrue(rowBlock.contains(".frame(minHeight: 56)"))
    }

    func testReviewSheetUsesDismissiveToolbarIcon() throws {
        let reviewFlowSource = try readSource(.filterReviewFlowView)
        let confirmationSheetBlock = try sourceBlock(
            in: reviewFlowSource,
            startingAt: "struct FilterConfirmationSheet: View",
            endingBefore: "struct DiffGroup: View"
        )

        XCTAssertTrue(confirmationSheetBlock.contains("ToolbarItem(placement: .cancellationAction)"))
        XCTAssertTrue(confirmationSheetBlock.contains("NativeToolbarIconButton(systemName: \"xmark\", accessibilityLabel: \"Cancel\", role: .cancel)"))
        XCTAssertFalse(confirmationSheetBlock.contains("LavaToolbarIconButton("))
        XCTAssertTrue(confirmationSheetBlock.contains("cancelIfStandaloneReview()"))
        XCTAssertTrue(confirmationSheetBlock.contains("dismiss()"))
        XCTAssertFalse(confirmationSheetBlock.contains("Button(\"Cancel\")"))
    }

    func testFilterSheetsUseNativeToolbarGlyphActions() throws {
        let sharedSource = try readSource(.filterSharedViews)
        let pickerSource = try readSource(.blocklistPickerView)
        let domainSource = try readSource(.filterDomainSheets)

        let lavaPlusSheetBlock = try sourceBlock(
            in: sharedSource,
            startingAt: "struct LavaPlusUpgradeSheet: View",
            endingBefore: "struct FilterAddButton: View"
        )
        let addBlocklistSheetBlock = try sourceBlock(
            in: pickerSource,
            startingAt: "struct AddBlocklistSheet: View",
            endingBefore: "private enum CustomBlocklistFocusField"
        )
        let addBlockedDomainSheetBlock = try sourceBlock(
            in: domainSource,
            startingAt: "struct AddBlockedDomainSheet: View",
            endingBefore: "struct AddAllowedExceptionSheet: View"
        )
        let addAllowedExceptionSheetBlock = try sourceBlock(
            in: domainSource,
            startingAt: "struct AddAllowedExceptionSheet: View"
        )

        for sheetBlock in [
            lavaPlusSheetBlock,
            addBlocklistSheetBlock,
            addBlockedDomainSheetBlock,
            addAllowedExceptionSheetBlock
        ] {
            XCTAssertTrue(sheetBlock.contains("ToolbarItem(placement: .cancellationAction)"))
            XCTAssertTrue(sheetBlock.contains("NativeToolbarIconButton(systemName: \"xmark\""))
            XCTAssertFalse(sheetBlock.contains("LavaToolbarIconButton("))
        }
    }

    func testReviewSheetBlocksInvalidDraftsBeforeCompile() throws {
        let appViewModelSource = try readSource(.appViewModel)
        let sharedReviewSource = try readSource(.filterReviewFlowView)

        XCTAssertTrue(appViewModelSource.contains("var filterDraftCanConfirm: Bool"))
        XCTAssertTrue(appViewModelSource.contains("var filterDraftValidationMessage: String?"))
        XCTAssertTrue(appViewModelSource.contains("draft.blockedDomains.count > configuration.limits.maxBlockedDomains"))
        XCTAssertTrue(appViewModelSource.contains("draft.allowedDomains.count > configuration.limits.maxAllowedDomains"))
        XCTAssertTrue(sharedReviewSource.contains("viewModel.filterDraftValidationMessage"))
        XCTAssertTrue(sharedReviewSource.contains(".disabled(!viewModel.filterDraftCanConfirm)"))
    }

    func testToolbarIconTemplateUsesCompactCircularChrome() throws {
        let rootViewSource = try readSource(.lavaScaffold)
        let toolbarTemplateBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "enum LavaToolbarMetrics"
        )
        let onboardingSource = try readSource(.onboardingFlowView)

        XCTAssertTrue(toolbarTemplateBlock.contains("static let buttonSize: CGFloat = 44"))
        XCTAssertTrue(toolbarTemplateBlock.contains("static let iconFrameSize: CGFloat = 24"))
        XCTAssertTrue(toolbarTemplateBlock.contains("static let chevronIconPointSize: CGFloat = 17"))
        XCTAssertTrue(toolbarTemplateBlock.contains("static let xmarkIconPointSize: CGFloat = 15"))
        XCTAssertTrue(toolbarTemplateBlock.contains("static let plusIconPointSize: CGFloat = 18"))
        XCTAssertTrue(toolbarTemplateBlock.contains("static let checkmarkIconPointSize: CGFloat = 17"))
        XCTAssertTrue(toolbarTemplateBlock.contains("static let framedIconPointSize: CGFloat = 15"))
        XCTAssertTrue(toolbarTemplateBlock.contains("static let wideIconPointSize: CGFloat = 15"))
        XCTAssertTrue(toolbarTemplateBlock.contains("static let framedIconVerticalOffset: CGFloat = -1"))
        XCTAssertTrue(toolbarTemplateBlock.contains("struct LavaToolbarIconButton: View"))
        XCTAssertTrue(toolbarTemplateBlock.contains("Button(action: action)"))
        XCTAssertTrue(toolbarTemplateBlock.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(toolbarTemplateBlock.contains("LavaToolbarIconSurface"))
        XCTAssertFalse(toolbarTemplateBlock.contains("glassEffect("))
        XCTAssertFalse(toolbarTemplateBlock.contains(".background("))
        XCTAssertFalse(toolbarTemplateBlock.contains(".buttonStyle(.glass)"))
        XCTAssertFalse(toolbarTemplateBlock.contains(".buttonBorderShape(.circle)"))
        XCTAssertFalse(toolbarTemplateBlock.contains(".controlSize(.regular)"))
        XCTAssertFalse(toolbarTemplateBlock.contains(".fixedSize()"))
        XCTAssertFalse(toolbarTemplateBlock.contains(".padding("))
        XCTAssertFalse(toolbarTemplateBlock.contains("systemChromeContentWidth"))
        XCTAssertFalse(toolbarTemplateBlock.contains(".frame(width: LavaToolbarMetrics.iconFrameSize, height: LavaToolbarMetrics.buttonSize)"))
        XCTAssertTrue(toolbarTemplateBlock.contains(".font(.system(size: iconPointSize, weight: .semibold))"))
        XCTAssertTrue(toolbarTemplateBlock.contains(".offset(y: iconVerticalOffset)"))
        XCTAssertTrue(toolbarTemplateBlock.contains("case \"chevron.left\""))
        XCTAssertTrue(toolbarTemplateBlock.contains("case \"xmark\""))
        XCTAssertTrue(toolbarTemplateBlock.contains("case \"plus\""))
        XCTAssertTrue(toolbarTemplateBlock.contains("case \"checkmark\""))
        XCTAssertTrue(toolbarTemplateBlock.contains("case \"square.and.pencil\""))
        XCTAssertTrue(toolbarTemplateBlock.contains("case \"trash\""))
        XCTAssertTrue(toolbarTemplateBlock.contains(".frame(width: LavaToolbarMetrics.iconFrameSize, height: LavaToolbarMetrics.iconFrameSize)"))
        XCTAssertTrue(toolbarTemplateBlock.contains(".frame(width: LavaToolbarMetrics.buttonSize, height: LavaToolbarMetrics.buttonSize)"))
        // The onboarding header uses its OWN circular bordered back button: the shared
        // template is intentionally chrome-less (see the assertions above), which read as
        // "on the edge" inside onboarding's custom bar, so it's not used there anymore.
        XCTAssertFalse(onboardingSource.contains("LavaToolbarIconButton(systemName: \"chevron.left\""))
        XCTAssertTrue(onboardingSource.contains(".background(.regularMaterial, in: Circle())"))
    }

    func testNativeToolbarIconButtonUsesSharedSquareLabelFrame() throws {
        let rootViewSource = try readSource(.lavaScaffold)
        let nativeToolbarButtonBlock = try sourceBlock(
            in: rootViewSource,
            startingAt: "struct NativeToolbarIconButton: View",
            endingBefore: "private struct LavaToolbarIconSymbol"
        )

        XCTAssertTrue(nativeToolbarButtonBlock.contains(".frame(width: LavaToolbarMetrics.iconFrameSize, height: LavaToolbarMetrics.iconFrameSize)"))
        XCTAssertFalse(nativeToolbarButtonBlock.contains(".frame(width: LavaToolbarMetrics.buttonSize"))
        XCTAssertFalse(nativeToolbarButtonBlock.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(nativeToolbarButtonBlock.contains(".background("))
    }

    func testFilterEditToolbarUsesSemanticNativePlacements() throws {
        let filtersViewSource = try readSource(.filterMyListView)
        let editToolbarBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct FilterEditToolbar: ToolbarContent",
            endingBefore: "private struct BlocklistEffectRow: View"
        )

        XCTAssertTrue(editToolbarBlock.contains("ToolbarItem(placement: .cancellationAction)"))
        XCTAssertTrue(editToolbarBlock.contains("ToolbarItem(placement: .confirmationAction)"))
        XCTAssertFalse(editToolbarBlock.contains("ToolbarItem(placement: .primaryAction)"))
        XCTAssertTrue(filtersViewSource.contains("ToolbarItemGroup(placement: .primaryAction)"))
        XCTAssertTrue(editToolbarBlock.contains("NativeToolbarIconButton(systemName: \"xmark\""))
        XCTAssertTrue(editToolbarBlock.contains("NativeToolbarIconButton(systemName: \"checkmark\""))
        XCTAssertFalse(editToolbarBlock.contains("NativeToolbarIconButton(systemName: \"square.and.pencil\""))
        XCTAssertTrue(filtersViewSource.contains("systemName: \"square.and.pencil\""))
        XCTAssertFalse(editToolbarBlock.contains("LavaToolbarIconButton("))
        XCTAssertFalse(editToolbarBlock.contains("ToolbarItem(placement: .topBarLeading)"))
        XCTAssertFalse(editToolbarBlock.contains("ToolbarItem(placement: .topBarTrailing)"))
    }
}
