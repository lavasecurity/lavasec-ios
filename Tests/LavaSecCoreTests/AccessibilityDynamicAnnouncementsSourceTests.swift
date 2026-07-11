import XCTest

/// Guardrails for the dynamic VoiceOver announcement fan-out (plan Task 6 / WS-X): wiring the
/// shared `LavaAccessibilityAnnouncer` (landed in #249) into the async completion points that
/// update UI *in place* — so VoiceOver, whose focus sits elsewhere, would otherwise stay silent.
/// Covers filter prepare/apply (FL1), Privacy & Data clear (S6), and backup restore/setup (S7).
///
/// Same regime as the sibling `*SourceTests`: the app target sits outside the SPM test target, so
/// these pin the wiring AS TEXT. They assert presence/structure only; runtime spoken output and
/// no-double-speak are covered by the plan's device-QA gates, not here.
final class AccessibilityDynamicAnnouncementsSourceTests: XCTestCase {

    // MARK: FL1 — filter prepare/apply terminal outcome

    func testFilterPreparationAnnouncesTerminalOutcome() throws {
        let block = try sourceBlock(
            in: try readSource(.filterReviewFlowView),
            startingAt: "struct FilterPreparationScreen: View {",
            endingBefore: "struct PreparationTickerTitle: View {"
        )
        // The outcome must be announced whether it PREDATES mount (a validation failure sets
        // `.failed` before presenting the cover) or FOLLOWS it (async success/failure). Both route
        // through one helper: `.onAppear` for the state already set at mount, `.onChange` after.
        XCTAssertTrue(
            block.contains(".onAppear {"),
            "The prepare screen must announce a terminal state already set at mount (fail-before-present)."
        )
        XCTAssertTrue(
            block.contains(".onChange(of: viewModel.filterPreparationState)"),
            "The prepare screen must announce terminal states reached after presentation."
        )
        // Helper defined once + called from both .onAppear and .onChange → three occurrences.
        XCTAssertEqual(
            block.components(separatedBy: "announceFilterPreparationOutcome(").count - 1, 3,
            "The announce helper must be defined once and called from both .onAppear and .onChange."
        )
        XCTAssertTrue(
            block.contains("LavaAccessibilityAnnouncer.announce(\"Filters updated.\".lavaLocalized)"),
            "A successful prepare/apply must announce completion to VoiceOver."
        )
        // Failure reuses the on-screen heading string so it stays localized without a new key.
        XCTAssertTrue(
            block.contains("\"We couldn't update your filter\".lavaLocalized"),
            "A failed prepare/apply must announce the failure (reusing the on-screen heading)."
        )
    }

    // MARK: S6 — Privacy & Data clear completion

    func testPrivacyDataClearAnnouncesPerTargetCompletion() throws {
        let source = try readSource(.privacySecuritySettingsView)
        XCTAssertTrue(
            source.contains("var clearedConfirmation: String"),
            "The clear target must expose a localized past-tense confirmation string."
        )
        let clearBlock = try sourceBlock(
            in: source,
            startingAt: "private func clear(_ target: LocalLogClearTarget) {",
            endingBefore: "private func exportLocalLogs()"
        )
        // The clear methods swallow write failures internally, so the announcement must be gated on
        // the VM reporting a durable clear — never spoken unconditionally.
        XCTAssertTrue(
            clearBlock.contains("if didClear {"),
            "The clear announcement must be gated on the mutation durably succeeding."
        )
        XCTAssertTrue(
            clearBlock.contains("LavaAccessibilityAnnouncer.announce(target.clearedConfirmation.lavaLocalized)"),
            "A successful Privacy & Data clear must announce a per-target completion confirmation."
        )
    }

    // MARK: S7 — backup restore + setup completion

    func testBackupRestoreAnnouncesSettledOutcome() throws {
        let source = try readSource(.backupRestoreView)
        // Both the success and the failure/cancelled paths announce their settled outcome — the
        // status panel updates in place, so neither would otherwise be spoken.
        XCTAssertEqual(
            source.components(separatedBy: "LavaAccessibilityAnnouncer.announce(").count - 1, 2,
            "Both the restore success and failure paths must announce their settled outcome."
        )
    }

    func testBackupSetupAnnouncesCompletion() throws {
        let source = try readSource(.backupSetupView)
        XCTAssertTrue(
            source.contains("LavaAccessibilityAnnouncer.announce(\"Encrypted backup is ready\".lavaLocalized)"),
            "Turning on encrypted backup must announce completion before the sheet dismisses."
        )
    }
}
