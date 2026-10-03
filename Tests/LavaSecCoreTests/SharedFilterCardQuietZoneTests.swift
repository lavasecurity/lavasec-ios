import XCTest
@testable import LavaSecKit

/// Behavioural tests for the card's quiet-zone arithmetic.
///
/// These exist because the original card satisfied the four-module rule horizontally
/// and silently missed it vertically: the page margin served one axis, and on the
/// other the neighbours were a chip and a line of text about 10pt away. A code can be
/// perfectly valid and still fail to scan after a messenger recompresses it, so the
/// rule is enforced by arithmetic rather than by inspection of a render.
///
/// Plan: `lavasec-infra/plans/2026-07-14-recipient-first-shared-filter-card-plan.md`
final class SharedFilterCardQuietZoneTests: XCTestCase {

    /// The worst case: shortest real Lava link, measured at 39 extent-modules.
    private let worstCaseModuleCount: CGFloat = 39
    private let maximumQRSide: CGFloat = 294

    func testModuleWidthUsesTheFullExtentIncludingTheBorder() {
        let width = SharedFilterCardQuietZone.moduleWidth(
            renderedSide: maximumQRSide,
            moduleCount: worstCaseModuleCount
        )
        XCTAssertEqual(width, 294.0 / 39.0, accuracy: 0.0001)
        XCTAssertGreaterThan(width, 7.5, "The shortest link has the fattest modules.")
    }

    func testModuleWidthIsZeroRatherThanInfiniteForAnEmptyCode() {
        XCTAssertEqual(
            SharedFilterCardQuietZone.moduleWidth(renderedSide: 294, moduleCount: 0),
            0
        )
    }

    func testCardSuppliesTheThreeModulesTheGeneratorDoesNot() {
        let module = SharedFilterCardQuietZone.moduleWidth(
            renderedSide: maximumQRSide,
            moduleCount: worstCaseModuleCount
        )
        let clearance = SharedFilterCardQuietZone.additionalClearance(widestModule: module)
        // Four required, one already drawn inside the image.
        XCTAssertEqual(clearance, 3 * module, accuracy: 0.0001)
        XCTAssertTrue(SharedFilterCardQuietZone.isSufficient(clearance: clearance, moduleWidth: module))
    }

    /// The defect this fix closes: the old layout's vertical clear space.
    func testTheOldVerticalClearanceWouldBeRejected() {
        let module = SharedFilterCardQuietZone.moduleWidth(
            renderedSide: maximumQRSide,
            moduleCount: worstCaseModuleCount
        )
        // 4pt inset plus a 6pt gap was the entire clear space above the code.
        XCTAssertFalse(
            SharedFilterCardQuietZone.isSufficient(clearance: 10, moduleWidth: module),
            "10pt of white must not read as a four-module quiet zone."
        )
        XCTAssertFalse(SharedFilterCardQuietZone.isSufficient(clearance: 11, moduleWidth: module))
    }

    /// A clearance sized for the widest module must stay sufficient when the code
    /// resolves smaller — that one-directional property is what lets a constant inset
    /// guard a flexibly-sized code.
    func testClearanceSizedForTheMaximumCoversEverySmallerRender() {
        let widest = SharedFilterCardQuietZone.moduleWidth(
            renderedSide: maximumQRSide,
            moduleCount: worstCaseModuleCount
        )
        let clearance = SharedFilterCardQuietZone.additionalClearance(widestModule: widest)

        for side in stride(from: 120.0, through: 294.0, by: 6.0) {
            for moduleCount in [39.0, 43.0, 47.0, 55.0, 71.0] {
                let module = SharedFilterCardQuietZone.moduleWidth(
                    renderedSide: CGFloat(side),
                    moduleCount: CGFloat(moduleCount)
                )
                XCTAssertTrue(
                    SharedFilterCardQuietZone.isSufficient(clearance: clearance, moduleWidth: module),
                    "\(side)pt at \(moduleCount) modules must still clear the rule."
                )
            }
        }
    }

    func testDenserCodesNeedLessClearanceThanSparseOnes() {
        let sparse = SharedFilterCardQuietZone.additionalClearance(
            widestModule: SharedFilterCardQuietZone.moduleWidth(renderedSide: 294, moduleCount: 39)
        )
        let dense = SharedFilterCardQuietZone.additionalClearance(
            widestModule: SharedFilterCardQuietZone.moduleWidth(renderedSide: 294, moduleCount: 71)
        )
        XCTAssertGreaterThan(sparse, dense, "Fewer, fatter modules need a wider quiet zone.")
    }
}
