import XCTest

final class LavaSurfaceSourceTests: XCTestCase {
    func testSharedSurfaceScaffoldDefinesCardPanelAndSelectionTokens() throws {
        let rootSource = try Self.source(named: "LavaTokens.swift", in: "LavaSecApp/LavaDesignSystem")
        let viewExtensionBlock = try Self.sourceBlock(
            in: rootSource,
            startingAt: "extension View",
            endingBefore: "*** end ***"
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
    }

    func testFormAndListScaffoldsUseCardSurfaceToken() throws {
        let rootSource = try Self.source(named: "LavaComponents.swift", in: "LavaSecApp/LavaDesignSystem")
        let plainCardBlock = try Self.sourceBlock(
            in: rootSource,
            startingAt: "struct LavaPlainCard<Content: View>: View",
            endingBefore: "struct LavaTextInputPanel<Content: View>: View"
        )
        let listSource = try Self.source(named: "LavaCondensedList.swift", in: "LavaSecApp")
        let condensedListBlock = try Self.sourceBlock(
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
        let diagnosticsSource = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let endpointButtonBlock = try Self.sourceBlock(
            in: diagnosticsSource,
            startingAt: "private struct ActivityDateEndpointButton",
            endingBefore: "private struct ActivityDateTodayButton"
        )
        let settingsSource = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let stepProgressBlock = try Self.sourceBlock(
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
        let diagnosticsSource = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let historyTypeBlock = try Self.sourceBlock(
            in: diagnosticsSource,
            startingAt: "LavaSectionGroup(\"Show\")",
            endingBefore: "LavaSectionGroup(\n                selectedFilter.rawValue"
        )
        let listSource = try Self.source(named: "LavaCondensedList.swift", in: "LavaSecApp")
        let condensedListBlock = try Self.sourceBlock(
            in: listSource,
            startingAt: "struct LavaCondensedList<Content: View>: View",
            endingBefore: "struct LavaCondensedDivider: View"
        )

        XCTAssertTrue(historyTypeBlock.contains("LavaCondensedList"))
        XCTAssertTrue(historyTypeBlock.contains("Picker(\"History Type\", selection: $selectedFilter)"))
        XCTAssertTrue(condensedListBlock.contains(".lavaSurface(.card)"))
    }

    func testSearchFieldsUsePanelSurfaceToken() throws {
        let diagnosticsSource = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        let localLogSearchBlock = try Self.sourceBlock(
            in: diagnosticsSource,
            startingAt: "private struct LocalLogSearchField: View",
            endingBefore: "struct NetworkActivityLogView: View"
        )
        let filtersSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let blocklistSearchBlock = try Self.sourceBlock(
            in: filtersSource,
            startingAt: "private struct BlocklistSearchField: View",
            endingBefore: "private enum BlocklistPickerItem"
        )

        XCTAssertTrue(localLogSearchBlock.contains(".lavaSurface(.panel, cornerRadius: LavaSurface.compactCornerRadius, borderTint: LavaSurface.panelStroke.opacity(0.65))"))
        XCTAssertTrue(blocklistSearchBlock.contains(".lavaSurface(.panel, cornerRadius: LavaSurface.compactCornerRadius, borderTint: LavaSurface.panelStroke.opacity(0.65))"))
        XCTAssertFalse(localLogSearchBlock.contains(".fill(LavaStyle.panelBackground)"))
        XCTAssertFalse(blocklistSearchBlock.contains(".fill(LavaStyle.panelBackground)"))
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
