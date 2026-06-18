import XCTest
@testable import LavaSecCore

final class OnboardingDefaultsTests: XCTestCase {
    func testSummaryUsesRecommendedOnboardingDefaults() {
        let summary = OnboardingDefaultsSummary(configuration: .lavaRecommendedDefaults)

        XCTAssertEqual(summary.blocklistText, "Block List Project Phishing + 1 more")
        XCTAssertEqual(summary.resolverText, "Device DNS")
        XCTAssertEqual(summary.deviceDNSFallbackText, "On")
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
}
