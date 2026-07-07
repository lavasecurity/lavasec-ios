import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class FilterSnapshotMemoryBudgetTests: XCTestCase {
    func testMaxFilterRuleCountMatchesBudgetFormulaAndHonorsAMillionPlus() {
        let expected = Int(
            ((FilterSnapshotMemoryBudget.maxResidentMegabytes - FilterSnapshotMemoryBudget.baselineMegabytes)
                * 1_048_576) / FilterSnapshotMemoryBudget.estimatedBytesPerRule
        )
        XCTAssertEqual(FilterSnapshotMemoryBudget.maxFilterRuleCount, expected)
        // Must comfortably honor the 1M+ goal while still bounding pathological
        // multi-list configs, and stay above the 2M paid tier ceiling.
        XCTAssertGreaterThan(FilterSnapshotMemoryBudget.maxFilterRuleCount, 3_000_000)
        XCTAssertLessThan(FilterSnapshotMemoryBudget.maxFilterRuleCount, 5_000_000)
    }

    func testExceedsBudgetAtBoundary() {
        let max = FilterSnapshotMemoryBudget.maxFilterRuleCount
        XCTAssertFalse(FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: 0))
        XCTAssertFalse(FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: max))
        XCTAssertTrue(FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: max + 1))
    }

    func testEstimatedResidentTracksTheDeviceMeasurement() {
        // QA device (2026-06-13): 789,831 rules → ~9.9 MB phys_footprint. The
        // rounded-up constants should estimate slightly above the measurement.
        let mb = FilterSnapshotMemoryBudget.estimatedResidentMegabytes(forRuleCount: 789_831)
        XCTAssertGreaterThan(mb, 9.0)
        XCTAssertLessThan(mb, 12.0)
        // 1M rules should still be well within budget.
        XCTAssertLessThan(FilterSnapshotMemoryBudget.estimatedResidentMegabytes(forRuleCount: 1_000_000), 16.0)
    }

    func testTierBudgetsSitUnderTheDeviceGuardrail() {
        // Free 500K / Plus 2M must both fit under the ~3.26M hard device cap.
        XCTAssertEqual(FeatureLimits.free.maxFilterRules, 500_000)
        XCTAssertEqual(FeatureLimits.paid.maxFilterRules, 2_000_000)
        XCTAssertLessThan(FeatureLimits.paid.maxFilterRules, FilterSnapshotMemoryBudget.maxFilterRuleCount)
    }

    func testDeviceErrorDescriptionNamesTotalsAndLargestSources() throws {
        let error = FilterSnapshotPreparationError.exceedsDeviceMemoryBudget(
            ruleCount: 5_000_000,
            maxRuleCount: 3_000_000,
            perSourceRuleCounts: ["huge-list": 4_000_000, "small-list": 1_000_000]
        )
        let description = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(description.contains("5,000,000"))
        XCTAssertTrue(description.contains("3,000,000"))
        XCTAssertTrue(description.contains("huge-list"))
        XCTAssertTrue(description.contains("filter rules"))
    }

    func testTierErrorOffersUpgradeOnlyForFreeUsers() throws {
        let freeError = FilterSnapshotPreparationError.exceedsTierFilterRuleLimit(
            ruleCount: 700_000,
            limitRuleCount: 500_000,
            isPaid: false,
            perSourceRuleCounts: ["big-list": 600_000]
        )
        let freeDescription = try XCTUnwrap(freeError.errorDescription)
        XCTAssertTrue(freeDescription.contains("700,000"))
        XCTAssertTrue(freeDescription.contains("500,000"))
        XCTAssertTrue(freeDescription.contains("upgrade to Plus"))
        XCTAssertTrue(freeDescription.contains("big-list"))

        let paidError = FilterSnapshotPreparationError.exceedsTierFilterRuleLimit(
            ruleCount: 2_500_000,
            limitRuleCount: 2_000_000,
            isPaid: true,
            perSourceRuleCounts: ["big-list": 2_400_000]
        )
        let paidDescription = try XCTUnwrap(paidError.errorDescription)
        XCTAssertFalse(paidDescription.contains("upgrade to Plus"))
        XCTAssertTrue(paidDescription.contains("Remove a list"))
    }
}
