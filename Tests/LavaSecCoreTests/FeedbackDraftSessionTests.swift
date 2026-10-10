import XCTest
import LavaSecAppServices

final class FeedbackDraftSessionTests: XCTestCase {
    private func reviewed() -> FeedbackDraftSession {
        var draft = FeedbackDraftSession()
        XCTAssertTrue(draft.selectTopic(.websiteAccess)); XCTAssertTrue(draft.advance())
        XCTAssertTrue(draft.change(.site, to: "example.com")); XCTAssertTrue(draft.change(.details, to: "Cannot open the site"))
        XCTAssertTrue(draft.setDiagnostics(true)); XCTAssertTrue(draft.advance())
        return draft
    }
    func testReviewedContextIsConsumedOnceAndCannotChangeDuringFlushOrSend() {
        var draft = reviewed(); let revision = draft.revision
        let context = draft.beginSubmission(review: revision)
        XCTAssertEqual(context?.normalizedAffectedSite, "example.com"); XCTAssertEqual(context?.includeDiagnostics, true)
        XCTAssertFalse(draft.canDismiss); XCTAssertNil(draft.beginSubmission(review: revision))
        XCTAssertFalse(draft.change(.details, to: "Unreviewed")); XCTAssertFalse(draft.navigate(to: 0))
        XCTAssertTrue(draft.beginSending()); XCTAssertFalse(draft.canDismiss)
        XCTAssertFalse(draft.setDiagnostics(false)); XCTAssertFalse(draft.advance())
        draft.complete(sent: false); XCTAssertTrue(draft.canDismiss)
        XCTAssertEqual(draft.beginSubmission(review: revision), context)
    }
    func testChangedInputInvalidatesReviewButPreviouslyVisitedStepsRemainAvailable() {
        var draft = reviewed(); let review = draft.revision
        XCTAssertTrue(draft.navigate(to: 1)); XCTAssertTrue(draft.change(.details, to: "Changed"))
        XCTAssertNil(draft.beginSubmission(review: review)); XCTAssertTrue(draft.navigate(to: 2))
        XCTAssertNil(draft.beginSubmission(review: review)); XCTAssertNotNil(draft.beginSubmission(review: draft.revision))
    }
    func testRetiredPreparationCannotStartAPostOrAdoptANewVisit() {
        var draft = reviewed(); XCTAssertNotNil(draft.beginSubmission(review: draft.revision))
        draft.retire(); XCTAssertFalse(draft.beginSending()); XCTAssertFalse(draft.change(.details, to: "Reopened"))
        let fresh = FeedbackDraftSession(); XCTAssertEqual(fresh.phase, .editing); XCTAssertFalse(fresh.dirty)
    }
    func testNativeNormalizationAndGraphemeLimitsGovernValidation() {
        var draft = FeedbackDraftSession(); draft.selectTopic(.websiteAccess); draft.advance()
        draft.change(.site, to: "example.com"); draft.change(.details, to: "\u{200B}\u{202E}")
        XCTAssertFalse(draft.validContext); XCTAssertFalse(draft.advance())
        let family = "👨‍👩‍👧‍👦"
        draft.change(.details, to: String(repeating: family, count: BugReportInputLimits.details + 1))
        XCTAssertEqual(draft.details.count, BugReportInputLimits.details)
        XCTAssertTrue(draft.validContext); draft.selectTopic(.suggestion)
        XCTAssertEqual(draft.site, ""); XCTAssertEqual(draft.context.normalizedAffectedSite, "")
    }
    func testSentVisitHasNoDirtyDraftAndCannotResubmit() {
        var draft = reviewed(); XCTAssertNotNil(draft.beginSubmission(review: draft.revision)); XCTAssertTrue(draft.beginSending())
        draft.complete(sent: true); XCTAssertFalse(draft.dirty); XCTAssertTrue(draft.canDismiss)
        XCTAssertNil(draft.beginSubmission(review: draft.revision))
    }
    func testUnacknowledgedPresentationEditGuardsDismissalWithoutChangingReviewedContext() {
        var draft = FeedbackDraftSession(); let context = draft.context; let revision = draft.revision
        XCTAssertTrue(draft.markPresentationEdited()); XCTAssertTrue(draft.dirty)
        XCTAssertEqual(draft.context, context); XCTAssertEqual(draft.revision, revision)
        XCTAssertNil(draft.reviewRevision); XCTAssertNil(draft.beginSubmission(review: revision))
        XCTAssertTrue(draft.change(.site, to: "")); XCTAssertTrue(draft.dirty)
        draft.retire(); XCTAssertFalse(draft.markPresentationEdited())
        XCTAssertFalse(FeedbackDraftSession().dirty)
    }
    func testPresentationHintCannotReopenPreparingSendingOrSentFeedback() {
        var draft = reviewed(); XCTAssertTrue(draft.markPresentationEdited())
        XCTAssertNotNil(draft.beginSubmission(review: draft.revision)); XCTAssertFalse(draft.markPresentationEdited())
        XCTAssertTrue(draft.beginSending()); XCTAssertFalse(draft.markPresentationEdited())
        draft.complete(sent: true); XCTAssertFalse(draft.markPresentationEdited()); XCTAssertFalse(draft.dirty)
    }
}
