import XCTest

final class LavaSheetScaffoldSourceTests: XCTestCase {
    func testSheetScaffoldUsesNativeSafeAreaBarsForFooters() throws {
        let rootSource = try readSource(.lavaScaffold)
        let scaffoldBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct LavaSheetScaffold<Header: View, Content: View, Footer: View>: View",
            endingBefore: "extension LavaSheetScaffold where Header == EmptyView, Footer == EmptyView"
        )

        XCTAssertTrue(scaffoldBlock.contains("private var contentSurface: some View"))
        XCTAssertTrue(scaffoldBlock.contains("private var scrollSurface: some View"))
        XCTAssertTrue(scaffoldBlock.contains("private var footerBar: some View"))
        XCTAssertTrue(scaffoldBlock.contains("safeAreaBar(edge: .bottom, spacing: 0)"))
        XCTAssertTrue(scaffoldBlock.contains("safeAreaInset(edge: .bottom, spacing: 0)"))
        XCTAssertTrue(scaffoldBlock.contains("scrollEdgeEffectStyle(.soft, for: .bottom)"))
        XCTAssertTrue(scaffoldBlock.contains(".background(.regularMaterial)"))
        XCTAssertFalse(scaffoldBlock.contains("VStack(spacing: spacing) {\n                header\n                sheetContent\n                footer"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(rootSource.contains("sheetContent"))
    }

    func testSheetScaffoldGivesScrollContentNativeBarBreathingRoom() throws {
        let rootSource = try readSource(.lavaScaffold)
        let scaffoldBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct LavaSheetScaffold<Header: View, Content: View, Footer: View>: View",
            endingBefore: "extension LavaSheetScaffold where Header == EmptyView, Footer == EmptyView"
        )

        XCTAssertTrue(rootSource.contains("private enum LavaSheetScaffoldMetrics"))
        XCTAssertTrue(rootSource.contains("static let scrollTopPadding: CGFloat = 28"))
        XCTAssertTrue(rootSource.contains("static let scrollBottomPadding: CGFloat = 44"))
        XCTAssertTrue(scaffoldBlock.contains(".padding(.top, LavaSheetScaffoldMetrics.scrollTopPadding)"))
        XCTAssertTrue(scaffoldBlock.contains(".padding(.bottom, LavaSheetScaffoldMetrics.scrollBottomPadding)"))
    }

    func testSheetScaffoldKeepsIOSSixteenPresentationBackgroundFallback() throws {
        let rootSource = try readSource(.lavaScaffold)
        let scaffoldBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct LavaSheetScaffold<Header: View, Content: View, Footer: View>: View",
            endingBefore: "extension LavaSheetScaffold where Header == EmptyView, Footer == EmptyView"
        )

        XCTAssertTrue(scaffoldBlock.contains(".presentationBackground("))
        XCTAssertTrue(scaffoldBlock.contains("sheetBackgroundStyle"))
        XCTAssertTrue(scaffoldBlock.contains("LavaStyle.groupedBackground"))
    }

    func testSheetScaffoldUnifiesTopHeaderAndNavigationMaterial() throws {
        let rootSource = try readSource(.lavaScaffold)
        let scaffoldBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct LavaSheetScaffold<Header: View, Content: View, Footer: View>: View",
            endingBefore: "extension LavaSheetScaffold where Header == EmptyView, Footer == EmptyView"
        )
        let headerBlock = try sourceBlock(
            in: scaffoldBlock,
            startingAt: "private var headerBar: some View",
            endingBefore: "private var footerBar: some View"
        )
        let toolbarModifierBlock = try sourceBlock(
            in: rootSource,
            startingAt: "private struct LavaSheetNavigationToolbarBackground",
            endingBefore: "enum LavaToolbarMetrics"
        )

        XCTAssertTrue(scaffoldBlock.contains(".modifier(LavaSheetNavigationToolbarBackground(hasHeader: hasHeader))"))
        XCTAssertTrue(toolbarModifierBlock.contains("content.toolbarBackground(.hidden, for: .navigationBar)"))
        XCTAssertTrue(toolbarModifierBlock.contains("content.toolbarBackground(.regularMaterial, for: .navigationBar)"))
        XCTAssertTrue(headerBlock.contains("Rectangle()"))
        XCTAssertTrue(headerBlock.contains(".fill(.regularMaterial)"))
        XCTAssertTrue(headerBlock.contains(".ignoresSafeArea(edges: .top)"))
        XCTAssertFalse(headerBlock.contains(".background(.regularMaterial)"))
    }

    func testAllBottomSheetCallSitesUseSharedSheetScaffold() throws {
        let appSources = [
            try readSource(.backupRestoreView),
            try readSource(.backupSetupView),
            try readSource(.diagnosticsView),
            try readSource(.filterReviewFlowView),
            try readSource(.filtersView),
            try readSource(.onboardingFlowView),
            try readSource(.settingsView),
            try readSource(.shareableFiltersUI)
        ].joined(separator: "\n")

        XCTAssertEqual(
            appSources.occurrences(of: "LavaSheetScaffold(") + appSources.occurrences(of: "LavaSheetScaffold {"),
            22
        )
        XCTAssertFalse(appSources.contains("safeAreaBar(edge: .bottom"))
    }
}

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
