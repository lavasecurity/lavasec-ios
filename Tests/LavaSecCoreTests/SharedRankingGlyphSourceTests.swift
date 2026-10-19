import XCTest

/// The shared custom glyph must remain available in native and RN navigation.
final class SharedRankingGlyphSourceTests: XCTestCase {
    func testRankingDestinationUsesTheSharedOrderedBarGlyph() throws {
        let tokens = try readSource(.lavaTokens)
        let components = try readSource(.lavaComponents)
        let activity = try readSource(.reactNativeActivityScreen)
        XCTAssertTrue(tokens.contains("static let ranking = \"lava.ranking\""))
        XCTAssertTrue(tokens.contains("struct LavaRankingGlyph: Shape"))
        XCTAssertTrue(components.contains("if systemImage == LavaGlyphSymbol.ranking"))
        XCTAssertTrue(components.contains("LavaRankingGlyph().fill(tint)"))
        XCTAssertTrue(activity.contains("ranking"))
    }
}
