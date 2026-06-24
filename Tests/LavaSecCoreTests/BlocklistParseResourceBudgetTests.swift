import XCTest
@testable import LavaSecCore

final class BlocklistParseResourceBudgetTests: XCTestCase {
    func testDefaultBudgetIsTheAppEnvelope() {
        let budget = BlocklistParseResourceBudget.default
        XCTAssertEqual(budget.maximumBlocklistBytes, 45 * 1024 * 1024)
        XCTAssertEqual(budget.maxRulesPerSource, FeatureLimits.plus.maxFilterRules) // 2M
        XCTAssertEqual(budget.maxConcurrentSources, 4)
    }

    func testInExtensionBudgetUsesDirtyAwareCapsAndSerialParse() {
        let budget = BlocklistParseResourceBudget.inExtension
        XCTAssertEqual(budget.maximumBlocklistBytes, 25 * 1024 * 1024)
        // The streaming compile parses each source uncapped (no per-source Set), so
        // `maxRulesPerSource` is set to the aggregate ceiling as a defensive value; the real
        // bound is the per-rule aggregate gate.
        XCTAssertEqual(budget.maxRulesPerSource, FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount)
        XCTAssertEqual(budget.maxConcurrentSources, 1)
    }

    func testStreamingCompileCeilingIsBelowTheCompactDeviceBudget() {
        // The streaming compile's transient ceiling (the compact entry arrays + sort/grow
        // slack) must stay under the 9 B/rule mapped-compact device budget.
        XCTAssertGreaterThan(FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount, 0)
        XCTAssertLessThan(
            FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount,
            FilterSnapshotMemoryBudget.maxFilterRuleCount
        )
    }

    // The whole point of the split: a source the app can parse must never reach the
    // memory-constrained extension fallback at a larger envelope than before. If anyone
    // raises the in-extension budget toward the app's, this fails.
    func testInExtensionBudgetNeverExceedsTheAppBudget() {
        let app = BlocklistParseResourceBudget.default
        let ext = BlocklistParseResourceBudget.inExtension
        XCTAssertLessThanOrEqual(ext.maximumBlocklistBytes, app.maximumBlocklistBytes)
        XCTAssertLessThanOrEqual(ext.maxRulesPerSource, app.maxRulesPerSource)
        XCTAssertLessThanOrEqual(ext.maxConcurrentSources, app.maxConcurrentSources)
    }

    func testPublicStaticByteCapMatchesDefaultBudget() {
        XCTAssertEqual(
            BlocklistCatalogSynchronizer.maximumBlocklistBytes,
            BlocklistParseResourceBudget.default.maximumBlocklistBytes
        )
    }
}
