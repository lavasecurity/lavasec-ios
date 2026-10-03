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
        XCTAssertTrue(controller.contains("guard !isPreparationPresented, !preparationState.isPreparing else { return }"))
        XCTAssertFalse(controller.contains("Task {"), "Dismissing presentation cannot cancel accepted native work.")
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
