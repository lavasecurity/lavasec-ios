import Foundation
import XCTest
@testable import LavaSecCore

/// Characterization tests for the IP-address scope classification behind
/// `NetworkEndpointValidator`. The `IPAddressScope` enum itself is file-private,
/// so the classification is observed through the three internal entry points,
/// which expose three distinguishable buckets:
///
/// - "public"  -> usable resolver address AND allowed public source host
/// - "private" -> usable resolver address BUT rejected public source host
/// - "unusable" -> rejected by both (loopback/link-local/multicast/unspecified/reserved)
final class NetworkEndpointValidationTests: XCTestCase {
    private enum ExpectedScope {
        case publicAddress
        case privateAddress
        case unusable
    }

    // MARK: - IPv4 classification

    func testIPv4ScopeClassificationAcrossValidatorEntryPoints() {
        let cases: [(host: String, expected: ExpectedScope, note: String)] = [
            // Unspecified / "this network" (leading octet 0 wins over everything)
            ("0.0.0.0", .unusable, "the unspecified address"),
            ("0.0.0.1", .unusable, "0.0.0.0/8 is classified by first octet alone"),
            ("0.255.255.255", .unusable, "upper edge of 0.0.0.0/8"),

            // Loopback 127.0.0.0/8
            ("126.255.255.255", .publicAddress, "one below the loopback block"),
            ("127.0.0.1", .unusable, "canonical loopback"),
            ("127.255.255.255", .unusable, "upper edge of 127.0.0.0/8"),
            ("128.0.0.0", .publicAddress, "one above the loopback block"),

            // RFC 1918 private: 10.0.0.0/8
            ("9.255.255.255", .publicAddress, "one below 10.0.0.0/8"),
            ("10.0.0.0", .privateAddress, "lower edge of 10.0.0.0/8"),
            ("10.255.255.255", .privateAddress, "upper edge of 10.0.0.0/8"),
            ("11.0.0.0", .publicAddress, "one above 10.0.0.0/8"),

            // RFC 1918 private: 172.16.0.0/12
            ("172.15.255.255", .publicAddress, "one below 172.16.0.0/12"),
            ("172.16.0.0", .privateAddress, "lower edge of 172.16.0.0/12"),
            ("172.31.255.255", .privateAddress, "upper edge of 172.16.0.0/12"),
            ("172.32.0.0", .publicAddress, "one above 172.16.0.0/12"),

            // RFC 1918 private: 192.168.0.0/16
            ("192.167.255.255", .publicAddress, "one below 192.168.0.0/16"),
            ("192.168.0.0", .privateAddress, "lower edge of 192.168.0.0/16"),
            ("192.168.255.255", .privateAddress, "upper edge of 192.168.0.0/16"),
            ("192.169.0.0", .publicAddress, "one above 192.168.0.0/16"),

            // CGNAT (shared address space) 100.64.0.0/10
            ("100.63.255.255", .publicAddress, "one below the CGNAT block"),
            ("100.64.0.0", .unusable, "lower edge of CGNAT 100.64.0.0/10"),
            ("100.127.255.255", .unusable, "upper edge of CGNAT 100.64.0.0/10"),
            ("100.128.0.0", .publicAddress, "one above the CGNAT block"),

            // Link-local 169.254.0.0/16
            ("169.253.255.255", .publicAddress, "one below the link-local block"),
            ("169.254.0.0", .unusable, "lower edge of link-local 169.254.0.0/16"),
            ("169.254.255.255", .unusable, "upper edge of link-local 169.254.0.0/16"),
            ("169.255.0.0", .publicAddress, "one above the link-local block"),

            // Multicast 224.0.0.0/4
            ("223.255.255.255", .publicAddress, "one below the multicast block"),
            ("224.0.0.0", .unusable, "start of multicast 224.0.0.0/4"),
            ("239.255.255.255", .unusable, "end of multicast 224.0.0.0/4"),

            // Class E 240.0.0.0/4 — "reserved for future use", not globally-routable public
            // unicast, so the whole /4 (incl. the 255/8 broadcast range) is reserved. Closing the
            // 240.0.0.0–254.255.255.255 gap the SSRF fetch gate previously left public (#40 review R1).
            ("240.0.0.0", .unusable, "start of Class E 240.0.0.0/4"),
            ("254.255.255.255", .unusable, "Class E just below the 255/8 range"),
            ("255.0.0.0", .unusable, "255.0.0.0/8 is reserved"),
            ("255.255.255.255", .unusable, "limited broadcast"),

            // IETF protocol assignments 192.0.0.0/24 + documentation TEST-NETs
            ("192.0.0.1", .unusable, "192.0.0.0/24 IETF protocol assignments"),
            ("192.0.1.1", .publicAddress, "192.0.1.0/24 is ordinary public space"),
            ("192.0.2.1", .unusable, "TEST-NET-1 192.0.2.0/24"),
            ("192.0.3.1", .publicAddress, "one /24 above TEST-NET-1"),
            ("198.51.99.1", .publicAddress, "one /24 below TEST-NET-2"),
            ("198.51.100.1", .unusable, "TEST-NET-2 198.51.100.0/24"),
            ("198.51.101.1", .publicAddress, "one /24 above TEST-NET-2"),
            ("203.0.112.1", .publicAddress, "one /24 below TEST-NET-3"),
            ("203.0.113.1", .unusable, "TEST-NET-3 203.0.113.0/24"),
            ("203.0.114.1", .publicAddress, "one /24 above TEST-NET-3"),

            // 6to4 relay anycast 192.88.99.0/24 (RFC 7526, deprecated) + benchmarking
            // 198.18.0.0/15 (RFC 2544) — reserved so the fetch gate rejects them (#40 review R1).
            ("192.88.98.1", .publicAddress, "one /24 below 6to4 anycast 192.88.99.0/24"),
            ("192.88.99.1", .unusable, "6to4 relay anycast 192.88.99.0/24"),
            ("192.88.100.1", .publicAddress, "one /24 above 6to4 anycast 192.88.99.0/24"),
            ("198.17.255.255", .publicAddress, "one below benchmarking 198.18.0.0/15"),
            ("198.18.0.0", .unusable, "start of benchmarking 198.18.0.0/15"),
            ("198.19.255.255", .unusable, "end of benchmarking 198.18.0.0/15"),
            ("198.20.0.0", .publicAddress, "one above benchmarking 198.18.0.0/15"),

            // Ordinary public resolvers
            ("1.1.1.1", .publicAddress, "Cloudflare"),
            ("8.8.8.8", .publicAddress, "Google"),
            ("9.9.9.9", .publicAddress, "Quad9"),

            // NOTE: leading-zero octets parse as DECIMAL ("010" == 10), unlike
            // POSIX inet_addr where a leading zero means octal. "010.0.0.1" is
            // therefore 10.0.0.1 (private) here. Characterized as-is.
            ("010.0.0.1", .privateAddress, "leading-zero octet parses as decimal 10 (see NOTE)"),
        ]

        for (host, expected, note) in cases {
            assertScope(host, expected, note)
        }
    }

