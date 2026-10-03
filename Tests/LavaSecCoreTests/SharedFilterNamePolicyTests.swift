import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Behavioral contract for derived filter naming.
///
/// This policy backs both the duplicate/created-filter path and shared filters
/// arriving from an import, so the sequence here is the app's single naming
/// convention: `base`, `base 2`, `base 3`, …
///
/// For imports the stakes are higher than cosmetics: the recipient never types a
/// name and the sender's name is deliberately never transmitted, so importing the
/// same card twice must produce two filters rather than silently overwriting the
/// first.
///
/// Plan: `lavasec-infra/plans/2026-07-14-recipient-first-shared-filter-card-plan.md`
final class SharedFilterNamePolicyTests: XCTestCase {
    private let base = "Shared filter"

    func testUsesTheBareBaseWhenNothingCollides() {
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(base: base, existingNames: []),
            "Shared filter"
        )
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(base: base, existingNames: ["Work", "Home"]),
            "Shared filter"
        )
    }

    func testNumbersSequentiallyPastCollisions() {
        // Starts at 2 because the unnumbered base is the first one — matching the
        // convention the app already uses for duplicated filters.
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(base: base, existingNames: ["Shared filter"]),
            "Shared filter 2"
        )
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(
                base: base,
                existingNames: ["Shared filter", "Shared filter 2"]
            ),
            "Shared filter 3"
        )
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(
                base: base,
                existingNames: ["Shared filter", "Shared filter 2", "Shared filter 3"]
            ),
            "Shared filter 4"
        )
    }

    func testFillsTheLowestGapRatherThanAppendingPastTheHighest() {
        // Deleting "Shared filter 2" should let the next import reuse that slot
        // instead of climbing forever.
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(
                base: base,
                existingNames: ["Shared filter", "Shared filter 3"]
            ),
            "Shared filter 2"
        )
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(
                base: base,
                existingNames: ["Shared filter", "Shared filter 2", "Shared filter 4"]
            ),
            "Shared filter 3"
        )
    }

    func testCollisionMatchingIsTrimmedAndCaseInsensitive() {
        // Mirrors AppViewModel.isFilterNameAvailable, which trims and compares
        // with localizedCaseInsensitiveCompare. A name that the library would
        // reject as a duplicate must also be treated as taken here.
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(base: base, existingNames: ["  shared FILTER  "]),
            "Shared filter 2"
        )
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(
                base: base,
                existingNames: ["SHARED FILTER", "shared filter 2"]
            ),
            "Shared filter 3"
        )
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(base: "  Shared filter  ", existingNames: []),
            "Shared filter",
            "the base itself is trimmed before use"
        )
    }

    func testReplacementCanReclaimTheTargetsOwnName() {
        // Replacement passes every name *except* the target's. A target already
        // called "Shared filter" therefore keeps that slot rather than being
        // renamed by its own presence in the library.
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(base: base, existingNames: ["Work", "Home"]),
            "Shared filter"
        )
        // ...while still colliding with every *other* filter.
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(base: base, existingNames: ["Work", "Shared filter"]),
            "Shared filter 2"
        )
    }

    func testUnrelatedNamesResemblingTheSuffixDoNotConsumeSlots() {
        // None of these are in the sequence, so none should push the counter.
        // "Shared filter 1" in particular is not a member: numbering starts at 2.
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(
                base: base,
                existingNames: ["Shared filter (2)", "Shared filter 1", "Shared filterr"]
            ),
            "Shared filter"
        )
    }

    func testIsDeterministicRegardlessOfInputOrder() {
        let names = ["Shared filter 3", "Shared filter", "Shared filter 2"]
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(base: base, existingNames: names),
            SharedFilterNamePolicy.nextAvailableName(base: base, existingNames: names.reversed())
        )
    }

    func testWorksWithALocalizedBase() {
        // The base is injected by the app already localized; the policy must not
        // assume ASCII or a particular script.
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(base: "共有フィルタ", existingNames: ["共有フィルタ"]),
            "共有フィルタ 2"
        )
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(
                base: "Filtre partagé",
                existingNames: ["filtre partagé"]
            ),
            "Filtre partagé 2",
            "case-insensitive matching must hold for accented scripts too"
        )
    }

    func testMatchesTheAppsExistingDerivedNameConvention() {
        // The unification point: duplicating a filter and importing a shared one
        // must produce the same shape of name. If AppViewModel.uniqueFilterName
        // ever stops delegating here, this is the contract it broke.
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(base: "Filter", existingNames: ["Filter"]),
            "Filter 2"
        )
        XCTAssertEqual(
            SharedFilterNamePolicy.nextAvailableName(
                base: "Filter",
                existingNames: ["Filter", "Filter 2"]
            ),
            "Filter 3"
        )
    }
    func testUntitledCreationUsesTheSameCollisionMatchingWithAnExplicitFirstNumber() {
        XCTAssertEqual(SharedFilterNamePolicy.nextAvailableName(base: "Untitled", existingNames: [], numberedFromOne: true), "Untitled 1")
        XCTAssertEqual(SharedFilterNamePolicy.nextAvailableName(base: "Untitled", existingNames: [" untitled 1 ", "Untitled 3"], numberedFromOne: true), "Untitled 2")
        XCTAssertEqual(SharedFilterNamePolicy.nextAvailableName(base: "Untitled", existingNames: ["Untitled 2"], numberedFromOne: true), "Untitled 1")
        XCTAssertEqual(SharedFilterNamePolicy.nextAvailableName(base: "Shared filter", existingNames: []), "Shared filter", "Existing imported/derived naming stays unchanged.")
    }

}
