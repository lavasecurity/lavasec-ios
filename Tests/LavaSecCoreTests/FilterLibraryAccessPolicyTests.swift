import XCTest
import LavaSecKit

final class FilterLibraryAccessPolicyTests: XCTestCase {
    private func library(active: String = "d") -> FilterLibrary {
        FilterLibrary(filters: ["a", "b", "c", "d"].map { Filter(id: $0, name: $0.uppercased()) }, activeFilterID: active)
    }

    func testLapsedTierKeepsActiveAndFirstRemainingSlotsUsable() {
        let policy = FilterLibraryAccessPolicy(library: library(), maximumFilters: 3)
        XCTAssertFalse(policy.canCreate)
        XCTAssertFalse(policy.isFrozen("d"))
        XCTAssertFalse(policy.isFrozen("a"))
        XCTAssertFalse(policy.isFrozen("b"))
        XCTAssertTrue(policy.isFrozen("c"))
    }

    func testCapAndActiveChangesRecomputeEligibilityFromCurrentLibrary() {
        let atCap = FilterLibraryAccessPolicy(library: library(), maximumFilters: 4)
        XCTAssertFalse(atCap.canCreate)
        XCTAssertFalse(atCap.isFrozen("c"))
        XCTAssertTrue(FilterLibraryAccessPolicy(library: library(), maximumFilters: 10).canCreate)
        let switched = FilterLibraryAccessPolicy(library: library(active: "c"), maximumFilters: 1)
        XCTAssertFalse(switched.isFrozen("c"))
        XCTAssertTrue(switched.isFrozen("a"))
        XCTAssertTrue(switched.isFrozen("d"))
    }

    func testNamesTrimAndCompareWithoutCaseButCanExcludeTheRenamedFilter() {
        let policy = FilterLibraryAccessPolicy(library: library(), maximumFilters: 3)
        XCTAssertFalse(policy.isNameAvailable(" \n"))
        XCTAssertFalse(policy.isNameAvailable(" a \n"))
        XCTAssertTrue(policy.isNameAvailable("a", excluding: "a"))
        XCTAssertFalse(policy.isNameAvailable("a", excluding: "b"))
        XCTAssertTrue(policy.isNameAvailable("New filter"))
    }
}
