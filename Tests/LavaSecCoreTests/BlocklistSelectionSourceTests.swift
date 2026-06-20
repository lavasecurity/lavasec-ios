import XCTest

final class BlocklistSelectionSourceTests: XCTestCase {
    func testFilterDraftBlocklistSheetStartsFromCurrentDraftSelection() throws {
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let blockedDomainsSheetBlock = try Self.sourceBlock(
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
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let availableBlocklistsBlock = try Self.sourceBlock(
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
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let appViewModelSource = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let addSelectionBlock = try Self.sourceBlock(
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
        let appViewModelSource = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let draftBlock = try Self.sourceBlock(
            in: appViewModelSource,
            startingAt: "func addCustomBlocklistToDraft(displayName: String, rawURL: String) -> String?",
            endingBefore: "func removeBlocklistFromDraft"
        )
        let immediateBlock = try Self.sourceBlock(
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
        let reviewFlowSource = try Self.source(named: "FilterReviewFlowView.swift", in: "LavaSecApp")
        let start = try XCTUnwrap(reviewFlowSource.range(of: "struct PreparationTickerTitle: View")?.lowerBound)
        let titleBlock = String(reviewFlowSource[start...])

        XCTAssertTrue(titleBlock.contains("@State private var titleOffset"))
        XCTAssertTrue(titleBlock.contains("titleOffset = -18"))
        XCTAssertTrue(titleBlock.contains("titleOffset = 18"))
        XCTAssertFalse(titleBlock.contains("ZStack"))
    }

    func testFilterEditToolbarUsesIconOnlyNativeActions() throws {
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let toolbarBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct FilterEditToolbar: ToolbarContent",
            endingBefore: "private struct LavaInlineInfoContent: View"
        )

        XCTAssertTrue(toolbarBlock.contains("NativeToolbarIconButton(systemName: \"checkmark\", accessibilityLabel: \"Save\", role: .confirm, action: save)"))
        XCTAssertTrue(toolbarBlock.contains("NativeToolbarIconButton(systemName: \"square.and.pencil\", accessibilityLabel: \"Edit\", action: beginEditing)"))
        XCTAssertFalse(toolbarBlock.contains("Button(\"Save\""))
        XCTAssertFalse(toolbarBlock.contains("Button(\"Edit\""))
    }

    func testFilterDiscardUsesPopupDialogWithStandardActions() throws {
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let myListBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct MyListCover: View",
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
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let myListBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct MyListCover: View",
            endingBefore: "private enum BlockedDomainSheet"
        )

        XCTAssertTrue(myListBlock.contains("viewModel.configuredProtectedDomainNumberText"))
        XCTAssertFalse(myListBlock.contains("viewModel.stagedBlocklistIDsForDisplay().count"))
        XCTAssertFalse(myListBlock.contains("viewModel.stagedBlockedDomainsForDisplay().count"))
        // The budget meter lives only in the add-a-blocklist picker — not duplicated on the cover.
        XCTAssertFalse(myListBlock.contains("FilterRuleBudgetBar("))
    }

    func testMyListPullToRefreshUsesCatalogSync() throws {
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let myListBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct MyListCover: View",
            endingBefore: "private enum BlockedDomainSheet"
        )

        XCTAssertTrue(myListBlock.contains("refreshAction: {"))
        XCTAssertTrue(myListBlock.contains("await viewModel.syncCatalog()"))
        XCTAssertFalse(
            filtersViewSource.contains("private struct CatalogSyncPanel: View"),
            "The catalog refresh panel is replaced by pull-to-refresh on the My list cover."
        )
    }

    func testFilterActionButtonsUseLeadingGlyphsWithStableLabelSpacing() throws {
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let myListBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct MyListCover: View",
            endingBefore: "private enum BlockedDomainSheet"
        )
        let filterAddButtonBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct FilterAddButton: View",
            endingBefore: "private struct DomainEntryForm: View"
        )