    // MARK: - IPv6 classification

    func testIPv6ScopeClassificationAcrossValidatorEntryPoints() {
        let cases: [(host: String, expected: ExpectedScope, note: String)] = [
            // Unspecified and loopback
            ("::", .unusable, "the unspecified address"),
            ("::1", .unusable, "IPv6 loopback"),
            // IPv4-compatible IPv6 (::a.b.c.d, deprecated) now borrows its embedded IPv4 scope so
            // an embedded loopback/private can't masquerade as public IPv6 (#42 review, SSRF
            // defense-in-depth in the same class as the IPv4 reserved-range fix).
            ("::2", .unusable, "::0.0.0.2 embeds 0.0.0.0/8 'this network' → unspecified"),
            ("::127.0.0.1", .unusable, "IPv4-compatible embeds loopback"),
            ("::10.0.0.1", .privateAddress, "IPv4-compatible embeds private 10/8 (rejected by the public fetch gate)"),
            ("::192.168.1.1", .privateAddress, "IPv4-compatible embeds private 192.168/16 (rejected by the public fetch gate)"),
            ("::169.254.0.1", .unusable, "IPv4-compatible embeds link-local"),
            ("::8.8.8.8", .publicAddress, "IPv4-compatible embedding a public IPv4 stays public (kept in the IPv6 bucket)"),

            // Multicast ff00::/8
            ("ff00::", .unusable, "start of multicast ff00::/8"),
            ("ff02::fb", .unusable, "mDNS link-local multicast group"),
            ("ffff::1", .unusable, "top of multicast ff00::/8"),

            // Unique local addresses fc00::/7
            ("fb00::1", .publicAddress, "one prefix below ULA fc00::/7"),
            ("fc00::", .privateAddress, "lower edge of ULA fc00::/7"),
            ("fd12:3456:789a::1", .privateAddress, "typical ULA fd00::/8 address"),
            ("fdff:ffff::1", .privateAddress, "upper edge of ULA fc00::/7"),
            ("fe00::1", .publicAddress, "between ULA and link-local blocks"),

            // Link-local fe80::/10
            ("fe7f::1", .publicAddress, "one prefix below link-local fe80::/10"),
            ("fe80::", .unusable, "lower edge of link-local fe80::/10"),
            ("fe80::1", .unusable, "canonical link-local address"),
            ("febf:ffff::1", .unusable, "upper edge of link-local fe80::/10"),
            // NOTE: deprecated site-local fec0::/10 is NOT classified and falls
            // through to public. Characterized as-is; flagged for review.
            ("fec0::1", .publicAddress, "deprecated site-local classifies public (see NOTE)"),

            // Documentation 2001:db8::/32
            ("2001:db7::1", .publicAddress, "one /32 below the documentation block"),
            ("2001:db8::1", .unusable, "documentation 2001:db8::/32"),
            ("2001:db8:ffff::1", .unusable, "still inside 2001:db8::/32"),
            ("2001:db9::1", .publicAddress, "one /32 above the documentation block"),

            // Ordinary public resolvers
            ("2606:4700:4700::1111", .publicAddress, "Cloudflare"),
            ("2001:4860:4860::8888", .publicAddress, "Google"),

            // IPv4-mapped IPv6 addresses borrow the embedded IPv4 address's scope
            // KIND (a mapped loopback/private literal must not masquerade as a
            // public IPv6 address) while keeping the IPv6 family for bucketing —
            // see testDNSResolverAddressesSplitsLiteralAddressesByFamily.
            ("::ffff:8.8.8.8", .publicAddress, "IPv4-mapped public address"),
            ("::ffff:127.0.0.1", .unusable, "IPv4-mapped loopback classifies as loopback"),
            ("::ffff:192.168.0.1", .privateAddress, "IPv4-mapped private classifies as private"),
            ("::ffff:100.64.0.1", .unusable, "IPv4-mapped CGNAT classifies as reserved"),

            // NAT64 well-known prefix 64:ff9b::/96 resolves to its embedded IPv4 target
            // on IPv6-only/NAT64 networks, so it borrows the embedded scope too.
            ("64:ff9b::8.8.8.8", .publicAddress, "NAT64-mapped public address"),
            ("64:ff9b::10.0.0.1", .privateAddress, "NAT64-mapped RFC1918 classifies as private"),
            ("64:ff9b::127.0.0.1", .unusable, "NAT64-mapped loopback classifies as loopback"),
            ("64:ff9b:0:1::8.8.8.8", .publicAddress, "outside the /96 (nonzero middle bits) stays plain IPv6"),
        ]

        for (host, expected, note) in cases {
            assertScope(host, expected, note)
        }
    }

