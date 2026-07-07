import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Unit coverage for the pure `FilterLibrary` operations relocated out of `AppViewModel` (LAV-100
/// Phase 4) so the foreground switch and the headless Focus engine share ONE definition: the freeze
/// rule, the persist-boundary active-filter sync, and warm-artifact GC retention.
final class FilterLibraryFocusSwitchTests: XCTestCase {
    private func library(active: String, ids: [(id: String, token: String?)]) -> FilterLibrary {
        let filters = ids.map {
            Filter(id: $0.id, name: $0.id.uppercased(), enabledBlocklistIDs: ["s1"], lastCompiledToken: $0.token)
        }
        return FilterLibrary(filters: filters, activeFilterID: active)
    }

    // MARK: - isFrozen

    func testNothingFrozenWhenWithinCap() {
        let lib = library(active: "f1", ids: [("f1", nil), ("f2", nil), ("f3", nil)])
        for id in ["f1", "f2", "f3"] {
            XCTAssertFalse(lib.isFrozen(filterID: id, maxFilters: 3))
        }
    }

    func testFreezesFiltersBeyondCapKeepingActivePlusFirstUsable() {
        // cap 3, active f1: active + first (cap-1)=2 non-active stay usable; the rest freeze.
        let lib = library(active: "f1", ids: [("f1", nil), ("f2", nil), ("f3", nil), ("f4", nil), ("f5", nil)])
        XCTAssertFalse(lib.isFrozen(filterID: "f1", maxFilters: 3), "Active is never frozen.")
        XCTAssertFalse(lib.isFrozen(filterID: "f2", maxFilters: 3))
        XCTAssertFalse(lib.isFrozen(filterID: "f3", maxFilters: 3))
        XCTAssertTrue(lib.isFrozen(filterID: "f4", maxFilters: 3))
        XCTAssertTrue(lib.isFrozen(filterID: "f5", maxFilters: 3))
    }

    // MARK: - syncActiveFilter

    func testSyncActiveFilterWritesThroughFieldsAndClearsTokenOnceThenNoOps() {
        var lib = library(active: "f1", ids: [("f1", "tok-1"), ("f2", nil)])
        var config = AppConfiguration(enabledBlocklistIDs: ["x", "y"], customBlocklists: [], configurationGeneration: 1)
        config.blockedDomains = ["bad.example"]
        config.allowedDomains = ["ok.example"]

        XCTAssertTrue(lib.syncActiveFilter(from: config), "Fields moved ⇒ library changed.")
        XCTAssertEqual(lib.activeFilter.enabledBlocklistIDs, ["x", "y"])
        XCTAssertEqual(lib.activeFilter.blockedDomains, ["bad.example"])
        XCTAssertEqual(lib.activeFilter.allowedDomains, ["ok.example"])
        XCTAssertNil(lib.activeFilter.lastCompiledToken, "A field change must clear the stale compile token.")

        XCTAssertFalse(lib.syncActiveFilter(from: config), "A second sync with identical fields is a no-op.")
    }

    // MARK: - retainedWarmArtifactTokens

    func testRetainsActiveFirstThenNonFrozenHostedThenEligibleSidecar() {
        var lib = library(active: "f1", ids: [("f1", "t1"), ("f2", "t2"), ("f3", "t3")])
        _ = lib // silence if unused warnings on some toolchains
        var index = BackgroundWarmIndex()
        index.setEntry(BackgroundWarmIndexEntry(token: "side2", syncedAt: Date()), forFilterID: "f2")
        index.setEntry(BackgroundWarmIndexEntry(token: "ghost", syncedAt: Date()), forFilterID: "deleted")

        let tokens = lib.retainedWarmArtifactTokens(maxFilters: 3, backgroundWarmIndex: index)

        XCTAssertEqual(tokens.first, "t1", "The active filter's token is retained first (most likely switch-back).")
        XCTAssertTrue(tokens.contains("t2"))
        XCTAssertTrue(tokens.contains("t3"))
        XCTAssertTrue(tokens.contains("side2"), "Sidecar entry for an existing, switchable filter is retained.")
        XCTAssertFalse(tokens.contains("ghost"), "Sidecar entry for a deleted filter must not pin a directory.")
    }

    func testFrozenFiltersTokenIsNotRetained() {
        let lib = library(active: "f1", ids: [("f1", "t1"), ("f2", "t2"), ("f3", "t3"), ("f4", "t4")])
        // cap 3 ⇒ f4 is frozen, so its token must not be retained.
        let tokens = lib.retainedWarmArtifactTokens(maxFilters: 3, backgroundWarmIndex: BackgroundWarmIndex())
        XCTAssertTrue(tokens.contains("t1"))
        XCTAssertTrue(tokens.contains("t2"))
        XCTAssertTrue(tokens.contains("t3"))
        XCTAssertFalse(tokens.contains("t4"), "A frozen filter's compiled directory is not kept warm.")
    }
}
