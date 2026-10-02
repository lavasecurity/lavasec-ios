import XCTest

final class AllowedExceptionsReminderSourceTests: XCTestCase {
    func testOverviewBannerRowSupportsOptInWrappingWithCenteredIcon() throws {
        let rootSource = try readSource(.lavaComponents)
        let bannerBlock = try sourceBlock(
            in: rootSource,
            startingAt: "struct LavaOverviewBannerRow: View",
            endingBefore: "struct LavaInfoPanel"
        )

        XCTAssertTrue(bannerBlock.contains("allowsTitleWrapping: Bool = false"))
        XCTAssertTrue(bannerBlock.contains("HStack(alignment: .center"))
        XCTAssertTrue(bannerBlock.contains(".lineLimit(titleLineLimit)"))
        XCTAssertTrue(bannerBlock.contains("private var titleLineLimit: Int?"))
        XCTAssertTrue(bannerBlock.contains("allowsTitleWrapping ? nil : 1"))
        XCTAssertTrue(bannerBlock.contains(".frame(minHeight: rowHeight)"))
        XCTAssertTrue(bannerBlock.contains(".frame(width: 28, height: 28)"))
    }
}
