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
        XCTAssertLessThan(FilterSnapshotMemoryBudget.maxFilterRuleCount, 7_000_000)
    }

    func testExceedsBudgetAtBoundary() {
        let max = FilterSnapshotMemoryBudget.maxFilterRuleCount
        XCTAssertFalse(FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: 0))
        XCTAssertFalse(FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: max))
        XCTAssertTrue(FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: max + 1))
    }

    func testEstimatedResidentTracksTheDeviceMeasurement() {
        // QA device (2026-06-13): 789,831 rules → ~9.9 MB phys_footprint with the OLD
        // 8-byte entry. The 4-byte entry halves the structural per-rule cost, so the model
        // (baseline + 5 B/rule) now estimates well under the old measurement. This is the
        // conservative re-derivation pending an on-device re-measure (see the W1 plan).
        let mb = FilterSnapshotMemoryBudget.estimatedResidentMegabytes(forRuleCount: 789_831)
        XCTAssertGreaterThan(mb, 6.0)
        XCTAssertLessThan(mb, 9.0)
        // 1M rules should still be well within budget.
        XCTAssertLessThan(FilterSnapshotMemoryBudget.estimatedResidentMegabytes(forRuleCount: 1_000_000), 16.0)
    }

    func testTierBudgetsSitUnderTheDeviceGuardrail() {
        // Free 500K / Plus 2M must both fit under the ~5.87M hard device cap.
        XCTAssertEqual(FeatureLimits.free.maxFilterRules, 500_000)
        XCTAssertEqual(FeatureLimits.paid.maxFilterRules, 2_000_000)
        XCTAssertLessThan(FeatureLimits.paid.maxFilterRules, FilterSnapshotMemoryBudget.maxFilterRuleCount)
    }

    /// 🔴 The headline capability of the 4-byte entry change (#538): the in-extension streaming
    /// compile can now admit a full 2M Plus config, so the ceiling is the POLICY cap (2M), not
    /// the memory bound. Pins both the 4 B/rule entry constant and the `min(memoryCeiling, 2M)`
    /// result — reverting `estimatedCompactEntryBytesPerRule` to 8.0 drops the memory ceiling
    /// below 2M, so the streaming compile would again fail closed on a near-cap config; this
    /// test catches that silently-reintroduced limitation.
    func testStreamingCompileCeilingReachesThePlusTierCap() {
        XCTAssertEqual(FilterSnapshotMemoryBudget.estimatedCompactEntryBytesPerRule, 4.0)
        // The memory bound (memoryCeiling, ~3.67M with the 4-byte entry) is above the 2M tier
        // cap, so the streaming ceiling is capped at exactly the Plus limit.
        XCTAssertEqual(
            FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount,
            FeatureLimits.plus.maxFilterRules)
        XCTAssertEqual(FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount, 2_000_000)
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
        XCTAssertTrue(freeDescription.contains("upgrade to Lava Plus"))
        XCTAssertTrue(freeDescription.contains("big-list"))

        let paidError = FilterSnapshotPreparationError.exceedsTierFilterRuleLimit(
            ruleCount: 2_500_000,
            limitRuleCount: 2_000_000,
            isPaid: true,
            perSourceRuleCounts: ["big-list": 2_400_000]
        )
        let paidDescription = try XCTUnwrap(paidError.errorDescription)
        XCTAssertFalse(paidDescription.contains("upgrade to Lava Plus"))
        XCTAssertTrue(paidDescription.contains("Remove a blocklist"))
    }
}
