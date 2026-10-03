import XCTest

final class FilterLibraryControllerSourceTests: XCTestCase {
    func testScreenOwnsItsControllerAndSheetObservesTheSameSession() throws {
        let screen = try readSource(.filterLibraryView)
        let controller = try readSource(.filterLibraryController)
        let composition = try readSource(.reactNativeAppFilters)
        XCTAssertTrue(composition.contains("let library = libraryEditor"))
        XCTAssertTrue(composition.contains("library: library"))
        XCTAssertTrue((try readSource(.reactNativeAppBridge)).contains("FilterLibraryController(hub: model)"))
        XCTAssertTrue((try readSource(.reactNativeAppFlows)).contains("CreateFilterSheet(library: library"))
        XCTAssertTrue(screen.contains("@ObservedObject var library: FilterLibraryController"))
        XCTAssertFalse(screen.contains("@State private var stagedDeletions"))
        XCTAssertTrue(controller.contains("private weak var hub: (any FilterLibraryHubBridging)?"))
        XCTAssertTrue(controller.contains("hub.libraryChanges.sink { [weak self] _ in"))
        XCTAssertFalse(controller.contains("Task {"), "Screen lifetime cannot own accepted native operations.")
    }

    func testNativeBackstopsAndPresentationUseOneExecutableEligibilityPolicy() throws {
        let app = try readAppViewModelSource()
        let controller = try readSource(.filterLibraryController)
        XCTAssertTrue(app.contains("filterLibraryAccessPolicy.canCreate"))
        XCTAssertTrue(app.contains("filterLibraryAccessPolicy.isFrozen(id)"))
        XCTAssertTrue(app.contains("filterLibraryAccessPolicy.isNameAvailable(name, excluding: excludedID)"))
        XCTAssertTrue(controller.contains("FilterLibraryAccessPolicy(library: hub.library, maximumFilters: hub.libraryMaximumFilters)"))
    }

    func testLibraryIdentityAndCreationStayWithinTheReviewBoundary() throws {
        let controller = try readSource(.filterLibraryController)
        let rnFlow = try readSource(.reactNativeAppFlows)
        XCTAssertTrue(controller.contains("var canCreateFilter: Bool { filters.count < maximumFilters }"))
        XCTAssertTrue(controller.contains("var canBeginCreatingFilter: Bool { canCreateFilter && !hasChanges }"))
        XCTAssertTrue(controller.contains("editSession.rename(filter.id, to: name, emoji: emoji)"))
        XCTAssertFalse(controller.contains("hub?.renameFilter(id: id, to: name, emoji: emoji)"))
        XCTAssertTrue((try readSource(.reactNativeAppFilters)).contains("guard library.editSession == reviewedSession, library.commitStagedDeletions()"))
        XCTAssertTrue(rnFlow.contains("library.renameFilter(id: id, to: $0, emoji: $1)"))
    }
}
