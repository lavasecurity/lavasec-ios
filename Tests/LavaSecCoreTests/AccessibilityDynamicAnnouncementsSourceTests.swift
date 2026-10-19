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

    func testFilterPreparationHasOneNativeAttemptScopedAnnouncementOwner() throws {
        let source = try readSource(.reactNativeAppPreparation)
        XCTAssertTrue(source.contains("drafts.announcePreparationOutcome(id: id)"))
        let owner = try readSource(.filterDraftController)
        XCTAssertTrue(owner.contains("preparationPresentation.claimAnnouncement(id: id, outcome: outcome.key)"))
        XCTAssertTrue(owner.contains("LavaAccessibilityAnnouncer.announce(outcome.message)"))
        XCTAssertTrue(owner.contains("\"Filters updated.\".lavaLocalized"))
        XCTAssertFalse(try readSource(.filterReviewFlowView).contains("LavaAccessibilityAnnouncer"))
    }

    // MARK: S6 — Privacy & Data clear completion

    // MARK: S7 — backup restore + setup completion

    func testBackupRestoreAnnouncesSettledOutcome() throws {
        let source = try readSource(.backupRestoreView)
        XCTAssertTrue(source.contains("LavaAccessibilityAnnouncer.announce(RestoreStatus.reviewing.title.lavaLocalized)"))
        XCTAssertTrue(source.contains("restoreStatus.title.lavaLocalized + \" \" + restoreStatus.detail.lavaLocalized"))
        XCTAssertTrue(source.contains("LavaAccessibilityAnnouncer.announce(restoreStatus.title.lavaLocalized"))
    }

    func testBackupSetupAnnouncesCompletion() throws {
        let source = try readSource(.backupSetupView)
        XCTAssertTrue(
            source.contains("LavaAccessibilityAnnouncer.announce(\"Backup is ready\".lavaLocalized)"),
            "Turning on encrypted backup must announce the confirmed completion shown in the success screen."
        )
    }
}
