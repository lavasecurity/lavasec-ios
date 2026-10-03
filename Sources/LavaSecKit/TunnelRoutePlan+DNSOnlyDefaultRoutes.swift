import Foundation

extension TunnelRoutePlan {
    /// A QA route-shape experiment, not a general forwarding path. A default declaration
    /// may affect OS DNS selection; exclusions leave only the local DNS hosts captured.
    static func dnsOnlyDefaultRouteExperiment() -> TunnelRoutePlan {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET, dnsServerAddress, &ipv4) == 1,
              inet_pton(AF_INET6, chainedDNSServerIPv6Address, &ipv6) == 1 else {
            // Never emit a default route without its complete exclusions.
            return make(for: .dnsOnly)
        }
        let v4 = withUnsafeBytes(of: &ipv4) { Array($0) }
        let v6 = withUnsafeBytes(of: &ipv6) { Array($0) }
        let excludedV4 = hostComplement(v4).map { bytes, prefix in
            let mask = UInt32.max << (32 - prefix)
            return IPv4Route(
                destinationAddress: bytes.map(String.init).joined(separator: "."),
                subnetMask: [24, 16, 8, 0].map { String((mask >> $0) & 255) }.joined(separator: "."))
        }
        let excludedV6 = hostComplement(v6).map { bytes, prefix in
            IPv6Route(
                destinationAddress: stride(from: 0, to: 16, by: 2).map {
                    String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16)
                }.joined(separator: ":"),
                prefixLength: prefix)
        }
        return TunnelRoutePlan(
            tunnelAddress: dnsOnlyTunnelAddress,
            tunnelSubnetMask: "255.255.255.255",
            dnsServerAddress: dnsServerAddress,
            dnsServerIPv6Address: chainedDNSServerIPv6Address,
            routeDescription: "QA DNS-only default declarations; local DNS hosts only; exclusions v4=32 v6=128",
            includedIPv4Routes: [IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")],
            tunnelIPv6Address: chainedTunnelIPv6Address,
            tunnelIPv6PrefixLength: 128,
            includedIPv6Routes: [IPv6Route(destinationAddress: "::", prefixLength: 0)],
            mtu: dnsOnlyMTU,
            excludedIPv4Routes: excludedV4,
            excludedIPv6Routes: excludedV6)
    }

    /// Each bit contributes the sibling prefix outside the retained host's path through
    /// the address tree. These disjoint prefixes cover every address except that host.
    private static func hostComplement(_ address: [UInt8]) -> [([UInt8], Int)] {
        var prefix = [UInt8](repeating: 0, count: address.count)
        return (0..<(address.count * 8)).map { bit in
            let index = bit / 8
            let mask = UInt8(1 << (7 - bit % 8))
            var sibling = prefix
            sibling[index] |= ~address[index] & mask
            prefix[index] |= address[index] & mask
            return (sibling, bit + 1)
        }
    }
}
