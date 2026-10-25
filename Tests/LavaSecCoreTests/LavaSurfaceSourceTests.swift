import XCTest

final class LavaSurfaceSourceTests: XCTestCase {
    func testUnusedDesignScaffoldsStayRemoved() throws {
        XCTAssertFalse(try readSource(.lavaScaffold).contains("struct LavaTabScreenContent"))
        XCTAssertFalse(try readSource(.lavaComponents).contains("struct LavaMetricPill"))
    }

    func testSharedSurfaceScaffoldDefinesCardPanelAndSelectionTokens() throws {
        let rootSource = try readSource(.lavaTokens)
        let viewExtensionBlock = try sourceBlock(
            in: rootSource,
            startingAt: "extension View"
        )

        XCTAssertTrue(rootSource.contains("enum LavaSurface"))
        XCTAssertTrue(rootSource.contains("struct LavaSurfaceBackground"))
        XCTAssertTrue(rootSource.contains("static let cardCornerRadius: CGFloat = 24"))
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
        let rootSource = try readSource(.lavaScaffold)
        let plainCardBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct LavaPlainCard<Content: View>: View",
            endingBefore: "struct LavaSuccessGlyph: View"
        )
        let listSource = try readSource(.lavaCondensedList)
        let condensedListBlock = try sourceBlock(
            in: listSource,
            startingAt: "struct LavaCondensedList<Content: View>: View",
            endingBefore: "struct LavaCondensedDivider: View"
        )

        XCTAssertTrue(plainCardBlock.contains(".lavaSurface(.card, borderTint: borderTint)"))
        XCTAssertTrue(condensedListBlock.contains("surface: LavaSurface.Role = .card"))
        XCTAssertTrue(condensedListBlock.contains(".lavaSurface(surface)"))
        XCTAssertFalse(plainCardBlock.contains("secondarySystemGroupedBackground"))
        XCTAssertFalse(condensedListBlock.contains("secondarySystemGroupedBackground"))
        XCTAssertFalse(condensedListBlock.contains("cornerRadius: 18"))
    }

    func testSearchFieldsUsePanelSurfaceToken() throws {
        let diagnosticsSource = try readSource(.diagnosticsLocalLogSupport)
        let localLogSearchBlock = try sourceBlock(
            in: diagnosticsSource,
            startingAt: "struct LocalLogSearchField: View",
            endingBefore: "extension FilterDecisionReason"
        )
        XCTAssertTrue(localLogSearchBlock.contains(".lavaSurface(.panel, cornerRadius:"))

    }
}
