import XCTest

final class UIScaffoldMaintenanceSourceTests: XCTestCase {

    func testRetiredSettingsNavigationRowsAreRemoved() throws {
        let settings = try readSource(.settingsView)
        XCTAssertFalse(settings.contains("private struct SettingsNavigationRow"))
        XCTAssertFalse(settings.contains("struct SettingsView: View"))
        XCTAssertFalse(settings.contains("path: $path,"))
    }

    func testAutoSwitchCommentsExplainRationaleWithoutReviewToolProvenance() throws {
        let library = try readSource(.filterLibraryView)
        let autoSwitchRationale = try sourceBlock(
            in: library,
            startingAt: "/// Deep links (focus-mode-sheet revamp)",
            endingBefore: "@ViewBuilder\n    private func howToSection"
        )

        XCTAssertTrue(autoSwitchRationale.contains("iOS exposes NO\n/// deep link to a Focus"))
        XCTAssertTrue(autoSwitchRationale.contains("it does not land on the Focus screen"))
        XCTAssertTrue(autoSwitchRationale.contains("no Focus row"))
        XCTAssertTrue(autoSwitchRationale.contains("cannot strand a user"))
        XCTAssertTrue(autoSwitchRationale.contains("each section is a self-contained path"))

        for rationale in [autoSwitchRationale] {
            XCTAssertFalse(rationale.contains("Codex"))
            XCTAssertFalse(rationale.contains("OpenCodeReview"))
        }
    }
}
