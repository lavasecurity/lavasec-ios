import XCTest

final class UIScaffoldMaintenanceSourceTests: XCTestCase {
    func testConfirmedDeadViewHelpersAndBranchesStayRemoved() throws {
        let myList = try readSource(.filterMyListView)
        XCTAssertFalse(myList.contains("struct LavaInlineInfoContent"))

        let editToolbar = try sourceBlock(
            in: myList,
            startingAt: "private struct FilterEditToolbar",
            endingBefore: "private struct BlocklistEffectRow"
        )
        XCTAssertFalse(editToolbar.contains("let isEditing: Bool"))
        XCTAssertFalse(editToolbar.contains("let beginEditing: () -> Void"))
        XCTAssertFalse(editToolbar.contains("if isEditing"))
        XCTAssertFalse(myList.contains("isEditing: true,"))
        XCTAssertFalse(myList.contains("beginEditing: beginEditing,"))

        let diagnostics = try readSource(.diagnosticsView)
        XCTAssertFalse(diagnostics.contains("struct ActivityDateScopeButton: View"))
        XCTAssertFalse(diagnostics.contains("struct ActivityDateScopeButtonStyle: ButtonStyle"))
        XCTAssertFalse(try readSource(.diagnosticsDateControls).contains("func exactText()"))
    }

    func testSettingsNavigationRowsDoNotAcceptAnUnusedPathBinding() throws {
        let settings = try readSource(.settingsView)
        let row = try sourceBlock(
            in: settings,
            startingAt: "private struct SettingsNavigationRow",
            endingBefore: "private struct SettingsExternalLinkRow"
        )

        XCTAssertFalse(row.contains("path: Binding<[SettingsRoute]>"))
        XCTAssertFalse(settings.contains("path: $path,"))
    }

    func testMovedFilterCommentsExplainRationaleWithoutReviewToolProvenance() throws {
        let library = try readSource(.filterLibraryView)
        let stagedDeletionRationale = try sourceBlock(
            in: library,
            startingAt: "// Leaving edit mode by ANY path",
            endingBefore: ".onChange(of: isEditing)"
        )
        let autoSwitchRationale = try sourceBlock(
            in: library,
            startingAt: "/// Deep links (focus-mode-sheet revamp)",
            endingBefore: "@ViewBuilder\n    private func howToSection"
        )

        XCTAssertTrue(stagedDeletionRationale.contains("stale stage can't survive into the next edit session"))
        XCTAssertTrue(stagedDeletionRationale.contains("same-ID restored defaults"))
        XCTAssertTrue(stagedDeletionRationale.contains("commit path deletes before this fires"))

        XCTAssertTrue(autoSwitchRationale.contains("iOS exposes NO\n/// deep link to a Focus"))
        XCTAssertTrue(autoSwitchRationale.contains("it does not land on the Focus screen"))
        XCTAssertTrue(autoSwitchRationale.contains("no Focus row"))
        XCTAssertTrue(autoSwitchRationale.contains("cannot strand a user"))
        XCTAssertTrue(autoSwitchRationale.contains("each section is a self-contained path"))

        for rationale in [stagedDeletionRationale, autoSwitchRationale] {
            XCTAssertFalse(rationale.contains("Codex"))
            XCTAssertFalse(rationale.contains("OpenCodeReview"))
        }
    }
}
