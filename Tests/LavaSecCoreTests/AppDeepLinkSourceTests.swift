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

    func testDeepLinkHandlerStagesImportAndNeverMutates() throws {
        let rootSource = try Self.readAppSource("LavaSecApp/RootView.swift")
        let handlerBlock = try Self.sourceBlock(
            in: rootSource,
            startingAt: "private func handleDeepLink(_ deepLink: LavaAppDeepLink)",
            endingBefore: "private static func importStartMode"
        )

        // The import on-ramp only *presents* the importer — it sets the sheet
        // state and never applies a change directly from the handler.
        XCTAssertTrue(handlerBlock.contains("case .importFilters(let entry):"))
        XCTAssertTrue(handlerBlock.contains("importDeepLinkPresentation = ImportDeepLinkPresentation("))

        // The deeplink-opened importer runs the same protected apply gate as the
        // in-app Filters entry point: fresh auth on the filter-editing surface.
        XCTAssertTrue(rootSource.contains("ImportFiltersFlow("))
        XCTAssertTrue(rootSource.contains("requireFreshAuthentication(for: .filterEditing, reason: \"Import filter\")"))

        // The importer sheet presents above the app-unlock overlay, so it must be
        // withheld until App Unlock is satisfied — otherwise a locked device could
        // reach filter replacement (an import replaces the block-side config)
        // without unlocking. The handler kicks the unlock prompt, and the sheet
        // binding reads nil while unlock is pending.
        XCTAssertTrue(handlerBlock.contains("authenticateAppUnlockIfNeeded"))
        XCTAssertTrue(rootSource.contains("var importDeepLinkSheetItem: Binding<ImportDeepLinkPresentation?>"))
        // Gate covers both the lock overlay and the app-switcher privacy mask so
        // the importer never sits above the lock nor lands in the .inactive snapshot.
        XCTAssertTrue(rootSource.contains("(security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible) ? nil : importDeepLinkPresentation"))
        XCTAssertTrue(rootSource.contains(".sheet(item: importDeepLinkSheetItem)"))

        // The feedback deeplink stages the bug-report sheet (the same surface as
        // the rage-shake gesture). That sheet previews diagnostics and can submit
        // a report. Unlike the importer it carries an accumulating draft, so it is
        // kept MOUNTED across an App Unlock lock (so the draft survives) and the
        // form paints its own opaque, hit-blocking mask while unlock is pending
        // (see BugReportSettingsView). The handler stages the destination and
        // kicks the unlock prompt so the mask drops once the device is unlocked.
        XCTAssertTrue(handlerBlock.contains("case .feedback = settingsRoute"))
        XCTAssertTrue(handlerBlock.contains("viewModel.rageShakeDestination = .bugReport"))
        XCTAssertTrue(rootSource.contains(".sheet(item: $viewModel.rageShakeDestination)"))
        // The feedback sheet is masked-in-place, NOT withheld — there must be no
        // nil-gate binding that would tear the sheet (and its draft) down on lock.
        XCTAssertFalse(rootSource.contains("var rageShakeSheetItem: Binding<RageShakeDestination?>"))

        // No hot-path mutation may be reachable from the deeplink handler. If a
        // future change wires one of these in, this test fails loudly.
        let forbiddenMutations = [
            "applyImportedShareableConfiguration",
            "setResolver",
            "setCustomResolverAddresses",
            "addAllowedDomain",
            "removeAllowedDomain",
            "removeBlocklist",
            "removeCustomBlocklist",
            "applyOnboardingRecommendedDefaults",
        ]
        for symbol in forbiddenMutations {
            XCTAssertFalse(
                handlerBlock.contains(symbol),
                "Deeplink handler must not call hot-path mutation \(symbol)"
            )
        }
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
