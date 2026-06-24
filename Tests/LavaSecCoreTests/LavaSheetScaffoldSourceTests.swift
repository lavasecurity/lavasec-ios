import XCTest

final class LavaSheetScaffoldSourceTests: XCTestCase {
    func testSheetScaffoldUsesNativeSafeAreaBarsForFooters() throws {
        let rootSource = try Self.source(named: "LavaScaffold.swift", in: "LavaSecApp/LavaDesignSystem")
        let scaffoldBlock = try Self.sourceBlock(
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
    }

    func testSheetScaffoldGivesScrollContentNativeBarBreathingRoom() throws {
        let rootSource = try Self.source(named: "LavaScaffold.swift", in: "LavaSecApp/LavaDesignSystem")
        let scaffoldBlock = try Self.sourceBlock(
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
        let rootSource = try Self.source(named: "LavaScaffold.swift", in: "LavaSecApp/LavaDesignSystem")
        let scaffoldBlock = try Self.sourceBlock(
            in: rootSource,
            startingAt: "struct LavaSheetScaffold<Header: View, Content: View, Footer: View>: View",
            endingBefore: "extension LavaSheetScaffold where Header == EmptyView, Footer == EmptyView"
        )

        XCTAssertTrue(scaffoldBlock.contains(".presentationBackground("))
        XCTAssertTrue(scaffoldBlock.contains("sheetBackgroundStyle"))
        XCTAssertTrue(scaffoldBlock.contains("LavaStyle.groupedBackground"))
    }

    func testSheetScaffoldUnifiesTopHeaderAndNavigationMaterial() throws {
        let rootSource = try Self.source(named: "LavaScaffold.swift", in: "LavaSecApp/LavaDesignSystem")
        let scaffoldBlock = try Self.sourceBlock(
            in: rootSource,
            startingAt: "struct LavaSheetScaffold<Header: View, Content: View, Footer: View>: View",
            endingBefore: "extension LavaSheetScaffold where Header == EmptyView, Footer == EmptyView"
        )
        let headerBlock = try Self.sourceBlock(
            in: scaffoldBlock,
            startingAt: "private var headerBar: some View",
            endingBefore: "private var footerBar: some View"
        )
        let toolbarModifierBlock = try Self.sourceBlock(
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
            try Self.source(named: "BackupRestoreView.swift", in: "LavaSecApp"),
            try Self.source(named: "BackupSetupView.swift", in: "LavaSecApp"),
            try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp"),
            try Self.source(named: "FilterReviewFlowView.swift", in: "LavaSecApp"),
            try Self.source(named: "FiltersView.swift", in: "LavaSecApp"),
            try Self.source(named: "OnboardingFlowView.swift", in: "LavaSecApp"),
            try Self.source(named: "SettingsView.swift", in: "LavaSecApp"),
            try Self.source(named: "ShareableFiltersUI.swift", in: "LavaSecApp")
        ].joined(separator: "\n")

        XCTAssertEqual(
            appSources.occurrences(of: "LavaSheetScaffold(") + appSources.occurrences(of: "LavaSheetScaffold {"),
            21
        )
        XCTAssertFalse(appSources.contains("safeAreaBar(edge: .bottom"))
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

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
