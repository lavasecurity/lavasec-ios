import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum NetworkEndpointValidationError: LocalizedError, Equatable, Sendable {
    case credentialsNotAllowed
    case localhostNotAllowed
    case privateNetworkNotAllowed
    case unusableResolverAddress
    case invalidResolverHost

    var errorDescription: String? {
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

enum NetworkEndpointValidator {
    static func validatePublicSourceURL(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return
        }

        if components.user != nil || components.password != nil {
            throw NetworkEndpointValidationError.credentialsNotAllowed
        }

        guard let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            return
        }

        if isLocalhostName(host) {
            throw NetworkEndpointValidationError.privateNetworkNotAllowed
        }

        if let scope = ipAddressScope(host) {
            if scope != .publicAddress(scope.version) {
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

    static func dnsResolverAddresses(from value: String) -> (ipv4: [String], ipv6: [String])? {
        guard let scope = ipAddressScope(value), scope.isUsableResolverAddress else {
            return nil
        }

        return scope.version == .ipv4 ? ([value], []) : ([], [value])
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
        } else if first == 255
            || (first == 100 && (64...127).contains(second))
            || (first == 192 && second == 0 && (octets[2] == 0 || octets[2] == 2))
            || (first == 198 && second == 51 && octets[2] == 100)
            || (first == 203 && second == 0 && octets[2] == 113) {
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

    var isUsableResolverAddress: Bool {
        switch self {
        case .publicAddress, .privateAddress:
            return true
        case .loopback, .linkLocal, .multicast, .unspecified, .reserved:
            return false
        }
    }
}
