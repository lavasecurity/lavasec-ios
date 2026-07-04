import XCTest

/// Source guardrails for the filter import/review flow accessibility retrofit (WS-U). Same regime as the
/// other `*SourceTests`: the app target sits outside the SPM test target, so these pin the accessibility
/// modifiers AS TEXT against `FilterReviewFlowView.swift`. They assert presence/structure/ordering only;
/// runtime VoiceOver focus order and spoken output are covered by the plan's device-QA gates, not here.
final class AccessibilityFilterReviewSourceTests: XCTestCase {

    // MARK: Change row — one VoiceOver element that conveys the add/remove action + item name

    func testFilterReviewChangeRowExposesAddRemoveAction() throws {
        let block = try sourceBlock(
            in: try readSource(.filterReviewFlowView),
            startingAt: "struct FilterReviewChangeRow: View {",
            endingBefore: "struct FilterPreparationScreen: View {"
        )
        XCTAssertTrue(
            block.contains(".accessibilityElement(children: .ignore)"),
            "Each diff change row must read as a single VoiceOver element."
        )
        // The add-vs-remove action was conveyed only by the +/- glyph + tint; expose it as a stable
        // localized label so VoiceOver doesn't lose it, with the item name as the value.
        XCTAssertTrue(
            block.contains(".accessibilityLabel(Text(symbol == \"+\" ? \"Added\" : \"Removed\"))"),
            "The row must expose the add/remove action as a stable localized label."
        )
        XCTAssertTrue(
            block.contains(".accessibilityValue(Text(localizesTitle ? title.lavaLocalized : title))"),
            "The row must speak the changed item name as its accessibility value."
        )
    }

    // MARK: Preparation screen — decorative result glyphs hidden; failure heading is a header

    func testFilterPreparationScreenHidesResultGlyphsAndMarksFailureHeader() throws {
        let block = try sourceBlock(
            in: try readSource(.filterReviewFlowView),
            startingAt: "struct FilterPreparationScreen: View {",
            endingBefore: "struct PreparationTickerTitle: View {"
        )
        // Both large result glyphs (success checkmark + failure triangle) are decorative — the ticker
        // title / failure heading already speak the outcome — so both are hidden from VoiceOver.
        XCTAssertEqual(
            block.components(separatedBy: ".accessibilityHidden(true)").count - 1, 2,
            "Both the success and failure result glyphs must be hidden from accessibility."
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isHeader)"),
            "The prepare-failure heading must be announced as a VoiceOver header."
        )
        // The failure heading trait follows the first hidden result glyph (success, in the .preparing arm).
        let firstHiddenIdx = try XCTUnwrap(block.range(of: ".accessibilityHidden(true)")?.lowerBound)
        let headerIdx = try XCTUnwrap(block.range(of: ".accessibilityAddTraits(.isHeader)")?.lowerBound)
        XCTAssertLessThan(firstHiddenIdx, headerIdx, "The failure heading trait must follow the hidden result glyphs.")
    }
}
