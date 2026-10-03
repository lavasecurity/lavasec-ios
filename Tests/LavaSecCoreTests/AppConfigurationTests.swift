import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class AppConfigurationTests: XCTestCase {
    func testDNSTierSettingsFollowBothFallbackDirectionsAndTheirOwnSwitches() {
        for primary in [DNSResolverPreset.device, .cloudflareDoH] {
            for deviceFallback in [false, true] {
                for providerFallback in [false, true] {
                    let settings = ResolverLadderInputs(
                        resolver: primary, fallbackToDeviceDNS: deviceFallback,
                        usesEncryptedDeviceDNSFallback: providerFallback,
                        encryptedFallbackResolver: .quad9UnfilteredDoH)
                    // With no runtime admission constraint, the settings table and the
                    // canonical T2 selection must agree for either primary and both switches.
                    let tier = ResolverTierTwo.resolve(
                        primaryTransport: primary.transport, effectiveTransport: primary.transport,
                        fallbackToDeviceDNS: deviceFallback,
                        usesEncryptedDeviceDNSFallback: providerFallback,
                        encryptedFallbackResolver: .quad9UnfilteredDoH,
                        allowsQueryFallback: true, hasDeviceDNSAddresses: true)
                    switch tier {
                    case .none:
                        XCTAssertFalse(settings.isConfiguredFallbackEnabled)
                    case .deviceDNS:
                        XCTAssertTrue(settings.isConfiguredFallbackEnabled)
                        XCTAssertEqual(settings.configuredFallbackResolver, .device)
                    case .resolver(let preset):
                        XCTAssertTrue(settings.isConfiguredFallbackEnabled)
                        XCTAssertEqual(settings.configuredFallbackResolver, preset)
                    }
                }
            }
        }
    }

    func testDNSTierSettingsKeepTheCustomFallbackSelectionWhenDisabled() throws {
        var configuration = AppConfiguration()
        configuration.resolverPresetID = DNSResolverPreset.device.id
        configuration.usesEncryptedDeviceDNSFallback = false
        configuration.fallbackResolverPresetID = DNSResolverPreset.customID
        configuration.fallbackCustomResolverName = "My resolver"
        configuration.fallbackCustomResolverAddress = "https://resolver.example/dns-query"
        let settings = configuration.resolverLadderInputs
        XCTAssertFalse(settings.isConfiguredFallbackEnabled)
        XCTAssertEqual(settings.configuredFallbackResolver.displayName, "My resolver")
        XCTAssertEqual(settings.configuredFallbackResolver.transport, .dnsOverHTTPS)
        XCTAssertEqual(settings.configuredFallbackResolver.dohEndpoint?.url.host, "resolver.example")
    }

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

    func testFallbackResolverSelectionDefaultsToQuad9DoH() {
        let configuration = AppConfiguration()
        XCTAssertEqual(configuration.fallbackResolverPresetID, DNSResolverPreset.quad9UnfilteredDoH.id)
        XCTAssertEqual(configuration.fallbackResolverPreset, .quad9UnfilteredDoH)
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

    func testRetiredDNSSBFallbackSelectionMigratesToQuad9() throws {
        let data = Data("""
        { "fallbackResolverPresetID": "dns-sb-doh" }
        """.utf8)
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
        XCTAssertEqual(configuration.fallbackResolverPresetID, DNSResolverPreset.quad9UnfilteredDoH.id)
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

    /// THE RUNG IS THE USER'S OWN RESOLVER SELECTION, carried through unchanged.
    ///
    /// The defect this rules out is the rung resolving something the user did not pick. It used
    /// to resolve a SECOND setting (`chainedFallbackResolverPresetID`) restricted to plain IPv4;
    /// the plan's S4 deleted that setting, so the one selection the user makes serves both modes.
    func testTheTierOneConfigurationIsTheUsersOwnResolverSelection() throws {
        var configuration = AppConfiguration()
        configuration.resolverPresetID = DNSResolverPreset.quad9UnfilteredDoH.id
        configuration.fallbackToDeviceDNS = true

        let rung = try XCTUnwrap(configuration.chainedTierOneResolverConfiguration)

        XCTAssertEqual(
            rung.resolverPreset.id, configuration.resolverPreset.id,
            "the rung resolves the resolver the user picked")
        XCTAssertEqual(
            rung.resolverPreset.transport, .dnsOverHTTPS,
            "on its own transport — the plain coercion is gone")
        XCTAssertTrue(
            rung.fallbackToDeviceDNS,
            "and carries the user's OWN device-fallback setting; it used to be forced off, which "
                + "was bookkeeping about a flag the rung's execution path never read")
    }

    /// The toggle gates the rung, and it is the ONLY thing that does.
    ///
    /// `chainedTierOneResolverConfiguration` answering nil is already every consumer's "no rung"
    /// — the tunnel's plan derivation, the latch, and the settings panel's own enabled question —
    /// so routing the toggle through it is what stops a second gate somewhere downstream
    /// disagreeing with this one.
    ///
    /// The DEFAULT is the compatibility story and is asserted separately: between the plan's S4
    /// and this toggle the rung ran with no consent gate at all, so defaulting false would have
    /// silently withdrawn the fallback from every existing user — including the one whose field
    /// reports drove PR #596.
    func testTheTierOneFallbackToggleGatesTheRung() throws {
        XCTAssertTrue(
            AppConfiguration().chainedTierOneFallbackEnabled,
            "default ON reproduces the pre-toggle behaviour exactly")

        var configuration = AppConfiguration()
        configuration.chainedTierOneFallbackEnabled = true
        XCTAssertNotNil(
            configuration.chainedTierOneResolverConfiguration,
            "enabled means the user's own selection is the rung")

        configuration.chainedTierOneFallbackEnabled = false
        XCTAssertNil(
            configuration.chainedTierOneResolverConfiguration,
            "disabled means NO rung — nil is the closed direction every consumer already handles")

        // The ENDPOINT list is deliberately unaffected: it describes what the selection IS, which
        // the settings panel still renders, not whether the rung may run. Conflating them would
        // make a disabled fallback also erase the description of the thing being disabled.
        configuration.resolverPresetID = DNSResolverPreset.cloudflareDoH.id
        XCTAssertFalse(
            configuration.chainedTierOneResolverEndpoints.isEmpty,
            "turning the rung off does not un-name the resolver it would have used")
    }

    /// The rung carries the user's device-fallback setting BOTH WAYS.
    ///
    /// One direction alone is not a pin: forcing the flag false passed the off case, and hardcoding
    /// it true would pass the on case. Assert that it tracks.
    ///
    /// The flag only became live when the rung moved from `resolvePrimaryUpstream` to
    /// `resolveUpstream` — the wrapper that reads it. Before that, every value here was inert
    /// (Codex P1, PR #593).
    func testTheRungCarriesTheUsersOwnDeviceFallbackSetting() throws {
        for chosen in [true, false] {
            var configuration = AppConfiguration()
            configuration.fallbackToDeviceDNS = chosen
            let rung = try XCTUnwrap(configuration.chainedTierOneResolverConfiguration)
            XCTAssertEqual(
                rung.fallbackToDeviceDNS, chosen,
                "the rung must neither impose nor withhold the ladder — it is the user's setting")
        }
    }

    /// DEVICE DNS IS ELIGIBLE AS THE RUNG, and the previous test here pinned the opposite.
    ///
    /// The refusal conflated device DNS IMPOSED on the rung by a fallback episode (still
    /// forbidden, at the plan site) with device DNS SELECTED by the user. Native Tailscale with
    /// MagicDNS and no global nameservers falls through to the system's own DHCP resolvers, so
    /// refusing the same shape left a chained user worse off than running their VPN's own client
    /// (founder, 2026-08-27).
    ///
    /// The ENDPOINTS stay empty, and that is not a contradiction: a device-DNS selection names no
    /// addresses in the configuration at all. The tunnel substitutes its live capture, which is
    /// the only place they exist.
    func testADeviceDNSSelectionIsEligibleAsTheRung() throws {
        var configuration = AppConfiguration()
        configuration.resolverPresetID = DNSResolverPreset.device.id

        XCTAssertEqual(configuration.resolverPreset.transport, .deviceDNS)
        let rung = try XCTUnwrap(configuration.chainedTierOneResolverConfiguration)
        XCTAssertEqual(rung.resolverPreset.transport, .deviceDNS)
        XCTAssertTrue(
            rung.fallbackToDeviceDNS,
            "the ladder follows the user's own setting (default on) — a device-DNS SELECTION and "
                + "a device-DNS FALLBACK are separate questions, and this asserts the selection "
                + "does not suppress the ladder")
        XCTAssertEqual(
            configuration.chainedTierOneResolverEndpoints, [],
            "no addresses are configured; the tunnel supplies its live capture")
    }

    /// An ENCRYPTED selection enumerates its endpoint HOST, never a plain IPv4 it does not use.
    ///
    /// The old `chainedFallbackResolverAddresses` ran every preset through `plainDNSVariant`, so
    /// a DoH selection reduced to that provider's plain servers — addresses the rung would never
    /// contact, latched as though it would, and compared as though they identified it.
    func testAnEncryptedSelectionEnumeratesItsEndpointHostRatherThanAPlainIPv4() throws {
        var configuration = AppConfiguration()
        configuration.resolverPresetID = DNSResolverPreset.cloudflareDoH.id

        let endpoints = configuration.chainedTierOneResolverEndpoints
        let host = try XCTUnwrap(DNSResolverPreset.cloudflareDoH.dohEndpoint?.url.host)

        XCTAssertEqual(endpoints, [host])
        for address in DNSResolverPreset.cloudflare.ipv4Servers {
            XCTAssertFalse(
                endpoints.contains(address),
                "a DoH selection must not be described by the plain variant's addresses")
        }
    }

    /// A PLAIN selection contributes its own servers, which the admission gate can judge.
    func testAPlainSelectionContributesItsOwnServers() {
        var configuration = AppConfiguration()
        configuration.resolverPresetID = DNSResolverPreset.cloudflare.id

        XCTAssertEqual(
            configuration.chainedTierOneResolverEndpoints,
            DNSResolverPreset.cloudflare.ipv4Servers + DNSResolverPreset.cloudflare.ipv6Servers)
    }

    /// An IPv6-ONLY plain selection is LISTED, so the gate has something to refuse.
    ///
    /// It projected to an empty list, and empty means the gate is handed nothing: the panel
    /// enumerated no reason, the tunnel admitted no address, and a split-tunnel session ran no
    /// rung while stating nowhere that it had declined one (Codex P2, PR #591). The rung stays
    /// IPv4-only per `INV-CHAIN-1` — what changes is that the refusal is sayable.
    func testAnIPv6PlainSelectionIsListedSoTheGateCanRefuseIt() {
        var configuration = AppConfiguration()
        configuration.resolverPresetID = DNSResolverPreset.customID
        configuration.customResolverAddress = "2606:4700:4700::1111"

        XCTAssertEqual(configuration.resolverPreset.transport, .plainDNS)
        XCTAssertEqual(
            configuration.chainedTierOneResolverEndpoints, ["2606:4700:4700::1111"],
            "a v6 selection must reach the gate, which is what lets the panel name the refusal")
        XCTAssertNotNil(
            configuration.chainedTierOneResolverConfiguration,
            "eligibility is about the transport; the ADDRESS gate is the tunnel's to apply")
    }

    /// An ENCRYPTED selection exposes the CACHE IDENTIFIERS the resolver counters are keyed by,
    /// which are not the hosts the panel displays.
    ///
    /// `ResolverOrchestrator.resolveEndpoints` records an attempt under the endpoint's
    /// `cacheIdentifier` — the complete `doh:<absolute URL>` — while the display projection
    /// publishes the bare host. The bug report's redaction folds counters by matching those keys,
    /// so a host-only map matched nothing and a Custom DoH endpoint travelled into the report
    /// intact (Codex P1, PR #591).
    func testAnEncryptedSelectionExposesTheCacheIdentifiersTheCountersUse() throws {
        var configuration = AppConfiguration()
        configuration.resolverPresetID = DNSResolverPreset.cloudflareDoH.id
        let endpoint = try XCTUnwrap(DNSResolverPreset.cloudflareDoH.dohEndpoint)

        XCTAssertEqual(configuration.chainedTierOneResolverAttemptKeys, [endpoint.cacheIdentifier])
        XCTAssertNotEqual(
            configuration.chainedTierOneResolverAttemptKeys,
            configuration.chainedTierOneResolverEndpoints,
            "the counter key and the display name differ for an encrypted selection — that "
                + "difference is the whole reason both projections exist")
    }

    /// For a PLAIN selection the two projections agree, which is why the mismatch above stayed
    /// invisible until an encrypted resolver could become the rung.
    func testThePlainProjectionsAgree() {
        var configuration = AppConfiguration()
        configuration.resolverPresetID = DNSResolverPreset.cloudflare.id

        XCTAssertEqual(
            configuration.chainedTierOneResolverAttemptKeys,
            configuration.chainedTierOneResolverEndpoints)
    }

    /// THE IDENTITY SEPARATES TWO TRANSPORTS OF ONE PROVIDER, which addresses could not.
    ///
    /// This is the freshness check's input. Comparing coerced address lists made Cloudflare-plain
    /// and Cloudflare-DoH identical, so the panel reported "current" for a session running the
    /// other one and the user was never told a restart was needed (the plan's S4 obligation).
    func testTheTierOneIdentityDistinguishesTransportsOfOneProvider() {
        var plain = AppConfiguration()
        plain.resolverPresetID = DNSResolverPreset.cloudflare.id
        var doh = AppConfiguration()
        doh.resolverPresetID = DNSResolverPreset.cloudflareDoH.id
        var dot = AppConfiguration()
        dot.resolverPresetID = DNSResolverPreset.cloudflareDoT.id

        XCTAssertNotEqual(plain.chainedTierOneResolverIdentity, doh.chainedTierOneResolverIdentity)
        XCTAssertNotEqual(doh.chainedTierOneResolverIdentity, dot.chainedTierOneResolverIdentity)
        XCTAssertNotEqual(plain.chainedTierOneResolverIdentity, dot.chainedTierOneResolverIdentity)
    }

    /// A CUSTOM entry keeps one preset ID across completely different addresses, so the identity
    /// has to carry the addresses too or two different resolvers compare equal.
    func testTheTierOneIdentitySeparatesTwoCustomResolvers() {
        var first = AppConfiguration()
        first.resolverPresetID = DNSResolverPreset.customID
        first.customResolverAddress = "9.9.9.9"
        var second = first
        second.customResolverAddress = "1.1.1.1"

        XCTAssertNotEqual(
            first.chainedTierOneResolverIdentity, second.chainedTierOneResolverIdentity)
    }

    /// TWO STAMPS SHARING AN ENDPOINT URL BUT NOT ITS BOOTSTRAP IPs ARE TWO RESOLVERS.
    ///
    /// `cacheIdentifier` is `doh:<url>` / `dot:<host>:<port>` and deliberately carries no bootstrap
    /// IPs — it keys the per-address counter maps and the bug report's redaction fold, so it has to
    /// stay stable. Building the identity straight from it therefore made a stamp replacement that
    /// changed only the bootstrap servers byte-identical: the ordinary resolver reload noticed the
    /// changed raw configuration, but the T1 relatch compares this value, so a running session
    /// kept resolving through the superseded bootstrap servers while the panel called the
    /// selection current (Codex P2, PR #599).
    func testTheIdentitySeparatesTwoStampsSharingAnEndpointURL() throws {
        let url = try XCTUnwrap(URL(string: "https://dns.example/dns-query"))
        func stamp(bootstrap: String) -> DNSResolverPreset {
            DNSResolverPreset(
                id: DNSResolverPreset.customID, displayName: "Custom",
                ipv4Servers: [], ipv6Servers: [], notes: "", hasUpstreamFiltering: false,
                transport: .dnsOverHTTPS,
                dohEndpoint: DNSOverHTTPSEndpoint(
                    url: url, bootstrapIPv4Servers: [bootstrap], bootstrapIPv6Servers: []))
        }
        let first = stamp(bootstrap: "9.9.9.9")
        let second = stamp(bootstrap: "1.1.1.1")

        XCTAssertEqual(
            first.dohEndpoint?.cacheIdentifier, second.dohEndpoint?.cacheIdentifier,
            "the counter-map key must NOT move — that is why the identity composes instead")
        XCTAssertNotEqual(
            AppConfiguration.resolverIdentity(of: first),
            AppConfiguration.resolverIdentity(of: second),
            "different bootstrap servers reach a different resolver and must relatch")
    }

    /// EVERY INPUT THE RUNG'S LADDER IS BUILT FROM, not just the resolver it asks first.
    ///
    /// `PacketTunnelProvider` relatches a running session's T1 rung on this value. Keyed on
    /// `chainedTierOneResolverIdentity` it missed the whole fallback policy, because since PR #596
    /// the rung runs the FULL ladder (`INV-CHAIN-7`) and `DNSResolverRuntimePlan.make` steers it
    /// with three more configuration fields. The consequence was a fail-open: turning device
    /// fallback OFF left the session still sending failed T1 lookups to the device resolver
    /// until restart — PR #575's privacy failure through a third door (Codex P1, PR #599).
    ///
    /// Each field is asserted SEPARATELY rather than in one combined config, so a fingerprint that
    /// happens to move for one reason cannot cover for a field it does not read.
    func testTheRungPolicyIdentityMovesWithEveryLadderInput() {
        let base = AppConfiguration()

        var deviceFallbackOff = base
        deviceFallbackOff.fallbackToDeviceDNS = !base.fallbackToDeviceDNS
        XCTAssertNotEqual(
            base.chainedTierOneRungPolicyIdentity,
            deviceFallbackOff.chainedTierOneRungPolicyIdentity,
            "device fallback steers the rung's ladder, so the session must relatch on it")

        var encryptedFallbackOn = base
        encryptedFallbackOn.usesEncryptedDeviceDNSFallback = !base.usesEncryptedDeviceDNSFallback
        XCTAssertNotEqual(
            base.chainedTierOneRungPolicyIdentity,
            encryptedFallbackOn.chainedTierOneRungPolicyIdentity,
            "the encrypted fallback leg is part of the ladder too")

        // THE ENCRYPTED RESOLVER COUNTS ONLY WHERE THE LADDER READS IT — the same pair of
        // conditions `DNSResolverRuntimePlan.make` gates `shouldFallbackToEncrypted` on. So this
        // case has to SET UP that state rather than flipping the field on the base config, which
        // is exactly the "asserts the right answer about the wrong world" trap this suite has hit
        // twice before.
        var encryptedLegLive = base
        encryptedLegLive.resolverPresetID = DNSResolverPreset.device.id
        encryptedLegLive.usesEncryptedDeviceDNSFallback = true
        var otherFallbackResolver = encryptedLegLive
        otherFallbackResolver.fallbackResolverPresetID = DNSResolverPreset.cloudflareDoH.id
        XCTAssertNotEqual(
            encryptedLegLive.chainedTierOneRungPolicyIdentity,
            otherFallbackResolver.chainedTierOneRungPolicyIdentity,
            "which resolver the encrypted leg asks is a ladder input where the leg is live")

        // AND NOT WHERE IT IS INERT. A relatch bumps the data-path epoch and republishes, so
        // moving this identity for a field the running ladder never reads pays that cost for
        // nothing (Kilo, PR #599). Both inert directions: leg off, and a non-device primary.
        var inertLegOff = base
        inertLegOff.resolverPresetID = DNSResolverPreset.device.id
        var inertLegOffMoved = inertLegOff
        inertLegOffMoved.fallbackResolverPresetID = DNSResolverPreset.cloudflareDoH.id
        XCTAssertEqual(
            inertLegOff.chainedTierOneRungPolicyIdentity,
            inertLegOffMoved.chainedTierOneRungPolicyIdentity,
            "the encrypted leg is off, so its resolver cannot change what the ladder does")

        var inertNonDevice = base
        inertNonDevice.usesEncryptedDeviceDNSFallback = true
        var inertNonDeviceMoved = inertNonDevice
        inertNonDeviceMoved.fallbackResolverPresetID = DNSResolverPreset.cloudflareDoH.id
        XCTAssertEqual(
            inertNonDevice.chainedTierOneRungPolicyIdentity,
            inertNonDeviceMoved.chainedTierOneRungPolicyIdentity,
            "the encrypted leg is device-primary only, so a non-device primary never reads it")

        var otherPrimary = base
        otherPrimary.resolverPresetID = DNSResolverPreset.cloudflareDoT.id
        XCTAssertNotEqual(
            base.chainedTierOneRungPolicyIdentity,
            otherPrimary.chainedTierOneRungPolicyIdentity,
            "the primary selection is still an input, and must not be lost in the widening")

        // A CUSTOM FALLBACK RESOLVER keeps one preset ID across different addresses, exactly as the
        // primary does — so the fallback half has to carry addresses too, not just the ID.
        // FROM `encryptedLegLive`, not from `base`. Since the term is gated on the leg being live,
        // a case built on the default configuration — Quad9 DoH primary, encrypted fallback off
        // — leaves both identities equal and this assertion can never pass. Exactly the
        // impossible-state trap this suite has now hit three times, introduced by the gating that
        // fixed a different finding (Codex P1, PR #599).
        var customFallback = encryptedLegLive
        customFallback.fallbackResolverPresetID = DNSResolverPreset.customID
        customFallback.fallbackCustomResolverAddress = "9.9.9.9"
        var customFallbackMoved = customFallback
        customFallbackMoved.fallbackCustomResolverAddress = "1.1.1.1"
        XCTAssertNotEqual(
            customFallback.chainedTierOneRungPolicyIdentity,
            customFallbackMoved.chainedTierOneRungPolicyIdentity,
            "two custom fallback resolvers are two resolvers, whatever the preset ID says")

        // AND IT MUST NOT CHURN. The relatch bumps the data-path epoch and republishes, so a value
        // that moved on unrelated writes would reset the panel's evidence on every settings save.
        var unrelated = base
        unrelated.keepFilteringCounts = !base.keepFilteringCounts
        unrelated.keepDomainDiagnostics = !base.keepDomainDiagnostics
        XCTAssertEqual(
            base.chainedTierOneRungPolicyIdentity,
            unrelated.chainedTierOneRungPolicyIdentity,
            "settings the rung's ladder never reads must not force a relatch")
    }

    // MARK: - Unchosen resolvers resolve to the network's own, never to a company

    /// A STORED CONFIGURATION WITH NO PRIMARY RESOLVER IS NOT A CHOICE FOR A THIRD PARTY.
    ///
    /// The field is absent on configurations written before it existed. Defaulting it to an
    /// encrypted third-party resolver silently routes that user's allowed lookups to a company
    /// they never picked; Device DNS hands the decision back to the network they are already on
    /// (`lavasec-infra` `plans/2026-06-15-device-dns-default-plan.md`, Product Rules).
    func testAbsentPrimaryResolverDecodesToDeviceDNSRatherThanAThirdParty() throws {
        let data = Data("{}".utf8)

        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertEqual(configuration.resolverPresetID, DNSResolverPreset.device.id)
        XCTAssertEqual(configuration.resolverPreset, .device)
    }

    /// An id this build cannot recognise — a downgrade past a later preset, or a corrupted
    /// value — is not a choice either, so the runtime resolves it to Device DNS.
    ///
    /// The MEMBERWISE initializer deliberately leaves the raw value alone: it is not a persistence
    /// boundary, and a value-type init that silently rewrites its argument breaks callers that
    /// pass a distinctive marker to prove a field survives a transform — which is exactly what
    /// `FilterSwitchPlanTests` does (Codex review, PR #642).
    func testUnrecognisedPrimaryResolverIDResolvesToDeviceDNSWithoutRewritingTheStoredValue() {
        let configuration = AppConfiguration(resolverPresetID: "a-preset-this-build-never-shipped")

        XCTAssertEqual(configuration.resolverPresetID, "a-preset-this-build-never-shipped")
        XCTAssertEqual(configuration.resolverPreset, .device)
    }

    /// ...and the same holds for an id assigned AFTER construction, which no initializer could
    /// normalise anyway. This is what keeps `resolverPreset`'s `?? .device` live.
    func testAnIDAssignedAfterConstructionStillResolvesToDeviceDNS() {
        var configuration = AppConfiguration()
        configuration.resolverPresetID = "a-preset-this-build-never-shipped"

        XCTAssertEqual(configuration.resolverPreset, .device)
    }

    /// THE OTHER HALF OF THE RULE, and the one that would make this change a regression if it
    /// broke: a user who DID choose keeps their choice, on decode and on the in-memory value.
    func testAnExplicitResolverChoiceIsNeverRewrittenToDeviceDNS() throws {
        let data = Data("""
        { "resolverPresetID": "\(DNSResolverPreset.google.id)" }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertEqual(decoded.resolverPresetID, DNSResolverPreset.google.id)
        XCTAssertEqual(decoded.resolverPreset, .google)
    }

    /// The ENCRYPTED FALLBACK keeps its own rule, and the asymmetry is the point: that field
    /// only runs when a Device-DNS primary has wedged, so resolving it to the device's resolver
    /// would aim the safety net at the thing it exists to rescue.
    func testTheEncryptedFallbackStillResolvesToQuad9NotDeviceDNS() {
        var configuration = AppConfiguration()
        configuration.fallbackResolverPresetID = "a-preset-this-build-never-shipped"

        XCTAssertEqual(configuration.fallbackResolverPreset, .quad9UnfilteredDoH)
        XCTAssertNotEqual(configuration.fallbackResolverPreset, .device)
    }

    /// WHAT THE SETTINGS SCREEN SHOWS MUST BE WHAT THE RESOLVER STACK RUNS.
    ///
    /// `resolverPreset` resolving an unknown id to Device DNS is not enough on its own:
    /// `DNSResolverSettingsView.usesDeviceDNSSetting` and `AppViewModel.dnsResolverSummaryText`
    /// both key off the RAW id, so a downgraded or corrupted configuration rendered as
    /// "Device + Fallback" while `ResolverTierTwo.make` returned `.none` — advertising a fallback
    /// path that did not exist (Codex review, PR #642). Normalising the stored id keeps the two
    /// in sync by construction.
    func testAnUnrecognisedStoredResolverIDIsNormalisedSoTheUIAndRuntimeAgree() throws {
        let data = Data("""
        { "resolverPresetID": "a-preset-a-later-build-added" }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertEqual(
            decoded.resolverPresetID, DNSResolverPreset.device.id,
            "the stored id is what the settings screen reads, so it has to be the real one")
        XCTAssertEqual(decoded.resolverPreset, .device)
    }

    /// A BUILDABLE Custom record is passed through untouched — normalising a real Custom selection
    /// would leave `isCustomResolverSelected` true while `usesDeviceDNSSetting` also became true,
    /// so the settings screen would claim both at once.
    func testABuildableCustomResolverIDIsNeverNormalisedToDeviceDNS() throws {
        let data = Data("""
        {
          "resolverPresetID": "\(DNSResolverPreset.customID)",
          "customResolverAddress": "https://dns.example/dns-query",
          "customResolverName": "My Resolver"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertEqual(decoded.resolverPresetID, DNSResolverPreset.customID)
        XCTAssertEqual(decoded.resolverPreset.displayName, "My Resolver")
    }

    /// ...but an UNBUILDABLE Custom record is not a Custom selection. Its address is missing,
    /// malformed, or in a form this build no longer parses, so `DNSResolverPreset.custom` returns
    /// nil and `resolverPreset` falls through to Device DNS — while `DNSResolverSettingsView`
    /// reads the raw id and presents Custom DNS. Same presentation-versus-runtime split as an
    /// unknown built-in id, through the door an unconditional Custom exemption left open (Codex
    /// review, PR #642).
    func testAnUnbuildableCustomResolverRecordNormalisesToDeviceDNS() throws {
        let data = Data("""
        { "resolverPresetID": "\(DNSResolverPreset.customID)" }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertEqual(
            decoded.resolverPresetID, DNSResolverPreset.device.id,
            "a Custom id with no address cannot build, so presenting Custom would be a lie")
        XCTAssertEqual(decoded.resolverPreset, .device)
    }

    /// The FALLBACK resolver keeps its own Custom handling — this normalisation is scoped to the
    /// primary, and a fallback Custom record is a separate field with separate addresses.
    func testTheFallbackCustomResolverIsUntouchedByPrimaryNormalisation() throws {
        let data = Data("""
        {
          "resolverPresetID": "\(DNSResolverPreset.device.id)",
          "fallbackResolverPresetID": "\(DNSResolverPreset.customID)",
          "fallbackCustomResolverAddress": "https://fallback.example/dns-query",
          "fallbackCustomResolverName": "My Fallback"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertEqual(decoded.fallbackResolverPresetID, DNSResolverPreset.customID)
        XCTAssertEqual(decoded.fallbackResolverPreset.displayName, "My Fallback")
    }

    /// A known built-in id survives decoding untouched — the normalisation must not be a
    /// blanket rewrite that quietly discards resolvers this build does support.
    func testEveryBuiltInResolverIDSurvivesNormalisation() throws {
        for preset in DNSResolverPreset.allPresets {
            let data = Data("{ \"resolverPresetID\": \"\(preset.id)\" }".utf8)
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
            XCTAssertEqual(
                decoded.resolverPresetID, preset.id,
                "\(preset.id) was rewritten by normalisation")
        }
    }
}