    // MARK: - dnsResolverAddresses family split

    func testDNSResolverAddressesSplitsLiteralAddressesByFamily() {
        let ipv4 = NetworkEndpointValidator.dnsResolverAddresses(from: "9.9.9.9")
        XCTAssertEqual(ipv4?.ipv4, ["9.9.9.9"], "public IPv4 literal must land in the IPv4 bucket")
        XCTAssertEqual(ipv4?.ipv6, [], "public IPv4 literal must not populate the IPv6 bucket")

        let privateIPv4 = NetworkEndpointValidator.dnsResolverAddresses(from: "192.168.1.53")
        XCTAssertEqual(privateIPv4?.ipv4, ["192.168.1.53"], "private IPv4 is a usable resolver (router-hosted DNS)")
        XCTAssertEqual(privateIPv4?.ipv6, [], "private IPv4 literal must not populate the IPv6 bucket")

        let ipv6 = NetworkEndpointValidator.dnsResolverAddresses(from: "2620:fe::fe")
        XCTAssertEqual(ipv6?.ipv4, [], "IPv6 literal must not populate the IPv4 bucket")
        XCTAssertEqual(ipv6?.ipv6, ["2620:fe::fe"], "public IPv6 literal must land in the IPv6 bucket")

        // IPv4-mapped literals borrow the embedded IPv4 SCOPE but keep IPv6 SYNTAX: the
        // string must stay in the IPv6 bucket (it is not a parseable IPv4 socket address),
        // while a mapped loopback is unusable exactly like its embedded address.
        let mapped = NetworkEndpointValidator.dnsResolverAddresses(from: "::ffff:8.8.8.8")
        XCTAssertEqual(mapped?.ipv4, [], "IPv4-mapped literal must not land in the IPv4 bucket")
        XCTAssertEqual(mapped?.ipv6, ["::ffff:8.8.8.8"], "IPv4-mapped literal keeps IPv6 syntax")
        XCTAssertNil(
            NetworkEndpointValidator.dnsResolverAddresses(from: "::ffff:127.0.0.1"),
            "IPv4-mapped loopback must be as unusable as 127.0.0.1 itself"
        )

        XCTAssertNil(
            NetworkEndpointValidator.dnsResolverAddresses(from: "127.0.0.1"),
            "unusable scopes must produce no resolver addresses"
        )
        XCTAssertNil(
            NetworkEndpointValidator.dnsResolverAddresses(from: "::"),
            "the unspecified address must produce no resolver addresses"
        )
        XCTAssertNil(
            NetworkEndpointValidator.dnsResolverAddresses(from: "dns.quad9.net"),
            "hostnames are not literal addresses and must return nil"
        )
        XCTAssertNil(
            NetworkEndpointValidator.dnsResolverAddresses(from: ""),
            "the empty string must return nil"
        )
        // NOTE: unlike validateDNSResolverHost, dnsResolverAddresses does NOT
        // trim whitespace, so a padded literal returns nil. Characterized as-is.
        XCTAssertNil(
            NetworkEndpointValidator.dnsResolverAddresses(from: " 9.9.9.9"),
            "dnsResolverAddresses does not trim whitespace (see NOTE)"
        )
    }

