import XCTest
@testable import LavaSecKit

final class DNSPatchProviderCatalogTests: XCTestCase {
    func testCandidatesReuseCatalogAndHaveTLSBootstrapAddresses() throws {
        XCTAssertFalse(DNSPatchProviderCatalog.providers.isEmpty)
        for provider in DNSPatchProviderCatalog.providers {
            XCTAssertTrue(DNSResolverPreset.settingsPresets.contains(provider))
            let endpoint = try XCTUnwrap(provider.dnsOverTLSVariant?.dotEndpoint)
            let contract = try XCTUnwrap(DNSPatchProviderCatalog.contract(for: provider.id))
            XCTAssertEqual(endpoint.port, 853)
            XCTAssertEqual(contract.serverName, endpoint.hostname)
            XCTAssertFalse(contract.serverAddresses.isEmpty)
            XCTAssertEqual(contract.serverAddresses, [endpoint.bootstrapIPv4Servers.first, endpoint.bootstrapIPv6Servers.first].compactMap { $0 })
            XCTAssertEqual(Set(contract.captureAddresses(observedEndpoints: [])), Set(contract.serverAddresses))
        }
    }

    func testExistingQuad9ProfileSurvivesWithoutReinstallation() throws {
        XCTAssertEqual(try DNSPatchProviderCatalog.contract(for: DNSPatchProviderCatalog.defaultID), try DNSPatchContract.bundled())
    }

    func testDeviceCustomAndUnknownIDsCannotBecomePatchProviders() throws {
        for id in [DNSResolverPreset.device.id, DNSResolverPreset.customID, "unknown"] {
            XCTAssertNil(try DNSPatchProviderCatalog.contract(for: id))
        }
    }

    func testNewProviderRejectsOldSystemDNSReadback() throws {
        let cloudflare = try XCTUnwrap(DNSPatchProviderCatalog.contract(for: DNSResolverPreset.cloudflare.id))
        let previous = try DNSPatchContract.bundled()
        XCTAssertFalse(cloudflare.matchesManagedSettings(serverName: previous.serverName,
            servers: previous.serverAddresses, matchDomains: [], allowsFailover: false, hasUniversalConnectRule: true))
        XCTAssertTrue(cloudflare.matchesManagedSettings(serverName: cloudflare.serverName,
            servers: cloudflare.serverAddresses, matchDomains: [], allowsFailover: false, hasUniversalConnectRule: true))
    }
    func testInstalledProviderReadbackRecoversEveryCatalogChoiceWithoutSavedPreference() throws {
        for provider in DNSPatchProviderCatalog.choices {
            let contract = try XCTUnwrap(DNSPatchProviderCatalog.contract(for: provider.id))
            let matched = try XCTUnwrap(DNSPatchProviderCatalog.matchingProvider(
                serverName: contract.serverName, servers: contract.serverAddresses,
                matchDomains: nil, allowsFailover: false, hasUniversalConnectRule: true,
                serverURL: contract.serverURL))
            XCTAssertEqual(try DNSPatchProviderCatalog.contract(for: matched.id), contract)
        }
    }

    func testReadbackRejectsPartialScopeFailoverAndUnknownEndpoint() throws {
        let contract = try DNSPatchContract.bundled()
        for (domains, failover, universal, host) in [
            (["example.com"], false, true, contract.serverName),
            ([], true, true, contract.serverName),
            ([], false, false, contract.serverName),
            ([], false, true, "unknown.invalid")
        ] {
            XCTAssertNil(try DNSPatchProviderCatalog.matchingProvider(serverName: host,
                servers: contract.serverAddresses, matchDomains: domains, allowsFailover: failover,
                hasUniversalConnectRule: universal, serverURL: nil))
        }
    }

}
