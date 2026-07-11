import XCTest

final class LavaSurfaceSourceTests: XCTestCase {
    func testUnusedDesignScaffoldsStayRemoved() throws {
        XCTAssertFalse(try readSource(.lavaScaffold).contains("struct LavaTabScreenContent"))
        XCTAssertFalse(try readSource(.lavaComponents).contains("struct LavaMetricPill"))
        XCTAssertFalse(try readSource(.lavaIcon).contains("struct LavaIcon: View"))
    }

    func testSharedSurfaceScaffoldDefinesCardPanelAndSelectionTokens() throws {
        let rootSource = try readSource(.lavaTokens)
        let viewExtensionBlock = try sourceBlock(
            in: rootSource,
            startingAt: "extension View"
        )

        XCTAssertTrue(rootSource.contains("enum LavaSurface"))
        XCTAssertTrue(rootSource.contains("struct LavaSurfaceBackground"))
        XCTAssertTrue(rootSource.contains("static let cardCornerRadius: CGFloat = 20"))
        XCTAssertTrue(rootSource.contains("static let compactCornerRadius: CGFloat = 16"))
        XCTAssertTrue(rootSource.contains("static let selectionCornerRadius: CGFloat = 12"))
        XCTAssertTrue(rootSource.contains("static let cardBackground = LavaStyle.cardBackground"))
        XCTAssertTrue(rootSource.contains("static let cardBackground = adaptiveColor("))
        XCTAssertFalse(rootSource.contains("static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)"))
        XCTAssertTrue(rootSource.contains("static let selectedSelectionBackground = LavaStyle.softGreen"))
        XCTAssertTrue(viewExtensionBlock.contains("func lavaSurface("))
        XCTAssertTrue(viewExtensionBlock.contains("func lavaPanelBackground("))
        XCTAssertTrue(viewExtensionBlock.contains("lavaSurface(.panel"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(rootSource.contains("cardBackground"))
    }

    func testFormAndListScaffoldsUseCardSurfaceToken() throws {
        let rootSource = try readSource(.lavaComponents)
        let plainCardBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct LavaPlainCard<Content: View>: View",
            endingBefore: "struct LavaTextInputPanel<Content: View>: View"
        )
        let listSource = try readSource(.lavaCondensedList)
        let condensedListBlock = try sourceBlock(
            in: listSource,
            startingAt: "struct LavaCondensedList<Content: View>: View",
            endingBefore: "struct LavaCondensedDivider: View"
        )

        XCTAssertTrue(plainCardBlock.contains(".lavaSurface(.card)"))
        XCTAssertTrue(condensedListBlock.contains(".lavaSurface(.card)"))
        XCTAssertFalse(plainCardBlock.contains("secondarySystemGroupedBackground"))
        XCTAssertFalse(condensedListBlock.contains("secondarySystemGroupedBackground"))
        XCTAssertFalse(condensedListBlock.contains("cornerRadius: 18"))
    }

    func testSelectionControlsUseSelectionSurfaceToken() throws {
        let diagnosticsSource = try readSource(.diagnosticsDateControls)
        let endpointButtonBlock = try sourceBlock(
            in: diagnosticsSource,
            startingAt: "private struct ActivityDateEndpointButton",
            endingBefore: "private struct ActivityDateTodayButton"
        )
        let settingsSource = try readSource(.bugReportSettingsView)
        let stepProgressBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "private struct BugReportStepProgressView: View",
            endingBefore: "private struct BugReportPreviewSectionCard: View"
        )

        XCTAssertTrue(endpointButtonBlock.contains(".lavaSurface(.selection(isSelected: isActive))"))
        XCTAssertTrue(stepProgressBlock.contains(".lavaSurface(.selection(isSelected: step == currentStep))"))
        XCTAssertFalse(endpointButtonBlock.contains("secondarySystemGroupedBackground"))
        XCTAssertFalse(stepProgressBlock.contains("secondarySystemGroupedBackground"))
    }

    func testDomainHistorySelectionRowsInheritCondensedListSurface() throws {
        let diagnosticsSource = try readSource(.diagnosticsDomainHistory)
        let historyTypeBlock = try sourceBlock(
            in: diagnosticsSource,
            startingAt: "LavaSectionGroup(\"Show\")",
            endingBefore: "LavaSectionGroup(\n                selectedFilter.rawValue"
        )
        let listSource = try readSource(.lavaCondensedList)
        let condensedListBlock = try sourceBlock(
            in: listSource,
            startingAt: "struct LavaCondensedList<Content: View>: View",
            endingBefore: "struct LavaCondensedDivider: View"
        )

        XCTAssertTrue(historyTypeBlock.contains("LavaCondensedList"))
        XCTAssertTrue(historyTypeBlock.contains("Picker(\"History Type\", selection: $selectedFilter)"))
        XCTAssertTrue(condensedListBlock.contains(".lavaSurface(.card)"))
    }

    func testSearchFieldsUsePanelSurfaceToken() throws {
        let diagnosticsSource = try readSource(.diagnosticsLocalLogSupport)
        let localLogSearchBlock = try sourceBlock(
            in: diagnosticsSource,
            startingAt: "struct LocalLogSearchField: View",
            endingBefore: "enum DomainHistoryFilter"
        )
        let filtersSource = try readSource(.blocklistPickerView)
        let blocklistSearchBlock = try sourceBlock(
            in: filtersSource,
            startingAt: "private struct BlocklistSearchField: View",
            endingBefore: "private enum BlocklistPickerItem"
        )

        XCTAssertTrue(localLogSearchBlock.contains(".lavaSurface(.panel, cornerRadius: LavaSurface.compactCornerRadius, borderTint: LavaSurface.panelStroke.opacity(0.65))"))
        XCTAssertTrue(blocklistSearchBlock.contains(".lavaSurface(.panel, cornerRadius: LavaSurface.compactCornerRadius, borderTint: LavaSurface.panelStroke.opacity(0.65))"))
        XCTAssertFalse(localLogSearchBlock.contains(".fill(LavaStyle.panelBackground)"))
        XCTAssertFalse(blocklistSearchBlock.contains(".fill(LavaStyle.panelBackground)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(diagnosticsSource.contains("LavaStyle"))
    }
}
