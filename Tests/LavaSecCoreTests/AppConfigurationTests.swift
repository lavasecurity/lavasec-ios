import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class AppConfigurationTests: XCTestCase {
    func testFreshConfigurationStartsWithoutGPLBlocklists() {
        XCTAssertTrue(AppConfiguration().enabledBlocklistIDs.isEmpty)
    }

    func testDeviceDNSFallbackDefaultsOnForFreshConfiguration() {
        XCTAssertTrue(AppConfiguration().fallbackToDeviceDNS)
    }

    func testEncryptedDeviceDNSFallbackDefaultsOffForFreshConfiguration() {
        // Enabling a third-party encrypted resolver for a Device-DNS primary is an
        // explicit opt-in; it must never be on without the user choosing it.
        XCTAssertFalse(AppConfiguration().usesEncryptedDeviceDNSFallback)
    }

    func testLocalLogPreferencesDefaultToKeepingCountsDomainHistoryNetworkActivityAndGuardProgress() {
        let configuration = AppConfiguration()

        XCTAssertTrue(configuration.keepFilteringCounts)
        XCTAssertTrue(configuration.keepDomainDiagnostics)
        XCTAssertTrue(configuration.keepNetworkActivity)
        XCTAssertTrue(configuration.keepLavaGuardProgress)
        XCTAssertTrue(configuration.lavaGuardUnlocks.records.isEmpty)
    }

    func testLegacyConfigurationWithoutDeviceDNSFallbackDefaultsToOn() throws {
        let data = Data("""
        {
          "protectionEnabled": true,
          "enabledBlocklistIDs": ["hagezi-multi-pro-mini"],
          "allowedDomains": [],
          "blockedDomains": [],
          "resolverPresetID": "google-public-dns",
          "keepDomainDiagnostics": false,
          "isPaid": false
        }
        """.utf8)

        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertTrue(configuration.fallbackToDeviceDNS)
        XCTAssertTrue(configuration.keepFilteringCounts)
        XCTAssertTrue(configuration.keepNetworkActivity)
        XCTAssertTrue(configuration.customBlocklists.isEmpty)
    }

    func testLegacyHapticFeedbackPreferenceIsIgnored() throws {
        let data = Data("""
        {
          "protectionEnabled": false,
          "enabledBlocklistIDs": [],
          "allowedDomains": [],
          "blockedDomains": [],
          "resolverPresetID": "google-public-dns",
          "keepDomainDiagnostics": false,
          "playsHapticFeedback": false,
          "isPaid": false
        }
        """.utf8)

        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
        let encoded = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)

        XCTAssertFalse(encoded.contains("playsHapticFeedback"))
    }

    func testDeviceDNSFallbackRoundTrips() throws {
        let configuration = AppConfiguration(fallbackToDeviceDNS: true)

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertTrue(decoded.fallbackToDeviceDNS)
    }

    func testFallbackResolverSelectionDefaultsToMullvadDoH() {
        let configuration = AppConfiguration()
        XCTAssertEqual(configuration.fallbackResolverPresetID, DNSResolverPreset.mullvadDoH.id)
        XCTAssertEqual(configuration.fallbackResolverPreset, .mullvadDoH)
    }

    func testFallbackResolverSelectionRoundTripsAndResolves() throws {
        let configuration = AppConfiguration(
            usesEncryptedDeviceDNSFallback: true,
            fallbackResolverPresetID: DNSResolverPreset.customID,
            fallbackCustomResolverAddress: "https://fallback.example/dns-query",
            fallbackCustomResolverName: " My Fallback "
        )

        let decoded = try JSONDecoder().decode(
            AppConfiguration.self,
            from: try JSONEncoder().encode(configuration)
        )

        XCTAssertTrue(decoded.usesEncryptedDeviceDNSFallback)
        XCTAssertEqual(decoded.fallbackResolverPresetID, DNSResolverPreset.customID)
        XCTAssertEqual(decoded.fallbackResolverPreset.displayName, "My Fallback")
        XCTAssertEqual(decoded.fallbackResolverPreset.dohEndpoints.map { $0.url.absoluteString }, [
            "https://fallback.example/dns-query"
        ])
    }

    func testRetiredDNSSBFallbackSelectionMigratesToMullvad() throws {
        let data = Data("""
        { "fallbackResolverPresetID": "dns-sb-doh" }
        """.utf8)
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
        XCTAssertEqual(configuration.fallbackResolverPresetID, DNSResolverPreset.mullvadDoH.id)
    }

    func testAppConfigurationResolvesDeviceDNSResolverIDFromCatalog() throws {
        let configuration = AppConfiguration(resolverPresetID: DNSResolverPreset.device.id)

        XCTAssertEqual(configuration.resolverPreset, .device)
    }

    func testAppConfigurationAppliesCustomResolverDisplayNameButKeepsDiagnosticsGeneric() throws {
        let configuration = AppConfiguration(
            resolverPresetID: DNSResolverPreset.customID,
            customResolverAddress: "https://dns.example/dns-query",
            customResolverSecondaryAddress: "https://backup.example/dns-query",
            customResolverName: " Home DNS "
        )

        XCTAssertEqual(configuration.resolverPreset.displayName, "Home DNS")
        XCTAssertEqual(configuration.resolverPreset.shortDisplayName, "Home DNS")
        XCTAssertEqual(configuration.resolverDiagnosticDisplayName, "Custom DNS")
        XCTAssertEqual(configuration.resolverPreset.dohEndpoints.map { $0.url.absoluteString }, [
            "https://dns.example/dns-query",
            "https://backup.example/dns-query"
        ])
    }

    func testCustomResolverSecondaryAddressRoundTrips() throws {
        let configuration = AppConfiguration(
            resolverPresetID: DNSResolverPreset.customID,
            customResolverAddress: "9.9.9.9",
            customResolverSecondaryAddress: "2620:fe::fe",
            customResolverName: "Home DNS"
        )

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertEqual(decoded.customResolverAddress, "9.9.9.9")
        XCTAssertEqual(decoded.customResolverSecondaryAddress, "2620:fe::fe")
        XCTAssertEqual(decoded.resolverPreset.ipv4Servers, ["9.9.9.9"])
        XCTAssertEqual(decoded.resolverPreset.ipv6Servers, ["2620:fe::fe"])
    }

    func testLocalLogPreferencesAndGuardLedgerRoundTrip() throws {
        let ledger = LavaGuardAchievementLedger(records: [
            LavaGuardUnlockRecord(
                guardID: "emberObsidian",
                unlockedAt: Date(timeIntervalSinceReferenceDate: 700)
            )
        ])
        let configuration = AppConfiguration(
            keepFilteringCounts: false,
            keepDomainDiagnostics: true,
            keepNetworkActivity: false,
            keepLavaGuardProgress: false,
            lavaGuardUnlocks: ledger
        )

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertFalse(decoded.keepFilteringCounts)
        XCTAssertTrue(decoded.keepDomainDiagnostics)
        XCTAssertFalse(decoded.keepNetworkActivity)
        XCTAssertFalse(decoded.keepLavaGuardProgress)
        XCTAssertEqual(decoded.lavaGuardUnlocks, ledger)
    }

    func testCustomBlocklistsRoundTrip() throws {
        let source = try CustomBlocklistSource(
            id: "custom-1",
            displayName: "My List",
            rawURL: "https://example.com/list.txt",
            lastAcceptedHash: String(repeating: "c", count: 64)
        )
        let configuration = AppConfiguration(
            enabledBlocklistIDs: [source.id],
            isPaid: true,
            customBlocklists: [source]
        )

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertEqual(decoded.customBlocklists, [source])
        XCTAssertEqual(decoded.enabledBlocklistIDs, [source.id])
    }

    func testAllowlistValidatorRejectsThreatAndProtectedDomainsAfterNormalization() throws {
        var threatRules = DomainRuleSet()
        try threatRules.insert(domain: "danger.example.com")
        let validator = AllowlistValidator(nonAllowableThreatRules: threatRules)

        XCTAssertEqual(validator.validate(" Good.Example.Com ").normalizedDomain, "good.example.com")
        XCTAssertTrue(validator.validate("good.example.com").isAllowed)

        let threatResult = validator.validate(" Danger.Example.Com ")
        XCTAssertFalse(threatResult.isAllowed)
        XCTAssertNil(threatResult.normalizedDomain)
        XCTAssertEqual(threatResult.message, "Some dangerous domains cannot be allowed.")

        let protectedResult = validator.validate("apple.com")
        XCTAssertFalse(protectedResult.isAllowed)
        XCTAssertNil(protectedResult.normalizedDomain)
        XCTAssertEqual(protectedResult.message, "This domain is protected so Lava can keep essential services working.")
    }
}
