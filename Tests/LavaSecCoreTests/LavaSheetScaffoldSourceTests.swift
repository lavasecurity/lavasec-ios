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
        XCTAssertTrue(scaffoldBlock.contains(".background(LavaStyle.groupedBackground)"))
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
        XCTAssertTrue(scaffoldBlock.contains(".padding(.bottom, scrollsFooter ? 0 : LavaSheetScaffoldMetrics.scrollBottomPadding)"))
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
            endingBefore: "struct LavaToolbarIconButton"
        )

        XCTAssertTrue(scaffoldBlock.contains(".modifier(LavaSheetNavigationToolbarBackground(hasHeader: hasHeader))"))
        XCTAssertTrue(toolbarModifierBlock.contains("content.toolbarBackground(.hidden, for: .navigationBar)"))
        XCTAssertFalse(toolbarModifierBlock.contains("toolbarBackground(LavaStyle.groupedBackground"))
        XCTAssertTrue(headerBlock.contains("Rectangle()"))
        XCTAssertTrue(headerBlock.contains(".fill(.bar)"))
        XCTAssertTrue(headerBlock.contains(".ignoresSafeArea(edges: .top)"))
        XCTAssertFalse(headerBlock.contains(".background(LavaStyle.groupedBackground)"))
    }

    func testFullSheetHeaderDelegatesGeometryAndGroupingToNativeNavigation() throws {
        let scaffold = try readSource(.lavaScaffold)
        let header = try sourceBlock(in: scaffold, startingAt: "func lavaFullSheetHeader<",
                                     endingBefore: "func lavaFullSheetHeader(_")
        XCTAssertTrue(header.contains("navigationTitle(title.lavaLocalized)"))
        XCTAssertTrue(header.contains("ToolbarItemGroup(placement: .topBarLeading)"))
        XCTAssertTrue(header.contains("ToolbarItemGroup(placement: .topBarTrailing)"))
        XCTAssertFalse(header.contains(".safeAreaInset("))
        XCTAssertFalse(header.contains(".padding("))
        let task = try sourceBlock(in: scaffold, startingAt: "struct LavaTaskSheet<",
                                   endingBefore: "struct LavaSuccessScreen<")
        XCTAssertTrue(task.contains(".lavaFullSheetHeader(title, leading:"))
        XCTAssertTrue(task.contains("action: back"))
        XCTAssertTrue(task.contains("action: close"))
        XCTAssertTrue(task.contains(".disabled(actionsDisabled)"))
    }

    func testFullSheetAdoptersPreserveDismissalAndNativePushBoundaries() throws {
        let imports = try readSource(.reactNativeImportFlow)
        XCTAssertTrue(imports.contains("<FlowSheet compactHeight={compactHeight} onNaturalSize={port.measure} footer={footer}>"))
        XCTAssertTrue(imports.contains("const compactHeight=window.width>window.height"))
        XCTAssertFalse(imports.contains("useReview("))
        let flows = try readSource(.reactNativeAppFlows)
        XCTAssertTrue(flows.contains("if flow.usesReactPresentation {"))
        XCTAssertTrue(flows.contains("LavaAppForegroundContent(id: flow.id.uuidString)"))
        XCTAssertTrue(flows.contains("LavaSheetLockMask {"))
        XCTAssertTrue(try readSource(.reactNativeAppHost).contains("bridge.flow?.name == \"feedback\" && bridge.feedbackDraftIsDirty"))
        let custom = try readSource(.reactNativeCustomEntryScreen)
        XCTAssertTrue(custom.contains("toolbarAction('Close','close'"))
        XCTAssertTrue(custom.contains("type:'customEntry.dismiss',id:token"))
        XCTAssertTrue(custom.contains("nav.goBack()"))
    }
}
