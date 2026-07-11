import XCTest

final class ActivityLocalLogSourceTests: XCTestCase {
    func testNetworkActivityUsesLargeNavigationTitleLikeDomainHistory() throws {
        let source = try readSource(.diagnosticsNetworkActivity)
        let localLogSupport = try readSource(.diagnosticsLocalLogSupport)
        let networkBlock = try sourceBlock(
            in: source,
            startingAt: "struct NetworkActivityLogView: View",
            endingBefore: "private struct NetworkActivityLogRow: View"
        )

        XCTAssertFalse(networkBlock.contains("LavaScreenContent(\n            title: \"Network Activity\""))
        XCTAssertTrue(localLogSupport.contains("private struct LocalLogSubpageChrome"))
        XCTAssertTrue(networkBlock.contains(".localLogSubpageChrome("))
        XCTAssertTrue(networkBlock.contains("title: \"Network Activity\""))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("LavaScreenContent"))
    }

    func testDomainHistoryAndNetworkActivityExposeTopRightClearActions() throws {
        let localLogSupport = try readSource(.diagnosticsLocalLogSupport)
        let networkSource = try readSource(.diagnosticsNetworkActivity)
        let domainSource = try readSource(.diagnosticsDomainHistory)
        let chromeBlock = try sourceBlock(
            in: localLogSupport,
            startingAt: "private struct LocalLogSubpageChrome",
            endingBefore: "extension View"
        )
        let networkBlock = try sourceBlock(
            in: networkSource,
            startingAt: "struct NetworkActivityLogView: View",
            endingBefore: "private struct NetworkActivityLogRow: View"
        )
        let domainBlock = try sourceBlock(
            in: domainSource,
            startingAt: "struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        XCTAssertTrue(chromeBlock.contains("ToolbarItem(placement: .primaryAction)"))
        XCTAssertTrue(chromeBlock.contains("NativeToolbarIconButton(systemName: \"trash\", accessibilityLabel: \"Clear\", role: .destructive, action: clear)"))
        XCTAssertFalse(chromeBlock.contains("LavaToolbarIconButton("))
        XCTAssertFalse(chromeBlock.contains("Button(\"Clear\""))
        XCTAssertTrue(chromeBlock.contains(".navigationBarTitleDisplayMode(.large)"))
        XCTAssertFalse(chromeBlock.contains(".navigationBarTitleDisplayMode(.inline)"))
        XCTAssertTrue(networkBlock.contains("showingClearActivityConfirmation"))
        XCTAssertTrue(networkBlock.contains("viewModel.clearNetworkActivityLog()"))
        XCTAssertTrue(domainBlock.contains("showingClearHistoryConfirmation"))
        XCTAssertTrue(domainBlock.contains("reports.clearDomainHistory()"))
    }

    func testDomainHistoryDoesNotKeepBottomManageClearSection() throws {
        let source = try readSource(.diagnosticsDomainHistory)
        let domainBlock = try sourceBlock(
            in: source,
            startingAt: "struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        XCTAssertFalse(domainBlock.contains("LavaSectionGroup(\"Manage\")"))
        XCTAssertFalse(domainBlock.contains("title: \"Clear local domain history\""))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("LavaSectionGroup"))
    }

    func testDomainHistorySearchLivesInContentInsteadOfNavigationDrawer() throws {
        let source = try readSource(.diagnosticsDomainHistory)
        let domainBlock = try sourceBlock(
            in: source,
            startingAt: "struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        XCTAssertTrue(try readSource(.diagnosticsLocalLogSupport).contains("struct LocalLogSearchField"))
        XCTAssertTrue(domainBlock.contains("LocalLogSearchField(text: $searchText)"))
        XCTAssertFalse(domainBlock.contains(".searchable("))
    }

    func testDomainHistoryDoesNotShowLongPressHintFinePrint() throws {
        let source = try readSource(.diagnosticsDomainHistory)
        let domainBlock = try sourceBlock(
            in: source,
            startingAt: "struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        let historyTypeSection = try sourceBlock(
            in: domainBlock,
            startingAt: "LavaSectionGroup(\"Show\")",
            endingBefore: "LavaSectionGroup(\n                selectedFilter.rawValue"
        )

        XCTAssertFalse(domainBlock.contains("Long-press domain to add to allowed/blocked domains"))
        XCTAssertFalse(historyTypeSection.contains("Long-press domain to add to allowed/blocked domains"))
    }

    func testDomainHistoryEmptyRowsAvoidTerminalPeriods() throws {
        let source = try readSource(.diagnosticsDomainHistory)
        let localLogSupport = try readSource(.diagnosticsLocalLogSupport)
        let domainFilterBlock = try sourceBlock(
            in: localLogSupport,
            startingAt: "enum DomainHistoryFilter",
            endingBefore: "struct DomainHistoryDomainActionAlert"
        )
        let domainBlock = try sourceBlock(
            in: source,
            startingAt: "struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        XCTAssertTrue(domainFilterBlock.contains("\"No allowed domains saved yet\""))
        XCTAssertTrue(domainFilterBlock.contains("\"No blocked domains saved yet\""))
        XCTAssertTrue(domainBlock.contains("\"No domains match this search\""))
        XCTAssertFalse(domainFilterBlock.contains("\"No allowed domains saved yet.\""))
        XCTAssertFalse(domainFilterBlock.contains("\"No blocked domains saved yet.\""))
        XCTAssertFalse(domainBlock.contains("\"No domains match this search.\""))
    }

    func testDomainHistoryAndNetworkActivityUsePagedVisibleRows() throws {
        let localLogSupport = try readSource(.diagnosticsLocalLogSupport)
        let networkSource = try readSource(.diagnosticsNetworkActivity)
        let domainSource = try readSource(.diagnosticsDomainHistory)
        let networkBlock = try sourceBlock(
            in: networkSource,
            startingAt: "struct NetworkActivityLogView: View",
            endingBefore: "private struct NetworkActivityLogRow: View"
        )
        let domainBlock = try sourceBlock(
            in: domainSource,
            startingAt: "struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        XCTAssertTrue(localLogSupport.contains("enum LocalLogPagination"))
        XCTAssertTrue(networkBlock.contains("@State private var visibleEntryCount"))
        XCTAssertTrue(networkBlock.contains(".prefix(visibleEntryCount)"))
        XCTAssertTrue(networkBlock.contains("LocalLogLoadMoreSentinel"))
        XCTAssertTrue(domainBlock.contains("@State private var visibleEventCount"))
        XCTAssertTrue(domainBlock.contains(".prefix(visibleEventCount)"))
        XCTAssertTrue(domainBlock.contains("limit: visibleEventCount + 1"))
        XCTAssertTrue(domainBlock.contains("hasMore: events.count > visibleEvents.count"))
        XCTAssertFalse(domainBlock.contains("limit: Int.max"))
        XCTAssertTrue(domainBlock.contains("LocalLogLoadMoreSentinel"))
        XCTAssertTrue(domainBlock.contains(".onChange(of: selectedFilter)"))
        XCTAssertTrue(domainBlock.contains(".onChange(of: searchText)"))
        XCTAssertTrue(localLogSupport.contains("loadMoreIfNeeded(sentinelMinY:"))
        XCTAssertTrue(localLogSupport.contains("UIScreen.main.bounds.height + 80"))
    }

    func testDomainHistoryRowsUseSharedTimestampLine() throws {
        let source = try readSource(.diagnosticsDomainHistory)
        let rowBlock = try sourceBlock(
            in: source,
            startingAt: "private struct DomainHistoryRow: View"
        )

        XCTAssertTrue(rowBlock.contains("event.timestampLine"))
        XCTAssertFalse(rowBlock.contains("formatted(date: .omitted, time: .shortened)"))
    }

    func testNetworkActivityPullRefreshAlwaysAllowsBounce() throws {
        let rootSource = try readSource(.lavaScaffold)
        let screenContentBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct LavaScreenContent<Content: View>: View",
            endingBefore: "struct LavaSheetScaffold"
        )
        let diagnosticsSource = try readSource(.diagnosticsNetworkActivity)
        let networkBlock = try sourceBlock(
            in: diagnosticsSource,
            startingAt: "struct NetworkActivityLogView: View",
            endingBefore: "private struct NetworkActivityLogRow: View"
        )

        XCTAssertTrue(screenContentBlock.contains(".scrollBounceBehavior(.always, axes: .vertical)"))
        XCTAssertTrue(screenContentBlock.contains(".refreshable {"))
        XCTAssertTrue(networkBlock.contains("refreshAction: {"))
        XCTAssertTrue(networkBlock.contains("viewModel.refreshNetworkActivityLog(force: true)"))
        XCTAssertFalse(networkBlock.contains("refreshCopy:"))
    }

    func testScrollablePullRefreshDoesNotInstallCompetingDragRecognizer() throws {
        let rootSource = try readSource(.lavaScaffold)
        let screenContentBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct LavaScreenContent<Content: View>: View",
            endingBefore: "struct LavaSheetScaffold"
        )

        XCTAssertTrue(screenContentBlock.contains(".refreshable {"))
        XCTAssertTrue(screenContentBlock.contains("await refreshAction()"))
        XCTAssertFalse(rootSource.contains("LavaPullRefreshScrollView"))
        XCTAssertFalse(rootSource.contains("LavaFixedPullRefreshSurface"))
        XCTAssertFalse(rootSource.contains("completePullGestureIfReleased"))
        XCTAssertFalse(rootSource.contains(".simultaneousGesture("))
        XCTAssertFalse(rootSource.contains("DragGesture(minimumDistance: 8)"))
    }

    func testDomainHistoryRowsExposeContextMenuDomainActions() throws {
        let source = try readSource(.diagnosticsDomainHistory)
        let domainBlock = try sourceBlock(
            in: source,
            startingAt: "struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )
        let rowBlock = try sourceBlock(
            in: source,
            startingAt: "private struct DomainHistoryRow: View"
        )

        XCTAssertTrue(domainBlock.contains("activeReviewSheet = .domainHistory"))
        XCTAssertTrue(domainBlock.contains("viewModel.stageDomainHistoryDomainAction"))
        XCTAssertTrue(rowBlock.contains(".contextMenu"))
        XCTAssertTrue(rowBlock.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(rowBlock.contains("Label(\"Copy\""))
        XCTAssertTrue(rowBlock.contains("UIPasteboard.general.string = event.domain"))
        XCTAssertTrue(rowBlock.contains("Label(\"Block\""))
        XCTAssertTrue(rowBlock.contains("Label(\"Allow\""))

        let copyRange = try XCTUnwrap(rowBlock.range(of: "Label(\"Copy\""))
        let blockedRange = try XCTUnwrap(rowBlock.range(of: "Label(\"Block\""))
        let allowedRange = try XCTUnwrap(rowBlock.range(of: "Label(\"Allow\""))
        XCTAssertLessThan(copyRange.lowerBound, blockedRange.lowerBound)
        XCTAssertLessThan(copyRange.lowerBound, allowedRange.lowerBound)
    }

    func testDomainHistoryUsesSharedFilterReviewAndPreparationScreens() throws {
        let diagnosticsSource = try readSource(.diagnosticsDomainHistory)
        let filtersSource = try readSource(.filterMyListView)
        let filtersShellSource = try readSource(.filtersView)
        let sharedReviewSource = try readSource(.filterReviewFlowView)
        let domainBlock = try sourceBlock(
            in: diagnosticsSource,
            startingAt: "struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        XCTAssertTrue(domainBlock.contains("FilterConfirmationSheet(origin: .domainHistory"))
        XCTAssertTrue(domainBlock.contains("FilterPreparationScreen(origin: .domainHistory"))
        XCTAssertTrue(filtersSource.contains("FilterConfirmationSheet(origin: .filters"))
        XCTAssertTrue(filtersShellSource.contains("FilterPreparationScreen(origin: .filters"))
        XCTAssertTrue(sharedReviewSource.contains("enum FilterReviewOrigin"))
        XCTAssertTrue(sharedReviewSource.contains("case domainHistory"))
        XCTAssertTrue(sharedReviewSource.contains("Back to Review"))
    }

    func testNetworkActivityRecordsFilterConfigurationChanges() throws {
        let appViewModelSource = try readSource(.appViewModel)
        let applyDraftBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "func prepareAndApplyFilterDraft(",
            endingBefore: "private static func filterPreparationFailureMessage"
        )
        let persistFilterChangesBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "private func persistFilterChanges()",
            endingBefore: "private func loadPersistedConfiguration"
        )

        XCTAssertTrue(appViewModelSource.contains("appendAppNetworkActivity(.changeFilters)"))
        XCTAssertTrue(applyDraftBlock.contains("appendAppNetworkActivity(.changeFilters)"))
        XCTAssertTrue(persistFilterChangesBlock.contains("appendAppNetworkActivity(.changeFilters)"))
    }

    func testNetworkActivityThemeHandlesConnectedLifecycleEvent() throws {
        let source = try readSource(.diagnosticsNetworkActivity)
        let themeBlock = try sourceBlock(
            in: source,
            startingAt: "private extension NetworkActivityEvent"
        )

        XCTAssertTrue(themeBlock.contains("case .protectionConnected:"))
        XCTAssertTrue(themeBlock.contains("case .networkSettingsReapplyFailed:"))
    }
}
