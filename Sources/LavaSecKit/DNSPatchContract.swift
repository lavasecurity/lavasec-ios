import Darwin
import Foundation

/// Versioned agreement between the downloadable DNS profile and local tunnel routes.
/// This is capture configuration, never a replacement for the user's T0/T1/T2 resolver choices.
public struct DNSPatchContract: Decodable, Equatable, Sendable {
    /// Profile revision, kept separate from Apple's required PayloadVersion (always 1).
    public let version: Int
    /// Stable removable profile identifier, retained across signed updates.
    public let identifier: String
    /// User-facing name in iOS Settings.
    public let displayName: String
    /// Descriptive organization; the certificate independently establishes the signer.
    public let organization: String
    /// Public TLS server used while Guard is stopped.
    public let serverName: String
    /// Literal bootstrap destinations captured while Guard is running.
    public let serverAddresses: [String]
    /// HTTPS URL when the system profile uses DoH; nil retains the TLS contract.
    public var serverURL: String? = nil

    /// Loads the same reviewed resource consumed by the release-profile generator.
    public static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "dns-patch-v1", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: Bundle.module.bundlePath])
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// Verifies the app-owned DNS contract rather than treating any saved DNS entry
    /// as an enabled patch. Empty/root domain scope covers all system lookups.
    public func matchesManagedSettings(serverName: String?, servers: [String],
        matchDomains: [String]?, allowsFailover: Bool, hasUniversalConnectRule: Bool, serverURL: String? = nil) -> Bool {
        serverName == self.serverName && serverURL == self.serverURL && !allowsFailover && hasUniversalConnectRule
            && (matchDomains ?? []).allSatisfy { $0.isEmpty }
            && servers.count == serverAddresses.count
            && serverAddresses.allSatisfy { expected in
                servers.contains { ResolverAddressIdentity.denotesSameAddress(expected, $0) }
            }
    }

    /// Only accept a translated address actually observed for this IPv4 server on a
    /// physical path. RFC 6052 allows six prefix lengths; never assume 64:ff9b::/96.
    /// This checks address shape, not discovery authenticity: callers must obtain the
    /// endpoint from their own interface-bound connection, never arbitrary user input.
    public func admitsObservedEndpoint(_ address: String) -> Bool {
        if serverAddresses.contains(where: { ResolverAddressIdentity.denotesSameAddress($0, address) }) {
            return true
        }
        var parsed = in6_addr()
        guard inet_pton(AF_INET6, address, &parsed) == 1 else { return false }
        let bytes = withUnsafeBytes(of: parsed) { Array($0) }
        // Multicast, link-local, unspecified and IPv4-mapped addresses cannot be Pref64.
        guard bytes[0] != 0xff, !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80),
              !bytes.prefix(12).allSatisfy({ $0 == 0 }),
              !(bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff)
        else { return false }
        for literal in serverAddresses {
            var ipv4 = in_addr()
            guard inet_pton(AF_INET, literal, &ipv4) == 1 else { continue }
            let target = withUnsafeBytes(of: ipv4) { Array($0) }
            for prefixBytes in [4, 5, 6, 7, 8, 12] {
                let positions = (prefixBytes..<16).filter { prefixBytes == 12 || $0 != 8 }.prefix(4)
                guard positions.map({ bytes[$0] }) == target else { continue }
                if prefixBytes != 12 {
                    guard bytes[8] == 0 else { continue }
                    let last = positions.last!
                    guard bytes.suffix(from: last + 1).allSatisfy({ $0 == 0 }) else { continue }
                }
                return true
            }
        }
        return false
    }

    /// Exact host destinations only. Observations are bounded and deduplicated by address
    /// identity; no prefix-wide interception or general traffic forwarding is introduced.
    public func captureAddresses(observedEndpoints: [String]) -> [String] {
        var result = serverAddresses
        for address in observedEndpoints.prefix(8) where admitsObservedEndpoint(address) {
            if !result.contains(where: { ResolverAddressIdentity.denotesSameAddress($0, address) }) {
                result.append(address)
            }
        }
        return result
    }

    /// Whether new observations change the patch's capture destination set.
    /// Interface duplicates, ordering and equivalent IPv6 spellings do not change
    /// destination membership. A real translated endpoint addition or removal does.
    public func requiresRouteUpdate(previousObservedEndpoints: [String], observedEndpoints: [String]) -> Bool {
        let previous = captureAddresses(observedEndpoints: previousObservedEndpoints)
        let current = captureAddresses(observedEndpoints: observedEndpoints)
        return !previous.allSatisfy { address in
            current.contains { ResolverAddressIdentity.denotesSameAddress(address, $0) }
        } || !current.allSatisfy { address in
            previous.contains { ResolverAddressIdentity.denotesSameAddress(address, $0) }
        }
    }
}
