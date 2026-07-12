import XCTest

/// Guardrails for the Voice Control `accessibilityInputLabels` pass (plan WS-X / X3). Voice Control
/// speaks a control's accessibility label as its "tap <name>" command; where that label is long,
/// phrase-like, or *toggles with state*, we add short, stable, localized spoken alternatives.
///
/// Same regime as the sibling `*SourceTests`: the app target sits outside the SPM test target, so
/// these pin the wiring AS TEXT. Runtime Voice Control matching is a device-QA gate, not here.
final class AccessibilityVoiceControlSourceTests: XCTestCase {

    // MARK: Shared toolbar wrapper — carries input labels through, defaulting to the label

    func testToolbarIconButtonAppliesInputLabels() throws {
        let block = try sourceBlock(
            in: try readSource(.lavaScaffold),
            startingAt: "struct NativeToolbarIconButton: View {",
            endingBefore: "private struct LavaToolbarIconSymbol: View {"
        )
        XCTAssertTrue(
            block.contains("var accessibilityInputLabels: [String] = []"),
            "The toolbar icon button must accept optional Voice Control input labels."
        )
        // Additive AND alias-first: `.accessibilityInputLabels` replaces the default set, and Voice
        // Control's Show Names surfaces the FIRST entry — so aliases come first (short command is
        // surfaced) with the accessibility label appended (original "tap <label>" still matches).
        // The appended label is localized to match the localized `.accessibilityLabel`, so the
        // "tap <label>" command matches the spoken label in every locale (UR-56 l10n sweep).
        // Empty aliases collapse to just the label (identical to the system default).
        XCTAssertTrue(
            block.contains(".accessibilityInputLabels(accessibilityInputLabels + [accessibilityLabel.lavaLocalized])"),
            "The wrapper must surface aliases first, then append the localized accessibility label (additive + discoverable)."
        )
    }

    // MARK: Call sites — long / phrase-like toolbar labels get short spoken commands

    func testFiltersToolbarButtonsProvideShortSpokenCommands() throws {
        let source = try [
            readSource(.filterLibraryView),
            readSource(.filterMyListView),
        ].joined(separator: "\n")
        // The moon "Switch filters automatically" button gets the short, localized "Auto switch".
        XCTAssertTrue(
            source.contains("accessibilityInputLabels: [\"Auto switch\".lavaLocalized]"),
            "The auto-switch how-to button must expose a short 'Auto switch' Voice Control command."
        )
        // Three toolbar buttons carry explicit input labels (moon + the two 'Close edit mode' xmarks).
        XCTAssertEqual(
            source.components(separatedBy: "accessibilityInputLabels: [").count - 1, 3,
            "The moon button and both edit-mode close buttons must carry explicit Voice Control commands."
        )
    }

    // MARK: Toggling label — the copy-phrase button stays addressable after it flips to "Copied"

    func testBackupCopyPhraseButtonPinsStableSpokenCommands() throws {
        let source = try readSource(.backupSetupView)
        // Stable aliases first (surfaced), then the current visible label appended so "tap Copied"
        // still works after the label flips — the copy button must stay addressable in both states.
        XCTAssertTrue(
            source.contains(".accessibilityInputLabels([\"Copy phrase\".lavaLocalized, \"Copy\".lavaLocalized] + (copiedRecoveryPhrase ? [\"Copied\".lavaLocalized] : []))"),
            "The copy-phrase button must surface stable commands first and keep the current label addressable."
        )
    }
}
