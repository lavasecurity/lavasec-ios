import XCTest
@testable import LavaSecCore

final class FilterSwitchPlanTests: XCTestCase {
    private func config(generation: Int = 7) -> AppConfiguration {
        AppConfiguration(
            enabledBlocklistIDs: ["active-src"],
            allowedDomains: ["active-allow.com"],
            blockedDomains: ["active-block.com"],
            customBlocklists: [],
            configurationGeneration: generation
        )
    }

    private func library() -> FilterLibrary {
        FilterLibrary(
            filters: [
                Filter(id: "active", name: "Active", enabledBlocklistIDs: ["active-src"],
                       blockedDomains: ["active-block.com"], allowedDomains: ["active-allow.com"]),
                Filter(id: "target", name: "Target", enabledBlocklistIDs: ["t-a", "t-b"],
                       blockedDomains: ["t-block.com"], allowedDomains: ["t-allow.com"],
                       lastCompiledToken: "warm-token")
            ],
            activeFilterID: "active"
        )
    }

    func testMakeMirrorsTargetFieldsAndMovesActive() throws {
        let outcome = try XCTUnwrap(FilterSwitchPlan.make(toFilterID: "target", configuration: config(), library: library()))

        XCTAssertEqual(outcome.library.activeFilterID, "target")
        XCTAssertEqual(outcome.configuration.enabledBlocklistIDs, ["t-a", "t-b"])
        XCTAssertEqual(outcome.configuration.blockedDomains, ["t-block.com"])
        XCTAssertEqual(outcome.configuration.allowedDomains, ["t-allow.com"])
        XCTAssertTrue(outcome.configuration.customBlocklists.isEmpty)
    }

    func testMakeDoesNotBumpGenerationOrMutateFilters() throws {
        let outcome = try XCTUnwrap(FilterSwitchPlan.make(toFilterID: "target", configuration: config(generation: 7), library: library()))
        // The generation bump belongs to the write step (it reads the on-disk generation), not the pure
        // transition — so the planned config keeps the input generation.
        XCTAssertEqual(outcome.configuration.configurationGeneration, 7)
        // The library's filter set is untouched (same filters, only the active selection moves).
        XCTAssertEqual(outcome.library.filters.map(\.id), ["active", "target"])
        XCTAssertEqual(outcome.library.filter(id: "target")?.lastCompiledToken, "warm-token")
    }

    func testMakeReturnsNilForAlreadyActiveTarget() {
        XCTAssertNil(FilterSwitchPlan.make(toFilterID: "active", configuration: config(), library: library()),
                     "Switching to the already-active filter is a no-op.")
    }

    func testMakeReturnsNilForUnknownTarget() {
        XCTAssertNil(FilterSwitchPlan.make(toFilterID: "ghost", configuration: config(), library: library()),
                     "Switching to a deleted/unknown filter must not produce a config/library mismatch.")
    }

    func testMakePreservesEveryDeviceGlobalFieldAndMirrorsOnlyTheFourScopedOnes() throws {
        // A Focus switch firing while the app is suspended must NEVER silently change the resolver, flip
        // protection, or alter paid/entitlement state — only the four filter-scoped fields move. Pin the
        // exact mirror scope with distinctive non-default device-global values so a future 5th mirrored
        // field (or a reset) fails this test.
        let input = AppConfiguration(
            protectionEnabled: true,
            enabledBlocklistIDs: ["active-src"],
            allowedDomains: ["active-allow.com"],
            blockedDomains: ["active-block.com"],
            resolverPresetID: "custom-resolver-x",
            customResolverAddress: "1.2.3.4",
            fallbackToDeviceDNS: false,
            keepFilteringCounts: true,
            isPaid: true,
            customBlocklists: [],
            configurationGeneration: 7
        )
        let outcome = try XCTUnwrap(FilterSwitchPlan.make(toFilterID: "target", configuration: input, library: library()))

        // The four scoped fields took the target's values.
        XCTAssertEqual(outcome.configuration.enabledBlocklistIDs, ["t-a", "t-b"])
        XCTAssertEqual(outcome.configuration.blockedDomains, ["t-block.com"])
        XCTAssertEqual(outcome.configuration.allowedDomains, ["t-allow.com"])
        XCTAssertTrue(outcome.configuration.customBlocklists.isEmpty)
        // Every device-global field is preserved unchanged.
        XCTAssertEqual(outcome.configuration.protectionEnabled, true)
        XCTAssertEqual(outcome.configuration.resolverPresetID, "custom-resolver-x")
        XCTAssertEqual(outcome.configuration.customResolverAddress, "1.2.3.4")
        XCTAssertEqual(outcome.configuration.fallbackToDeviceDNS, false)
        XCTAssertEqual(outcome.configuration.keepFilteringCounts, true)
        XCTAssertEqual(outcome.configuration.isPaid, true)
        XCTAssertEqual(outcome.configuration.configurationGeneration, 7)
    }

    func testMakeIsPureLeavingInputsUnchanged() throws {
        let inputConfig = config()
        let inputLibrary = library()
        _ = try XCTUnwrap(FilterSwitchPlan.make(toFilterID: "target", configuration: inputConfig, library: inputLibrary))
        // Value types: the inputs must be unchanged (the transition returns new values).
        XCTAssertEqual(inputConfig.enabledBlocklistIDs, ["active-src"])
        XCTAssertEqual(inputLibrary.activeFilterID, "active")
    }
}
