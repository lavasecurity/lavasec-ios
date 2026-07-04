import XCTest
@testable import LavaSecCore

final class BlocklistCatalogSizeSourceTests: XCTestCase {
    func testSizeBucketsExposeCompactLabels() {
        XCTAssertEqual(BlocklistSourceSizeBucket.small.abbreviation, "S")
        XCTAssertEqual(BlocklistSourceSizeBucket.medium.abbreviation, "M")
        XCTAssertEqual(BlocklistSourceSizeBucket.large.abbreviation, "L")
    }

    func testCatalogRowsUsePlainDomainCountWithLeadingSizeBucketPill() throws {
        let filtersViewSource = try readSource(.filtersView)
        let catalogListBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "BlocklistPickerList(",
            endingBefore: ".blocklistJumpAnchor(id: section.id)"
        )
        let pickerTextStackBlock = try sourceBlock(
            in: filtersViewSource,
            startingAt: "private struct BlocklistPickerTextStack: View",
            endingBefore: "private struct BlocklistPickerStatusPill"
        )
        let prefixRange = try XCTUnwrap(pickerTextStackBlock.range(of: "BlocklistPickerStatusPill(status: metadataPrefixStatus)"))
        let metadataRange = try XCTUnwrap(pickerTextStackBlock.range(of: "Text(metadata.lavaLocalized)"))

        XCTAssertTrue(catalogListBlock.contains("items: section.items"))
        XCTAssertTrue(catalogListBlock.contains("catalogMetadata: viewModel.blocklistRuleCountText(for:)"))
        XCTAssertTrue(catalogListBlock.contains("catalogMetadataPrefixStatus: blocklistSizeStatus(for:)"))
        XCTAssertFalse(catalogListBlock.contains("status: blocklistSizeStatus(for:)"))
        XCTAssertLessThan(prefixRange.lowerBound, metadataRange.lowerBound)
    }

    func testCondensedListRendersMetadataPrefixStatusBeforePlainMetadata() throws {
        let listSource = try readSource(.lavaCondensedList)
        let metadataRowBlock = try sourceBlock(
            in: listSource,
            startingAt: "HStack(spacing: 8)",
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
