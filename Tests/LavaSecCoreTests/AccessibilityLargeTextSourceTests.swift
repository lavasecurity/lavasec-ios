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

    func testOnboardingHeadlineReflows() throws {
        let source = try readSource(.onboardingFlowView)
        XCTAssertTrue(source.contains("LavaSetupStepLayout("))
        let heading = try sourceBlock(in: try readSource(.lavaScaffold),
                                      startingAt: "struct LavaSetupStepHeading:",
                                      endingBefore: "struct LavaSetupChoiceRow:")
        XCTAssertTrue(heading.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(heading.contains(".accessibilityAddTraits(.isHeader)"))
        XCTAssertFalse(heading.contains(".lineLimit("))
        XCTAssertFalse(heading.contains(".minimumScaleFactor("))
    }

    func testOnboardingCTAsReflow() throws {
        let source = try readSource(.onboardingFlowView)
        XCTAssertTrue(source.contains(".buttonStyle(LavaStandaloneActionButtonStyle())"))
        XCTAssertTrue(source.contains(".buttonStyle(LavaSecondaryActionButtonStyle())"))
        let primary = try sourceBlock(in: try readSource(.lavaScaffold),
                                      startingAt: "struct LavaStandaloneActionButtonStyle:",
                                      endingBefore: "struct LavaCondensedRowButtonStyle:")
        let secondary = try sourceBlock(in: try readSource(.lavaComponents),
                                        startingAt: "struct LavaSecondaryActionButtonStyle:",
                                        endingBefore: "struct LavaToggleRow:")
        for style in [primary, secondary] {
            XCTAssertTrue(style.contains("LavaFullWidthActionPrimitiveStyle("))
            XCTAssertTrue(style.contains(".makeBody(configuration: configuration)"))
            XCTAssertFalse(style.contains(".lineLimit("))
            XCTAssertFalse(style.contains(".frame(height:"))
        }
        let body = try sourceBlock(in: try readSource(.lavaScaffold),
                                   startingAt: "struct LavaFullWidthActionButtonBody<",
                                   endingBefore: "struct LavaFullWidthActionPrimitiveStyle:")
        XCTAssertTrue(body.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(body.contains(".frame(minHeight: LavaSurface.actionButtonHeight)"))
        XCTAssertFalse(body.contains(".lineLimit("))
        XCTAssertFalse(body.contains(".frame(height:"))
    }

    // MARK: Filters

    // MARK: Settings

    func testUpgradeComparisonKeepsHorizontalFixedSizeForStackedFallback() throws {
        // The comparison values row lives inside `ViewThatFits(in: .horizontal)`. Its
        // `.fixedSize(horizontal: true)` forces intrinsic width so, when the row can't fit at large
        // text, ViewThatFits rejects the horizontal candidate and picks the STACKED VStack fallback.
        // Flipping it to `horizontal: false` (with lineLimit(1) + minimumScaleFactor still on the
        // chain) would let the row compress in place and never stack — the correct large-text
        // behavior here is the stack, so keep the horizontal fixedSize.
        let valuesBlock = try sourceBlock(
            in: try readSource(.upgradeSettingsView),
            startingAt: "private func comparisonValues(free:",
            endingBefore: "private func paidValue"
        )
        XCTAssertTrue(valuesBlock.contains(".fixedSize(horizontal: true, vertical: false)"),
                      "The upgrade-comparison row must keep horizontal fixedSize so ViewThatFits picks the stacked fallback at large text.")
    }

    // MARK: Backup

    func testBackupTitlesUseTheSharedFullSheetHeaderPolicy() throws {
        // Full-size sheets share a wrapping title above their scroll content;
        // ordinary pushed navigation retains its separate native title policy.
        XCTAssertTrue(try readSource(.backupSetupView).contains("LavaTaskSheet(title: step.title"))
        XCTAssertTrue(try readSource(.backupRestoreView).contains("LavaTaskSheet(title: \"Restore Backup\""))
        let scaffold = try sourceBlock(
            in: try readSource(.lavaScaffold),
            startingAt: "struct LavaTaskSheet<",
            endingBefore: "struct LavaPrimaryTabScreenContent<"
        )
        XCTAssertTrue(scaffold.contains(".lavaFullSheetHeader(title, leading:"))
        let header = try sourceBlock(in: try readSource(.lavaScaffold),
                                     startingAt: "func lavaFullSheetHeader<",
                                     endingBefore: "func lavaFullSheetHeader(_")
        XCTAssertTrue(header.contains("navigationTitle(title.lavaLocalized)"))
        XCTAssertTrue(header.contains(".navigationBarTitleDisplayMode(.inline)"))
        XCTAssertTrue(header.contains("ToolbarItemGroup(placement: .topBarLeading)"))
        XCTAssertTrue(header.contains("ToolbarItemGroup(placement: .topBarTrailing)"))
        XCTAssertFalse(header.contains(".safeAreaInset("))
    }

    // MARK: Diagnostics

    // MARK: LavaComponents overview banner row

    func testOverviewBannerRowGrowsViaMinHeight() throws {
        let compact = try compactSource(.lavaComponents)

        // Banner row grows via minHeight instead of pinning the fixed row height.
        XCTAssertTrue(compact.contains(".frame(minHeight:rowHeight)"),
                      "LavaOverviewBannerRow must grow via minHeight.")
        XCTAssertFalse(compact.contains(".frame(height:rowHeight)"),
                       "LavaOverviewBannerRow must not pin a fixed row height.")
    }
}
