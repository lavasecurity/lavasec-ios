import XCTest

final class LavaCondensedListLayoutSourceTests: XCTestCase {
    func testMetadataLineReservesStableHeightForStatusPills() throws {
        let listSource = try Self.source(named: "LavaCondensedList.swift", in: "LavaSecApp")
        let itemBlock = try Self.sourceBlock(
            in: listSource,
            startingAt: "struct LavaCondensedListItem<Leading: View>: View",
            endingBefore: "extension LavaCondensedListItem"
        )
        let pillBlock = try Self.sourceBlock(
            in: listSource,
            startingAt: "private struct LavaCondensedStatusPill: View",
            endingBefore: "*** end ***"
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
        let listSource = try Self.source(named: "LavaCondensedList.swift", in: "LavaSecApp")
        let itemBlock = try Self.sourceBlock(
            in: listSource,
            startingAt: "struct LavaCondensedListItem<Leading: View>: View",
            endingBefore: "extension LavaCondensedListItem"
        )

        XCTAssertFalse(
            itemBlock.contains(".strikethrough("),
            "Pending-removal rows already use dimming and a status pill; strikethrough clips long blocklist names."
        )
    }

    private static func source(named fileName: String, in directoryName: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL
            .appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func sourceBlock(
        in source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        guard endMarker != "*** end ***" else {
            return String(suffix)
        }

        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }
}