    // MARK: - Localhost names

    func testLocalhostNamesRejectedWithEntryPointSpecificErrors() {
        let localhostNames = ["localhost", "LOCALHOST", "dev.localhost", "a.b.localhost"]

        for name in localhostNames {
            XCTAssertThrowsError(
                try NetworkEndpointValidator.validateDNSResolverHost(name),
                "\(name) must be rejected as a resolver host"
            ) { error in
                XCTAssertEqual(
                    error as? NetworkEndpointValidationError,
                    .localhostNotAllowed,
                    "\(name) must map to localhostNotAllowed on the resolver entry point"
                )
            }

            guard let url = Self.sourceURL(host: name.lowercased()) else {
                XCTFail("could not build a source URL for \(name)")
                continue
            }
            XCTAssertThrowsError(
                try NetworkEndpointValidator.validatePublicSourceURL(url),
                "\(name) must be rejected as a public source host"
            ) { error in
                XCTAssertEqual(
                    error as? NetworkEndpointValidationError,
                    .privateNetworkNotAllowed,
                    "\(name) must map to privateNetworkNotAllowed on the source-URL entry point"
                )
            }
        }

        // Whitespace is trimmed before the localhost check on the resolver path.
        XCTAssertThrowsError(
            try NetworkEndpointValidator.validateDNSResolverHost(" localhost\n"),
            "padded localhost must still be rejected"
        ) { error in
            XCTAssertEqual(error as? NetworkEndpointValidationError, .localhostNotAllowed)
        }

        // Suffix matching, not substring matching: localhost as a LEFT label is fine.
        XCTAssertNoThrow(
            try NetworkEndpointValidator.validateDNSResolverHost("localhost.example.com"),
            "localhost.example.com is an ordinary public hostname"
        )
        XCTAssertNoThrow(
            try NetworkEndpointValidator.validatePublicSourceURL(
                XCTUnwrap(Self.sourceURL(host: "localhost.example.com"))
            ),
            "localhost.example.com is an ordinary public source host"
        )
    }

    // MARK: - Source-URL specific rules

    func testPublicSourceURLRejectsEmbeddedCredentials() {
        let cases: [(urlString: String, note: String)] = [
            ("https://user@example.com/list.txt", "username only"),
            ("https://user:pass@example.com/list.txt", "username and password"),
            ("https://:pass@example.com/list.txt", "password only"),
        ]

        for (urlString, note) in cases {
            guard let url = URL(string: urlString) else {
                XCTFail("could not build URL for credentials case: \(note)")
                continue
            }
            XCTAssertThrowsError(
                try NetworkEndpointValidator.validatePublicSourceURL(url),
                "credentials (\(note)) must be rejected"
            ) { error in
                XCTAssertEqual(
                    error as? NetworkEndpointValidationError,
                    .credentialsNotAllowed,
                    "credentials (\(note)) must map to credentialsNotAllowed"
                )
            }
        }
    }

