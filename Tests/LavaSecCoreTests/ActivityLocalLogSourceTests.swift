import XCTest

final class ActivityLocalLogSourceTests: XCTestCase {

    func testScrollablePullRefreshDoesNotInstallCompetingDragRecognizer() throws {
        let rootSource = try readSource(.lavaScaffold)
        let screenContentBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct LavaScreenContent<Content: View>: View",
            endingBefore: "private enum LavaSheetScaffoldMetrics"
        )

        XCTAssertTrue(screenContentBlock.contains(".refreshable {"))
        XCTAssertTrue(screenContentBlock.contains("await refreshAction()"))
        XCTAssertFalse(rootSource.contains("LavaPullRefreshScrollView"))
        XCTAssertFalse(rootSource.contains("LavaFixedPullRefreshSurface"))
        XCTAssertFalse(rootSource.contains("completePullGestureIfReleased"))
        // The screen's refresh owner must not compete with its ScrollView.
        // Independent action-button gestures elsewhere in this file are unrelated.
        XCTAssertFalse(screenContentBlock.contains(".simultaneousGesture("))
        XCTAssertFalse(screenContentBlock.contains("DragGesture("))
    }

    func testDomainHistoryUsesSharedFilterReviewAndPreparationScreens() throws {
        let source = try readSource(.reactNativeAppQueries)
        XCTAssertTrue(source.contains("fresh: name == \"domains.stage\""))
        XCTAssertTrue(source.contains("standaloneDomainReviews[token]"))
    }

    func testNetworkActivityRecordsFilterConfigurationChanges() throws {
        let appViewModelSource = try readAppViewModelSource()
        let applyDraftBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "func prepareAndApplyFilterDraft(",
            endingBefore: "static func filterPreparationFailureMessage"
        )
        let persistFilterChangesBlock = try sourceBlock(
            in: appViewModelSource,
            startingAt: "func persistFilterChanges()",
            endingBefore: "func loadPersistedConfiguration"
        )

        XCTAssertTrue(appViewModelSource.contains("appendAppNetworkActivity(.changeFilters)"))
        XCTAssertTrue(applyDraftBlock.contains("appendAppNetworkActivity(.changeFilters)"))
        XCTAssertTrue(persistFilterChangesBlock.contains("appendAppNetworkActivity(.changeFilters)"))
    }

    func testNetworkActivityThemeHandlesConnectedLifecycleEvent() throws {
        let source = try readSource(.diagnosticsNetworkActivity)
        let themeBlock = try sourceBlock(
            in: source,
            startingAt: "extension NetworkActivityEvent"
        )

        XCTAssertTrue(themeBlock.contains("case .protectionConnected:"))
        XCTAssertTrue(themeBlock.contains("case .networkSettingsReapplyFailed:"))
    }
}
