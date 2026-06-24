import XCTest
@testable import LavaSecCore

final class DNSResolverRuntimePlanTests: XCTestCase {
    func testDeviceDNSPrimaryGetsEncryptedFallbackWhenToggleOn() {
        let plan = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false
        )

        XCTAssertEqual(plan.transport, .deviceDNS)
        // Inverse fallback: a Device-DNS primary gets the Mullvad DoH safety net.
        XCTAssertTrue(plan.shouldFallbackToEncrypted)
        XCTAssertEqual(plan.encryptedFallbackEndpoints, [DNSResolverRuntimePlan.mullvadEncryptedFallbackEndpoint])
        // Mutually exclusive with the device fallback (that needs a non-device primary).
        XCTAssertFalse(plan.shouldFallbackToDeviceDNS)
        XCTAssertEqual(
            plan.cacheIdentifier,
            "device:192.168.1.1|fallback:encrypted:doh:https://dns.mullvad.net/dns-query"
        )
    }

    func testDeviceDNSRejectionTriggerOnlyWhenResolverWedged() {
        // Healthy device resolver: a SERVFAIL/REFUSED reply is an authoritative
        // verdict, so the rejection path stays off (only no-response falls back).
        let healthy = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            deviceResolverWedged: false
        )
        XCTAssertTrue(healthy.shouldFallbackToEncrypted)
        XCTAssertFalse(healthy.treatsResolverRejectionAsFallbackTrigger)

        // Health-confirmed wedge: refusals now count as fallback evidence.
        let wedged = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            deviceResolverWedged: true
        )
        XCTAssertTrue(wedged.treatsResolverRejectionAsFallbackTrigger)

        // The rejection trigger requires the encrypted fallback to be active at all,
        // so an encrypted primary never sets it regardless of wedge state.
        let encryptedPrimary = DNSResolverRuntimePlan.make(
            resolver: .cloudflareDoH,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            deviceResolverWedged: true
        )
        XCTAssertFalse(encryptedPrimary.treatsResolverRejectionAsFallbackTrigger)
    }

    func testDeviceDNSPrimaryEncryptedFallbackRespectsToggleAndProbeContext() {
        // Encrypted-fallback opt-in off (default) → no fallback, even though the
        // separate device-DNS-fallback flag is on.
        let toggleOff = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: false,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false
        )
        XCTAssertFalse(toggleOff.shouldFallbackToEncrypted)
        XCTAssertTrue(toggleOff.encryptedFallbackEndpoints.isEmpty)
        XCTAssertEqual(toggleOff.cacheIdentifier, "device:192.168.1.1")

        // Smoke probe (allowsQueryFallback == false) → no fallback, so the probe
        // still measures the primary device resolver's own health.
        let probe = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            allowsQueryFallback: false
        )
        XCTAssertFalse(probe.shouldFallbackToEncrypted)
    }

    func testEncryptedPrimaryUsesDeviceFallbackNotEncryptedFallback() {
        let plan = DNSResolverRuntimePlan.make(
            resolver: .cloudflareDoH,
            fallbackToDeviceDNS: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false
        )

        XCTAssertTrue(plan.shouldFallbackToDeviceDNS)
        XCTAssertFalse(plan.shouldFallbackToEncrypted)
        XCTAssertTrue(plan.encryptedFallbackEndpoints.isEmpty)
    }

    func testCustomDoQEncryptedFallbackSurfacesDoQEndpointsForBootstrap() throws {
        // A custom doq:// fallback resolver keeps its hostname only in the nested
        // fallback plan, so the tunnel needs `encryptedFallbackDoQEndpoints` to
        // bootstrap/prewarm it — otherwise the DoQ lookup recurses through the wedged
        // Device DNS the fallback exists to escape.
        let fallbackResolver = try XCTUnwrap(DNSResolverPreset.custom(rawValue: "doq://dns.example"))
        XCTAssertEqual(fallbackResolver.transport, .dnsOverQUIC)

        let plan = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            encryptedFallbackResolver: fallbackResolver
        )

        XCTAssertTrue(plan.shouldFallbackToEncrypted)
        XCTAssertEqual(plan.encryptedFallback?.plan.transport, .dnsOverQUIC)
        XCTAssertEqual(plan.encryptedFallbackDoQEndpoints.map(\.hostname), ["dns.example"])
        // The DoH back-compat accessor stays empty for a DoQ fallback.
        XCTAssertTrue(plan.encryptedFallbackEndpoints.isEmpty)
    }

    func testCustomDoTEncryptedFallbackSurfacesDoTEndpointsForBootstrap() throws {
        // A custom tls:// fallback resolver keeps its hostname only in the nested
        // fallback plan, so the tunnel needs `encryptedFallbackDoTEndpoints` to
        // bootstrap/prewarm it — otherwise the DoT lookup recurses through the wedged
        // Device DNS the fallback exists to escape.
        let fallbackResolver = try XCTUnwrap(DNSResolverPreset.custom(rawValue: "tls://dns.example"))
        XCTAssertEqual(fallbackResolver.transport, .dnsOverTLS)

        let plan = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            encryptedFallbackResolver: fallbackResolver
        )

        XCTAssertTrue(plan.shouldFallbackToEncrypted)
        XCTAssertEqual(plan.encryptedFallback?.plan.transport, .dnsOverTLS)
        XCTAssertEqual(plan.encryptedFallbackDoTEndpoints.map(\.hostname), ["dns.example"])
        // The DoH/DoQ accessors stay empty for a DoT fallback.
        XCTAssertTrue(plan.encryptedFallbackEndpoints.isEmpty)
        XCTAssertTrue(plan.encryptedFallbackDoQEndpoints.isEmpty)
    }

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

    func testPrimaryCacheIdentifierIgnoresFallbackOnlyChanges() {
        // The primary identity must NOT move when only a fallback wrapper changes — that is what
        // lets the resolver-identity baseline / rejected-streak reset fire on a genuine primary
        // switch but NOT on a fallback-only runtime reset (Codex #86 round 22).
        let withoutEncryptedFallback = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: false,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false
        )
        let withEncryptedFallback = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true, // ONLY the fallback differs
            deviceDNSAddresses: ["192.168.1.1"],  // SAME primary
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false
        )
        // The full cache identifiers differ (the encrypted fallback folds in)...
        XCTAssertNotEqual(withoutEncryptedFallback.cacheIdentifier, withEncryptedFallback.cacheIdentifier)
        // ...but the PRIMARY identity is the same, so a fallback-only reset won't trip the switch.
        XCTAssertEqual(withoutEncryptedFallback.primaryCacheIdentifier, withEncryptedFallback.primaryCacheIdentifier)
        XCTAssertEqual(withEncryptedFallback.primaryCacheIdentifier, "device:192.168.1.1")

        // A genuine primary switch (different device-resolver addresses) DOES move it.
        let differentPrimary = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["10.0.0.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false
        )
        XCTAssertNotEqual(withEncryptedFallback.primaryCacheIdentifier, differentPrimary.primaryCacheIdentifier)
    }
}
