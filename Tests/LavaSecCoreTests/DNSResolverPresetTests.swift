import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class DNSResolverPresetTests: XCTestCase {
    func testBuiltInResolversKeepCurrentIPBasedPresetsOnly() throws {
        XCTAssertEqual(DNSResolverPreset.builtInPresets.map(\.id), [
            "device-dns",
            "mullvad",
            "cloudflare-1111",
            "quad9-secure",
            "google-public-dns"
        ])
    }

    func testAllPresetsKeepCurrentIPBasedPresetsAndAppendEncryptedPresets() throws {
        XCTAssertEqual(DNSResolverPreset.allPresets.map(\.id), [
            "device-dns",
            "mullvad",
            "cloudflare-1111",
            "quad9-secure",
            "google-public-dns",
            "mullvad-doh",
            "cloudflare-1111-doh",
            "quad9-secure-doh",
            "google-public-dns-doh",
            "mullvad-dot",
            "cloudflare-1111-dot",
            "quad9-secure-dot",
            "google-public-dns-dot"
        ])
    }

    func testBuiltInDoHEndpointsUseExpectedURLs() throws {
        XCTAssertNil(DNSResolverPreset.device.dohEndpoint)
        XCTAssertNil(DNSResolverPreset.google.dohEndpoint)
        XCTAssertNil(DNSResolverPreset.cloudflare.dohEndpoint)
        XCTAssertNil(DNSResolverPreset.quad9Secure.dohEndpoint)
        XCTAssertNil(DNSResolverPreset.mullvad.dohEndpoint)

        XCTAssertEqual(DNSResolverPreset.googleDoH.dohEndpoint?.url.absoluteString, "https://dns.google/dns-query")
        XCTAssertEqual(DNSResolverPreset.cloudflareDoH.dohEndpoint?.url.absoluteString, "https://cloudflare-dns.com/dns-query")
        XCTAssertEqual(DNSResolverPreset.quad9SecureDoH.dohEndpoint?.url.absoluteString, "https://dns.quad9.net/dns-query")
        XCTAssertEqual(DNSResolverPreset.mullvadDoH.dohEndpoint?.url.absoluteString, "https://dns.mullvad.net/dns-query")
    }

    func testBuiltInDoTEndpointsUseExpectedHostsAndPorts() throws {
        XCTAssertNil(DNSResolverPreset.device.dotEndpoint)
        XCTAssertNil(DNSResolverPreset.google.dotEndpoint)
        XCTAssertNil(DNSResolverPreset.cloudflare.dotEndpoint)
        XCTAssertNil(DNSResolverPreset.quad9Secure.dotEndpoint)
        XCTAssertNil(DNSResolverPreset.mullvad.dotEndpoint)

        XCTAssertEqual(DNSResolverPreset.googleDoT.dotEndpoint?.hostname, "dns.google")
        XCTAssertEqual(DNSResolverPreset.googleDoT.dotEndpoint?.port, 853)
        XCTAssertEqual(DNSResolverPreset.googleDoT.dotEndpoint?.bootstrapIPv4Servers, ["8.8.8.8", "8.8.4.4"])
        XCTAssertEqual(DNSResolverPreset.cloudflareDoT.dotEndpoint?.hostname, "one.one.one.one")
        XCTAssertEqual(DNSResolverPreset.cloudflareDoT.dotEndpoint?.port, 853)
        XCTAssertEqual(DNSResolverPreset.quad9SecureDoT.dotEndpoint?.hostname, "dns.quad9.net")
        XCTAssertEqual(DNSResolverPreset.mullvadDoT.dotEndpoint?.hostname, "dns.mullvad.net")
    }

    func testDoHDisplayNamesAreSuffixed() throws {
        XCTAssertEqual(DNSResolverPreset.googleDoH.displayName, "Google Public DNS (DoH)")
        XCTAssertEqual(DNSResolverPreset.cloudflareDoH.displayName, "Cloudflare 1.1.1.1 (DoH)")
        XCTAssertEqual(DNSResolverPreset.quad9SecureDoH.displayName, "Quad9 Secure (DoH)")
        XCTAssertEqual(DNSResolverPreset.mullvadDoH.displayName, "Mullvad (DoH)")
    }

    func testDoTDisplayNamesAreSuffixed() throws {
        XCTAssertEqual(DNSResolverPreset.googleDoT.displayName, "Google Public DNS (DoT)")
        XCTAssertEqual(DNSResolverPreset.cloudflareDoT.displayName, "Cloudflare 1.1.1.1 (DoT)")
        XCTAssertEqual(DNSResolverPreset.quad9SecureDoT.displayName, "Quad9 Secure (DoT)")
        XCTAssertEqual(DNSResolverPreset.mullvadDoT.displayName, "Mullvad (DoT)")
    }

    func testShortDisplayNamesUseCompactProviderNames() throws {
        XCTAssertEqual(DNSResolverPreset.device.shortDisplayName, "Device")
        XCTAssertEqual(DNSResolverPreset.google.shortDisplayName, "Google")
        XCTAssertEqual(DNSResolverPreset.cloudflare.shortDisplayName, "Cloudflare")
        XCTAssertEqual(DNSResolverPreset.quad9Secure.shortDisplayName, "Quad9")
        XCTAssertEqual(DNSResolverPreset.mullvad.shortDisplayName, "Mullvad")
        XCTAssertEqual(DNSResolverPreset.googleDoH.shortDisplayName, "Google (DoH)")
        XCTAssertEqual(DNSResolverPreset.cloudflareDoH.shortDisplayName, "Cloudflare (DoH)")
        XCTAssertEqual(DNSResolverPreset.quad9SecureDoH.shortDisplayName, "Quad9 (DoH)")
        XCTAssertEqual(DNSResolverPreset.mullvadDoH.shortDisplayName, "Mullvad (DoH)")
        XCTAssertEqual(DNSResolverPreset.googleDoT.shortDisplayName, "Google (DoT)")
        XCTAssertEqual(DNSResolverPreset.cloudflareDoT.shortDisplayName, "Cloudflare (DoT)")
        XCTAssertEqual(DNSResolverPreset.quad9SecureDoT.shortDisplayName, "Quad9 (DoT)")
        XCTAssertEqual(DNSResolverPreset.mullvadDoT.shortDisplayName, "Mullvad (DoT)")
    }

    func testGuardFlowDNSDetailsDoNotRepeatDNS() throws {
        XCTAssertEqual(DNSResolverPreset.device.guardFlowDNSDetailText, "Device")
        XCTAssertEqual(DNSResolverPreset.google.guardFlowDNSDetailText, "Google (IP)")
        XCTAssertEqual(DNSResolverPreset.cloudflare.guardFlowDNSDetailText, "Cloudflare (IP)")
        XCTAssertEqual(DNSResolverPreset.quad9Secure.guardFlowDNSDetailText, "Quad9 (IP)")
        XCTAssertEqual(DNSResolverPreset.mullvad.guardFlowDNSDetailText, "Mullvad (IP)")
        XCTAssertEqual(DNSResolverPreset.googleDoH.guardFlowDNSDetailText, "Google (DoH)")
        XCTAssertEqual(DNSResolverPreset.cloudflareDoH.guardFlowDNSDetailText, "Cloudflare (DoH)")
        XCTAssertEqual(DNSResolverPreset.quad9SecureDoH.guardFlowDNSDetailText, "Quad9 (DoH)")
        XCTAssertEqual(DNSResolverPreset.mullvadDoH.guardFlowDNSDetailText, "Mullvad (DoH)")
        XCTAssertEqual(DNSResolverPreset.googleDoT.guardFlowDNSDetailText, "Google (DoT)")
        XCTAssertEqual(DNSResolverPreset.cloudflareDoT.guardFlowDNSDetailText, "Cloudflare (DoT)")
        XCTAssertEqual(DNSResolverPreset.quad9SecureDoT.guardFlowDNSDetailText, "Quad9 (DoT)")
        XCTAssertEqual(DNSResolverPreset.mullvadDoT.guardFlowDNSDetailText, "Mullvad (DoT)")
    }

    func testDoHPresetsAnnotateDoH3OnlyForNegotiatedHTTP3() {
        XCTAssertEqual(DNSResolverPreset.googleDoH.shortDisplayName(dohHTTPVersion: "h3"), "Google (DoH3)")
        XCTAssertEqual(DNSResolverPreset.cloudflareDoH.shortDisplayName(dohHTTPVersion: "h3"), "Cloudflare (DoH3)")
        XCTAssertEqual(DNSResolverPreset.quad9SecureDoH.shortDisplayName(dohHTTPVersion: "h3"), "Quad9 (DoH3)")
        XCTAssertEqual(DNSResolverPreset.mullvadDoH.shortDisplayName(dohHTTPVersion: "h3"), "Mullvad (DoH3)")

        // Draft ALPN identifiers still count as HTTP/3.
        XCTAssertEqual(DNSResolverPreset.cloudflareDoH.shortDisplayName(dohHTTPVersion: "h3-29"), "Cloudflare (DoH3)")

        // Anything other than an observed h3 negotiation keeps the plain
        // annotation: DoH3 is preferred, never promised.
        XCTAssertEqual(DNSResolverPreset.cloudflareDoH.shortDisplayName(dohHTTPVersion: "h2"), "Cloudflare (DoH)")
        XCTAssertEqual(DNSResolverPreset.cloudflareDoH.shortDisplayName(dohHTTPVersion: "http/1.1"), "Cloudflare (DoH)")
        XCTAssertEqual(DNSResolverPreset.cloudflareDoH.shortDisplayName(dohHTTPVersion: nil), "Cloudflare (DoH)")

        // Non-DoH presets never pick up the DoH3 annotation.
        XCTAssertEqual(DNSResolverPreset.cloudflareDoT.shortDisplayName(dohHTTPVersion: "h3"), "Cloudflare (DoT)")
        XCTAssertEqual(DNSResolverPreset.cloudflare.shortDisplayName(dohHTTPVersion: "h3"), "Cloudflare")

        XCTAssertEqual(DNSResolverPreset.quad9SecureDoH.guardFlowDNSDetailText(dohHTTPVersion: "h3"), "Quad9 (DoH3)")
    }

    func testGuardFlowDNSDetailComponentsSeparateNameAndTransport() throws {
        XCTAssertEqual(
            DNSResolverPreset.quad9SecureDoH.guardFlowDNSDetailComponents(dohHTTPVersion: "h3"),
            GuardFlowDNSDetail(name: "Quad9", transportAnnotation: "DoH3")
        )
        XCTAssertEqual(
            DNSResolverPreset.cloudflareDoT.guardFlowDNSDetailComponents(),
            GuardFlowDNSDetail(name: "Cloudflare", transportAnnotation: "DoT")
        )
        XCTAssertEqual(
            DNSResolverPreset.google.guardFlowDNSDetailComponents(),
            GuardFlowDNSDetail(name: "Google", transportAnnotation: "IP")
        )
        XCTAssertEqual(
            DNSResolverPreset.device.guardFlowDNSDetailComponents(),
            GuardFlowDNSDetail(name: "Device", transportAnnotation: nil),
            "The device resolver's name already is the transport."
        )

        // Custom resolvers carry their EFFECTIVE transport, including plain IP.
        let customDoH = try XCTUnwrap(
            DNSResolverPreset.custom(rawValue: "https://dns.example/dns-query", displayName: "Home DNS")
        )
        XCTAssertEqual(
            customDoH.guardFlowDNSDetailComponents(),
            GuardFlowDNSDetail(name: "Home DNS", transportAnnotation: "DoH")
        )
        XCTAssertEqual(
            customDoH.guardFlowDNSDetailComponents(dohHTTPVersion: "h3"),
            GuardFlowDNSDetail(name: "Home DNS", transportAnnotation: "DoH3")
        )

        let customPlain = try XCTUnwrap(DNSResolverPreset.custom(rawValue: "1.2.3.4"))
        XCTAssertEqual(customPlain.guardFlowDNSDetailComponents().transportAnnotation, "IP")
    }

    func testCustomResolverUsesOptionalDisplayNameWithGenericFallback() throws {
        let namedResolver = try XCTUnwrap(
            DNSResolverPreset.custom(rawValue: "https://dns.example/dns-query", displayName: " Home DNS ")
        )
        let unnamedResolver = try XCTUnwrap(
            DNSResolverPreset.custom(rawValue: "https://dns.example/dns-query", displayName: "   ")
        )

        XCTAssertEqual(namedResolver.displayName, "Home DNS")
        XCTAssertEqual(namedResolver.shortDisplayName, "Home DNS")
        XCTAssertEqual(
            namedResolver.guardFlowDNSDetailText,
            "Home DNS (DoH)",
            "Custom resolvers surface their effective transport in the Guard step."
        )
        XCTAssertEqual(unnamedResolver.displayName, "Custom DNS")
        XCTAssertEqual(unnamedResolver.shortDisplayName, "Custom DNS")
    }

    func testCustomResolverCombinesPrimaryAndSecondaryPlainDNSAddresses() throws {
        let preset = try XCTUnwrap(
            DNSResolverPreset.custom(
                primaryRawValue: "9.9.9.9",
                secondaryRawValue: "2620:fe::fe",
                displayName: "Home DNS"
            )
        )

        XCTAssertEqual(preset.transport, .plainDNS)
        XCTAssertEqual(preset.ipv4Servers, ["9.9.9.9"])
        XCTAssertEqual(preset.ipv6Servers, ["2620:fe::fe"])
        XCTAssertNil(preset.dohEndpoint)
        XCTAssertNil(preset.dotEndpoint)
    }

    func testCustomResolverCombinesPrimaryAndSecondaryDoHEndpoints() throws {
        let preset = try XCTUnwrap(
            DNSResolverPreset.custom(
                primaryRawValue: "https://one.example/dns-query",
                secondaryRawValue: "https://two.example/dns-query",
                displayName: nil
            )
        )

        XCTAssertEqual(preset.transport, .dnsOverHTTPS)
        XCTAssertEqual(preset.dohEndpoints.map { $0.url.absoluteString }, [
            "https://one.example/dns-query",
            "https://two.example/dns-query"
        ])
        XCTAssertEqual(preset.dohEndpoint?.url.absoluteString, "https://one.example/dns-query")
        XCTAssertNil(preset.dotEndpoint)
    }

    func testCustomResolverCombinesPrimaryAndSecondaryDoTEndpoints() throws {
        let preset = try XCTUnwrap(
            DNSResolverPreset.custom(
                primaryRawValue: "tls://one.example:853",
                secondaryRawValue: "dot://two.example:853",
                displayName: nil
            )
        )

        XCTAssertEqual(preset.transport, .dnsOverTLS)
        XCTAssertEqual(preset.dotEndpoints.map(\.displayAddress), [
            "one.example:853",
            "two.example:853"
        ])
        XCTAssertEqual(preset.dotEndpoint?.hostname, "one.example")
        XCTAssertNil(preset.dohEndpoint)
    }

    func testCustomResolverCombinesPrimaryAndSecondaryDoQEndpoints() throws {
        let preset = try XCTUnwrap(
            DNSResolverPreset.custom(
                primaryRawValue: "doq://one.example:853",
                secondaryRawValue: "quic://two.example:853",
                displayName: nil
            )
        )

        XCTAssertEqual(preset.transport, .dnsOverQUIC)
        XCTAssertEqual(preset.doqEndpoints.map(\.displayAddress), [
            "one.example:853",
            "two.example:853"
        ])
        XCTAssertEqual(preset.doqEndpoint?.hostname, "one.example")
        XCTAssertNil(preset.dohEndpoint)
        XCTAssertNil(preset.dotEndpoint)
    }

    func testCustomResolverRejectsSecondaryWithDifferentTransport() throws {
        XCTAssertNil(
            DNSResolverPreset.custom(
                primaryRawValue: "https://dns.example/dns-query",
                secondaryRawValue: "9.9.9.9",
                displayName: nil
            )
        )
        XCTAssertEqual(
            DNSResolverPreset.customValidationMessage(
                primaryRawValue: "https://dns.example/dns-query",
                secondaryRawValue: "9.9.9.9"
            ),
            "Secondary DNS must use the same transport as Primary DNS."
        )
    }

    func testResolverTransportComesFromPreset() throws {
        XCTAssertEqual(DNSResolverPreset.device.transport, .deviceDNS)
        XCTAssertEqual(DNSResolverPreset.google.transport, .plainDNS)
        XCTAssertEqual(DNSResolverPreset.googleDoH.transport, .dnsOverHTTPS)
        XCTAssertEqual(DNSResolverPreset.googleDoT.transport, .dnsOverTLS)
        XCTAssertEqual(DNSResolverPreset.custom(rawValue: "doq://dns.example")?.transport, .dnsOverQUIC)
    }

    func testTransportMenuTitlesUseProtocolNamesForSettingsSelector() throws {
        XCTAssertEqual(DNSResolverTransport.plainDNS.menuTitle, "IP")
        XCTAssertEqual(DNSResolverTransport.dnsOverHTTPS.menuTitle, "HTTPS")
        XCTAssertEqual(DNSResolverTransport.dnsOverTLS.menuTitle, "TLS")
        XCTAssertEqual(DNSResolverTransport.dnsOverQUIC.menuTitle, "QUIC")
    }

    func testDeviceDNSPresetDoesNotBakeInPublicResolverAddresses() throws {
        XCTAssertEqual(DNSResolverPreset.device.displayName, "Device DNS")
        XCTAssertTrue(DNSResolverPreset.device.ipv4Servers.isEmpty)
        XCTAssertTrue(DNSResolverPreset.device.ipv6Servers.isEmpty)
        XCTAssertFalse(DNSResolverPreset.device.hasUpstreamFiltering)
    }

    func testDoHCacheIdentifiersIncludeEndpointURL() throws {
        XCTAssertEqual(DNSResolverPreset.googleDoH.dohEndpoint?.cacheIdentifier, "doh:https://dns.google/dns-query")
    }

    func testDoTCacheIdentifiersIncludeHostnameAndPort() throws {
        XCTAssertEqual(DNSResolverPreset.googleDoT.dotEndpoint?.cacheIdentifier, "dot:dns.google:853")
    }

    func testBuiltInResolversDoNotExposeDNSOverQUIC() throws {
        XCTAssertFalse(DNSResolverPreset.allPresets.contains { $0.transport == .dnsOverQUIC })
        XCTAssertFalse(DNSResolverPreset.settingsPresets.contains { $0.availableTransports.contains(.dnsOverQUIC) })
    }

    func testLegacyJSONWithoutTransportDecodesAsPlainDNS() throws {
        let json = """
        {
            "id": "legacy-resolver",
            "displayName": "Legacy Resolver",
            "ipv4Servers": ["192.0.2.1"],
            "ipv6Servers": [],
            "notes": "Encoded before resolver transport metadata existed.",
            "hasUpstreamFiltering": false
        }
        """.data(using: .utf8)!

        let preset = try JSONDecoder().decode(DNSResolverPreset.self, from: json)

        XCTAssertEqual(preset.transport, .plainDNS)
        XCTAssertNil(preset.dohEndpoint)
    }

    func testRetiredDNSSBIDsMigrateToMullvad() throws {
        XCTAssertEqual(DNSResolverPreset.migratedPresetID("dns-sb"), DNSResolverPreset.mullvad.id)
        XCTAssertEqual(DNSResolverPreset.migratedPresetID("dns-sb-doh"), DNSResolverPreset.mullvadDoH.id)
        XCTAssertEqual(DNSResolverPreset.migratedPresetID("dns-sb-dot"), DNSResolverPreset.mullvadDoT.id)
        XCTAssertEqual(DNSResolverPreset.migratedPresetID("cloudflare-1111"), "cloudflare-1111")
    }

    func testDecodingConfigurationWithRetiredDNSSBIDMigratesToMullvad() throws {
        let json = """
        {
            "resolverPresetID": "dns-sb"
        }
        """.data(using: .utf8)!

        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: json)

        XCTAssertEqual(configuration.resolverPreset.id, DNSResolverPreset.mullvad.id)
    }

    func testAppConfigurationResolvesPersistedDoHResolverIDFromFullCatalog() throws {
        let configuration = AppConfiguration(resolverPresetID: DNSResolverPreset.cloudflareDoH.id)

        XCTAssertEqual(configuration.resolverPreset, .cloudflareDoH)
    }

    func testAppConfigurationResolvesPersistedDoTResolverIDFromFullCatalog() throws {
        let configuration = AppConfiguration(resolverPresetID: DNSResolverPreset.cloudflareDoT.id)

        XCTAssertEqual(configuration.resolverPreset, .cloudflareDoT)
    }

    func testCustomResolverAcceptsDNSOverTLSURL() throws {
        let preset = try XCTUnwrap(DNSResolverPreset.custom(rawValue: "tls://dns.example:853"))

        XCTAssertEqual(preset.transport, .dnsOverTLS)
        XCTAssertEqual(preset.dotEndpoint?.hostname, "dns.example")
        XCTAssertEqual(preset.dotEndpoint?.port, 853)
        XCTAssertTrue(preset.dotEndpoint?.bootstrapIPv4Servers.isEmpty == true)
    }

    func testCustomResolverRejectsDNSOverTLSURLWithInvalidPort() throws {
        XCTAssertNil(DNSResolverPreset.custom(rawValue: "tls://dns.example:99999"))
    }

    func testCustomResolverAcceptsDNSOverQUICURLs() throws {
        let explicitPortPreset = try XCTUnwrap(DNSResolverPreset.custom(rawValue: "doq://dns.quad9.net:853"))
        let defaultPortPreset = try XCTUnwrap(DNSResolverPreset.custom(rawValue: "quic://dns.example"))

        XCTAssertEqual(explicitPortPreset.transport, .dnsOverQUIC)
        XCTAssertEqual(explicitPortPreset.doqEndpoint?.hostname, "dns.quad9.net")
        XCTAssertEqual(explicitPortPreset.doqEndpoint?.port, 853)
        XCTAssertEqual(explicitPortPreset.doqEndpoint?.cacheIdentifier, "doq:dns.quad9.net:853")
        XCTAssertEqual(defaultPortPreset.transport, .dnsOverQUIC)
        XCTAssertEqual(defaultPortPreset.doqEndpoint?.displayAddress, "dns.example:853")
    }

    func testCustomResolverRejectsAmbiguousOrUnsafeEndpointValuesWithSpecificMessages() throws {
        XCTAssertEqual(
            DNSResolverPreset.customValidationMessage(rawValue: ""),
            "Enter one IPv4/6 DNS server, DoH URL, DoT URL, DoQ URL, or DNS stamp."
        )
        XCTAssertEqual(
            DNSResolverPreset.customValidationMessage(rawValue: "http://dns.example/dns-query"),
            "Use one IPv4/6 DNS server, DoH URL, DoT URL, DoQ URL, or sdns:// DNS stamp."
        )
        XCTAssertEqual(
            DNSResolverPreset.customValidationMessage(rawValue: "https://dns.example"),
            "DNS-over-HTTPS URLs must include a path, such as /dns-query."
        )
        XCTAssertEqual(
            DNSResolverPreset.customValidationMessage(rawValue: "https://localhost/dns-query"),
            "Localhost cannot be used as a DNS resolver here."
        )
        XCTAssertEqual(
            DNSResolverPreset.customValidationMessage(rawValue: "tls://dns_example:853"),
            "Enter a valid DNS resolver host."
        )
        XCTAssertEqual(
            DNSResolverPreset.customValidationMessage(rawValue: "0.0.0.0"),
            "Enter a usable DNS resolver address, not a loopback, multicast, or unspecified address."
        )
        XCTAssertNil(DNSResolverPreset.customValidationMessage(rawValue: "9.9.9.9"))
        XCTAssertNil(DNSResolverPreset.customValidationMessage(rawValue: "https://dns.example/dns-query"))
        XCTAssertNil(DNSResolverPreset.customValidationMessage(rawValue: "tls://dns.example:853"))
        XCTAssertNil(DNSResolverPreset.customValidationMessage(rawValue: "doq://dns.example:853"))
    }

    func testCustomResolverRejectsDNSOverQUICWhenRuntimeIsUnsupported() throws {
        XCTAssertEqual(
            DNSResolverPreset.customValidationMessage(rawValue: "doq://dns.example:853", supportsDNSOverQUIC: false),
            "DNS over QUIC is not supported on this device."
        )
        XCTAssertEqual(
            DNSResolverPreset.customValidationMessage(primaryRawValue: "doq://dns.example:853", secondaryRawValue: nil, supportsDNSOverQUIC: false),
            "DNS over QUIC is not supported on this device."
        )
        XCTAssertEqual(
            DNSResolverPreset.customValidationMessage(primaryRawValue: "9.9.9.9", secondaryRawValue: "quic://dns.example", supportsDNSOverQUIC: false),
            "DNS over QUIC is not supported on this device."
        )
        XCTAssertNil(DNSResolverPreset.customValidationMessage(rawValue: "doq://dns.example:853", supportsDNSOverQUIC: true))
    }

    func testCustomResolverAcceptsPlainDNSStamp() throws {
        let stamp = Self.plainDNSStamp(address: "9.9.9.9")
        let preset = try XCTUnwrap(DNSResolverPreset.custom(rawValue: stamp))

        XCTAssertEqual(preset.transport, .plainDNS)
        XCTAssertEqual(preset.ipv4Servers, ["9.9.9.9"])
        XCTAssertTrue(preset.ipv6Servers.isEmpty)
    }

    func testCustomResolverAcceptsDoHStamp() throws {
        let stamp = Self.dohStamp(
            address: "1.1.1.1",
            hostname: "cloudflare-dns.com",
            path: "/dns-query",
            bootstrapIPs: ["1.0.0.1"]
        )
        let preset = try XCTUnwrap(DNSResolverPreset.custom(rawValue: stamp))

        XCTAssertEqual(preset.transport, .dnsOverHTTPS)
        XCTAssertEqual(preset.dohEndpoint?.url.absoluteString, "https://cloudflare-dns.com/dns-query")
        XCTAssertEqual(preset.dohEndpoint?.bootstrapIPv4Servers, ["1.1.1.1", "1.0.0.1"])
    }

    func testCustomResolverAcceptsDoTStamp() throws {
        let stamp = Self.dotStamp(
            address: "94.140.14.14:853",
            hostname: "dns.adguard-dns.com",
            bootstrapIPs: ["94.140.15.15"]
        )
        let preset = try XCTUnwrap(DNSResolverPreset.custom(rawValue: stamp))

        XCTAssertEqual(preset.transport, .dnsOverTLS)
        XCTAssertEqual(preset.dotEndpoint?.hostname, "dns.adguard-dns.com")
        XCTAssertEqual(preset.dotEndpoint?.port, 853)
        XCTAssertEqual(preset.dotEndpoint?.bootstrapIPv4Servers, ["94.140.14.14", "94.140.15.15"])
    }

    func testCustomResolverAcceptsDoQStamp() throws {
        let stamp = Self.doqStamp(
            address: "9.9.9.9:853",
            hostname: "dns.quad9.net",
            bootstrapIPs: ["149.112.112.112"]
        )
        let preset = try XCTUnwrap(DNSResolverPreset.custom(rawValue: stamp))

        XCTAssertEqual(preset.transport, .dnsOverQUIC)
        XCTAssertEqual(preset.doqEndpoint?.hostname, "dns.quad9.net")
        XCTAssertEqual(preset.doqEndpoint?.port, 853)
        XCTAssertEqual(preset.doqEndpoint?.bootstrapIPv4Servers, ["9.9.9.9", "149.112.112.112"])
    }

    private static func plainDNSStamp(address: String) -> String {
        stamp(protocolID: 0x00) {
            appendLP(address, to: &$0)
        }
    }

    private static func dohStamp(address: String, hostname: String, path: String, bootstrapIPs: [String]) -> String {
        stamp(protocolID: 0x02) {
            appendLP(address, to: &$0)
            appendLP("", to: &$0)
            appendLP(hostname, to: &$0)
            appendLP(path, to: &$0)
            appendVLP(bootstrapIPs, to: &$0)
        }
    }

    private static func dotStamp(address: String, hostname: String, bootstrapIPs: [String]) -> String {
        stamp(protocolID: 0x03) {
            appendLP(address, to: &$0)
            appendLP("", to: &$0)
            appendLP(hostname, to: &$0)
            appendVLP(bootstrapIPs, to: &$0)
        }
    }

    private static func doqStamp(address: String, hostname: String, bootstrapIPs: [String]) -> String {
        stamp(protocolID: 0x04) {
            appendLP(address, to: &$0)
            appendLP("", to: &$0)
            appendLP(hostname, to: &$0)
            appendVLP(bootstrapIPs, to: &$0)
        }
    }

    private static func stamp(protocolID: UInt8, body: (inout Data) -> Void) -> String {
        var data = Data([protocolID])
        data.append(contentsOf: Array(repeating: UInt8(0), count: 8))
        body(&data)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "sdns://\(encoded)"
    }

    private static func appendLP(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        data.append(UInt8(bytes.count))
        data.append(bytes)
    }

    private static func appendVLP(_ values: [String], to data: inout Data) {
        for (index, value) in values.enumerated() {
            let bytes = Data(value.utf8)
            let hasMore = index < values.count - 1
            data.append(UInt8(bytes.count) | (hasMore ? 0x80 : 0x00))
            data.append(bytes)
        }
    }
}
