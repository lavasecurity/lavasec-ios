import Foundation
#if canImport(Darwin)
import Darwin
#endif

package enum NetworkEndpointValidationError: LocalizedError, Equatable, Sendable {
    case credentialsNotAllowed
    case localhostNotAllowed
    case privateNetworkNotAllowed
    case unusableResolverAddress
    case invalidResolverHost

    package var errorDescription: String? {
        switch self {
        case .credentialsNotAllowed:
            return LavaCoreStrings.localized("core.endpoint.credentialsNotAllowed")
        case .localhostNotAllowed:
            return LavaCoreStrings.localized("core.endpoint.localhostNotAllowed")
        case .privateNetworkNotAllowed:
            return LavaCoreStrings.localized("core.endpoint.privateNetworkNotAllowed")
        case .unusableResolverAddress:
            return LavaCoreStrings.localized("core.endpoint.unusableResolverAddress")
        case .invalidResolverHost:
            return LavaCoreStrings.localized("core.endpoint.invalidResolverHost")
        }
    }
}

package enum NetworkEndpointValidator {
    package static func validatePublicSourceURL(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return
        }

        if components.user != nil || components.password != nil {
            throw NetworkEndpointValidationError.credentialsNotAllowed
        }

        guard var host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            return
        }

        // URLComponents returns an IPv6-literal host WITH its brackets ([2606:4700::1111])
        // on current Foundation. Unstripped, `ipAddressScope` cannot parse it, so every
        // IPv6-literal host — public or private — fell through to DomainName.normalize and
        // was rejected with a misleading error, and the scope gate below never ran for IPv6.
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }

        if isLocalhostName(host) {
            throw NetworkEndpointValidationError.privateNetworkNotAllowed
        }

        if let scope = ipAddressScope(host) {
            if !scope.isPublicAddress {
                throw NetworkEndpointValidationError.privateNetworkNotAllowed
            }
            return
        }

        _ = try DomainName.normalize(host)
    }

    static func validateDNSResolverHost(_ host: String) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw NetworkEndpointValidationError.invalidResolverHost
        }

        if isLocalhostName(trimmedHost) {
            throw NetworkEndpointValidationError.localhostNotAllowed
        }

        if let scope = ipAddressScope(trimmedHost) {
            guard scope.isUsableResolverAddress else {
                throw NetworkEndpointValidationError.unusableResolverAddress
            }
            return
        }

        do {
            _ = try DomainName.normalize(trimmedHost)
        } catch {
            throw NetworkEndpointValidationError.invalidResolverHost
        }
    }

    package static func dnsResolverAddresses(from value: String) -> (ipv4: [String], ipv6: [String])? {
        guard let scope = ipAddressScope(value), scope.isUsableResolverAddress else {
            return nil
        }

        return scope.version == .ipv4 ? ([value], []) : ([], [value])
    }

    // SEC-1 connect-time gate: classify a RESOLVED peer address by its raw network-order
    // bytes (an A/AAAA answer from `getaddrinfo`, or an IP literal's `rawValue`) as
    // globally-routable public unicast, reusing the SAME `IPAddressScope` map —
    // including the IPv4-mapped and NAT64-embedded borrowing — that
    // `validatePublicSourceURL` applies to IP-LITERAL hosts. This is what lets the fetcher
    // refuse a hostname that DNS-resolves into a private/loopback/reserved address (the
    // residual `validatePublicSourceURL` cannot see, because it only classifies literals).
    // Wrong-length input fails closed (treated as non-public).
    package static func isPublicResolvedIPv4(octets: [UInt8]) -> Bool {
        guard octets.count == 4 else {
            return false
        }
        return IPAddressScope(ipv4Octets: octets).isPublicAddress
    }

    package static func isPublicResolvedIPv6(bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else {
            return false
        }
        return IPAddressScope(ipv6Bytes: bytes).isPublicAddress
    }

    private static func isLocalhostName(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return host == "localhost" || host.hasSuffix(".localhost")
    }

    private static func ipAddressScope(_ value: String) -> IPAddressScope? {
        if let octets = ipv4Octets(from: value) {
            return IPAddressScope(ipv4Octets: octets)
        }

        #if canImport(Darwin)
        var ipv6Address = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6Address) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv6Address) { Array($0) }
            return IPAddressScope(ipv6Bytes: bytes)
        }
        #endif

        return nil
    }

    private static func ipv4Octets(from value: String) -> [UInt8]? {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else {
            return nil
        }

        var octets: [UInt8] = []
        for piece in pieces {
            guard !piece.isEmpty,
                  piece.allSatisfy(\.isNumber),
                  let number = UInt8(piece)
            else {
                return nil
            }
            octets.append(number)
        }
        return octets
    }
}

