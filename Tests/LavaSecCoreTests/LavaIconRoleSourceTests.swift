import XCTest

/// Phase 2: the LavaIcon role layer + shared-component migration. Locks the iOS
/// resolution table to today's SF Symbols (visual no-op) and guards that the shared
/// components name roles, not Apple glyph strings.
final class LavaIconRoleSourceTests: XCTestCase {
    func testIconRoleTableResolvesToCurrentGlyphs() throws {
        let icon = try readSource(.lavaIcon)
        XCTAssertTrue(icon.contains("var sfSymbolName: String"))
        // Tab roles must still resolve to today's symbols.
        for (role, symbol) in [("guardShield", "shield.fill"),
                               ("filters", "line.3.horizontal.decrease.circle"),
                               ("activity", "chart.bar.xaxis"),
                               ("settings", "gearshape")] {
            XCTAssertTrue(icon.contains("case .\(role):"), "missing role .\(role)")
            XCTAssertTrue(icon.contains("\"\(symbol)\""), "missing symbol \(symbol)")
        }
    }

    func testRankingDestinationUsesTheSharedOrderedBarGlyph() throws {
        let icon = try readSource(.lavaIcon)
        let tokens = try readSource(.lavaTokens)
        let components = try readSource(.lavaComponents)
        let activity = try readSource(.reactNativeActivityScreen)
        XCTAssertTrue(icon.components(separatedBy: .whitespacesAndNewlines).joined().contains("case.ranking:LavaGlyphSymbol.ranking"))
        XCTAssertTrue(tokens.contains("static let ranking = \"lava.ranking\""))
        XCTAssertTrue(tokens.contains("struct LavaRankingGlyph: Shape"))
        XCTAssertTrue(components.contains("if systemImage == LavaGlyphSymbol.ranking"))
        XCTAssertTrue(components.contains("LavaRankingGlyph().fill(tint)"))
        XCTAssertTrue(activity.contains("ranking"))
    }

    func testRootAndSettingsNavigationUseRNTabs() throws {
        let root = try readSource(.rootView)
        let navigation = try readSource(.reactNativeReviewNavigation)
        XCTAssertFalse(root.contains("TabView(selection: guardedRootTabSelection)"))
        XCTAssertTrue(navigation.contains("<Tabs.Screen name=\"GuardTab\""))
        XCTAssertTrue(navigation.contains("<Tabs.Screen name=\"SettingsTab\""))
    }
}
