import XCTest
@testable import LavaSecCore
@testable import LavaSecKit
@testable import LavaSecAppServices

final class RetiredDNSMigrationTests: XCTestCase {
    func testRetiredPrimaryAndFallbackSelectionsMigrateWithTransportPreserved() throws {
        for prefix in ["mullvad", "quad9-secure", "dns-sb"] {
            for (suffix, expected) in [("", DNSResolverPreset.quad9Unfiltered),
                                       ("-doh", .quad9UnfilteredDoH), ("-dot", .quad9UnfilteredDoT)] {
                let id = prefix + suffix
                let data = Data("{\"resolverPresetID\":\"\(id)\",\"fallbackResolverPresetID\":\"\(id)\"}".utf8)
                let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
                XCTAssertEqual(configuration.resolverPresetID, expected.id)
                XCTAssertEqual(configuration.fallbackResolverPresetID, expected.id)
                XCTAssertEqual(configuration.resolverPreset, expected)
                XCTAssertEqual(configuration.fallbackResolverPreset, expected)
                XCTAssertFalse(expected.hasUpstreamFiltering)
                XCTAssertEqual(DNSResolverPreset.migratedPresetID(expected.id), expected.id)
                let backup = Data("{\"keepDomainDiagnostics\":true,\"protectionEnabledHint\":false,\"enabledBlocklistIDs\":[],\"allowedDomains\":[],\"blockedDomains\":[],\"resolverPresetID\":\"\(id)\",\"fallbackResolverPresetID\":\"\(id)\"}".utf8)
                let payload = try JSONDecoder().decode(BackupConfigurationPayload.self, from: backup)
                XCTAssertEqual(payload.resolverPresetID, expected.id)
                XCTAssertEqual(payload.fallbackResolverPresetID, expected.id)
            }
        }
    }

    func testCustomMullvadEndpointAndOtherProviderChoicesAreNotRewritten() throws {
        var configuration = AppConfiguration(resolverPresetID: DNSResolverPreset.customID,
            customResolverAddress: "https://dns.mullvad.net/dns-query",
            fallbackResolverPresetID: DNSResolverPreset.cloudflareDoT.id)
        configuration.fallbackToDeviceDNS = false
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decoded.customResolverAddress, "https://dns.mullvad.net/dns-query")
        XCTAssertFalse(decoded.fallbackToDeviceDNS)
    }

    func testPickerHasOneUnfilteredQuad9AndNoRetiredProvider() {
        let choices = DNSResolverPreset.settingsPresets
        XCTAssertEqual(choices.filter { $0.displayName.contains("Quad9") }, [.quad9Unfiltered])
        XCTAssertFalse(choices.contains { $0.id.contains("mullvad") || $0.id.contains("quad9-secure") })
        XCTAssertEqual(DNSResolverPreset.quad9Unfiltered.availableTransports, [.plainDNS, .dnsOverHTTPS, .dnsOverTLS])
    }
}
