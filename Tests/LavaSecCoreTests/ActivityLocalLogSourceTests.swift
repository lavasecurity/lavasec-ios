import XCTest

final class ActivityLocalLogSourceTests: XCTestCase {
    func testNetworkActivityUsesLargeNavigationTitleLikeDomainHistory() throws {
        let source = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let networkBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct NetworkActivityLogView: View",
            endingBefore: "private struct NetworkActivityLogRow: View"
        )

        XCTAssertFalse(networkBlock.contains("LavaScreenContent(\n            title: \"Network Activity\""))
        XCTAssertTrue(source.contains("private struct LocalLogSubpageChrome"))
        XCTAssertTrue(networkBlock.contains(".localLogSubpageChrome("))
        XCTAssertTrue(networkBlock.contains("title: \"Network Activity\""))
    }

    func testDomainHistoryAndNetworkActivityExposeTopRightClearActions() throws {
        let source = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let chromeBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct LocalLogSubpageChrome",
            endingBefore: "private struct NetworkActivityLogView: View"
        )
        let networkBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct NetworkActivityLogView: View",
            endingBefore: "private struct NetworkActivityLogRow: View"
        )
        let domainBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        XCTAssertTrue(chromeBlock.contains("ToolbarItem(placement: .primaryAction)"))
        XCTAssertTrue(chromeBlock.contains("NativeToolbarIconButton(systemName: \"trash\", accessibilityLabel: \"Clear\", action: clear)"))
        XCTAssertFalse(chromeBlock.contains("LavaToolbarIconButton("))
        XCTAssertFalse(chromeBlock.contains("Button(\"Clear\""))
        XCTAssertTrue(chromeBlock.contains(".navigationBarTitleDisplayMode(.large)"))
        XCTAssertFalse(chromeBlock.contains(".navigationBarTitleDisplayMode(.inline)"))
        XCTAssertTrue(networkBlock.contains("showingClearActivityConfirmation"))
        XCTAssertTrue(networkBlock.contains("viewModel.clearNetworkActivityLog()"))
        XCTAssertTrue(domainBlock.contains("showingClearHistoryConfirmation"))
        XCTAssertTrue(domainBlock.contains("viewModel.clearDomainHistory()"))
    }

    func testDomainHistoryDoesNotKeepBottomManageClearSection() throws {
        let source = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let domainBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        XCTAssertFalse(domainBlock.contains("LavaSectionGroup(\"Manage\")"))
        XCTAssertFalse(domainBlock.contains("title: \"Clear local domain history\""))
    }

    func testDomainHistorySearchLivesInContentInsteadOfNavigationDrawer() throws {
        let source = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let domainBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        XCTAssertTrue(source.contains("private struct LocalLogSearchField"))
        XCTAssertTrue(domainBlock.contains("LocalLogSearchField(text: $searchText)"))
        XCTAssertFalse(domainBlock.contains(".searchable("))
    }

    func testDomainHistoryDoesNotShowLongPressHintFinePrint() throws {
        let source = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let domainBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        let historyTypeSection = try Self.sourceBlock(
            in: domainBlock,
            startingAt: "LavaSectionGroup(\"History Type\")",
            endingBefore: "LavaSectionGroup(\n                selectedFilter.rawValue"
        )

        XCTAssertFalse(domainBlock.contains("Long-press domain to add to allowed/blocked domains"))
        XCTAssertFalse(historyTypeSection.contains("Long-press domain to add to allowed/blocked domains"))
    }

    func testDomainHistoryEmptyRowsAvoidTerminalPeriods() throws {
        let source = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let domainFilterBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private enum DomainHistoryFilter",
            endingBefore: "private struct DomainHistoryDomainActionAlert"
        )
        let domainBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct DomainHistoryView: View",
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
        let source = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let networkBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct NetworkActivityLogView: View",
            endingBefore: "private struct NetworkActivityLogRow: View"
        )
        let domainBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        XCTAssertTrue(source.contains("private enum LocalLogPagination"))
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
        XCTAssertTrue(source.contains("loadMoreIfNeeded(sentinelMinY:"))
        XCTAssertTrue(source.contains("UIScreen.main.bounds.height + 80"))
    }

    func testDomainHistoryRowsUseSharedTimestampLine() throws {
        let source = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let rowBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct DomainHistoryRow: View",
            endingBefore: "*** end ***"
        )

        XCTAssertTrue(rowBlock.contains("event.timestampLine"))
        XCTAssertFalse(rowBlock.contains("formatted(date: .omitted, time: .shortened)"))
    }

    func testNetworkActivityPullRefreshAlwaysAllowsBounce() throws {
        let rootSource = try Self.source(named: "RootView.swift", in: "LavaSecApp")
        let screenContentBlock = try Self.sourceBlock(
            in: rootSource,
            startingAt: "struct LavaScreenContent<Content: View>: View",
            endingBefore: "struct LavaSheetScaffold"
        )
        let diagnosticsSource = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let networkBlock = try Self.sourceBlock(
            in: diagnosticsSource,
            startingAt: "private struct NetworkActivityLogView: View",
            endingBefore: "private struct ActivityDateScopeButton"
        )

        XCTAssertTrue(screenContentBlock.contains(".scrollBounceBehavior(.always, axes: .vertical)"))
        XCTAssertTrue(screenContentBlock.contains(".refreshable {"))
        XCTAssertTrue(networkBlock.contains("refreshAction: {"))
        XCTAssertTrue(networkBlock.contains("viewModel.refreshNetworkActivityLog(force: true)"))
        XCTAssertFalse(networkBlock.contains("refreshCopy:"))
    }

    func testScrollablePullRefreshDoesNotInstallCompetingDragRecognizer() throws {
        let rootSource = try Self.source(named: "RootView.swift", in: "LavaSecApp")
        let screenContentBlock = try Self.sourceBlock(
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
        let source = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let domainBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )
        let rowBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private struct DomainHistoryRow: View",
            endingBefore: "*** end ***"
        )

        XCTAssertTrue(domainBlock.contains("activeReviewSheet = .domainHistory"))
        XCTAssertTrue(domainBlock.contains("viewModel.stageDomainHistoryDomainAction"))
        XCTAssertTrue(rowBlock.contains(".contextMenu"))
        XCTAssertTrue(rowBlock.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(rowBlock.contains("Copy Domain"))
        XCTAssertTrue(rowBlock.contains("UIPasteboard.general.string = event.domain"))
        XCTAssertTrue(rowBlock.contains("Add to Blocked Domains"))
        XCTAssertTrue(rowBlock.contains("Add to Allowed Domains"))

        let copyRange = try XCTUnwrap(rowBlock.range(of: "Copy Domain"))
        let blockedRange = try XCTUnwrap(rowBlock.range(of: "Add to Blocked Domains"))
        let allowedRange = try XCTUnwrap(rowBlock.range(of: "Add to Allowed Domains"))
        XCTAssertLessThan(copyRange.lowerBound, blockedRange.lowerBound)
        XCTAssertLessThan(copyRange.lowerBound, allowedRange.lowerBound)
    }

    func testDomainHistoryUsesSharedFilterReviewAndPreparationScreens() throws {
        let diagnosticsSource = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let filtersSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let sharedReviewSource = try Self.source(named: "FilterReviewFlowView.swift", in: "LavaSecApp")
        let domainBlock = try Self.sourceBlock(
            in: diagnosticsSource,
            startingAt: "private struct DomainHistoryView: View",
            endingBefore: "private struct DomainHistoryRow: View"
        )

        XCTAssertTrue(domainBlock.contains("FilterConfirmationSheet(origin: .domainHistory"))
        XCTAssertTrue(domainBlock.contains("FilterPreparationScreen(origin: .domainHistory"))
        XCTAssertTrue(filtersSource.contains("FilterConfirmationSheet(origin: .filters"))
        XCTAssertTrue(filtersSource.contains("FilterPreparationScreen(origin: .filters"))
        XCTAssertTrue(sharedReviewSource.contains("enum FilterReviewOrigin"))
        XCTAssertTrue(sharedReviewSource.contains("case domainHistory"))
        XCTAssertTrue(sharedReviewSource.contains("Back to Review"))
    }

    func testNetworkActivityRecordsFilterConfigurationChanges() throws {
        let appViewModelSource = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let applyDraftBlock = try Self.sourceBlock(
            in: appViewModelSource,
            startingAt: "func prepareAndApplyFilterDraft() async",
            endingBefore: "private static func filterPreparationFailureMessage"
        )
        let persistFilterChangesBlock = try Self.sourceBlock(
            in: appViewModelSource,
            startingAt: "private func persistFilterChanges()",
            endingBefore: "private func loadPersistedConfiguration"
        )

        XCTAssertTrue(appViewModelSource.contains("appendAppNetworkActivity(.changeFilters)"))
        XCTAssertTrue(applyDraftBlock.contains("appendAppNetworkActivity(.changeFilters)"))
        XCTAssertTrue(persistFilterChangesBlock.contains("appendAppNetworkActivity(.changeFilters)"))
    }

    func testNetworkActivityThemeHandlesConnectedLifecycleEvent() throws {
        let source = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let themeBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private extension NetworkActivityEvent",
            endingBefore: "private struct ActivityDateRange"
        )

        XCTAssertTrue(themeBlock.contains("case .protectionConnected:"))
        XCTAssertTrue(themeBlock.contains("case .networkSettingsReapplyFailed:"))
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
