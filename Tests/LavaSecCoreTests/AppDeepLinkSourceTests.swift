import XCTest

final class AppDeepLinkSourceTests: XCTestCase {
    func testAppDeclaresLavaDeepLinkEntrypoints() throws {
        let infoPlist = try Self.readAppSource("LavaSecApp/Info.plist")
        let entitlements = try Self.readAppSource("LavaSecApp/LavaSecApp.entitlements")
        let appSource = try Self.readAppSource("LavaSecApp/LavaSecApp.swift")

        XCTAssertTrue(infoPlist.contains("<string>lavasecurity</string>"))
        XCTAssertTrue(entitlements.contains("applinks:lavasecurity.app"))
        XCTAssertTrue(appSource.contains("static let lavaOpenDeepLinkURL"))
        XCTAssertTrue(appSource.contains("NotificationCenter.default.post(name: .lavaOpenDeepLinkURL, object: url)"))
        XCTAssertTrue(appSource.contains("GIDSignIn.sharedInstance.handle(url)"))
    }

    func testRootViewMapsDeepLinksToTabsAndSettingsRoutes() throws {
        let rootSource = try Self.readAppSource("LavaSecApp/RootView.swift")

        XCTAssertTrue(rootSource.contains("LavaAppDeepLink(url: url)"))
        XCTAssertTrue(rootSource.contains("private func handleDeepLink(_ deepLink: LavaAppDeepLink)"))
        XCTAssertTrue(rootSource.contains("case .guardPanel:"))
        XCTAssertTrue(rootSource.contains("case .filters:"))
        XCTAssertTrue(rootSource.contains("case .activity:"))
        XCTAssertTrue(rootSource.contains("case .settings(let settingsRoute):"))
        XCTAssertTrue(rootSource.contains("private extension SettingsRoute"))
        XCTAssertTrue(rootSource.contains("init?(_ deepLink: LavaSettingsDeepLink)"))
        XCTAssertTrue(rootSource.contains("case .upgrade:"))
        XCTAssertTrue(rootSource.contains("self = .upgrade"))
        XCTAssertTrue(rootSource.contains("case .dnsResolver:"))
        XCTAssertTrue(rootSource.contains("self = .dnsResolver"))
        XCTAssertTrue(rootSource.contains("case .feedback:"))
        XCTAssertTrue(rootSource.contains("self = .bugReport"))
    }

    func testSettingsHelpOpensCanonicalSupportPage() throws {
        let settingsSource = try Self.readAppSource("LavaSecApp/SettingsView.swift")
        let settingsBlock = try Self.sourceBlock(
            in: settingsSource,
            startingAt: "struct SettingsView: View",
            endingBefore: "private struct SettingsNavigationRow: View"
        )

        XCTAssertTrue(settingsSource.contains("private enum LavaWebLinks"))
        XCTAssertTrue(settingsSource.contains("static let support = URL(string: \"https://lavasecurity.app/support/\")!"))
        XCTAssertTrue(settingsBlock.contains("SettingsExternalLinkRow("))
        XCTAssertTrue(settingsBlock.contains("destination: LavaWebLinks.support"))
        XCTAssertTrue(settingsBlock.contains("title: \"Help\""))
        XCTAssertFalse(settingsSource.contains("case .help"))
        XCTAssertFalse(settingsSource.contains("private struct HelpSettingsView"))
        XCTAssertFalse(settingsSource.contains("private struct HelpArticleView"))
    }

    private static func readAppSource(_ relativePath: String) throws -> String {
        let current = URL(fileURLWithPath: #filePath)
        let packageRoot = current
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
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
