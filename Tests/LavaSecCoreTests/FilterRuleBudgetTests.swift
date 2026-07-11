import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class FilterRuleBudgetTests: XCTestCase {
    func testAbbreviatedFormatsKAndM() {
        XCTAssertEqual(FilterRuleBudget.abbreviated(0), "0")
        XCTAssertEqual(FilterRuleBudget.abbreviated(999), "999")
        XCTAssertEqual(FilterRuleBudget.abbreviated(1_000), "1K")
        XCTAssertEqual(FilterRuleBudget.abbreviated(216_000), "216K")
        XCTAssertEqual(FilterRuleBudget.abbreviated(500_000), "500K")
        XCTAssertEqual(FilterRuleBudget.abbreviated(1_200_000), "1.2M")
        XCTAssertEqual(FilterRuleBudget.abbreviated(2_000_000), "2M")
    }

    func testAbbreviatedRollsThousandsUpToMillionsAndAvoidsTrailingZero() {
        // 999,500–999,999 must read "1M", not "1000K".
        XCTAssertEqual(FilterRuleBudget.abbreviated(999_499), "999K")
        XCTAssertEqual(FilterRuleBudget.abbreviated(999_500), "1M")
        XCTAssertEqual(FilterRuleBudget.abbreviated(1_000_000), "1M")
        // Just under a whole million should round to the clean "2M", not "2.0M".
        XCTAssertEqual(FilterRuleBudget.abbreviated(1_999_999), "2M")
    }

    func testAbbreviatedClampsNegativeToZero() {
        XCTAssertEqual(FilterRuleBudget.abbreviated(-5), "0")
    }

    func testSoftCeilingIsTenPercentOverBudget() {
        XCTAssertEqual(FilterRuleBudget.softCeiling(forBudget: 500_000), 550_000)
        XCTAssertEqual(FilterRuleBudget.softCeiling(forBudget: 2_000_000), 2_200_000)
    }

    func testExceedsSoftCeilingAtBoundary() {
        XCTAssertFalse(FilterRuleBudget.exceedsSoftCeiling(knownRuleCount: 550_000, budget: 500_000))
        XCTAssertTrue(FilterRuleBudget.exceedsSoftCeiling(knownRuleCount: 550_001, budget: 500_000))
    }

    func testDisplayedRuleCountClampsToBudgetWhileSavable() {
        // Under budget: shown as-is.
        XCTAssertEqual(
            FilterRuleBudget.displayedRuleCount(knownRuleCount: 429_339, budget: 500_000),
            429_339
        )
        // Over budget but within the soft-ceiling margin (savable): clamp to the
        // budget so "506K of 500K" reads as "500K of 500K".
        XCTAssertEqual(
            FilterRuleBudget.displayedRuleCount(knownRuleCount: 506_000, budget: 500_000),
            500_000
        )
        // Exactly at the soft ceiling is still savable, so it clamps too.
        XCTAssertEqual(
            FilterRuleBudget.displayedRuleCount(knownRuleCount: 550_000, budget: 500_000),
            500_000
        )
    }

    func testDisplayedRuleCountShowsTrueCountOnceOverSoftCeiling() {
        // Past the soft ceiling (no longer savable): show the real number so the
        // user sees how far over they are.
        XCTAssertEqual(
            FilterRuleBudget.displayedRuleCount(knownRuleCount: 550_001, budget: 500_000),
            550_001
        )
        XCTAssertEqual(
            FilterRuleBudget.displayedRuleCount(knownRuleCount: 815_000, budget: 500_000),
            815_000
        )
    }

    func testFractionCapsAtOneAndGuardsZeroBudget() {
        XCTAssertEqual(FilterRuleBudget.fraction(knownRuleCount: 0, budget: 500_000), 0, accuracy: 0.0001)
        XCTAssertEqual(FilterRuleBudget.fraction(knownRuleCount: 250_000, budget: 500_000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(FilterRuleBudget.fraction(knownRuleCount: 600_000, budget: 500_000), 1.0, accuracy: 0.0001)
        XCTAssertEqual(FilterRuleBudget.fraction(knownRuleCount: 100, budget: 0), 0, accuracy: 0.0001)
    }

    // MARK: - INV-TIER-1: compiled totals get the exact budget, never the soft margin

    func testCompiledTotalFitsTierBudgetAtExactBoundary() {
        XCTAssertTrue(FilterRuleBudget.fitsTierBudget(compiledTotal: 499_999, maxFilterRules: 500_000))
        XCTAssertTrue(FilterRuleBudget.fitsTierBudget(compiledTotal: 500_000, maxFilterRules: 500_000))
        XCTAssertFalse(FilterRuleBudget.fitsTierBudget(compiledTotal: 500_001, maxFilterRules: 500_000))
    }

    func testCompiledTotalGetsNoSoftMargin() {
        // The ×1.10 soft ceiling tolerates over-counting in the selection-time
        // per-list SUM only. A deduped compiled total inside that margin still
        // violates INV-TIER-1: the field case this pins is a free-tier device
        // serving a 558,917-rule deduped union past the 500K budget.
        // …a selection summing 500,001 is still savable (inside the margin)…
        XCTAssertFalse(FilterRuleBudget.exceedsSoftCeiling(knownRuleCount: 500_001, budget: 500_000))
        // …but a COMPILED total of 500,001 is already a violation.
        XCTAssertFalse(FilterRuleBudget.fitsTierBudget(compiledTotal: 500_001, maxFilterRules: 500_000))
        XCTAssertFalse(FilterRuleBudget.fitsTierBudget(compiledTotal: 550_000, maxFilterRules: 500_000))
        XCTAssertFalse(FilterRuleBudget.fitsTierBudget(compiledTotal: 558_917, maxFilterRules: 500_000))
        // The same total is fine under the Plus budget.
        XCTAssertTrue(FilterRuleBudget.fitsTierBudget(compiledTotal: 558_917, maxFilterRules: 2_000_000))
    }

    func testNilRecordedTotalFailsClosed() {
        // A legacy/under-covered artifact that never recorded its compiled
        // total must not be reused/published on the recorded-total fast path —
        // callers fall back to the gated cold compile, which recomputes.
        XCTAssertFalse(FilterRuleBudget.fitsTierBudget(recordedTotal: nil, maxFilterRules: 2_000_000))
        XCTAssertTrue(FilterRuleBudget.fitsTierBudget(recordedTotal: 500_000, maxFilterRules: 500_000))
        XCTAssertFalse(FilterRuleBudget.fitsTierBudget(recordedTotal: 500_001, maxFilterRules: 500_000))
    }
}
