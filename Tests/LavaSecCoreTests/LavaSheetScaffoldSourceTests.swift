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
        XCTAssertTrue(toolbarModifierBlock.contains("content.toolbarBackground(LavaStyle.groupedBackground, for: .navigationBar)"))
        XCTAssertTrue(headerBlock.contains("Rectangle()"))
        XCTAssertTrue(headerBlock.contains(".fill(LavaStyle.groupedBackground)"))
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
        XCTAssertTrue(try readSource(.onboardingFlowView).contains(".lavaFullSheetHeader(\"\", leading:"))
    }

    func testFullSheetAdoptersPreserveDismissalAndNativePushBoundaries() throws {
        let imports = try readSource(.shareableFiltersUI)
        for title in ["Enter a code", "Scan a QR code", "Review import", "Replace a filter"] {
            XCTAssertTrue(imports.contains(".importFullSheetHeader(\"\(title)\""))
        }
        XCTAssertTrue(imports.contains(".lavaFullSheetHeader(\"Import a filter\", close: onClose)"))
        let feedback = try readSource(.bugReportSettingsView)
        XCTAssertTrue(feedback.contains("isPresented: onDismissRequested != nil && !usesPageNavigation && !isShowingThankYou"))
        let mask = try XCTUnwrap(feedback.range(of: "LavaSheetLockMask("))
        let header = try XCTUnwrap(feedback.range(of: ".lavaFullSheetHeader(\"Feedback\""))
        XCTAssertLessThan(mask.lowerBound, header.lowerBound, "Dismissal chrome must remain outside the privacy mask.")
        let dns = try readSource(.dnsResolverSettingsView)
        XCTAssertTrue(dns.contains("accessibilityLabel: \"Close\", role: .close, action: requestCustomResolverDismiss"))
        XCTAssertTrue(dns.contains("if let onDismissRequested { onDismissRequested() }"))
        XCTAssertTrue(dns.contains("case .dismiss:\n            dismissCustomResolver()"))
        XCTAssertTrue(dns.contains(".interactiveDismissDisabled(isFullSheet && customResolverHasUnsavedDraft)"))
        XCTAssertTrue(try readSource(.reactNativeAppFlows).contains("DNSResolverSettingsView(onDismissRequested: { bridge.flow = nil })"))
        for source in [SourceFile.dnsResolverSettingsView] {
            XCTAssertTrue(try readSource(source).contains(".toolbar(.visible, for: .navigationBar)"))
        }
    }

    func testPermissionIllustrationsShareAnIntrinsicEnvelope() throws {
        let illustration = try sourceBlock(in: try readSource(.lavaScaffold),
                                            startingAt: "struct LavaSetupPermissionIllustration:")
        XCTAssertTrue(illustration.contains("enum Kind: String, CaseIterable"))
        XCTAssertTrue(illustration.contains("ZStack {"))
        XCTAssertTrue(illustration.contains("ForEach(Kind.allCases"))
        XCTAssertTrue(illustration.contains(".opacity(kind == variant ? 1 : 0)"))
        XCTAssertTrue(illustration.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(illustration.contains("LavaGuardianShieldShape()"))
        XCTAssertFalse(illustration.contains(".lineLimit("))
        XCTAssertFalse(illustration.contains(".clipped()"))
    }

    func testAllBottomSheetCallSitesUseSharedSheetScaffold() throws {
        let appSources = [
            try readSource(.backupRestoreView),
            try readSource(.backupSetupView),
            try readDiagnosticsSourceAggregate(),
            try readSource(.filterReviewFlowView),
            try readFiltersSourceAggregate(),
            try readSource(.onboardingFlowView),
            try readSettingsSourceAggregate(),
            try readSource(.shareableFiltersUI)
        ].joined(separator: "\n")

        XCTAssertEqual(
            appSources.occurrences(of: "LavaSheetScaffold(") + appSources.occurrences(of: "LavaSheetScaffold {")
                + appSources.occurrences(of: "LavaTaskSheet("),
            // Native start/end DatePickers own Activity; new-filter creation
            // now joins the shared task-sheet family instead of a bespoke Form.
            // The retired SwiftUI onboarding-account and filter-confirmation sheets
            // were the last two bespoke call sites; RN owns those routes.
            // Optional onboarding choices now live in the flow itself; the
            // separate additional-setup chooser has also been removed.
            15
        )
        XCTAssertFalse(appSources.contains("safeAreaBar(edge: .bottom"))
    }
}

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