        XCTAssertTrue(myListBlock.contains("FilterAddButton(title: \"Add a blocklist\", systemImage: \"plus\")"))
        XCTAssertTrue(myListBlock.contains("FilterAddButton(title: \"Block a domain\", systemImage: \"plus\")"))
        XCTAssertTrue(myListBlock.contains("FilterAddButton(title: \"Add an exception\", systemImage: \"plus\")"))
        XCTAssertTrue(filterAddButtonBlock.contains("private enum FilterActionLabelMetrics"))
        XCTAssertTrue(filterAddButtonBlock.contains("static let iconFrameSize: CGFloat = 16"))
        XCTAssertTrue(filterAddButtonBlock.contains("static let iconPointSize: CGFloat = 13"))
        XCTAssertTrue(filterAddButtonBlock.contains("static let iconTextSpacing: CGFloat = 7"))
        XCTAssertTrue(filterAddButtonBlock.contains("FilterActionLabel(title: title, systemImage: systemImage)"))
        XCTAssertTrue(filterAddButtonBlock.contains("HStack(spacing: FilterActionLabelMetrics.iconTextSpacing)"))
        XCTAssertTrue(filterAddButtonBlock.contains("width: FilterActionLabelMetrics.iconFrameSize"))
        XCTAssertTrue(filterAddButtonBlock.contains("height: FilterActionLabelMetrics.iconFrameSize"))
        XCTAssertFalse(filterAddButtonBlock.contains("Label(title.lavaLocalized"))
    }

    func testBlocklistEditRowsUseStrikethroughInsteadOfPendingStatusPills() throws {
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let blocklistRowBlock = try Self.sourceBlock(
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
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let domainRowBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct DomainEffectRow: View",
            endingBefore: "private struct FilterAddButton: View"
        )

        XCTAssertTrue(domainRowBlock.contains("Text(domain.lavaLocalized)"))
        XCTAssertTrue(domainRowBlock.contains(".strikethrough(isPendingRemoval"))
        XCTAssertTrue(domainRowBlock.contains(".frame(minHeight: 56)"))
        XCTAssertFalse(domainRowBlock.contains("status:"))
        XCTAssertFalse(domainRowBlock.contains("private var status"))
        XCTAssertFalse(domainRowBlock.contains(".pendingRemoval"))
        XCTAssertFalse(domainRowBlock.contains(".newlyAdded"))
    }

    func testStandaloneToolbarIconButtonsUseFullTapAreas() throws {
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let rootViewSource = try Self.source(named: "LavaScaffold.swift", in: "LavaSecApp/LavaDesignSystem")
        let toolbarBlock = try Self.sourceBlock(
            in: rootViewSource,
            startingAt: "struct LavaToolbarIconButton: View",
            endingBefore: "struct NativeToolbarIconButton: View"
        )
        let nativeToolbarBlock = try Self.sourceBlock(
            in: rootViewSource,
            startingAt: "struct NativeToolbarIconButton: View",
            endingBefore: "private struct LavaToolbarIconSymbol: View"
        )
        let blocklistRowBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct BlocklistEffectRow: View",
            endingBefore: "private struct DomainEffectRow: View"
        )
        let domainRowBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct DomainEffectRow: View",
            endingBefore: "private struct FilterAddButton: View"
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
        let addBlocklistSheetBlock = try Self.sourceBlock(
            in: try Self.source(named: "FiltersView.swift", in: "LavaSecApp"),
            startingAt: "struct AddBlocklistSheet: View",
            endingBefore: "private enum CustomBlocklistFocusField"
        )
        let flatListBlock = try Self.sourceBlock(
            in: addBlocklistSheetBlock,
            startingAt: "private struct BlocklistPickerList: View",
            endingBefore: "private struct BlocklistPickerRow: View"
        )
        let rowBlock = try Self.sourceBlock(
            in: addBlocklistSheetBlock,
            startingAt: "private struct BlocklistPickerRow: View",
            endingBefore: "*** end ***"
        )

        XCTAssertTrue(addBlocklistSheetBlock.contains("BlocklistPickerList("))
        XCTAssertTrue(flatListBlock.contains("BlocklistPickerRow("))
        XCTAssertTrue(flatListBlock.contains("Divider()"))
        XCTAssertTrue(rowBlock.contains("Button {"))
        XCTAssertTrue(rowBlock.contains("toggle(blocklist.id)"))
        XCTAssertTrue(rowBlock.contains(".contentShape(Rectangle())"))
        XCTAssertFalse(addBlocklistSheetBlock.contains("LavaCondensedList {"))
        XCTAssertFalse(addBlocklistSheetBlock.contains("LavaCondensedListItem("))
    }

    func testBlocklistPickerUsesAllBlocklistsSearchAndCustomListRoute() throws {
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let addBlocklistSheetBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "struct AddBlocklistSheet: View",
            endingBefore: "private struct BlocklistSearchField: View"
        )

        XCTAssertTrue(addBlocklistSheetBlock.contains("@State private var navigationPath: [AddBlocklistRoute] = []"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("@State private var searchText = \"\""))
        XCTAssertTrue(addBlocklistSheetBlock.contains("BlocklistSearchField(text: $searchText)"))
        XCTAssertTrue(addBlocklistSheetBlock.contains("LavaSectionGroup(\"All blocklists\")"))
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

    func testBlocklistSearchFieldMatchesDomainHistorySearchDesign() throws {
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let searchFieldBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct BlocklistSearchField: View",
            endingBefore: "private enum BlocklistPickerItem"
        )

        XCTAssertTrue(searchFieldBlock.contains("Image(systemName: \"magnifyingglass\")"))
        XCTAssertTrue(searchFieldBlock.contains("TextField(\"Search list name\", text: $text)"))
        XCTAssertTrue(searchFieldBlock.contains("Image(systemName: \"xmark.circle.fill\")"))
        XCTAssertTrue(searchFieldBlock.contains(".frame(height: 48)"))
        XCTAssertTrue(searchFieldBlock.contains(".lavaSurface(.panel, cornerRadius: LavaSurface.compactCornerRadius, borderTint: LavaSurface.panelStroke.opacity(0.65))"))
        XCTAssertFalse(searchFieldBlock.contains(".fill(LavaStyle.panelBackground)"))
    }

    func testBringYourOwnListSheetGatesFreeUsersAndUsesBackNavigation() throws {
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let byolBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct BringYourOwnListView: View",
            endingBefore: "private struct AddBlockedDomainSheet: View"
        )
        let customListFormBlock = try Self.sourceBlock(
            in: byolBlock,
            startingAt: "private var customListForm: some View",
            endingBefore: "private var upgradeRow"
        )

        XCTAssertTrue(byolBlock.contains(".navigationTitle(\"Bring your own list\")"))
        XCTAssertTrue(byolBlock.contains("@Environment(\\.dismiss) private var dismiss"))
        XCTAssertFalse(byolBlock.contains(".navigationBarBackButtonHidden(true)"))
        XCTAssertFalse(byolBlock.contains("NativeToolbarIconButton(systemName: \"chevron.left\""))
        XCTAssertFalse(byolBlock.contains("let goBack"))
        XCTAssertTrue(byolBlock.contains("if allowsCustomBlocklists"))
        XCTAssertTrue(byolBlock.contains("LavaTextInputPanel"))
        XCTAssertTrue(byolBlock.contains("LavaTextInputRow(title: \"Name (optional)\")"))
        XCTAssertTrue(byolBlock.contains("LavaTextInputRow(title: \"Blocklist URL\")"))
        XCTAssertTrue(byolBlock.contains("TextField(\"My blocklist\".lavaLocalized, text: $customDisplayName)"))
        XCTAssertTrue(byolBlock.contains("TextField(\"https://example.com/pi-hole-style-list.txt\".lavaLocalized, text: $customURL)"))
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
    }

    func testCustomBlocklistRowsUsePendingRefreshAndTrashConfirmation() throws {
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let customRowBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct CustomBlocklistPickerRow: View",
            endingBefore: "private struct BlocklistPickerStatusPill"
        )
        let addBlocklistSheetBlock = try Self.sourceBlock(
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
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let formBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct DomainEntryForm: View",
            endingBefore: "private struct DomainTextField: View"
        )
        let fieldBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct DomainTextField: View",
            endingBefore: "private enum AddBlocklistRoute"
        )
        let blockedSheetBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct AddBlockedDomainSheet: View",
            endingBefore: "private struct AddAllowedExceptionSheet: View"
        )
        let allowedSheetBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct AddAllowedExceptionSheet: View",
            endingBefore: "*** end ***"
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
    }

    func testCustomBlocklistURLInputStateLivesInDedicatedSubview() throws {
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let addBlocklistSheetBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "struct AddBlocklistSheet: View",
            endingBefore: "private enum CustomBlocklistFocusField"
        )
        let bringYourOwnListBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct BringYourOwnListView: View",
            endingBefore: "private struct AddBlockedDomainSheet: View"
        )

        XCTAssertTrue(addBlocklistSheetBlock.contains("BringYourOwnListView("))
        XCTAssertFalse(addBlocklistSheetBlock.contains("@State private var customDisplayName"))
        XCTAssertFalse(addBlocklistSheetBlock.contains("@State private var customURL"))
        XCTAssertFalse(addBlocklistSheetBlock.contains("@State private var customMessage"))
        XCTAssertTrue(bringYourOwnListBlock.contains("@State private var customDisplayName"))
        XCTAssertTrue(bringYourOwnListBlock.contains("@State private var customURL"))
        XCTAssertTrue(bringYourOwnListBlock.contains("@State private var customMessage"))
    }

    func testCatalogAndPreparationCopyAvoidsRawFreshAndChecksumLanguage() throws {
        let appViewModelSource = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let freshnessTitleBlock = try Self.sourceBlock(
            in: appViewModelSource,
            startingAt: "var blocklistCatalogFreshnessTitle: String",
            endingBefore: "var blocklistCatalogFreshnessDescription: String"
        )
        let preparationBlock = try Self.sourceBlock(
            in: appViewModelSource,
            startingAt: "func prepareAndApplyFilterDraft() async",
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
        let reviewFlowSource = try Self.source(named: "FilterReviewFlowView.swift", in: "LavaSecApp")
        let diffGroupBlock = try Self.sourceBlock(
            in: reviewFlowSource,
            startingAt: "struct DiffGroup: View",
            endingBefore: "struct FilterPreparationScreen: View"
        )

        XCTAssertTrue(diffGroupBlock.contains("FilterReviewChangeRow("))
        XCTAssertFalse(diffGroupBlock.contains("LavaCondensedListItem("))
        guard reviewFlowSource.contains("struct FilterReviewChangeRow: View") else {
            return
        }

        let rowBlock = try Self.sourceBlock(
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
        let reviewFlowSource = try Self.source(named: "FilterReviewFlowView.swift", in: "LavaSecApp")
        let confirmationSheetBlock = try Self.sourceBlock(
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
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")

        let lavaPlusSheetBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct LavaPlusUpgradeSheet: View",
            endingBefore: "private struct FilterEditToolbar: ToolbarContent"
        )
        let addBlocklistSheetBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "struct AddBlocklistSheet: View",
            endingBefore: "private enum CustomBlocklistFocusField"
        )
        let addBlockedDomainSheetBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct AddBlockedDomainSheet: View",
            endingBefore: "private struct AddAllowedExceptionSheet: View"
        )
        let addAllowedExceptionSheetBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct AddAllowedExceptionSheet: View",
            endingBefore: "*** end ***"
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
        let appViewModelSource = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let sharedReviewSource = try Self.source(named: "FilterReviewFlowView.swift", in: "LavaSecApp")

        XCTAssertTrue(appViewModelSource.contains("var filterDraftCanConfirm: Bool"))
        XCTAssertTrue(appViewModelSource.contains("var filterDraftValidationMessage: String?"))
        XCTAssertTrue(appViewModelSource.contains("draft.blockedDomains.count > configuration.limits.maxBlockedDomains"))
        XCTAssertTrue(appViewModelSource.contains("draft.allowedDomains.count > configuration.limits.maxAllowedDomains"))
        XCTAssertTrue(sharedReviewSource.contains("viewModel.filterDraftValidationMessage"))
        XCTAssertTrue(sharedReviewSource.contains(".disabled(!viewModel.filterDraftCanConfirm)"))
    }

    func testToolbarIconTemplateUsesCompactCircularChrome() throws {
        let rootViewSource = try Self.source(named: "LavaScaffold.swift", in: "LavaSecApp/LavaDesignSystem")
        let toolbarTemplateBlock = try Self.sourceBlock(
            in: rootViewSource,
            startingAt: "enum LavaToolbarMetrics",
            endingBefore: "*** end ***"
        )
        let onboardingSource = try Self.source(named: "OnboardingFlowView.swift", in: "LavaSecApp")

        XCTAssertTrue(toolbarTemplateBlock.contains("static let buttonSize: CGFloat = 44"))
        XCTAssertTrue(toolbarTemplateBlock.contains("static let iconFrameSize: CGFloat = 24"))
        XCTAssertTrue(toolbarTemplateBlock.contains("static let chevronIconPointSize: CGFloat = 22"))
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
        XCTAssertTrue(onboardingSource.contains("LavaToolbarIconButton(systemName: \"chevron.left\", accessibilityLabel: \"Back\", action: goBack)"))
    }

    func testNativeToolbarIconButtonUsesSharedSquareLabelFrame() throws {
        let rootViewSource = try Self.source(named: "LavaScaffold.swift", in: "LavaSecApp/LavaDesignSystem")
        let nativeToolbarButtonBlock = try Self.sourceBlock(
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
        let filtersViewSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let editToolbarBlock = try Self.sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct FilterEditToolbar: ToolbarContent",
            endingBefore: "private struct LavaInlineInfoContent: View"
        )

        XCTAssertTrue(editToolbarBlock.contains("ToolbarItem(placement: .cancellationAction)"))
        XCTAssertTrue(editToolbarBlock.contains("ToolbarItem(placement: .confirmationAction)"))
        XCTAssertTrue(editToolbarBlock.contains("ToolbarItem(placement: .primaryAction)"))
        XCTAssertTrue(editToolbarBlock.contains("NativeToolbarIconButton(systemName: \"xmark\""))
        XCTAssertTrue(editToolbarBlock.contains("NativeToolbarIconButton(systemName: \"checkmark\""))
        XCTAssertTrue(editToolbarBlock.contains("NativeToolbarIconButton(systemName: \"square.and.pencil\""))
        XCTAssertFalse(editToolbarBlock.contains("LavaToolbarIconButton("))
        XCTAssertFalse(editToolbarBlock.contains("ToolbarItem(placement: .topBarLeading)"))
        XCTAssertFalse(editToolbarBlock.contains("ToolbarItem(placement: .topBarTrailing)"))
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
