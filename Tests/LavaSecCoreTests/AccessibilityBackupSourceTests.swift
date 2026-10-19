import XCTest

/// Source guardrails for the backup setup + restore VoiceOver pass (plan Task 7 / WS-U). Like the
/// other `*SourceTests`, these pin the accessibility modifiers AS TEXT because the app target sits
/// outside the SPM test target. They assert presence/structure only; runtime VoiceOver focus order
/// and spoken output are covered by the plan's device-QA gates, not here.
final class AccessibilityBackupSourceTests: XCTestCase {

    // MARK: BackupSetupView — step chrome + card rows

    func testBackupSetupUsesSharedAccessibleTaskTitle() throws {
        let source = try readSource(.reactNativeAccountBackupAdapter)
        XCTAssertTrue(source.contains("title:state.title"))
        XCTAssertTrue(source.contains("useToolbar("))
    }

    func testBackupSetupFactRowHidesIconAndCombines() throws {
        let source = try readSource(.reactNativeAccountBackupFlow)
        let fact = try sourceBlock(in: source, startingAt: "function Fact(")
        XCTAssertTrue(fact.contains("<View accessible"))
        XCTAssertTrue(fact.contains("<Symbol name={icon}"))
        XCTAssertTrue(fact.contains("<Copy role=\"section\" color={labelColor}>{title}</Copy>"))
    }

    func testBackupSetupRecoveryWordCombinesNumberAndWord() throws {
        let source = try readSource(.reactNativeBackupCredentials)
        XCTAssertTrue(source.contains(".accessibilityElement(children: .combine)"))
    }

    func testBackupRestoreUsesSharedAccessibleTaskTitle() throws {
        let source = try readSource(.reactNativeAccountBackupAdapter)
        XCTAssertTrue(source.contains("title:state.title"))
        XCTAssertTrue(try readSource(.reactNativeAppAccountBackup).contains("Restore Backup"))
    }

    func testBackupRestoreWordFieldHidesRedundantNumber() throws {
        let source = try readSource(.reactNativeBackupCredentials)
        XCTAssertTrue(source.contains(".frame(width: 18, alignment: .trailing).accessibilityHidden(true)"))
        XCTAssertTrue(source.contains("Word %lld"))
    }

}
