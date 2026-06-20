import XCTest

final class AllowedExceptionsReminderSourceTests: XCTestCase {
    func testAllowedExceptionCautionLivesInReviewSheetNotGuardrailPage() throws {
        let reviewSource = try Self.source(named: "FilterReviewFlowView.swift", in: "LavaSecApp")
        let confirmationBlock = try Self.sourceBlock(
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

        let filtersSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        XCTAssertFalse(filtersSource.contains("AllowedExceptionReminderPanel"))
        XCTAssertFalse(filtersSource.contains("ProtectionGuardrailsHelpView"))
        XCTAssertFalse(filtersSource.contains("Learn more about guardrails"))
    }

    func testOverviewBannerRowSupportsOptInWrappingWithCenteredIcon() throws {
        let rootSource = try Self.source(named: "LavaComponents.swift", in: "LavaSecApp/LavaDesignSystem")
        let bannerBlock = try Self.sourceBlock(
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
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)

        return String(suffix[..<end])
    }
}