private enum IPAddressVersion: Equatable {
    case ipv4
    case ipv6
}

private enum IPAddressScope: Equatable {
    case publicAddress(IPAddressVersion)
    case privateAddress(IPAddressVersion)
    case loopback(IPAddressVersion)
    case linkLocal(IPAddressVersion)
    case multicast(IPAddressVersion)
    case unspecified(IPAddressVersion)
    case reserved(IPAddressVersion)

    init(ipv4Octets octets: [UInt8]) {
        let first = octets[0]
        let second = octets[1]

        if first == 0 {
            self = .unspecified(.ipv4)
        } else if first == 10 || (first == 172 && (16...31).contains(second)) || (first == 192 && second == 168) {
            self = .privateAddress(.ipv4)
        } else if first == 127 {
            self = .loopback(.ipv4)
        } else if first == 169 && second == 254 {
            self = .linkLocal(.ipv4)
        } else if (224...239).contains(first) {
            self = .multicast(.ipv4)
        } else if (240...255).contains(first)                                        // 240.0.0.0/4 Class E "reserved" (incl. 255.255.255.255 limited broadcast)
            || (first == 100 && (64...127).contains(second))                          // 100.64.0.0/10 CGNAT (RFC 6598)
            || (first == 192 && second == 0 && (octets[2] == 0 || octets[2] == 2))    // 192.0.0.0/24 IETF protocol assignments + 192.0.2.0/24 TEST-NET-1
            || (first == 192 && second == 88 && octets[2] == 99)                      // 192.88.99.0/24 6to4 relay anycast (RFC 7526, deprecated)
            || (first == 198 && (18...19).contains(second))                           // 198.18.0.0/15 benchmarking (RFC 2544)
            || (first == 198 && second == 51 && octets[2] == 100)                     // 198.51.100.0/24 TEST-NET-2
            || (first == 203 && second == 0 && octets[2] == 113) {                    // 203.0.113.0/24 TEST-NET-3
            // Special-purpose ranges that are NOT globally-routable public unicast — they must
            // fail the isPublicAddress gate so PinnedPublicHTTPSFetcher never pins/connects to a
            // hostname that resolves into one (SSRF / DNS-rebinding defense in depth).
            self = .reserved(.ipv4)
        } else {
            self = .publicAddress(.ipv4)
        }
    }

