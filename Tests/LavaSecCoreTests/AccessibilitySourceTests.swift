import XCTest

/// Source guardrails for the shared design-system accessibility retrofit — the WS-F foundation of the
/// iOS assistive-navigation accessibility plan. These pin the accessibility modifiers AS TEXT because
/// the app target sits outside the SPM test target (same regime as the other `*SourceTests`). They
/// assert presence/structure only; runtime VoiceOver focus order and spoken output are covered by the
/// plan's device-QA gates, not here.
final class AccessibilitySourceTests: XCTestCase {

    // MARK: LavaComponents — compact metric/detail blocks read as one VoiceOver element

    func testMetricPillCombinesValueAndLabel() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaComponents),
            startingAt: "struct LavaMetricPill",
            endingBefore: "struct LavaInfoCard"
        )
        XCTAssertTrue(
            block.contains(".accessibilityElement(children: .combine)"),
            "LavaMetricPill must group its value + title into a single VoiceOver element."
        )
    }

    func testOverviewMetricBlockCombinesValueAndLabel() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaComponents),
            startingAt: "struct LavaOverviewMetricBlock",
            endingBefore: "struct LavaOverviewBannerRow"
        )
        XCTAssertTrue(
            block.contains(".accessibilityElement(children: .combine)"),
            "LavaOverviewMetricBlock must group its value + label into a single VoiceOver element."
        )
    }

    func testDetailRowHidesIconAndCombines() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaComponents),
            startingAt: "struct LavaDetailRow",
            endingBefore: "struct LavaMetricPill"
        )
        XCTAssertTrue(
            block.contains(".accessibilityHidden(true)"),
            "LavaDetailRow's decorative leading glyph must be hidden from accessibility."
        )
        XCTAssertTrue(
            block.contains(".accessibilityElement(children: .combine)"),
            "LavaDetailRow must read its title + subtitle as a single VoiceOver element."
        )
    }

    // MARK: LavaNavigationRow — decorative glyphs hidden; the NavigationLink keeps its own label

    func testNavigationRowHidesDecorativeGlyphs() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaComponents),
            startingAt: "struct LavaNavigationRow",
            endingBefore: "private struct LavaNavigationRowButtonStyle"
        )
        let hiddenCount = block.components(separatedBy: ".accessibilityHidden(true)").count - 1
        XCTAssertGreaterThanOrEqual(
            hiddenCount, 2,
            "LavaNavigationRow must hide both its leading icon badge and its trailing chevron from accessibility."
        )
        XCTAssertFalse(
            block.contains(".accessibilityElement(children: .combine)"),
            "LavaNavigationRow must NOT .combine — it wraps a NavigationLink whose interactive label would be collapsed."
        )
    }

    // MARK: LavaScaffold — shared section/screen titles expose VoiceOver headers

    func testSectionGroupTitleIsHeader() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaScaffold),
            startingAt: "struct LavaSectionGroup",
            endingBefore: "enum LavaToolbarMetrics"
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isHeader)"),
            "LavaSectionGroup's title must carry the VoiceOver header trait so the rotor can jump between sections."
        )
    }

    func testScreenContentTitleIsHeader() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaScaffold),
            startingAt: "private var paddedContent",
            endingBefore: "private func scrollToTop"
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isHeader)"),
            "LavaScreenContent's large title must carry the VoiceOver header trait."
        )
    }
}
