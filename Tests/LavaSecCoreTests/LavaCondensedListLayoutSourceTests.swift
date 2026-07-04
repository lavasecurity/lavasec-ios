import XCTest

final class LavaCondensedListLayoutSourceTests: XCTestCase {
    func testMetadataLineReservesStableHeightForStatusPills() throws {
        let listSource = try readSource(.lavaCondensedList)
        let itemBlock = try sourceBlock(
            in: listSource,
            startingAt: "struct LavaCondensedListItem<Leading: View>: View",
            endingBefore: "extension LavaCondensedListItem"
        )
        let pillBlock = try sourceBlock(
            in: listSource,
            startingAt: "private struct LavaCondensedStatusPill: View"
        )

        XCTAssertTrue(listSource.contains("private enum LavaCondensedListMetrics"))
        XCTAssertTrue(listSource.contains("static let metadataLineMinHeight: CGFloat = 20"))
        XCTAssertTrue(
            itemBlock.contains(".frame(minHeight: LavaCondensedListMetrics.metadataLineMinHeight, alignment: .center)"),
            "Metadata rows should reserve the same height whether a status pill is present or not."
        )
        XCTAssertTrue(
            pillBlock.contains(".frame(minHeight: LavaCondensedListMetrics.metadataLineMinHeight)"),
            "Status pills should fit inside the reserved metadata line instead of changing row height."
        )
    }

    func testInactiveRowsDoNotDrawThroughLongBlocklistTitles() throws {
        let listSource = try readSource(.lavaCondensedList)
        let itemBlock = try sourceBlock(
            in: listSource,
            startingAt: "struct LavaCondensedListItem<Leading: View>: View",
            endingBefore: "extension LavaCondensedListItem"
        )

        XCTAssertFalse(
            itemBlock.contains(".strikethrough("),
            "Pending-removal rows already use dimming and a status pill; strikethrough clips long blocklist names."
        )
    }
}
