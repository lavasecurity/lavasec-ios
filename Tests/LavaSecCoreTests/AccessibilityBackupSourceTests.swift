import XCTest

/// Source guardrails for the backup setup + restore VoiceOver pass (plan Task 7 / WS-U). Like the
/// other `*SourceTests`, these pin the accessibility modifiers AS TEXT because the app target sits
/// outside the SPM test target. They assert presence/structure only; runtime VoiceOver focus order
/// and spoken output are covered by the plan's device-QA gates, not here.
final class AccessibilityBackupSourceTests: XCTestCase {

    // MARK: BackupSetupView — step chrome + card rows

    func testBackupSetupHeaderTitleIsHeader() throws {
        let block = try sourceBlock(
            in: try readSource(.backupSetupView),
            startingAt: "private var header: some View {",
            endingBefore: "private var isStepActionInFlight"
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isHeader)"),
            "The backup-setup step title must carry the VoiceOver header trait so the rotor can jump to it."
        )
    }

    func testBackupSetupFactRowHidesIconAndCombines() throws {
        let block = try sourceBlock(
            in: try readSource(.backupSetupView),
            startingAt: "private struct BackupSetupFactRow",
            endingBefore: "private struct BackupRecoveryPhraseWord"
        )
        XCTAssertTrue(
            block.contains(".accessibilityHidden(true)"),
            "The fact row's decorative leading SF Symbol must be hidden from accessibility."
        )
        XCTAssertTrue(
            block.contains(".accessibilityElement(children: .combine)"),
            "The fact row must read its title + detail as a single VoiceOver element."
        )
    }

    func testBackupSetupRecoveryWordCombinesNumberAndWord() throws {
        let block = try sourceBlock(
            in: try readSource(.backupSetupView),
            startingAt: "private struct BackupRecoveryPhraseWord",
            endingBefore: "private struct BackupConfirmationToggle"
        )
        XCTAssertTrue(
            block.contains(".accessibilityElement(children: .combine)"),
            "Each recovery-phrase word chip must read its position number + word as one VoiceOver element."
        )
    }

    // MARK: BackupRestoreView — sheet chrome + editable word grid

    func testBackupRestoreHeaderTitleIsHeader() throws {
        let block = try sourceBlock(
            in: try readSource(.backupRestoreView),
            startingAt: "private var header: some View {",
            endingBefore: "private var recoveryPhraseFields"
        )
        XCTAssertTrue(
            block.contains(".accessibilityAddTraits(.isHeader)"),
            "The restore sheet title must carry the VoiceOver header trait."
        )
    }

    func testBackupRestoreWordFieldHidesRedundantNumber() throws {
        let block = try sourceBlock(
            in: try readSource(.backupRestoreView),
            startingAt: "private struct BackupRecoveryWordField",
            endingBefore: "enum BackupRestoreMode"
        )
        XCTAssertTrue(
            block.contains(".accessibilityHidden(true)"),
            "The word field's decorative position number must be hidden — the field's own 'Word N' label already carries it."
        )
    }
}