    func testPublicSourceURLWithoutHostOrWithDomainHostPasses() {
        // Host-less URLs are outside this validator's concern (scheme policy
        // is enforced elsewhere); it returns without throwing.
        XCTAssertNoThrow(
            try NetworkEndpointValidator.validatePublicSourceURL(
                XCTUnwrap(URL(string: "file:///tmp/list.txt"))
            ),
            "a host-less URL passes through the endpoint validator unexamined"
        )

        XCTAssertNoThrow(
            try NetworkEndpointValidator.validatePublicSourceURL(
                XCTUnwrap(Self.sourceURL(host: "example.com"))
            ),
            "an ordinary public domain host is allowed"
        )
    }

    // MARK: - Resolver-host specific rules

    func testResolverHostEntryPointEdgeCases() {
        let invalidHosts: [(host: String, note: String)] = [
            ("", "empty string"),
            ("   ", "whitespace only"),
            ("256.1.1.1", "out-of-range octet is IP-shaped, so it is rejected as a domain too"),
        ]

        for (host, note) in invalidHosts {
            XCTAssertThrowsError(
                try NetworkEndpointValidator.validateDNSResolverHost(host),
                "\(note) must be rejected as a resolver host"
            ) { error in
                XCTAssertEqual(
                    error as? NetworkEndpointValidationError,
                    .invalidResolverHost,
                    "\(note) must map to invalidResolverHost"
                )
            }
        }

        // A zone-indexed link-local literal still parses on Darwin and classifies by its
        // address scope, so it is rejected as UNUSABLE (link-local) rather than invalid —
        // either way it can never become a resolver host. Characterized as-is.
        XCTAssertThrowsError(
            try NetworkEndpointValidator.validateDNSResolverHost("fe80::1%en0"),
            "a zone-indexed link-local literal must be rejected as a resolver host"
        ) { error in
            XCTAssertEqual(
                error as? NetworkEndpointValidationError,
                .unusableResolverAddress,
                "the zone-indexed literal classifies by scope (link-local), not as an invalid domain"
            )
        }

        XCTAssertNoThrow(
            try NetworkEndpointValidator.validateDNSResolverHost("dns.quad9.net"),
            "a resolvable hostname is a valid resolver host"
        )
        XCTAssertNoThrow(
            try NetworkEndpointValidator.validateDNSResolverHost(" 9.9.9.9\n"),
            "the resolver entry point trims surrounding whitespace"
        )
    }

    // MARK: - Helpers

    /// Asserts the observable classification of `host` on all three entry points.
    private func assertScope(
        _ host: String,
        _ expected: ExpectedScope,
        _ note: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch expected {
        case .publicAddress, .privateAddress:
            XCTAssertNoThrow(
                try NetworkEndpointValidator.validateDNSResolverHost(host),
                "\(host) (\(note)) must be a usable resolver address",
                file: file,
                line: line
            )
            XCTAssertNotNil(
                NetworkEndpointValidator.dnsResolverAddresses(from: host),
                "\(host) (\(note)) must produce resolver addresses",
                file: file,
                line: line
            )
        case .unusable:
            XCTAssertThrowsError(
                try NetworkEndpointValidator.validateDNSResolverHost(host),
                "\(host) (\(note)) must be rejected as a resolver address",
                file: file,
                line: line
            ) { error in
                XCTAssertEqual(
                    error as? NetworkEndpointValidationError,
                    .unusableResolverAddress,
                    "\(host) (\(note)) must map to unusableResolverAddress",
                    file: file,
                    line: line
                )
            }
            XCTAssertNil(
                NetworkEndpointValidator.dnsResolverAddresses(from: host),
                "\(host) (\(note)) must produce no resolver addresses",
                file: file,
                line: line
            )
        }

        guard let url = Self.sourceURL(host: host) else {
            XCTFail("could not build a source URL for \(host) (\(note))", file: file, line: line)
            return
        }

        switch expected {
        case .publicAddress:
            XCTAssertNoThrow(
                try NetworkEndpointValidator.validatePublicSourceURL(url),
                "\(host) (\(note)) must be allowed as a public source host",
                file: file,
                line: line
            )
        case .privateAddress, .unusable:
            XCTAssertThrowsError(
                try NetworkEndpointValidator.validatePublicSourceURL(url),
                "\(host) (\(note)) must be rejected as a public source host",
                file: file,
                line: line
            ) { error in
                XCTAssertEqual(
                    error as? NetworkEndpointValidationError,
                    .privateNetworkNotAllowed,
                    "\(host) (\(note)) must map to privateNetworkNotAllowed",
                    file: file,
                    line: line
                )
            }
        }
    }

    private static func sourceURL(host: String) -> URL? {
        let authority = host.contains(":") ? "[\(host)]" : host
        return URL(string: "https://\(authority)/blocklist.txt")
    }
}
