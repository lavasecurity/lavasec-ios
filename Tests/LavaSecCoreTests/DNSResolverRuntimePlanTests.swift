import XCTest
@testable import LavaSecCore

final class DNSResolverRuntimePlanTests: XCTestCase {
    func testDoTResolverPlanUsesEncryptedEndpointAndBootstrapAddresses() {
        let plan = DNSResolverRuntimePlan.make(
            resolver: .quad9SecureDoT,
            fallbackToDeviceDNS: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false
        )

        XCTAssertEqual(plan.transport, .dnsOverTLS)
        XCTAssertEqual(plan.dotEndpoints.map(\.displayAddress), ["dns.quad9.net:853"])
        XCTAssertEqual(plan.plainAddresses, ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"])
        XCTAssertEqual(plan.deviceDNSFallbackAddresses, ["192.168.1.1"])
        XCTAssertTrue(plan.shouldFallbackToDeviceDNS)
        XCTAssertFalse(plan.usesDeviceDNSFallbackMode)
        XCTAssertEqual(
            plan.cacheIdentifier,
            "dot:dns.quad9.net:853|fallback:device:192.168.1.1"
        )
    }

    func testDeviceDNSFallbackModeOverridesEncryptedResolver() {
        let plan = DNSResolverRuntimePlan.make(
            resolver: .quad9SecureDoT,
            fallbackToDeviceDNS: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: true
        )

        XCTAssertEqual(plan.transport, .deviceDNS)
        XCTAssertEqual(plan.plainAddresses, ["192.168.1.1"])
        XCTAssertTrue(plan.usesDeviceDNSFallbackMode)
        XCTAssertFalse(plan.shouldFallbackToDeviceDNS)
        XCTAssertEqual(plan.cacheIdentifier, "device:192.168.1.1|mode:device-dns-fallback")
    }

    func testIgnoringFallbackModeKeepsPrimaryResolverForRecoveryProbes() {
        let plan = DNSResolverRuntimePlan.make(
            resolver: .quad9SecureDoT,
            fallbackToDeviceDNS: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: true,
            ignoresDeviceDNSFallbackMode: true
        )

        XCTAssertEqual(plan.transport, .dnsOverTLS)
        XCTAssertFalse(plan.usesDeviceDNSFallbackMode)
        XCTAssertTrue(plan.shouldFallbackToDeviceDNS)
        XCTAssertEqual(
            plan.cacheIdentifier,
            "dot:dns.quad9.net:853|fallback:device:192.168.1.1"
        )
    }

    func testCellularNetworksPreferIPv6ResolverAddresses() {
        let plan = DNSResolverRuntimePlan.make(
            resolver: .google,
            fallbackToDeviceDNS: false,
            deviceDNSAddresses: [],
            networkKind: .cellular,
            deviceDNSFallbackModeActive: false
        )

        XCTAssertEqual(plan.transport, .plainDNS)
        XCTAssertEqual(plan.plainAddresses, [
            "2001:4860:4860::8888",
            "2001:4860:4860::8844",
            "8.8.8.8",
            "8.8.4.4"
        ])
        XCTAssertFalse(plan.shouldFallbackToDeviceDNS)
    }
}