    init(ipv6Bytes bytes: [UInt8]) {
        if bytes.allSatisfy({ $0 == 0 }) {
            self = .unspecified(.ipv6)
        } else if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 {
            self = .loopback(.ipv6)
        } else if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            // IPv4-mapped (::ffff:a.b.c.d): borrow the embedded IPv4 address's scope KIND so
            // a mapped loopback/private literal cannot masquerade as a public IPv6 address
            // (an SSRF-class dodge once bracketed URL hosts classify at all), but keep the
            // .ipv6 version — the literal still has IPv6 syntax and must stay in the IPv6
            // bucket when `dnsResolverAddresses` splits by family.
            self = IPAddressScope(ipv4Octets: Array(bytes[12...15])).withVersion(.ipv6)
        } else if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xff, bytes[3] == 0x9b,
                  bytes[4..<12].allSatisfy({ $0 == 0 }) {
            // NAT64 well-known prefix (64:ff9b::/96, RFC 6052): on an IPv6-only/NAT64
            // network this literal RESOLVES to its embedded IPv4 target, so a NAT64-mapped
            // loopback/private literal is a private-network fetch dressed as public IPv6.
            // Borrow the embedded scope, mirroring DeviceDNSFallbackPolicy's low-32-bit
            // treatment of the same prefix.
            self = IPAddressScope(ipv4Octets: Array(bytes[12...15])).withVersion(.ipv6)
        } else if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xff, bytes[3] == 0x9b,
                  bytes[4] == 0x00, bytes[5] == 0x01 {
            // NAT64 LOCAL-USE prefix (64:ff9b:1::/48, RFC 8215): reserved for a site's own
            // IPv4/IPv6 translation, so on a network that routes it this literal resolves to
            // whatever the LOCAL translator maps — the embedded IPv4 (at a prefix-dependent
            // offset) is untrustworthy, and even an embedded-public-looking address could be
            // locally remapped into private space. Unlike the globally-defined /96 there is no
            // trustworthy "public" address here. Classify as PRIVATE, not reserved: that fails
            // the isPublicAddress fetch gate so PinnedPublicHTTPSFetcher never pins/connects to
            // it (SSRF / DNS-rebinding defense), while keeping it a usable local resolver —
            // matching DeviceDNSFallbackPolicy, which keeps 64:ff9b:1:: reachable via CLAT.
            self = .privateAddress(.ipv6)
        } else if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            // IPv4-compatible IPv6 (::a.b.c.d, RFC 4291 §2.5.5.1 — deprecated): the high 96 bits
            // are zero with NO 0xffff mapped marker. `::` (unspecified) and `::1` (loopback) are
            // already handled above, so anything reaching here embeds a non-trivial IPv4 address.
            // Borrow its scope exactly like the mapped/NAT64 cases so ::127.0.0.1 / ::10.0.0.1 /
            // ::192.168.0.1 can't masquerade as public IPv6 and slip past the fetch gate.
            self = IPAddressScope(ipv4Octets: Array(bytes[12...15])).withVersion(.ipv6)
        } else if bytes[0] == 0xff {
            self = .multicast(.ipv6)
        } else if bytes[0] & 0xfe == 0xfc {
            self = .privateAddress(.ipv6)
        } else if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 {
            self = .linkLocal(.ipv6)
        } else if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 {
            self = .reserved(.ipv6)
        } else {
            self = .publicAddress(.ipv6)
        }
    }

    var version: IPAddressVersion {
        switch self {
        case .publicAddress(let version),
             .privateAddress(let version),
             .loopback(let version),
             .linkLocal(let version),
             .multicast(let version),
             .unspecified(let version),
             .reserved(let version):
            return version
        }
    }

    private func withVersion(_ version: IPAddressVersion) -> IPAddressScope {
        switch self {
        case .publicAddress: .publicAddress(version)
        case .privateAddress: .privateAddress(version)
        case .loopback: .loopback(version)
        case .linkLocal: .linkLocal(version)
        case .multicast: .multicast(version)
        case .unspecified: .unspecified(version)
        case .reserved: .reserved(version)
        }
    }

    var isUsableResolverAddress: Bool {
        switch self {
        case .publicAddress, .privateAddress:
            return true
        case .loopback, .linkLocal, .multicast, .unspecified, .reserved:
            return false
        }
    }

    /// Globally-routable public unicast — the only scope a blocklist source (initial URL or
    /// redirect target) may be fetched from. Everything else (private, loopback, link-local,
    /// multicast, unspecified, reserved) is an SSRF target and refused.
    var isPublicAddress: Bool {
        self == .publicAddress(version)
    }
}
