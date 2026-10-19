import XCTest

final class FilterDraftControllerSourceTests: XCTestCase {
    func testAppUsesOneDraftOwnerAndForwardsExistingProjectionObservation() throws {
        let app = try readAppViewModelSource()
        let controller = try readSource(.filterDraftController)
        XCTAssertTrue(app.contains("private(set) lazy var filterDrafts = FilterDraftController(context: self)"))
        XCTAssertFalse(app.contains("var filterEditDrafts:"))
        for field in ["filterEditTargetID", "filterPreparationState", "filterPreparationOrigin", "isFilterPreparationScreenPresented"] {
            XCTAssertFalse(app.contains("@Published var \(field)"))
        }
        XCTAssertTrue(controller.contains("@Published private(set) var sessions = FilterDraftSessionState()"))
        XCTAssertTrue(app.contains("filterDrafts.objectWillChange.sink { [weak self] _ in"))
        XCTAssertTrue(app.contains("self?.objectWillChange.send()"))
        let endViewing = try sourceBlock(in: controller, startingAt: "func endViewing(", endingBefore: "func resetSessions()")
        XCTAssertTrue(sourceContainsInOrder([
            "guard !isPreparationPresented, !preparationState.isPreparing else { return }",
            "sessions.endViewing(activeFilterID: activeFilterID, hasChanges: hasChanges)"
        ], in: endViewing))
        XCTAssertFalse(endViewing.contains("Task {"))
        XCTAssertFalse(endViewing.contains(".cancel()"), "Dismissing presentation cannot cancel accepted native work.")
        XCTAssertFalse(endViewing.contains("preparationState ="))
        XCTAssertFalse(endViewing.contains("isPreparationPresented ="))
        // Only the bounded announcement fallback belongs to the presentation
        // owner. Its cancellation must never become accepted-operation cleanup.
        XCTAssertEqual(sourceOccurrenceCount(of: "Task {", in: sourceWithoutCommentLines(controller)), 1)
        XCTAssertTrue(controller.contains("private var preparationTerminalFallback: Task<Void, Never>?"))
        let fallback = try sourceBlock(in: controller, startingAt: "private func schedulePreparationTerminalFallback()", endingBefore: "func waitForPreparationSuccessPresentation(")
        XCTAssertTrue(fallback.contains("preparationTerminalFallback = Task { [weak self] in"))
        let cancellations = sourceWithoutCommentLines(controller).split(separator: "\n").filter { $0.contains(".cancel()") }
        XCTAssertFalse(cancellations.isEmpty)
        XCTAssertTrue(cancellations.allSatisfy { $0.contains("preparationTerminalFallback?.cancel()") })
    }

    func testEditingScreenObservesTheOwnerAndRestoreRollsBackItsWholeSnapshot() throws {
        let screen = try readSource(.reactNativeAppFilters)
        let app = try readSource(.lavaSecApp)
        XCTAssertTrue(screen.contains("model.filterDrafts"))
        XCTAssertTrue(app.contains(".environmentObject(viewModel.filterDrafts)"))
        let hub = try readSource(.appViewModelHubBridges)
        XCTAssertTrue(hub.contains("let draftsBeforeRestore = filterDrafts.sessions"))
        XCTAssertTrue(hub.contains("filterDrafts.restoreSessions(draftsBeforeRestore)"))
    }
}
