import Foundation
import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class FilterConfigurationDiffTests: XCTestCase {
    func testDiffGroupsAddedAndRemovedValues() {
        let old = FilterConfigurationSelection(
            enabledBlocklistIDs: ["hagezi", "malware"],
            blockedDomains: ["old-block.example"],
            allowedDomains: ["old-allow.example"]
        )
        let new = FilterConfigurationSelection(
            enabledBlocklistIDs: ["hagezi", "scam"],
            blockedDomains: ["new-block.example"],
            allowedDomains: ["old-allow.example", "new-allow.example"]
        )

        let diff = FilterConfigurationDiff(from: old, to: new)

        XCTAssertEqual(diff.addedBlocklistIDs, ["scam"])
        XCTAssertEqual(diff.removedBlocklistIDs, ["malware"])
        XCTAssertEqual(diff.addedBlockedDomains, ["new-block.example"])
        XCTAssertEqual(diff.removedBlockedDomains, ["old-block.example"])
        XCTAssertEqual(diff.addedAllowedDomains, ["new-allow.example"])
        XCTAssertEqual(diff.removedAllowedDomains, [])
        XCTAssertEqual(diff.changeCount, 5)
        XCTAssertFalse(diff.isEmpty)
    }

    func testEmptyDiff() {
        let selection = FilterConfigurationSelection(
            enabledBlocklistIDs: ["hagezi"],
            blockedDomains: ["block.example"],
            allowedDomains: ["allow.example"]
        )

        let diff = FilterConfigurationDiff(from: selection, to: selection)

        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.changeCount, 0)
    }
}
