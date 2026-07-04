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

    func testGuardProtectionTitleAndHintReflow() throws {
        let source = try readSource(.guardView)

        // Primary Guard status title — full text only lives in `.accessibilityValue`, so it must
        // wrap rather than truncate/shrink.
        let titleBlock = try sourceBlock(
            in: source,
            startingAt: "Text(viewModel.protectionTitle.lavaLocalized)",
            endingBefore: "Text(viewModel.protectionSubtitle.lavaLocalized)"
        )
        XCTAssertFalse(titleBlock.contains(".lineLimit(1)"),
                       "Guard protection title must wrap at large text, not clamp to one line.")
        XCTAssertFalse(titleBlock.contains(".minimumScaleFactor("),
                       "Guard protection title must not shrink-to-fit.")

        // The only affordance hint on the primary button.
        let hintBlock = try sourceBlock(
            in: source,
            startingAt: "Text(\"Long-press for pause options\".lavaLocalized)",
            endingBefore: "}"
        )
        XCTAssertFalse(hintBlock.contains(".lineLimit(1)"),
                       "The long-press hint must wrap at large text.")
        XCTAssertFalse(hintBlock.contains(".minimumScaleFactor("),
                       "The long-press hint must not shrink-to-fit.")

        // The primary-action label grows instead of clipping to a fixed height (≥44pt hit target).
        XCTAssertTrue(source.contains(".frame(minHeight: ProtectionStatusMetrics.primaryActionHeight)"),
                      "The primary action must grow via minHeight.")
        XCTAssertFalse(source.contains(".frame(height: ProtectionStatusMetrics.primaryActionHeight)"),
                       "The primary action must not pin a fixed height.")
    }

    // MARK: Onboarding

    func testOnboardingHeadlineReflows() throws {
        let source = try readSource(.onboardingFlowView)
        let compact = try compactSource(.onboardingFlowView)

        // The headline chain runs font → foregroundStyle → frame → header trait with no
        // `.lineLimit(1)` / `.minimumScaleFactor` in between, so it wraps at large text.
        XCTAssertTrue(
            compact.contains(".font(.largeTitle.bold()).foregroundStyle(LavaStyle.ink).frame(maxWidth:.infinity,alignment:.leading).accessibilityAddTraits(.isHeader)"),
            "Onboarding page headline must wrap (no one-line clamp / shrink-to-fit)."
        )
        XCTAssertFalse(source.contains(".minimumScaleFactor(0.68)"),
                       "The 0.68 headline shrink factor must be gone.")
    }

    func testOnboardingCTAsReflow() throws {
        let source = try readSource(.onboardingFlowView)
        let compact = try compactSource(.onboardingFlowView)

        // Primary CTA: the label runs straight from `.font(.headline)` into the HStack's closing
        // brace and grows via minHeight — no truncation modifiers.
        XCTAssertTrue(
            compact.contains("Text(title.lavaLocalized).font(.headline)}.foregroundStyle(.white).frame(maxWidth:.infinity).frame(minHeight:52).background(LavaStyle.safeControlGreen"),
            "Onboarding primary CTA must wrap and grow via minHeight: 52."
        )
        // Secondary CTA: label chain has no truncation modifiers and grows via minHeight.
        XCTAssertTrue(
            compact.contains(".foregroundStyle(LavaStyle.panelActionGreen).frame(maxWidth:.infinity).frame(minHeight:52).background(LavaStyle.panelActionFill"),
            "Onboarding secondary CTA must wrap and grow via minHeight: 52."
        )

        XCTAssertEqual(source.components(separatedBy: ".frame(minHeight: 52)").count - 1, 2,
                       "Both onboarding CTAs must grow via minHeight: 52.")
        XCTAssertFalse(source.contains(".frame(height: 52)"),
                       "No onboarding CTA may pin a fixed 52pt height.")
    }

    // MARK: Filters

    func testCategoryJumpPillReflows() throws {
        let source = try readSource(.filtersView)
        // The jump-pill label must remain free of one-line truncation so it grows inside the
        // horizontal scroller at large text.
        let jumpPill = try sourceBlock(
            in: source,
            startingAt: "private struct BlocklistCategoryJumpPills",
            endingBefore: "private enum BlocklistJumpMetrics"
        )
        XCTAssertFalse(jumpPill.contains(".lineLimit(1)"),
                       "Category jump-pill label must reflow, not truncate to one line.")
        XCTAssertFalse(jumpPill.contains(".minimumScaleFactor("),
                       "Category jump-pill label must not shrink-to-fit.")
        XCTAssertFalse(jumpPill.contains(".frame(height:"),
                       "Category jump-pill must not pin a fixed height.")
    }

    // MARK: Settings

    func testUpgradeComparisonKeepsHorizontalFixedSizeForStackedFallback() throws {
        // The comparison values row lives inside `ViewThatFits(in: .horizontal)`. Its
        // `.fixedSize(horizontal: true)` forces intrinsic width so, when the row can't fit at large
        // text, ViewThatFits rejects the horizontal candidate and picks the STACKED VStack fallback.
        // Flipping it to `horizontal: false` (with lineLimit(1) + minimumScaleFactor still on the
        // chain) would let the row compress in place and never stack — the correct large-text
        // behavior here is the stack, so keep the horizontal fixedSize.
        let valuesBlock = try sourceBlock(
            in: try readSource(.settingsView),
            startingAt: "private func comparisonValues(free:",
            endingBefore: "private func paidValue"
        )
        XCTAssertTrue(valuesBlock.contains(".fixedSize(horizontal: true, vertical: false)"),
                      "The upgrade-comparison row must keep horizontal fixedSize so ViewThatFits picks the stacked fallback at large text.")
    }

    // MARK: Backup

    func testBackupTitlesReflow() throws {
        let setup = try readSource(.backupSetupView)
        let setupTitle = try sourceBlock(
            in: setup,
            startingAt: "Text(step.title.lavaLocalized)",
            endingBefore: ".accessibilityAddTraits(.isHeader)"
        )
        XCTAssertFalse(setupTitle.contains(".lineLimit(1)"),
                       "Backup setup step title must wrap at large text.")
        XCTAssertFalse(setupTitle.contains(".minimumScaleFactor("),
                       "Backup setup step title must not shrink-to-fit.")

        let restore = try readSource(.backupRestoreView)
        let restoreTitle = try sourceBlock(
            in: restore,
            startingAt: "Text(\"Restore Backup\".lavaLocalized)",
            endingBefore: ".accessibilityAddTraits(.isHeader)"
        )
        XCTAssertFalse(restoreTitle.contains(".lineLimit(1)"),
                       "Backup restore nav title must wrap at large text.")
        XCTAssertFalse(restoreTitle.contains(".minimumScaleFactor("),
                       "Backup restore nav title must not shrink-to-fit.")
    }

    // MARK: Diagnostics

    func testDiagnosticsDateSitesReflow() throws {
        let compact = try compactSource(.diagnosticsView)

        // The date-range pill is a **toolbar title accessory** (rendered inside a
        // `ToolbarItem(.topBarTrailing)` via `LavaPrimaryTabScreenContent`), so it CANNOT reflow —
        // a multi-line pill would clip or collide inside the navigation bar. Per Rule 1's carve-out
        // it intentionally stays a compact toolbar variant: one line, gentle shrink-to-fit, fixed
        // 34pt capsule height. (Reverting the Task-2 reflow here — Codex #265 P2.)
        XCTAssertTrue(compact.contains("Text(range.pillText().lavaLocalized).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.82)"),
                      "The Activity date-range pill must stay a compact one-line toolbar variant.")
        XCTAssertTrue(compact.contains(".padding(.horizontal,11).frame(height:34)"),
                      "The date-range pill must keep a fixed 34pt capsule height (toolbar accessory).")
        XCTAssertFalse(compact.contains(".padding(.horizontal,11).frame(minHeight:34)"),
                       "The date-range pill must not grow vertically inside the toolbar.")

        // The date endpoint, in contrast, lives in scrollable sheet content and DOES reflow: no
        // shrink-to-fit, and its tile grows and centers via minHeight when the value wraps.
        XCTAssertFalse(compact.contains(".minimumScaleFactor(0.72)"),
                       "The Activity date endpoint must not shrink-to-fit.")
        XCTAssertTrue(compact.contains(".frame(maxWidth:.infinity).frame(minHeight:56).lavaSurface(.selection(isSelected:isActive))"),
                      "The date endpoint tile must grow via minHeight: 56.")
    }

    func testDiagnosticsMetricRowIsSafePartial() throws {
        let compact = try compactSource(.diagnosticsView)
        // Rule 3 safe partial: the horizontal label:value row keeps its 0.7 fallback but relaxes to
        // two lines — it does NOT fully wrap (a dense stat row).
        XCTAssertTrue(compact.contains(".monospacedDigit().lineLimit(2).minimumScaleFactor(0.7)"),
                      "The Activity metric row value must relax to two lines while keeping its gentle fallback.")
        XCTAssertFalse(compact.contains(".lineLimit(1).minimumScaleFactor(0.7)"),
                       "The Activity metric row value must not stay clamped to one line.")
    }

    // MARK: LavaComponents metric tiles (Rule 3 safe partial) + banner row

    func testCompactMetricTilesGrowAndRelaxLineLimit() throws {
        let compact = try compactSource(.lavaComponents)

        // LavaMetricPill: two-line value + gentle fallback, grows via minHeight.
        XCTAssertTrue(compact.contains("Text(value).font(.headline).lineLimit(2).minimumScaleFactor(0.75)"),
                      "LavaMetricPill value must relax to two lines while keeping its fallback.")
        XCTAssertTrue(compact.contains(".frame(minHeight:54)"),
                      "LavaMetricPill must grow via minHeight: 54.")

        // LavaOverviewMetricBlock numeral + label + tile.
        XCTAssertTrue(compact.contains(".monospacedDigit().lineLimit(2).allowsTightening(true).minimumScaleFactor(0.9)"),
                      "LavaOverviewMetricBlock numeral must relax to two lines while keeping its fallback.")
        XCTAssertTrue(compact.contains(".lineLimit(2).minimumScaleFactor(0.9).multilineTextAlignment(.center)"),
                      "LavaOverviewMetricBlock label must relax to two lines while keeping its fallback.")
        XCTAssertTrue(compact.contains(".frame(minHeight:52)"),
                      "LavaOverviewMetricBlock numeral must grow via minHeight: 52.")
        XCTAssertTrue(compact.contains(".frame(minHeight:74)"),
                      "LavaOverviewMetricBlock tile must grow via minHeight: 74.")

        // The old fixed metric-tile heights must all be gone.
        XCTAssertFalse(compact.contains(".frame(height:52)"),
                       "The 52pt metric numeral height must be a minHeight now.")
        XCTAssertFalse(compact.contains(".frame(height:54)"),
                       "The 54pt metric-pill height must be a minHeight now.")
        XCTAssertFalse(compact.contains(".frame(height:74)"),
                       "The 74pt metric-tile height must be a minHeight now.")

        // Banner row grows via minHeight instead of pinning the fixed row height.
        XCTAssertTrue(compact.contains(".frame(minHeight:rowHeight)"),
                      "LavaOverviewBannerRow must grow via minHeight.")
        XCTAssertFalse(compact.contains(".frame(height:rowHeight)"),
                       "LavaOverviewBannerRow must not pin a fixed row height.")
    }
}
