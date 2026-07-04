import XCTest

final class AllowedExceptionsReminderSourceTests: XCTestCase {
    func testAllowedExceptionCautionLivesInReviewSheetNotGuardrailPage() throws {
        let reviewSource = try readSource(.filterReviewFlowView)
        let confirmationBlock = try sourceBlock(
            in: reviewSource,
            startingAt: "struct FilterConfirmationSheet: View",
            endingBefore: "struct DiffGroup: View"
        )

        // The "be extra careful" caution is surfaced in the review sheet — gated to
        // changes that actually add an allowed exception — not as a standalone panel
        // on the My list cover, and not a separate guardrail page.
        XCTAssertTrue(confirmationBlock.contains("if !diff.addedAllowedDomains.isEmpty {"))
        XCTAssertTrue(confirmationBlock.contains("title: \"Be extra careful\""))
        XCTAssertTrue(confirmationBlock.contains("Allowed exceptions let a site through even when a blocklist would catch it."))

        let filtersSource = try readSource(.filtersView)
        XCTAssertFalse(filtersSource.contains("AllowedExceptionReminderPanel"))
        XCTAssertFalse(filtersSource.contains("ProtectionGuardrailsHelpView"))
        XCTAssertFalse(filtersSource.contains("Learn more about guardrails"))
    }

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
        XCTAssertTrue(bannerBlock.contains(".frame(height: rowHeight)"))
        XCTAssertTrue(bannerBlock.contains(".frame(width: 28, height: 28)"))
    }
}
