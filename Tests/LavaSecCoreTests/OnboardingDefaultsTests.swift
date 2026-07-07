import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class OnboardingDefaultsTests: XCTestCase {
    func testRecommendedOnboardingDefaultsUseDeviceDNSWithMullvadDoHFallback() {
        let defaults = AppConfiguration.lavaRecommendedDefaults

        XCTAssertEqual(defaults.resolverPresetID, DNSResolverPreset.device.id)
        XCTAssertTrue(defaults.usesEncryptedDeviceDNSFallback)
        XCTAssertEqual(defaults.fallbackResolverPreset.id, DNSResolverPreset.mullvadDoH.id)
    }

    func testSummaryUsesRecommendedOnboardingDefaults() {
        let summary = OnboardingDefaultsSummary(configuration: .lavaRecommendedDefaults)

        XCTAssertEqual(summary.blocklistText, "Block List Basic + 1 more")
        XCTAssertEqual(summary.resolverText, "Device DNS")
        XCTAssertEqual(summary.deviceDNSFallbackText, "Mullvad (DoH)")
        XCTAssertEqual(summary.localLoggingText, "Domain counts, domain history, and network activity")
        XCTAssertEqual(summary.accountText, "Continue without account")
    }

    func testSummaryReflectsCustomizedConfiguration() {
        let summary = OnboardingDefaultsSummary(
            configuration: AppConfiguration(
                enabledBlocklistIDs: [DefaultCatalog.blockListProjectBasic.id, DefaultCatalog.blockListProjectPhishing.id],
                resolverPresetID: DNSResolverPreset.quad9SecureDoH.id,
                fallbackToDeviceDNS: false,
                keepFilteringCounts: false,
                keepDomainDiagnostics: true,
                keepNetworkActivity: false
            )
        )

        XCTAssertEqual(summary.blocklistText, "Block List Basic + 1 more")
        XCTAssertEqual(summary.resolverText, "Quad9 Secure (DoH)")
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
