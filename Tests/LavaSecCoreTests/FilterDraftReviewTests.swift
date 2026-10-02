import XCTest
import LavaSecKit

final class FilterDraftReviewTests: XCTestCase {
    private let baseline = FilterConfigurationSelection(
        enabledBlocklistIDs: ["existing"], blockedDomains: ["old.example"], allowedDomains: []
    )
    private let limits = FeatureLimits(
        maxAllowedDomains: 1, maxBlockedDomains: 1, maxFilterRules: 100,
        allowsCustomBlocklists: true, allowsCustomDNS: true
    )

    private func draft(blocked: Set<String> = ["new.example"], allowed: Set<String> = []) -> FilterEditDraft {
        FilterEditDraft(enabledBlocklistIDs: ["existing"], customBlocklists: [],
                        blockedDomains: blocked, allowedDomains: allowed)
    }

    func testNoDraftHasNoChangesOrValidationEvenWhenBudgetIsUnavailable() {
        let review = FilterDraftReview(baseline: baseline, draft: nil, limits: limits,
                                      ruleBudgetRejection: "Over budget")
        XCTAssertTrue(review.diff.isEmpty)
        XCTAssertNil(review.validationIssue)
        XCTAssertFalse(review.canConfirm)
    }

    func testReviewDescribesTheViewedBaselineWithoutWritingIt() {
        let review = FilterDraftReview(baseline: baseline, draft: draft(allowed: ["allowed.example"]),
                                      limits: limits, ruleBudgetRejection: nil)
        XCTAssertEqual(review.diff.removedBlockedDomains, ["old.example"])
        XCTAssertEqual(review.diff.addedBlockedDomains, ["new.example"])
        XCTAssertEqual(review.diff.addedAllowedDomains, ["allowed.example"])
        XCTAssertEqual(review.diff.changeCount, 3)
        XCTAssertTrue(review.canConfirm)
        XCTAssertEqual(baseline.blockedDomains, ["old.example"])
    }

    func testUnchangedDraftCannotConfirmAndExactLimitsAreAllowed() {
        let unchanged = FilterDraftReview(baseline: baseline, draft: draft(blocked: ["old.example"]),
                                         limits: limits, ruleBudgetRejection: nil)
        XCTAssertNil(unchanged.validationIssue)
        XCTAssertFalse(unchanged.canConfirm)
        let atLimits = FilterDraftReview(baseline: baseline, draft: draft(allowed: ["allowed.example"]),
                                        limits: limits, ruleBudgetRejection: nil)
        XCTAssertNil(atLimits.validationIssue)
        XCTAssertTrue(atLimits.canConfirm)
    }

    func testValidationPreservesBudgetThenBlockedThenAllowedPriority() {
        let overBoth = draft(blocked: ["a.example", "b.example"], allowed: ["c.example", "d.example"])
        let budget = FilterDraftReview(baseline: baseline, draft: overBoth, limits: limits,
                                      ruleBudgetRejection: "Native budget rejection")
        XCTAssertEqual(budget.validationIssue, .ruleBudget("Native budget rejection"))
        XCTAssertFalse(budget.canConfirm)
        let blocked = FilterDraftReview(baseline: baseline, draft: overBoth, limits: limits,
                                       ruleBudgetRejection: nil)
        XCTAssertEqual(blocked.validationIssue, .blockedDomainLimit(1))
        XCTAssertFalse(blocked.canConfirm)
        let allowed = FilterDraftReview(baseline: baseline, draft: draft(allowed: overBoth.allowedDomains),
                                       limits: limits, ruleBudgetRejection: nil)
        XCTAssertEqual(allowed.validationIssue, .allowedExceptionLimit(1))
        XCTAssertFalse(allowed.canConfirm)
    }

    func testReprojectionUsesCurrentLimitsAndDraftWithoutChangingPriorValue() {
        let edited = draft(blocked: ["a.example", "b.example"])
        let restricted = FilterDraftReview(baseline: baseline, draft: edited, limits: limits,
                                          ruleBudgetRejection: nil)
        let upgraded = FilterDraftReview(baseline: baseline, draft: edited, limits: .paid,
                                        ruleBudgetRejection: nil)
        XCTAssertFalse(restricted.canConfirm)
        XCTAssertTrue(upgraded.canConfirm)
        XCTAssertEqual(restricted.diff, upgraded.diff)
        let cancelled = FilterDraftReview(baseline: baseline, draft: nil, limits: .paid,
                                         ruleBudgetRejection: nil)
        XCTAssertFalse(cancelled.canConfirm)
        XCTAssertTrue(upgraded.canConfirm)
    }
}
