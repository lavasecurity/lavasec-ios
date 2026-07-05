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

    func testPrimaryIdentityIsStableAcrossDeviceDNSFallbackModeFlip() {
        // COH-1: an encrypted primary's `primaryCacheIdentifier` must not change when device-DNS
        // fallback MODE flips — the rejected-response streak is keyed on it, so a moving identity
        // re-scopes the streak and pins the LAV-87 escalation (a second DNS-1 channel).
        func primaryIdentity(fallbackModeActive: Bool, modeInsensitive: Bool) -> String {
            DNSResolverRuntimePlan.make(
                resolver: .cloudflareDoH,
                fallbackToDeviceDNS: true,
                deviceDNSAddresses: ["192.168.1.1"],
                networkKind: .wifi,
                deviceDNSFallbackModeActive: fallbackModeActive,
                ignoresDeviceDNSFallbackMode: modeInsensitive
            ).primaryCacheIdentifier
        }

        // Mode-SENSITIVE (the plain view): the flip DOES move the primary identity — the effective
        // transport becomes `.deviceDNS`. This is exactly why the streak sites must not use it.
        XCTAssertNotEqual(
            primaryIdentity(fallbackModeActive: false, modeInsensitive: false),
            primaryIdentity(fallbackModeActive: true, modeInsensitive: false),
            "Under fallback mode the effective transport flips to device DNS, changing the plain primary identity."
        )

        // Mode-INSENSITIVE (what the rejected-streak count + change-detect sites use): the primary
        // identity is pinned to the configured encrypted upstream and survives the flip.
        XCTAssertEqual(
            primaryIdentity(fallbackModeActive: false, modeInsensitive: true),
            primaryIdentity(fallbackModeActive: true, modeInsensitive: true),
            "ignoresDeviceDNSFallbackMode pins the primary identity to the configured upstream across a mode flip (COH-1)."
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

    // The DNS hot path captures the plan once and reuses it when the query resolves; the wedge
    // bit can flip in between and is NOT folded into cacheIdentifier, so `forward` re-reads it
    // onto the captured plan via this helper. It must flip ONLY the rejection trigger.
    func testRecomputingResolverRejectionFallbackTriggerFlipsOnlyTheWedgeBit() {
        // Device-DNS primary with encrypted fallback, captured while healthy → trigger off.
        let captured = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            deviceResolverWedged: false
        )
        XCTAssertTrue(captured.shouldFallbackToEncrypted)
        XCTAssertFalse(captured.treatsResolverRejectionAsFallbackTrigger)

        // Re-reading a now-wedged state flips the trigger ON without disturbing anything else —
        // cacheIdentifier especially (the wedge bit is deliberately not folded into it).
        let rewedged = captured.recomputingResolverRejectionFallbackTrigger(deviceResolverWedged: true)
        XCTAssertTrue(rewedged.treatsResolverRejectionAsFallbackTrigger)
        XCTAssertEqual(rewedged.cacheIdentifier, captured.cacheIdentifier)
        XCTAssertEqual(rewedged.shouldFallbackToEncrypted, captured.shouldFallbackToEncrypted)
        XCTAssertEqual(rewedged.plainAddresses, captured.plainAddresses)
        XCTAssertEqual(rewedged.deviceDNSFallbackAddresses, captured.deviceDNSFallbackAddresses)

        // Re-reading a healthy state flips it back off (idempotent round-trip, identity preserved).
        let rehealthy = rewedged.recomputingResolverRejectionFallbackTrigger(deviceResolverWedged: false)
        XCTAssertFalse(rehealthy.treatsResolverRejectionAsFallbackTrigger)
        XCTAssertEqual(rehealthy.cacheIdentifier, captured.cacheIdentifier)

        // An encrypted primary has no encrypted fallback, so shouldFallbackToEncrypted gates the
        // trigger off even when the recompute is handed a wedged state.
        let encryptedPrimary = DNSResolverRuntimePlan.make(
            resolver: .cloudflareDoH,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            deviceResolverWedged: false
        )
        XCTAssertFalse(encryptedPrimary.shouldFallbackToEncrypted)
        XCTAssertFalse(
            encryptedPrimary.recomputingResolverRejectionFallbackTrigger(deviceResolverWedged: true)
                .treatsResolverRejectionAsFallbackTrigger
        )
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

    // (LAV-87) `orderedResolverAddresses` flips v4/v6 ordering by network kind, so the SAME
    // primary address set must not read as a different identity across a wifi↔cellular flap —
    // the rejected-response streak keys on this value and must survive exactly that churn.
    func testPrimaryCacheIdentifierIsOrderInsensitiveAcrossNetworkKinds() {
        let addresses = ["9.9.9.9", "2620:fe::fe"]
        let wifi = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            deviceDNSAddresses: addresses,
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false
        )
        let cellular = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            deviceDNSAddresses: addresses,
            networkKind: .cellular,
            deviceDNSFallbackModeActive: false
        )
        // wifi orders v4-first, cellular v6-first — the connection ordering really does differ...
        XCTAssertNotEqual(wifi.plainAddresses, cellular.plainAddresses)
        // ...but the primary IDENTITY must not.
        XCTAssertEqual(wifi.primaryCacheIdentifier, cellular.primaryCacheIdentifier)
    }

    // Only the AUTOMATIC family flip is neutralized: a user swapping primary/secondary
    // addresses within a family changes try-order behavior, so it must register as a real
    // identity change (clearing identity-scoped evidence like the rejected streak) — carrying
    // the old primary's rejection evidence onto a newly promoted primary would trigger a false
    // reconnect after a single further rejection (Codex P2 on this PR).
    func testPrimaryCacheIdentifierPreservesUserAddressOrderWithinFamily() {
        let primaryFirst = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            deviceDNSAddresses: ["9.9.9.9", "149.112.112.112"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false
        )
        let secondaryFirst = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            deviceDNSAddresses: ["149.112.112.112", "9.9.9.9"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false
        )
        XCTAssertNotEqual(primaryFirst.primaryCacheIdentifier, secondaryFirst.primaryCacheIdentifier)
    }

    // The count-site scenario: an encrypted primary with the device fallback enabled (the
    // default). Captured-address churn moves the FULL runtime identifier (it must — it is the
    // runtime-reset no-op key) but never the primary identity the rejected streak is scoped to.
    func testDeviceFallbackAddressChurnMovesRuntimeIdentifierButNotPrimaryIdentity() {
        let before = DNSResolverRuntimePlan.make(
            resolver: .cloudflareDoH,
            fallbackToDeviceDNS: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false
        )
        let after = DNSResolverRuntimePlan.make(
            resolver: .cloudflareDoH,
            fallbackToDeviceDNS: true,
            deviceDNSAddresses: ["10.0.0.1"], // a handoff recaptured different device addresses
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false
        )
        XCTAssertNotEqual(before.cacheIdentifier, after.cacheIdentifier)
        XCTAssertEqual(before.primaryCacheIdentifier, after.primaryCacheIdentifier)
    }
}
