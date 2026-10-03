import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class OnboardingDefaultsTests: XCTestCase {
    func testRecommendedOnboardingDefaultsUseDeviceDNSWithQuad9DoHFallback() {
        let defaults = AppConfiguration.lavaRecommendedDefaults

        XCTAssertEqual(defaults.resolverPresetID, DNSResolverPreset.device.id)
        XCTAssertTrue(defaults.usesEncryptedDeviceDNSFallback)
        XCTAssertEqual(defaults.fallbackResolverPreset.id, DNSResolverPreset.quad9UnfilteredDoH.id)
    }

    func testAppBootstrapUsesEffectiveOnboardingDNSWithoutChangingOtherDefaults() {
        var expected = AppConfiguration()
        expected.resolverPresetID = DNSResolverPreset.device.id
        expected.usesEncryptedDeviceDNSFallback = true
        expected.fallbackResolverPresetID = DNSResolverPreset.quad9UnfilteredDoH.id
        XCTAssertEqual(AppConfiguration.lavaAppInitialDefaults, expected)
        XCTAssertEqual(AppConfiguration().resolverPresetID, DNSResolverPreset.quad9UnfilteredDoH.id,
                       "Other processes and decoder compatibility keep the original model defaults.")
    }

    func testInterruptedFreshOnboardingKeepsDNSDefaultsAndLaterToggleChoice() throws {
        var firstLaunch = AppConfiguration.lavaAppInitialDefaults
        // Initial bootstrap / VPN-profile persistence occurs before the DNS step.
        var resumed = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(firstLaunch))
        XCTAssertEqual(resumed.resolverPresetID, DNSResolverPreset.device.id)
        XCTAssertTrue(resumed.usesEncryptedDeviceDNSFallback)
        resumed.applyOnboardingEncryptedFallback(false)
        firstLaunch = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(resumed))
        XCTAssertEqual(firstLaunch.resolverPresetID, DNSResolverPreset.device.id)
        XCTAssertFalse(firstLaunch.usesEncryptedDeviceDNSFallback)
        XCTAssertEqual(firstLaunch.fallbackResolverPresetID, DNSResolverPreset.quad9UnfilteredDoH.id)
    }

    func testAppBootstrapLoadsSavedDNSOverInitialDefaultsWithoutMigration() throws {
        let app = try readAppViewModelSource()
        XCTAssertTrue(app.contains("@Published var configuration = AppConfiguration.lavaAppInitialDefaults"))
        let load = try sourceBlock(in: app, startingAt: "func loadPersistedConfiguration()", endingBefore: "func reloadSharedStateIfBlockedByDataProtection()")
        XCTAssertTrue(load.contains("case .loaded(let persistedConfiguration):\n                configuration = persistedConfiguration"))
        XCTAssertFalse(load.contains("lavaAppInitialDefaults"), "A reload must accept saved settings, not reapply setup defaults.")
        XCTAssertTrue(load.contains("sharedStateUnavailableAtLoad = true"), "Unreadable state remains protected by the existing writer fence.")
    }

    func testFallbackTogglePreservesEveryOtherSavedSetting() {
        for provider in [DNSResolverPreset.quad9UnfilteredDoH.id, DNSResolverPreset.quad9SecureDoH.id, DNSResolverPreset.customID] {
            for enabled in [false, true] {
                var saved = AppConfiguration.lavaRecommendedDefaults
                saved.resolverPresetID = DNSResolverPreset.customID
                saved.customResolverAddress = "https://primary.example/dns-query"
                saved.customResolverName = "My primary"
                saved.fallbackResolverPresetID = provider
                saved.fallbackCustomResolverAddress = "https://backup.example/dns-query"
                saved.fallbackCustomResolverSecondaryAddress = "https://secondary.example/dns-query"
                saved.fallbackCustomResolverName = "My backup"
                saved.fallbackToDeviceDNS = false
                saved.usesEncryptedDeviceDNSFallback = !enabled
                var expected = saved
                expected.usesEncryptedDeviceDNSFallback = enabled
                saved.applyOnboardingEncryptedFallback(enabled)
                XCTAssertEqual(saved, expected, "Setup must change only its visible fallback toggle, including for a saved custom provider.")
            }
        }
    }

    func testOnboardingFallbackViewSeedsSavedStateAndUsesNarrowPersistBoundary() throws {
        let flow = try readSource(.onboardingFlowView)
        XCTAssertTrue(flow.contains("useEncryptedFallback = viewModel.configuration.usesEncryptedDeviceDNSFallback"))
        XCTAssertTrue(flow.contains("if !isMock && !hasLoadedConnectionChoice {"))
        XCTAssertFalse(flow.contains("@State private var fallbackResolverPresetID"))
        let app = try readAppViewModelSource()
        let apply = try sourceBlock(in: app, startingAt: "func applyOnboardingConnectionPreferences(", endingBefore: "func selectOnboardingBlocklists(")
        XCTAssertTrue(apply.contains("configuration.applyOnboardingEncryptedFallback(useEncryptedFallback)"))
        XCTAssertTrue(apply.contains("if persistImmediately {"))
        XCTAssertTrue(apply.contains("persistFilterChanges()"))
        XCTAssertFalse(apply.contains("configuration.resolverPresetID ="))
        XCTAssertFalse(apply.contains("configuration.fallbackResolverPresetID ="))
    }

    func testSummaryUsesRecommendedOnboardingDefaults() {
        let summary = OnboardingDefaultsSummary(configuration: .lavaRecommendedDefaults)

        XCTAssertEqual(summary.blocklistText, "Block List Basic + 1 more")
        XCTAssertEqual(summary.resolverText, "Device DNS")
        XCTAssertEqual(summary.deviceDNSFallbackText, "Quad9 (DoH)")
        XCTAssertEqual(summary.localLoggingText, "Domain counts, domain history, and network activity")
        XCTAssertEqual(summary.accountText, "Continue without account")
    }

    func testSummaryReflectsCustomizedConfiguration() {
        let summary = OnboardingDefaultsSummary(
            configuration: AppConfiguration(
                enabledBlocklistIDs: [DefaultCatalog.blockListProjectBasic.id, DefaultCatalog.blockListProjectPhishing.id],
                resolverPresetID: DNSResolverPreset.quad9UnfilteredDoH.id,
                fallbackToDeviceDNS: false,
                keepFilteringCounts: false,
                keepDomainDiagnostics: true,
                keepNetworkActivity: false
            )
        )

        XCTAssertEqual(summary.blocklistText, "Block List Basic + 1 more")
        XCTAssertEqual(summary.resolverText, "Quad9 (DoH)")
        XCTAssertEqual(summary.deviceDNSFallbackText, "Off")
        XCTAssertEqual(summary.localLoggingText, "Domain history")
    }

    // MARK: - Protection-level lever (onboarding Step 1)

    func testEssentialStopIsTheSecuritySubsetOfTheDefaults() {
        // Essential = the security-category defaults only (Block List Basic today).
        XCTAssertEqual(
            OnboardingProtectionLevel.essential.enabledBlocklistIDs(),
            [DefaultCatalog.blockListProjectBasic.id]
        )
        XCTAssertEqual(OnboardingProtectionLevel.essential.enabledCategories(), [.security])
    }

    func testBalancedStopEqualsTheCatalogRecommendedDefault() {
        // THE load-bearing invariant: the recommended one-tap stop == the catalog default,
        // so tapping straight through onboarding yields the fresh-install recommended config.
        XCTAssertEqual(OnboardingProtectionLevel.recommended, .balanced)
        XCTAssertEqual(
            OnboardingProtectionLevel.balanced.enabledBlocklistIDs(),
            DefaultCatalog.recommendedDefaultSourceIDs
        )
        XCTAssertEqual(
            OnboardingProtectionLevel.balanced.enabledBlocklistIDs(),
            [DefaultCatalog.blockListProjectBasic.id, DefaultCatalog.stevenBlackUnifiedHosts.id]
        )
        XCTAssertEqual(OnboardingProtectionLevel.balanced.enabledCategories(), [.security, .multiPurpose])
    }

    func testComprehensiveStopAddsTheAdsTrackingCategory() {
        let balanced = OnboardingProtectionLevel.balanced.enabledBlocklistIDs()
        let comprehensive = OnboardingProtectionLevel.comprehensive.enabledBlocklistIDs()
        let adsTrackingIDs = Set(
            DefaultCatalog.curatedSources.filter { $0.category == .adsTracking }.map(\.id)
        )
        XCTAssertFalse(adsTrackingIDs.isEmpty)
        XCTAssertEqual(comprehensive, balanced.union(adsTrackingIDs))
        XCTAssertEqual(
            OnboardingProtectionLevel.comprehensive.enabledCategories(),
            [.security, .multiPurpose, .adsTracking]
        )
    }

    func testProtectionLevelsAreCumulative() {
        let essential = OnboardingProtectionLevel.essential.enabledBlocklistIDs()
        let balanced = OnboardingProtectionLevel.balanced.enabledBlocklistIDs()
        let comprehensive = OnboardingProtectionLevel.comprehensive.enabledBlocklistIDs()
        XCTAssertTrue(essential.isSubset(of: balanced))
        XCTAssertTrue(balanced.isSubset(of: comprehensive))
        XCTAssertTrue(essential.isStrictSubset(of: comprehensive))
    }

    func testNoProtectionLevelEnablesAGPLOrNonCatalogSource() {
        // Every stop must stay within the catalog and never enable a GPL list (the
        // default/recommended path must remain permissively licensed at every stop).
        let catalogByID = Dictionary(uniqueKeysWithValues: DefaultCatalog.curatedSources.map { ($0.id, $0) })
        for level in OnboardingProtectionLevel.allCases {
            for id in level.enabledBlocklistIDs() {
                let source = catalogByID[id]
                XCTAssertNotNil(source, "\(level) enabled unknown source \(id)")
                XCTAssertFalse(source!.licenseName.hasPrefix("GPL"), "\(level) enabled GPL source \(id)")
            }
        }
    }
}
