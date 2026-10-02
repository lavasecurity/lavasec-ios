import XCTest
@testable import LavaSecKit

final class DNSPatchContractTests: XCTestCase {
    func testManagedSettingsRequireWholeContract() throws {
        let contract = try DNSPatchContract.bundled()
        func matches(name: String? = nil, servers: [String]? = nil,
            domains: [String]? = nil, failover: Bool = false, rule: Bool = true) -> Bool {
            contract.matchesManagedSettings(serverName: name ?? contract.serverName,
                servers: servers ?? contract.serverAddresses, matchDomains: domains,
                allowsFailover: failover, hasUniversalConnectRule: rule)
        }
        XCTAssertTrue(matches())
        XCTAssertTrue(matches(servers: contract.serverAddresses.reversed(), domains: [""]))
        XCTAssertFalse(matches(name: "other.example"))
        XCTAssertFalse(matches(servers: ["9.9.9.9"]))
        XCTAssertFalse(matches(domains: ["example.com"]))
        XCTAssertFalse(matches(failover: true))
        XCTAssertFalse(matches(rule: false))
    }

    func testOlderConfigurationDefaultsOffAndOptInRoundTrips() throws {
        XCTAssertFalse(try JSONDecoder().decode(AppConfiguration.self, from: Data("{}".utf8)).dnsPatchEnabled)
        let config = AppConfiguration(dnsPatchEnabled: true)
        XCTAssertTrue(try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config)).dnsPatchEnabled)
    }

    func testOptInProducesHostRoutesWithoutGeneralForwarding() throws {
        let contract = try DNSPatchContract.bundled()
        let plan = TunnelRoutePlan.make(for: .dnsOnly,
            dnsCaptureResolverAddresses: contract.captureAddresses(observedEndpoints: ["64:ff9b::909:90a"]),
            capturesIPv6InDNSOnly: true)
        XCTAssertTrue(plan.includedIPv4Routes.contains(.init(destinationAddress: "9.9.9.10", subnetMask: "255.255.255.255")))
        XCTAssertTrue(plan.includedIPv6Routes.contains(.init(destinationAddress: "64:ff9b::909:90a", prefixLength: 128)))
        XCTAssertFalse(plan.includedIPv4Routes.contains(where: { $0.subnetMask == "0.0.0.0" }))
        XCTAssertFalse(plan.includedIPv6Routes.contains(where: { $0.prefixLength == 0 }))
    }

    func testOnlyProfileDestinationsArePresentWithoutPhysicalObservations() throws {
        let contract = try DNSPatchContract.bundled()
        XCTAssertEqual(contract.captureAddresses(observedEndpoints: []), ["9.9.9.10", "2620:fe::10"])
        XCTAssertFalse(contract.captureAddresses(observedEndpoints: []).contains("64:ff9b::909:90a"))
    }

    func testObservedTranslationIsNotLimitedToChimmysCarrierPrefix() throws {
        let contract = try DNSPatchContract.bundled()
        for address in ["64:ff9b::909:90a", "2001:db8:1234:5678:abcd:ef01:909:90a",
                        "2001:db8:909:90a::", "2001:db8:1209:909:a::",
                        "2001:db8:1234:909:9:a00::", "2001:db8:1234:5609:9:90a::",
                        "2001:db8:1234:5678:9:909:a00:0"] {
            XCTAssertTrue(contract.admitsObservedEndpoint(address), address)
        }
    }

    func testUnrelatedAndMalformedAddressesCannotBecomeRoutes() throws {
        let contract = try DNSPatchContract.bundled()
        for address in ["0.0.0.0/0", "::/0", "192.168.1.1", "1.1.1.1", "::1", "::ffff:9.9.9.10",
                        "ff00::909:90a", "fe80::909:90a", "64:ff9b::909:909", "not-an-ip",
                        "2001:db8:909:90a:100::", "2001:db8:909:90a::1"] {
            XCTAssertFalse(contract.admitsObservedEndpoint(address), address)
        }
    }

    func testRoutesDeduplicateEquivalentIPv6Spellings() throws {
        let contract = try DNSPatchContract.bundled()
        XCTAssertEqual(contract.captureAddresses(observedEndpoints: ["2620:00fe:0:0:0:0:0:0010", "64:ff9b::909:90a",
            "0064:ff9b:0:0:0:0:0909:090a", "1.1.1.1"]), ["9.9.9.10", "2620:fe::10", "64:ff9b::909:90a"])
    }

    func testLiteralEndpointDiscoveryDoesNotRequireAnotherSettingsPost() throws {
        let contract = try DNSPatchContract.bundled()
        XCTAssertFalse(contract.requiresRouteUpdate(previousObservedEndpoints: [], observedEndpoints: ["9.9.9.10"]))
        XCTAssertFalse(contract.requiresRouteUpdate(previousObservedEndpoints: ["9.9.9.10"],
            observedEndpoints: ["9.9.9.10", "9.9.9.10"]))
    }

    func testEquivalentIPv6AndRepeatedInterfaceObservationsDoNotChangeRoutes() throws {
        let contract = try DNSPatchContract.bundled()
        XCTAssertFalse(contract.requiresRouteUpdate(previousObservedEndpoints: ["64:ff9b::909:90a"],
            observedEndpoints: ["0064:ff9b:0:0:0:0:0909:090a", "64:ff9b::909:90a"]))
        XCTAssertFalse(contract.requiresRouteUpdate(previousObservedEndpoints: [],
            observedEndpoints: ["2620:00fe:0:0:0:0:0:0010"]))
    }

    func testObservationOrderDoesNotChangeCaptureDestinations() throws {
        let contract = try DNSPatchContract.bundled()
        let endpoints = ["64:ff9b::909:90a", "2001:db8:1234:5678:abcd:ef01:909:90a"]
        XCTAssertFalse(contract.requiresRouteUpdate(previousObservedEndpoints: endpoints,
            observedEndpoints: endpoints.reversed()))
    }

    func testRealTranslatedEndpointAdditionsRemovalsAndChangesRequireSettingsPosts() throws {
        let contract = try DNSPatchContract.bundled()
        let translated = "64:ff9b::909:90a"
        XCTAssertTrue(contract.requiresRouteUpdate(previousObservedEndpoints: [], observedEndpoints: [translated]))
        XCTAssertTrue(contract.requiresRouteUpdate(previousObservedEndpoints: [translated], observedEndpoints: []))
        XCTAssertTrue(contract.requiresRouteUpdate(previousObservedEndpoints: [translated],
            observedEndpoints: ["2001:db8:1234:5678:abcd:ef01:909:90a"]))
    }

    func testRejectedOrOutOfBoundObservationsDoNotRequireSettingsPosts() throws {
        let contract = try DNSPatchContract.bundled()
        XCTAssertFalse(contract.requiresRouteUpdate(previousObservedEndpoints: [],
            observedEndpoints: ["1.1.1.1", "not-an-ip", "::/0"]))
        XCTAssertFalse(contract.requiresRouteUpdate(previousObservedEndpoints: Array(repeating: "9.9.9.10", count: 8),
            observedEndpoints: Array(repeating: "9.9.9.10", count: 8) + ["64:ff9b::909:90a"]))
    }
}
