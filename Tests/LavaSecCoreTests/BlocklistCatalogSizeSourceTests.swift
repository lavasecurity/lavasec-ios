import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class BlocklistCatalogSizeSourceTests: XCTestCase {
    func testSizeBucketsExposeCompactLabels() {
        XCTAssertEqual(BlocklistSourceSizeBucket.small.abbreviation, "S")
        XCTAssertEqual(BlocklistSourceSizeBucket.medium.abbreviation, "M")
        XCTAssertEqual(BlocklistSourceSizeBucket.large.abbreviation, "L")
    }

    func testCondensedListRendersMetadataPrefixStatusBeforePlainMetadata() throws {
        let listSource = try readSource(.lavaCondensedList)
        let metadataRowBlock = try sourceBlock(
            in: listSource,
            startingAt: "HStack(spacing: LavaSpacing.sm)",
            endingBefore: ".fixedSize(horizontal: false, vertical: true)"
        )

        let prefixRange = try XCTUnwrap(metadataRowBlock.range(of: "metadataPrefixStatus"))
        let metadataRange = try XCTUnwrap(metadataRowBlock.range(of: "if let metadata {"))
        let trailingStatusRange = try XCTUnwrap(metadataRowBlock.range(of: "if let status"))

        XCTAssertLessThan(prefixRange.lowerBound, metadataRange.lowerBound)
        XCTAssertLessThan(metadataRange.lowerBound, trailingStatusRange.lowerBound)
    }

    func testBlocklistSizeStatusUsesBucketAbbreviationInsteadOfDomainCount() throws {
        let listSource = try readSource(.lavaCondensedList)
        let statusBlock = try sourceBlock(
            in: listSource,
            startingAt: "static func blocklistSize",
            endingBefore: "struct LavaCondensedTrailingAction"
        )

        XCTAssertTrue(statusBlock.contains("bucket.abbreviation"))
        XCTAssertFalse(statusBlock.contains("\"%@ domains\""))
    }
}
