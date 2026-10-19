import XCTest

/// Guardrails for the Larger-Text (Dynamic Type) reflow pass — visual-accessibility plan / Task 2.
///
/// Launch-critical text must **reflow** (wrap / grow via `minHeight`) at large accessibility
/// sizes instead of truncating to one line (`.lineLimit(1)`), shrinking (`minimumScaleFactor`),
/// or being pinned to a fixed `.frame(height:)`. These assertions pin *presence of the reflow
/// shape* as text — the rendered largest-text behavior is a device/simulator gate (Task 6). They
/// are the size-axis analog of `AccessibilityReducedMotionSourceTests` and
/// `ColorContrastSourceTests`.
///
/// Two metric-tile families are an intentional **safe partial** (Rule 3 of the pass): the compact
/// stat chips and the horizontal label:value row keep `minimumScaleFactor` as a gentle fallback and
/// only relax `.lineLimit(1)` → `.lineLimit(2)` plus fixed `height:` → `minHeight:`, rather than a
/// full wrap redesign — so a hero numeral never wraps to an unbounded column.
final class AccessibilityLargeTextSourceTests: XCTestCase {

    /// Whitespace-insensitive view of a source file, for asserting on adjacent-modifier chains
    /// without pinning exact indentation.
    private func compactSource(_ file: SourceFile) throws -> String {
        try readSource(file).filter { !$0.isWhitespace }
    }

    // MARK: Guard

    // MARK: Onboarding

    func testUpgradeBenefitsReflowWithTextScaleAndIntrinsicPageHeight() throws {
        let scene = try sourceBlock(
            in: readSource(.reactNativePlusScaffold),
            startingAt: "function BenefitScene(",
            endingBefore: "function RoutineCard("
        )
        XCTAssertTrue(scene.contains("useAccessibilityTextScale()"))
        XCTAssertTrue(scene.contains("landscape&&usable/scale>="),
                      "Large text must reject the paired art/copy layout when its scaled reading width cannot fit.")
        XCTAssertTrue(scene.contains("s.pairedPart"))
        XCTAssertFalse(scene.contains("numberOfLines"))
        XCTAssertFalse(scene.contains("adjustsFontSizeToFit"))

        let pages = try readSource(.reactNativePagingScaffold)
        XCTAssertTrue(pages.contains("alignItems:'stretch'"))
        XCTAssertTrue(pages.contains("alignSelf:'stretch'"))
        XCTAssertFalse(pages.contains("height:"),
                       "The tallest intrinsic benefit page must determine the carousel height at larger text sizes.")
    }

    // MARK: Backup

    func testBackupTitlesUseTheSharedFullSheetHeaderPolicy() throws {
        let source = try readSource(.reactNativeAccountBackupAdapter)
        XCTAssertTrue(source.contains("...nativeInlineHeader"))
        XCTAssertTrue(source.contains("title:state.title"))
        XCTAssertTrue(source.contains("toolbarAction('Back','back'"))
        XCTAssertTrue(source.contains("toolbarAction('Close','close'"))
    }

    func testOverviewBannerRowGrowsViaMinHeight() throws {
        let compact = try compactSource(.lavaComponents)

        // Banner row grows via minHeight instead of pinning the fixed row height.
        XCTAssertTrue(compact.contains(".frame(minHeight:rowHeight)"),
                      "LavaOverviewBannerRow must grow via minHeight.")
        XCTAssertFalse(compact.contains(".frame(height:rowHeight)"),
                       "LavaOverviewBannerRow must not pin a fixed row height.")
    }
}
