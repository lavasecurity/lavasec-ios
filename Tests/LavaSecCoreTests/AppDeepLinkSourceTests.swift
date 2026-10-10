import XCTest

final class AppDeepLinkSourceTests: XCTestCase {
    func testAppDeclaresLavaDeepLinkEntrypoints() throws {
        let infoPlist = try readSource(.appInfoPlist)
        let entitlements = try readSource(.appEntitlements)
        let appSource = try readSource(.lavaSecApp)

        XCTAssertTrue(infoPlist.contains("<string>lavasecurity</string>"))
        XCTAssertTrue(entitlements.contains("applinks:lavasecurity.app"))
        XCTAssertTrue(appSource.contains("static let lavaOpenDeepLinkURL"))
        XCTAssertTrue(appSource.contains("NotificationCenter.default.post(name: .lavaOpenDeepLinkURL, object: url)"))
        XCTAssertTrue(appSource.contains("GIDSignIn.sharedInstance.handle(url)"))
    }

    func testRootViewMapsDeepLinksToTabsAndSettingsRoutes() throws {
        let rootSource = try readSource(.rootView)

        XCTAssertTrue(rootSource.contains("LavaAppDeepLink(url: url)"))
        XCTAssertTrue(rootSource.contains("private func handleDeepLink(_ deepLink: LavaAppDeepLink)"))
        XCTAssertTrue(rootSource.contains("case .guardPanel:"))
        XCTAssertTrue(rootSource.contains("case .filters:"))
        XCTAssertTrue(rootSource.contains("case .activity:"))
        XCTAssertTrue(rootSource.contains("case .settings(let settingsRoute):"))
        XCTAssertTrue(rootSource.contains("private extension SettingsRoute"))
        // Pin the mapping arms inside `SettingsRoute(deepLink:)` itself: the bare
        // `case ...:` spellings also appear in `forwardReactNavigation`, so a
        // whole-file match would pass without the mapping (Kilo, PR #786). The
        // sourceBlock throws if the initializer disappears entirely.
        let settingsRouteMapping = try sourceBlock(
            in: rootSource,
            startingAt: "init?(_ deepLink: LavaSettingsDeepLink)",
            endingBefore: "struct BugReportSheetView"
        )
        XCTAssertTrue(settingsRouteMapping.contains("case .upgrade:"))
        XCTAssertTrue(settingsRouteMapping.contains("self = .upgrade"))
        XCTAssertTrue(settingsRouteMapping.contains("case .dnsResolver:"))
        XCTAssertTrue(settingsRouteMapping.contains("self = .dnsResolver"))
        XCTAssertTrue(settingsRouteMapping.contains("case .feedback:"))
        XCTAssertTrue(settingsRouteMapping.contains("self = .bugReport"))
        // Every user-facing SettingsRoute must be reachable from the URL parser;
        // Customization and Network Activity were the two that had no link.
        XCTAssertTrue(settingsRouteMapping.contains("case .customization:"))
        XCTAssertTrue(settingsRouteMapping.contains("self = .customization"))
        XCTAssertTrue(settingsRouteMapping.contains("case .networkActivity:"))
        XCTAssertTrue(settingsRouteMapping.contains("self = .networkActivity"))
    }

    func testExploreDeepLinkUsesGuardStackAndAppSettingsGate() throws {
        let root = try readSource(.rootView)
        let bridge = try readSource(.reactNativeAppBridge)
        XCTAssertTrue(root.contains("guardNavigationPath = [.explore]"))
        XCTAssertTrue(root.contains("case .explore: screen = \"Explore\""))
        // The auth prompt names the destination the link actually opens; reusing
        // the Settings reason would misdescribe an Explore deep link.
        XCTAssertTrue(bridge.contains("if tab == \"SettingsTab\" || screen == \"Explore\" { try await authorize(.appSettings, screen == \"Explore\" ? \"Explore\" : \"Open Settings\", fresh: false) }"))
        // Revalidate both the request and the onboarding destination after auth.
        let postAuthentication = try sourceBlock(in: bridge, startingAt: "if screen == \"Security\"", endingBefore: "navigation = [\"serial\"")
        XCTAssertTrue(postAuthentication.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .contains("guard serial == navigationSerial, targetsGuard || onboardingVisit?.keepsGuardVisible != true else { return }"))
    }

    func testDeepLinkHandlerStagesImportAndNeverMutates() throws {
        let rootSource = try readSource(.rootView)
        let handlerBlock = try sourceBlock(
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
        XCTAssertTrue((try readSource(.reactNativeAppFlows)).contains("ImportFiltersFlow("))
        XCTAssertTrue((try readSource(.reactNativeAppFlows)).contains("requireFreshAuthentication(for: .filterEditing, reason: \"Import filter\")"))

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

        // RN UIKit sheets use the topmost presenter, while the native reference
        // keeps the same binding. External imports still pass through the gated
        // importDeepLinkSheetItem, and cannot bypass its App Unlock check.
        XCTAssertTrue(rootSource.contains("let presentation = importDeepLinkSheetItem.wrappedValue"))
        XCTAssertTrue(rootSource.contains("importStartMode: presentation.startMode"))

        // A Feedback deep link follows the guarded Settings route. The Settings
        // row and rage shake open the native sheet without bypassing this gate.
        XCTAssertTrue(handlerBlock.contains("guard let route = SettingsRoute(settingsRoute)"))
        XCTAssertTrue(handlerBlock.contains("openSettingsRoute(route)"))
        XCTAssertFalse(handlerBlock.contains("reports.rageShakeDestination = .bugReport"))
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
        // Canary: the negative pins above key on the rage-shake destination - if the sheet
        // binding is renamed or removed, those pins pass vacuously. Anchored to the live
        // sheet-item shape (a bare "RageShakeDestination" match would be satisfied by the
        // dismissRageShakeDestination() method-name substring).
    }

    func testSettingsHelpOpensCanonicalSupportPage() throws {
        let settingsSource = try readSource(.settingsCommon)
        let settingsBlock = try sourceBlock(
            in: readSource(.reactNativeSettingsScreens),
            startingAt: "<SettingsGroup title=\"Support\">",
            endingBefore: "</SettingsGroup>"
        )

        XCTAssertTrue(settingsSource.contains("enum LavaWebLinks"))
        XCTAssertTrue(settingsSource.contains("static let support = URL(string: \"https://lavasecurity.app/support/\")!"))
        XCTAssertTrue(settingsBlock.contains("title=\"Help\""))
        XCTAssertTrue(settingsBlock.contains("https://lavasecurity.app/support/"))
        XCTAssertFalse(settingsSource.contains("case .help"))
        XCTAssertFalse(settingsSource.contains("private struct HelpSettingsView"))
        XCTAssertFalse(settingsSource.contains("private struct HelpArticleView"))
    }
}
