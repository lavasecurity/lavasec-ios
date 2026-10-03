import XCTest
import LavaSecPresentation
import LavaSecKit

final class FilterLibraryEditSessionTests: XCTestCase {
    func testStageAndUndoOnlyChangeTheEditingSession() {
        var session = FilterLibraryEditSession()
        session.toggleDeletion("a")
        XCTAssertTrue(session.stagedDeletions.isEmpty)
        session.beginEditing()
        session.toggleDeletion("a")
        session.toggleDeletion("b")
        session.toggleDeletion("a")
        XCTAssertEqual(session.stagedDeletions, ["b"])
        XCTAssertTrue(session.isEditing)
    }

    func testEveryExitDiscardsStagingAndNextEditStartsClean() {
        var session = FilterLibraryEditSession()
        session.beginEditing()
        session.toggleDeletion("restored-same-id")
        let stagedBeforeCommit = session.stagedDeletions
        session.endEditing()
        XCTAssertEqual(stagedBeforeCommit, ["restored-same-id"])
        XCTAssertFalse(session.isEditing)
        XCTAssertTrue(session.stagedDeletions.isEmpty)
        session.beginEditing()
        XCTAssertTrue(session.stagedDeletions.isEmpty)
    }
    private var library: FilterLibrary {
        FilterLibrary(filters: [Filter(id: "a", name: "Active"), Filter(id: "b", name: "Other")], activeFilterID: "a")
    }
    func testMixedChangesStageWithoutChangingBaselineAndCommitAsOneBatch() throws {
        let original = library
        var session = FilterLibraryEditSession()
        session.beginEditing(library: original)
        session.rename("a", to: "Core")
        session.toggleDeletion("b")
        session.add(Filter(id: "c", name: "New", blockedDomains: ["example.com"]))
        XCTAssertEqual(session.baseline, original)
        XCTAssertEqual(original.filters.map(\.name), ["Active", "Other"])
        let committed = try XCTUnwrap(session.validatedLibrary(current: original, maximumFilters: 2))
        XCTAssertEqual(committed.filters.map(\.name), ["Core", "New"])
        XCTAssertEqual(committed.activeFilterID, "a")
    }
    func testUndoRenameAndNewAdditionReturnsToNoChanges() {
        var session = FilterLibraryEditSession()
        session.beginEditing(library: library)
        session.rename("b", to: "Renamed")
        session.rename("b", to: "Other")
        session.add(Filter(id: "c", name: "New"))
        session.toggleDeletion("c")
        XCTAssertFalse(session.hasChanges)
    }
    func testNameAndEmojiRemainInReviewUntilCommit() throws {
        let original = library
        var session = FilterLibraryEditSession()
        session.beginEditing(library: original)
        session.rename("b", to: "Renamed", emoji: "🔥")
        XCTAssertEqual(original.filter(id: "b")?.name, "Other")
        XCTAssertEqual(session.displayedFilters.first(where: { $0.id == "b" })?.emoji, "🔥")
        XCTAssertTrue(session.hasChanges)
        let committed = try XCTUnwrap(session.validatedLibrary(current: original, maximumFilters: 2))
        XCTAssertEqual(committed.filter(id: "b")?.name, "Renamed")
        XCTAssertEqual(committed.filter(id: "b")?.emoji, "🔥")
        session.rename("b", to: "Other", emoji: original.filter(id: "b")!.emoji)
        XCTAssertFalse(session.hasChanges)
    }
    func testEmojiOnlyEditIsReviewedAndDeletionRemainsValid() throws {
        let original = library
        var session = FilterLibraryEditSession()
        session.beginEditing(library: original)
        session.rename("b", to: "Other", emoji: "🔥")
        XCTAssertTrue(session.hasChanges)
        XCTAssertEqual(try XCTUnwrap(session.validatedLibrary(current: original, maximumFilters: 2)).filter(id: "b")?.emoji, "🔥")
        session.toggleDeletion("b")
        XCTAssertNotNil(session.validatedLibrary(current: original, maximumFilters: 2))
    }
    func testStaleActiveDuplicateNameAndLimitFailuresRejectWholeBatch() {
        let baseline = library
        var session = FilterLibraryEditSession()
        session.beginEditing(library: baseline)
        session.rename("b", to: "Other renamed")
        var changed = baseline
        changed.mutateFilter(id: "b") { $0.name = "Concurrent rename" }
        XCTAssertNil(session.validatedLibrary(current: changed, maximumFilters: 3))
        session.rename("b", to: "ACTIVE")
        XCTAssertNil(session.validatedLibrary(current: baseline, maximumFilters: 3))
        session.rename("b", to: "Other renamed")
        session.toggleDeletion("a")
        XCTAssertNil(session.validatedLibrary(current: baseline, maximumFilters: 3))
        session.toggleDeletion("a")
        session.add(Filter(id: "c", name: "New"))
        XCTAssertNil(session.validatedLibrary(current: baseline, maximumFilters: 2))
        XCTAssertEqual(session.additions.count, 1)
        XCTAssertEqual(session.renames["b"], "Other renamed")
    }

}
