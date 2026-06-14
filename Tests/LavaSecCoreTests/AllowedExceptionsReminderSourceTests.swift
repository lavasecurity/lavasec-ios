import XCTest

final class AllowedExceptionsReminderSourceTests: XCTestCase {
    func testAllowedExceptionsUsesCareReminderInsteadOfGuardrailPage() throws {
        let filtersSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let allowedExceptionsBlock = try Self.sourceBlock(
            in: filtersSource,
            startingAt: "private struct AllowedExceptionsDetailView",
            endingBefore: "private struct FilterEditToolbar"
        )

        XCTAssertTrue(allowedExceptionsBlock.contains("AllowedExceptionReminderPanel()"))
        XCTAssertTrue(filtersSource.contains("Be extra careful"))
        XCTAssertTrue(filtersSource.contains("title: \"Do you know this domain\""))
        XCTAssertTrue(filtersSource.contains("title: \"Is the domain spelling correct\""))
        XCTAssertTrue(filtersSource.contains("title: \"Is the domain flagged suspicious\""))
        XCTAssertFalse(filtersSource.contains("title: \"Do you know this domain?\""))
        XCTAssertFalse(filtersSource.contains("title: \"Is the domain spelling correct?\""))
        XCTAssertFalse(filtersSource.contains("title: \"Is the domain flagged suspicious?\""))
        XCTAssertFalse(filtersSource.contains("Do you know and trust this domain?"))
        XCTAssertFalse(filtersSource.contains("Is this site flagged as suspicious anywhere?"))
        XCTAssertFalse(filtersSource.contains("Has the domain been flagged suspicious anywhere?"))
        XCTAssertFalse(filtersSource.contains("Is it the exact site you meant to allow?"))
        XCTAssertFalse(filtersSource.contains("Does the spelling match the site you trust?"))
        XCTAssertFalse(filtersSource.contains("Can you confirm it from an official source?"))
        XCTAssertFalse(filtersSource.contains("Could allowing it bypass a blocklist you rely on?"))
        XCTAssertFalse(filtersSource.contains("ProtectionGuardrailsHelpView"))
        XCTAssertFalse(filtersSource.contains("Learn more about guardrails"))
    }

    func testAllowedExceptionReminderPointsUseOverviewBanners() throws {
        let filtersSource = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let reminderBlock = try Self.sourceBlock(
            in: filtersSource,
            startingAt: "private struct AllowedExceptionReminderPanel",
            endingBefore: "private struct LavaInlineInfoContent"
        )

        XCTAssertTrue(reminderBlock.contains("LavaOverviewBannerRow("))
        XCTAssertEqual(reminderBlock.components(separatedBy: "systemImage: \"questionmark.circle.fill\"").count - 1, 3)
        XCTAssertEqual(reminderBlock.components(separatedBy: "background: LavaStyle.lavaOrangeSoft").count - 1, 3)
        XCTAssertEqual(reminderBlock.components(separatedBy: "tint: LavaStyle.lavaOrange,\n                        background: LavaStyle.lavaOrangeSoft").count - 1, 3)
        XCTAssertFalse(reminderBlock.contains("systemImage: \"scope\""))
        XCTAssertFalse(reminderBlock.contains("systemImage: \"text.magnifyingglass\""))
        XCTAssertFalse(reminderBlock.contains("background: LavaStyle.softGreen"))
        XCTAssertFalse(reminderBlock.contains("background: LavaStyle.secondaryText.opacity(0.12)"))
        XCTAssertTrue(reminderBlock.contains("allowsTitleWrapping: true"))
        XCTAssertFalse(reminderBlock.contains("LavaDetailRow("))
    }

    func testOverviewBannerRowSupportsOptInWrappingWithCenteredIcon() throws {
        let rootSource = try Self.source(named: "RootView.swift", in: "LavaSecApp")
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
