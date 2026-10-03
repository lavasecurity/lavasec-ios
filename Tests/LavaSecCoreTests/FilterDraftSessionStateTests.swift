import XCTest
import LavaSecKit
import LavaSecPresentation

final class FilterDraftSessionStateTests: XCTestCase {
    private func draft(_ domain: String) -> FilterEditDraft {
        FilterEditDraft(enabledBlocklistIDs: [], customBlocklists: [], blockedDomains: [domain], allowedDomains: [])
    }

    func testOpeningAnotherFilterPreservesEachDraftAndActiveAccess() {
        var state = FilterDraftSessionState()
        state.setDraft(draft("active.example"), for: "active")
        state.beginViewing(id: "other", activeFilterID: "active")
        state.setDraft(draft("other.example"), for: state.currentFilterID(activeFilterID: "active"))
        XCTAssertEqual(state.currentDraft(activeFilterID: "active"), draft("other.example"))
        XCTAssertEqual(state.drafts["active"], draft("active.example"))
        state.beginViewing(id: "active", activeFilterID: "active")
        XCTAssertNil(state.detailTargetID)
        XCTAssertEqual(state.currentDraft(activeFilterID: "active"), draft("active.example"))
        XCTAssertEqual(state.drafts["other"], draft("other.example"))
    }

    func testClosingCleanDetailDropsOnlyItsDraftAndDirtyDetailResumes() {
        var state = FilterDraftSessionState()
        state.setDraft(draft("active.example"), for: "active")
        state.setDraft(draft("other.example"), for: "other")
        state.beginViewing(id: "other", activeFilterID: "active")
        state.endViewing(activeFilterID: "active", hasChanges: true)
        XCTAssertNil(state.detailTargetID)
        state.beginViewing(id: "other", activeFilterID: "active")
        XCTAssertEqual(state.currentDraft(activeFilterID: "active"), draft("other.example"))
        state.endViewing(activeFilterID: "active", hasChanges: false)
        XCTAssertNil(state.drafts["other"])
        XCTAssertEqual(state.drafts["active"], draft("active.example"))
    }

    func testDiscardingOneDraftDoesNotChangeOtherDraftsOrDetailTarget() {
        var state = FilterDraftSessionState()
        state.setDraft(draft("active.example"), for: "active")
        state.setDraft(draft("other.example"), for: "other")
        state.beginViewing(id: "other", activeFilterID: "active")
        state.setDraft(nil, for: "active")
        XCTAssertNil(state.drafts["active"])
        XCTAssertEqual(state.currentDraft(activeFilterID: "active"), draft("other.example"))
        XCTAssertEqual(state.detailTargetID, "other")
    }

    func testActiveContextFollowsActiveIdentityWithoutMovingPreservedDrafts() {
        var state = FilterDraftSessionState()
        state.setDraft(draft("a.example"), for: "a")
        state.setDraft(draft("b.example"), for: "b")
        XCTAssertEqual(state.currentDraft(activeFilterID: "a"), draft("a.example"))
        XCTAssertEqual(state.currentDraft(activeFilterID: "b"), draft("b.example"))
        state.beginViewing(id: "a", activeFilterID: "b")
        XCTAssertEqual(state.currentDraft(activeFilterID: "b"), draft("a.example"))
    }

    func testLibraryReplacementClearsDraftsAndTargetAndSnapshotCanRollBack() {
        var state = FilterDraftSessionState()
        state.setDraft(draft("other.example"), for: "other")
        state.beginViewing(id: "other", activeFilterID: "active")
        let beforeReplacement = state
        state.reset()
        XCTAssertTrue(state.drafts.isEmpty)
        XCTAssertNil(state.detailTargetID)
        state = beforeReplacement
        XCTAssertEqual(state.currentDraft(activeFilterID: "active"), draft("other.example"))
        XCTAssertEqual(state.detailTargetID, "other")
    }
    func testNewFilterDraftNeverReplacesSavedOrActiveDraftAndCancelDropsItsIdentity() {
        var state = FilterDraftSessionState()
        let active = draft("active.example")
        state.setDraft(active, for: "active")
        let filter = Filter(id: "new", name: "Untitled 1", enabledBlocklistIDs: ["basic"])
        state.beginCreating(filter, draft: draft("new.example"))
        XCTAssertEqual(state.newFilter, filter)
        XCTAssertEqual(state.detailTargetID, "new")
        XCTAssertEqual(state.drafts["active"], active)
        state.renameNewFilter(name: "Work", emoji: "🏡")
        XCTAssertEqual(state.newFilter?.name, "Work")
        XCTAssertEqual(state.newFilter?.emoji, "🏡")
        state.discardNewFilter()
        XCTAssertNil(state.newFilter)
        XCTAssertNil(state.drafts["new"])
        XCTAssertNil(state.detailTargetID)
        XCTAssertEqual(state.drafts["active"], active)
    }

    func testCreationCommitRetiresOnlyTransientStateAndLibraryReplacementCanRollBack() {
        var state = FilterDraftSessionState()
        state.beginCreating(Filter(id: "new", name: "Untitled 1"), draft: draft("new.example"))
        let staged = state
        state.reset()
        XCTAssertNil(state.newFilter)
        XCTAssertTrue(state.drafts.isEmpty)
        state = staged
        XCTAssertEqual(state.newFilter?.id, "new")
        state.completeCreation()
        XCTAssertNil(state.newFilter)
        XCTAssertNil(state.drafts["new"])
        XCTAssertEqual(state.detailTargetID, "new", "A successful write keeps the detail open on its now-saved identity.")
    }

    func testAbandoningANewDetailDoesNotPreserveAnUnreachablePlaceholder() {
        for changed in [false, true] {
            var state = FilterDraftSessionState()
            let active = draft("active.example")
            state.setDraft(active, for: "active")
            state.beginCreating(Filter(id: "new", name: "Untitled 1"), draft: draft("new.example"))
            state.endViewing(activeFilterID: "active", hasChanges: changed)
            XCTAssertNil(state.newFilter)
            XCTAssertNil(state.drafts["new"])
            XCTAssertNil(state.detailTargetID)
            XCTAssertEqual(state.drafts["active"], active)
        }
    }

}
