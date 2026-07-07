import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum DNSResolverTransport: String, Codable, Hashable, Sendable {
    case deviceDNS = "device-dns"
    case plainDNS = "plain-dns"
    case dnsOverHTTPS = "dns-over-https"
    case dnsOverTLS = "dns-over-tls"
    case dnsOverQUIC = "dns-over-quic"

    public var displayName: String {
        switch self {
        case .deviceDNS:
            return "Device DNS"
        case .plainDNS:
            return "Standard DNS"
        case .dnsOverHTTPS:
            return "DNS over HTTPS"
        case .dnsOverTLS:
            return "DNS over TLS"
        case .dnsOverQUIC:
            return "DNS over QUIC"
        }
    }

    public var menuTitle: String {
        switch self {
        case .deviceDNS:
            return "Device"
        case .plainDNS:
            return "IP"
        case .dnsOverHTTPS:
            return "HTTPS"
        case .dnsOverTLS:
            return "TLS"
        case .dnsOverQUIC:
            return "QUIC"
        }
    }
}

public struct DNSOverHTTPSEndpoint: Hashable, Codable, Sendable {
    public let url: URL
    public let bootstrapIPv4Servers: [String]
    public let bootstrapIPv6Servers: [String]

    public init(url: URL, bootstrapIPv4Servers: [String], bootstrapIPv6Servers: [String]) {
        self.url = url
        self.bootstrapIPv4Servers = bootstrapIPv4Servers
        self.bootstrapIPv6Servers = bootstrapIPv6Servers
    }

    public var cacheIdentifier: String {
        "doh:\(url.absoluteString)"
    }

    public var allBootstrapServers: [String] {
        bootstrapIPv4Servers + bootstrapIPv6Servers
    }
}

public struct DNSOverTLSEndpoint: Hashable, Codable, Sendable {
    public let hostname: String
    public let port: UInt16
    public let bootstrapIPv4Servers: [String]
    public let bootstrapIPv6Servers: [String]

    public init(
        hostname: String,
        port: UInt16 = 853,
        bootstrapIPv4Servers: [String],
        bootstrapIPv6Servers: [String]
    ) {
        self.hostname = hostname
        self.port = port
        self.bootstrapIPv4Servers = bootstrapIPv4Servers
        self.bootstrapIPv6Servers = bootstrapIPv6Servers
    }

    public var cacheIdentifier: String {
        "dot:\(hostname):\(port)"
    }

    public var displayAddress: String {
        "\(hostname):\(port)"
    }

    public var allBootstrapServers: [String] {
        bootstrapIPv4Servers + bootstrapIPv6Servers
    }
}

public struct DNSOverQUICEndpoint: Hashable, Codable, Sendable {
    public let hostname: String
    public let port: UInt16
    public let bootstrapIPv4Servers: [String]
    public let bootstrapIPv6Servers: [String]

    public init(
        hostname: String,
        port: UInt16 = 853,
        bootstrapIPv4Servers: [String],
        bootstrapIPv6Servers: [String]
    ) {
        self.hostname = hostname
        self.port = port
        self.bootstrapIPv4Servers = bootstrapIPv4Servers
        self.bootstrapIPv6Servers = bootstrapIPv6Servers
    }

    public var cacheIdentifier: String {
        "doq:\(hostname):\(port)"
    }

    public var displayAddress: String {
        "\(hostname):\(port)"
    }

    public var allBootstrapServers: [String] {
        bootstrapIPv4Servers + bootstrapIPv6Servers
    }
}

public struct DNSResolverPreset: Identifiable, Hashable, Codable, Sendable {
    public static let customID = "custom-dns"

    public let id: String
    public let displayName: String
    public let ipv4Servers: [String]
    public let ipv6Servers: [String]
    public let notes: String
    public let hasUpstreamFiltering: Bool
    public let transport: DNSResolverTransport
    public let dohEndpoint: DNSOverHTTPSEndpoint?
    public let dotEndpoint: DNSOverTLSEndpoint?
    public let doqEndpoint: DNSOverQUICEndpoint?
    public let secondaryDohEndpoint: DNSOverHTTPSEndpoint?
    public let secondaryDotEndpoint: DNSOverTLSEndpoint?
    public let secondaryDoqEndpoint: DNSOverQUICEndpoint?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case ipv4Servers
        case ipv6Servers
        case notes
        case hasUpstreamFiltering
        case transport
        case dohEndpoint
        case dotEndpoint
        case doqEndpoint
        case secondaryDohEndpoint
        case secondaryDotEndpoint
        case secondaryDoqEndpoint
    }

    public init(
        id: String,
        displayName: String,
        ipv4Servers: [String],
        ipv6Servers: [String],
        notes: String,
        hasUpstreamFiltering: Bool,
        transport: DNSResolverTransport = .plainDNS,
        dohEndpoint: DNSOverHTTPSEndpoint? = nil,
        dotEndpoint: DNSOverTLSEndpoint? = nil,
        doqEndpoint: DNSOverQUICEndpoint? = nil,
        secondaryDohEndpoint: DNSOverHTTPSEndpoint? = nil,
        secondaryDotEndpoint: DNSOverTLSEndpoint? = nil,
        secondaryDoqEndpoint: DNSOverQUICEndpoint? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.ipv4Servers = ipv4Servers
        self.ipv6Servers = ipv6Servers
        self.notes = notes
        self.hasUpstreamFiltering = hasUpstreamFiltering
        self.transport = transport
        self.dohEndpoint = dohEndpoint
        self.dotEndpoint = dotEndpoint
        self.doqEndpoint = doqEndpoint
        self.secondaryDohEndpoint = secondaryDohEndpoint
        self.secondaryDotEndpoint = secondaryDotEndpoint
        self.secondaryDoqEndpoint = secondaryDoqEndpoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.ipv4Servers = try container.decode([String].self, forKey: .ipv4Servers)
        self.ipv6Servers = try container.decode([String].self, forKey: .ipv6Servers)
        self.notes = try container.decode(String.self, forKey: .notes)
        self.hasUpstreamFiltering = try container.decode(Bool.self, forKey: .hasUpstreamFiltering)
        self.transport = try container.decodeIfPresent(DNSResolverTransport.self, forKey: .transport) ?? .plainDNS
        self.dohEndpoint = try container.decodeIfPresent(DNSOverHTTPSEndpoint.self, forKey: .dohEndpoint)
        self.dotEndpoint = try container.decodeIfPresent(DNSOverTLSEndpoint.self, forKey: .dotEndpoint)
        self.doqEndpoint = try container.decodeIfPresent(DNSOverQUICEndpoint.self, forKey: .doqEndpoint)
        self.secondaryDohEndpoint = try container.decodeIfPresent(DNSOverHTTPSEndpoint.self, forKey: .secondaryDohEndpoint)
        self.secondaryDotEndpoint = try container.decodeIfPresent(DNSOverTLSEndpoint.self, forKey: .secondaryDotEndpoint)
        self.secondaryDoqEndpoint = try container.decodeIfPresent(DNSOverQUICEndpoint.self, forKey: .secondaryDoqEndpoint)
    }

    public var allServers: [String] {
        ipv4Servers + ipv6Servers
    }

    public var dohEndpoints: [DNSOverHTTPSEndpoint] {
        [dohEndpoint, secondaryDohEndpoint].compactMap(\.self)
    }

    public var dotEndpoints: [DNSOverTLSEndpoint] {
        [dotEndpoint, secondaryDotEndpoint].compactMap(\.self)
    }

    public var doqEndpoints: [DNSOverQUICEndpoint] {
        [doqEndpoint, secondaryDoqEndpoint].compactMap(\.self)
    }

    public var shortDisplayName: String {
        shortDisplayName(dohHTTPVersion: nil)
    }

    public func shortDisplayName(dohHTTPVersion: String?) -> String {
        let dohAnnotation = DoHHTTPVersion.dohAnnotation(negotiatedHTTPVersion: dohHTTPVersion)
        return switch id {
        case Self.customID:
            displayName
        case Self.device.id:
            "Device"
        case Self.google.id:
            "Google"
        case Self.cloudflare.id:
            "Cloudflare"
        case Self.quad9Secure.id:
            "Quad9"
        case Self.mullvad.id:
            "Mullvad"
        case Self.googleDoH.id:
            "Google (\(dohAnnotation))"
        case Self.cloudflareDoH.id:
            "Cloudflare (\(dohAnnotation))"
        case Self.quad9SecureDoH.id:
            "Quad9 (\(dohAnnotation))"
        case Self.mullvadDoH.id:
            "Mullvad (\(dohAnnotation))"
        case Self.googleDoT.id:
            "Google (DoT)"
        case Self.cloudflareDoT.id:
            "Cloudflare (DoT)"
        case Self.quad9SecureDoT.id:
            "Quad9 (DoT)"
        case Self.mullvadDoT.id:
            "Mullvad (DoT)"
        default:
            displayName
        }
    }

    public var guardFlowDNSDetailText: String {
        guardFlowDNSDetailText(dohHTTPVersion: nil)
    }

    public func guardFlowDNSDetailText(dohHTTPVersion: String?) -> String {
        guardFlowDNSDetailComponents(dohHTTPVersion: dohHTTPVersion).displayText
    }

    // Name and transport annotation as separate components so long custom
    // names can truncate without losing the annotation. Every resolver
    // surfaces its EFFECTIVE transport — encrypted ones as DoH/DoH3/DoT/DoQ,
    // plain ones as "IP" (the Settings menu's own term) — except the device
    // resolver, where the name already is the transport.
    public func guardFlowDNSDetailComponents(dohHTTPVersion: String? = nil) -> GuardFlowDNSDetail {
        let annotation: String?
        switch transport {
        case .dnsOverHTTPS:
            annotation = DoHHTTPVersion.dohAnnotation(negotiatedHTTPVersion: dohHTTPVersion)
        case .dnsOverTLS:
            annotation = "DoT"
        case .dnsOverQUIC:
            annotation = "DoQ"
        case .plainDNS:
            annotation = "IP"
        case .deviceDNS:
            annotation = nil
        }

        let name = switch id {
        case Self.device.id:
            "Device"
        case Self.google.id, Self.googleDoH.id, Self.googleDoT.id:
            "Google"
        case Self.cloudflare.id, Self.cloudflareDoH.id, Self.cloudflareDoT.id:
            "Cloudflare"
        case Self.quad9Secure.id, Self.quad9SecureDoH.id, Self.quad9SecureDoT.id:
            "Quad9"
        case Self.mullvad.id, Self.mullvadDoH.id, Self.mullvadDoT.id:
            "Mullvad"
        default:
            displayName
        }

        return GuardFlowDNSDetail(name: name, transportAnnotation: annotation)
    }

    public var settingsBasePreset: DNSResolverPreset {
        if id == Self.customID {
            return self
        }

        switch id {
        case Self.googleDoH.id:
            return .google
        case Self.cloudflareDoH.id:
            return .cloudflare
        case Self.quad9SecureDoH.id:
            return .quad9Secure
        case Self.mullvadDoH.id:
            return .mullvad
        case Self.googleDoT.id:
            return .google
        case Self.cloudflareDoT.id:
            return .cloudflare
        case Self.quad9SecureDoT.id:
            return .quad9Secure
        case Self.mullvadDoT.id:
            return .mullvad
        default:
            return DNSResolverPreset.settingsPresets.first { $0.id == id } ?? self
        }
    }

    public var dnsOverHTTPSVariant: DNSResolverPreset? {
        if settingsBasePreset.id == Self.customID {
            return transport == .dnsOverHTTPS ? self : nil
        }

        switch settingsBasePreset.id {
        case Self.google.id:
            return .googleDoH
        case Self.cloudflare.id:
            return .cloudflareDoH
        case Self.quad9Secure.id:
            return .quad9SecureDoH
        case Self.mullvad.id:
            return .mullvadDoH
        default:
            return nil
        }
    }

    public var plainDNSVariant: DNSResolverPreset {
        if settingsBasePreset.id == Self.customID {
            return self
        }

        return settingsBasePreset
    }

    public var dnsOverTLSVariant: DNSResolverPreset? {
        if settingsBasePreset.id == Self.customID {
            return transport == .dnsOverTLS ? self : nil
        }

        switch settingsBasePreset.id {
        case Self.google.id:
            return .googleDoT
        case Self.cloudflare.id:
            return .cloudflareDoT
        case Self.quad9Secure.id:
            return .quad9SecureDoT
        case Self.mullvad.id:
            return .mullvadDoT
        default:
            return nil
        }
    }

    public var availableTransports: [DNSResolverTransport] {
        if id == Self.customID || settingsBasePreset.id == Self.customID {
            return [transport]
        }

        var transports: [DNSResolverTransport] = [.plainDNS]
        if dnsOverHTTPSVariant != nil {
            transports.append(.dnsOverHTTPS)
        }
        if dnsOverTLSVariant != nil {
            transports.append(.dnsOverTLS)
        }
        return transports
    }

    public func resolverVariant(for transport: DNSResolverTransport) -> DNSResolverPreset {
        switch transport {
        case .deviceDNS:
            return .device
        case .plainDNS:
            return plainDNSVariant
        case .dnsOverHTTPS:
            return dnsOverHTTPSVariant ?? plainDNSVariant
        case .dnsOverTLS:
            return dnsOverTLSVariant ?? plainDNSVariant
        case .dnsOverQUIC:
            return settingsBasePreset.id == Self.customID && transport == .dnsOverQUIC ? self : plainDNSVariant
        }
    }

    public static func custom(rawValue: String?, displayName rawDisplayName: String? = nil) -> DNSResolverPreset? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            return nil
        }
        let displayName = customDisplayName(from: rawDisplayName)

        if let addresses = customResolverAddresses(from: value) {
            return DNSResolverPreset(
                id: customID,
                displayName: displayName,
                ipv4Servers: addresses.ipv4,
                ipv6Servers: addresses.ipv6,
                notes: "Use your own resolver.",
                hasUpstreamFiltering: false,
                transport: .plainDNS
            )
        }

        if let stampPreset = DNSStampParser.customPreset(from: value, displayName: displayName) {
            return stampPreset
        }

        if let endpointURL = customDoHEndpointURL(from: value) {
            return DNSResolverPreset(
                id: customID,
                displayName: displayName,
                ipv4Servers: [],
                ipv6Servers: [],
                notes: "Use your own resolver.",
                hasUpstreamFiltering: false,
                transport: .dnsOverHTTPS,
                dohEndpoint: DNSOverHTTPSEndpoint(
                    url: endpointURL,
                    bootstrapIPv4Servers: [],
                    bootstrapIPv6Servers: []
                )
            )
        }

        if let endpoint = customDoTEndpoint(from: value) {
            return DNSResolverPreset(
                id: customID,
                displayName: displayName,
                ipv4Servers: [],
                ipv6Servers: [],
                notes: "Use your own resolver.",
                hasUpstreamFiltering: false,
                transport: .dnsOverTLS,
                dotEndpoint: endpoint
            )
        }

        if let endpoint = customDoQEndpoint(from: value) {
            return DNSResolverPreset(
                id: customID,
                displayName: displayName,
                ipv4Servers: [],
                ipv6Servers: [],
                notes: "Use your own resolver.",
                hasUpstreamFiltering: false,
                transport: .dnsOverQUIC,
                doqEndpoint: endpoint
            )
        }

        return nil
    }

    public static func custom(
        primaryRawValue: String?,
        secondaryRawValue: String? = nil,
        displayName rawDisplayName: String? = nil
    ) -> DNSResolverPreset? {
        let primaryValue = primaryRawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secondaryValue = secondaryRawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let primaryPreset = custom(rawValue: primaryValue, displayName: rawDisplayName) else {
            return nil
        }
        guard !secondaryValue.isEmpty else {
            return primaryPreset
        }
        guard let secondaryPreset = custom(rawValue: secondaryValue, displayName: rawDisplayName),
              primaryPreset.transport == secondaryPreset.transport
        else {
            return nil
        }

        switch primaryPreset.transport {
        case .plainDNS:
            return DNSResolverPreset(
                id: customID,
                displayName: primaryPreset.displayName,
                ipv4Servers: primaryPreset.ipv4Servers + secondaryPreset.ipv4Servers,
                ipv6Servers: primaryPreset.ipv6Servers + secondaryPreset.ipv6Servers,
                notes: "Use your own resolver.",
                hasUpstreamFiltering: false,
                transport: .plainDNS
            )
        case .dnsOverHTTPS:
            guard let primaryEndpoint = primaryPreset.dohEndpoint,
                  let secondaryEndpoint = secondaryPreset.dohEndpoint
            else {
                return nil
            }

            return DNSResolverPreset(
                id: customID,
                displayName: primaryPreset.displayName,
                ipv4Servers: [],
                ipv6Servers: [],
                notes: "Use your own resolver.",
                hasUpstreamFiltering: false,
                transport: .dnsOverHTTPS,
                dohEndpoint: primaryEndpoint,
                secondaryDohEndpoint: secondaryEndpoint
            )
        case .dnsOverTLS:
            guard let primaryEndpoint = primaryPreset.dotEndpoint,
                  let secondaryEndpoint = secondaryPreset.dotEndpoint
            else {
                return nil
            }

            return DNSResolverPreset(
                id: customID,
                displayName: primaryPreset.displayName,
                ipv4Servers: [],
                ipv6Servers: [],
                notes: "Use your own resolver.",
                hasUpstreamFiltering: false,
                transport: .dnsOverTLS,
                dotEndpoint: primaryEndpoint,
                secondaryDotEndpoint: secondaryEndpoint
            )
        case .dnsOverQUIC:
            guard let primaryEndpoint = primaryPreset.doqEndpoint,
                  let secondaryEndpoint = secondaryPreset.doqEndpoint
            else {
                return nil
            }

            return DNSResolverPreset(
                id: customID,
                displayName: primaryPreset.displayName,
                ipv4Servers: [],
                ipv6Servers: [],
                notes: "Use your own resolver.",
                hasUpstreamFiltering: false,
                transport: .dnsOverQUIC,
                doqEndpoint: primaryEndpoint,
                secondaryDoqEndpoint: secondaryEndpoint
            )
        case .deviceDNS:
            return nil
        }
    }

    public static func customValidationMessage(rawValue: String?, supportsDNSOverQUIC: Bool = true) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            return customResolverEmptyValidationMessage
        }

        if let preset = custom(rawValue: value) {
            if preset.transport == .dnsOverQUIC, !supportsDNSOverQUIC {
                return customResolverDoQUnsupportedValidationMessage
            }

            return nil
        }

        return customResolverValidationMessage(from: value)
    }

    public static func customValidationMessage(
        primaryRawValue: String?,
        secondaryRawValue: String?,
        supportsDNSOverQUIC: Bool = true
    ) -> String? {
        let primaryValue = primaryRawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secondaryValue = secondaryRawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let primaryValidationMessage = customValidationMessage(
            rawValue: primaryValue,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        ) {
            return primaryValidationMessage
        }

        guard !secondaryValue.isEmpty else {
            return nil
        }

        if let secondaryValidationMessage = customValidationMessage(
            rawValue: secondaryValue,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        ) {
            return secondaryValidationMessage
        }

        guard let primaryPreset = custom(rawValue: primaryValue),
              let secondaryPreset = custom(rawValue: secondaryValue),
              primaryPreset.transport == secondaryPreset.transport
        else {
            return LavaCoreStrings.localized("core.resolver.secondaryTransportMismatch")
        }

        return nil
    }

    public static func customDisplayName(from rawValue: String?) -> String {
        let trimmedValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? "Custom DNS" : trimmedValue
    }

    private static func customDoHEndpointURL(from value: String) -> URL? {
        try? validatedCustomDoHEndpointURL(from: value)
    }

    private static func customDoTEndpoint(from value: String) -> DNSOverTLSEndpoint? {
        try? validatedCustomDoTEndpoint(from: value)
    }

    private static func customDoQEndpoint(from value: String) -> DNSOverQUICEndpoint? {
        try? validatedCustomDoQEndpoint(from: value)
    }

    private static func validatedCustomDoHEndpointURL(from value: String) throws -> URL {
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            throw CustomDNSResolverValidationError.unsupportedFormat
        }

        try validateURLAuthority(components)
        try NetworkEndpointValidator.validateDNSResolverHost(host)

        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty && path != "/" else {
            throw CustomDNSResolverValidationError.missingDoHPath
        }

        components.scheme = "https"
        guard let url = components.url else {
            throw CustomDNSResolverValidationError.unsupportedFormat
        }
        return url
    }

    private static func validatedCustomDoTEndpoint(from value: String) throws -> DNSOverTLSEndpoint {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "tls" || scheme == "dot",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            throw CustomDNSResolverValidationError.unsupportedFormat
        }

        try validateURLAuthority(components)

        guard components.query == nil,
              components.fragment == nil
        else {
            throw CustomDNSResolverValidationError.unsupportedFormat
        }

        do {
            try NetworkEndpointValidator.validateDNSResolverHost(host)
        } catch NetworkEndpointValidationError.localhostNotAllowed {
            throw NetworkEndpointValidationError.localhostNotAllowed
        } catch NetworkEndpointValidationError.unusableResolverAddress {
            throw NetworkEndpointValidationError.unusableResolverAddress
        } catch {
            throw NetworkEndpointValidationError.invalidResolverHost
        }

        guard let port = UInt16(exactly: components.port ?? 853),
              port > 0
        else {
            throw CustomDNSResolverValidationError.unsupportedFormat
        }

        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty || path == "/" else {
            throw CustomDNSResolverValidationError.unsupportedFormat
        }

        return DNSOverTLSEndpoint(
            hostname: host,
            port: port,
            bootstrapIPv4Servers: [],
            bootstrapIPv6Servers: []
        )
    }

    private static func validatedCustomDoQEndpoint(from value: String) throws -> DNSOverQUICEndpoint {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "doq" || scheme == "quic",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            throw CustomDNSResolverValidationError.unsupportedFormat
        }

        try validateURLAuthority(components)

        guard components.query == nil,
              components.fragment == nil
        else {
            throw CustomDNSResolverValidationError.unsupportedFormat
        }

        do {
            try NetworkEndpointValidator.validateDNSResolverHost(host)
        } catch NetworkEndpointValidationError.localhostNotAllowed {
            throw NetworkEndpointValidationError.localhostNotAllowed
        } catch NetworkEndpointValidationError.unusableResolverAddress {
            throw NetworkEndpointValidationError.unusableResolverAddress
        } catch {
            throw NetworkEndpointValidationError.invalidResolverHost
        }

        guard let port = UInt16(exactly: components.port ?? 853),
              port > 0
        else {
            throw CustomDNSResolverValidationError.unsupportedFormat
        }

        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty || path == "/" else {
            throw CustomDNSResolverValidationError.unsupportedFormat
        }

        return DNSOverQUICEndpoint(
            hostname: host,
            port: port,
            bootstrapIPv4Servers: [],
            bootstrapIPv6Servers: []
        )
    }

    private static func validateURLAuthority(_ components: URLComponents) throws {
        guard components.user == nil,
              components.password == nil
        else {
            throw CustomDNSResolverValidationError.credentialsNotAllowed
        }
    }

    private static func customResolverValidationMessage(from value: String) -> String {
        let lowercasedValue = value.lowercased()

        if lowercasedValue.hasPrefix("https://") {
            do {
                _ = try validatedCustomDoHEndpointURL(from: value)
            } catch {
                return customResolverValidationMessage(for: error)
            }
        }

        if lowercasedValue.hasPrefix("tls://") || lowercasedValue.hasPrefix("dot://") {
            do {
                _ = try validatedCustomDoTEndpoint(from: value)
            } catch {
                return customResolverValidationMessage(for: error)
            }
        }

        if lowercasedValue.hasPrefix("doq://") || lowercasedValue.hasPrefix("quic://") {
            do {
                _ = try validatedCustomDoQEndpoint(from: value)
            } catch {
                return customResolverValidationMessage(for: error)
            }
        }

        if lowercasedValue.hasPrefix("sdns://") {
            return LavaCoreStrings.localized("core.resolver.badStamp")
        }

        if (try? NetworkEndpointValidator.validateDNSResolverHost(value)) == nil,
           value.contains(".") || value.contains(":") {
            do {
                try NetworkEndpointValidator.validateDNSResolverHost(value)
            } catch NetworkEndpointValidationError.unusableResolverAddress {
                return NetworkEndpointValidationError.unusableResolverAddress.localizedDescription
            } catch NetworkEndpointValidationError.localhostNotAllowed {
                return NetworkEndpointValidationError.localhostNotAllowed.localizedDescription
            } catch {
                return customResolverUnsupportedValidationMessage
            }
        }

        return customResolverUnsupportedValidationMessage
    }

    private static func customResolverValidationMessage(for error: Error) -> String {
        switch error {
        case CustomDNSResolverValidationError.missingDoHPath:
            return LavaCoreStrings.localized("core.resolver.missingDoHPath")
        case CustomDNSResolverValidationError.credentialsNotAllowed:
            return LavaCoreStrings.localized("core.resolver.credentialsNotAllowed")
        case NetworkEndpointValidationError.localhostNotAllowed:
            return NetworkEndpointValidationError.localhostNotAllowed.localizedDescription
        case NetworkEndpointValidationError.unusableResolverAddress:
            return NetworkEndpointValidationError.unusableResolverAddress.localizedDescription
        case NetworkEndpointValidationError.invalidResolverHost:
            return NetworkEndpointValidationError.invalidResolverHost.localizedDescription
        default:
            return customResolverUnsupportedValidationMessage
        }
    }

    private static var customResolverEmptyValidationMessage: String {
        LavaCoreStrings.localized("core.resolver.empty")
    }

    private static var customResolverUnsupportedValidationMessage: String {
        LavaCoreStrings.localized("core.resolver.unsupported")
    }

    private static var customResolverDoQUnsupportedValidationMessage: String {
        LavaCoreStrings.localized("core.resolver.doqUnsupported")
    }

    fileprivate static func customResolverAddresses(from value: String) -> (ipv4: [String], ipv6: [String])? {
        NetworkEndpointValidator.dnsResolverAddresses(from: value)
    }

    public static let device = DNSResolverPreset(
        id: "device-dns",
        displayName: "Device DNS",
        ipv4Servers: [],
        ipv6Servers: [],
        notes: "Uses the DNS servers from the current Wi-Fi or cellular network when available.",
        hasUpstreamFiltering: false,
        transport: .deviceDNS
    )

    public static let google = DNSResolverPreset(
        id: "google-public-dns",
        displayName: "Google Public DNS",
        ipv4Servers: ["8.8.8.8", "8.8.4.4"],
        ipv6Servers: ["2001:4860:4860::8888", "2001:4860:4860::8844"],
        notes: "Default unfiltered resolver.",
        hasUpstreamFiltering: false
    )

    public static let cloudflare = DNSResolverPreset(
        id: "cloudflare-1111",
        displayName: "Cloudflare 1.1.1.1",
        ipv4Servers: ["1.1.1.1", "1.0.0.1"],
        ipv6Servers: ["2606:4700:4700::1111", "2606:4700:4700::1001"],
        notes: "Fast privacy-oriented resolver with no content filtering in the standard preset.",
        hasUpstreamFiltering: false
    )

    public static let quad9Secure = DNSResolverPreset(
        id: "quad9-secure",
        displayName: "Quad9 Secure",
        ipv4Servers: ["9.9.9.9", "149.112.112.112"],
        ipv6Servers: ["2620:fe::fe", "2620:fe::9"],
        notes: "Includes Quad9 upstream threat blocking.",
        hasUpstreamFiltering: true
    )

    public static let mullvad = DNSResolverPreset(
        id: "mullvad",
        displayName: "Mullvad",
        ipv4Servers: ["194.242.2.2"],
        ipv6Servers: ["2a07:e340::2"],
        notes: "Privacy-focused resolver from Mullvad VPN with no logging and DNSSEC validation.",
        hasUpstreamFiltering: false
    )

    public static let googleDoH = DNSResolverPreset(
        id: "google-public-dns-doh",
        displayName: "Google Public DNS (DoH)",
        ipv4Servers: ["8.8.8.8", "8.8.4.4"],
        ipv6Servers: ["2001:4860:4860::8888", "2001:4860:4860::8844"],
        notes: "DNS over HTTPS endpoint metadata for Google Public DNS.",
        hasUpstreamFiltering: false,
        transport: .dnsOverHTTPS,
        dohEndpoint: DNSOverHTTPSEndpoint(
            url: URL(string: "https://dns.google/dns-query")!,
            bootstrapIPv4Servers: ["8.8.8.8", "8.8.4.4"],
            bootstrapIPv6Servers: ["2001:4860:4860::8888", "2001:4860:4860::8844"]
        )
    )

    public static let cloudflareDoH = DNSResolverPreset(
        id: "cloudflare-1111-doh",
        displayName: "Cloudflare 1.1.1.1 (DoH)",
        ipv4Servers: ["1.1.1.1", "1.0.0.1"],
        ipv6Servers: ["2606:4700:4700::1111", "2606:4700:4700::1001"],
        notes: "DNS over HTTPS endpoint metadata for Cloudflare 1.1.1.1.",
        hasUpstreamFiltering: false,
        transport: .dnsOverHTTPS,
        dohEndpoint: DNSOverHTTPSEndpoint(
            url: URL(string: "https://cloudflare-dns.com/dns-query")!,
            bootstrapIPv4Servers: ["1.1.1.1", "1.0.0.1"],
            bootstrapIPv6Servers: ["2606:4700:4700::1111", "2606:4700:4700::1001"]
        )
    )

    public static let quad9SecureDoH = DNSResolverPreset(
        id: "quad9-secure-doh",
        displayName: "Quad9 Secure (DoH)",
        ipv4Servers: ["9.9.9.9", "149.112.112.112"],
        ipv6Servers: ["2620:fe::fe", "2620:fe::9"],
        notes: "DNS over HTTPS endpoint metadata for Quad9 Secure.",
        hasUpstreamFiltering: true,
        transport: .dnsOverHTTPS,
        dohEndpoint: DNSOverHTTPSEndpoint(
            url: URL(string: "https://dns.quad9.net/dns-query")!,
            bootstrapIPv4Servers: ["9.9.9.9", "149.112.112.112"],
            bootstrapIPv6Servers: ["2620:fe::fe", "2620:fe::9"]
        )
    )

    public static let mullvadDoH = DNSResolverPreset(
        id: "mullvad-doh",
        displayName: "Mullvad (DoH)",
        ipv4Servers: ["194.242.2.2"],
        ipv6Servers: ["2a07:e340::2"],
        notes: "DNS over HTTPS endpoint metadata for Mullvad.",
        hasUpstreamFiltering: false,
        transport: .dnsOverHTTPS,
        dohEndpoint: DNSOverHTTPSEndpoint(
            url: URL(string: "https://dns.mullvad.net/dns-query")!,
            bootstrapIPv4Servers: ["194.242.2.2"],
            bootstrapIPv6Servers: ["2a07:e340::2"]
        )
    )

    public static let googleDoT = DNSResolverPreset(
        id: "google-public-dns-dot",
        displayName: "Google Public DNS (DoT)",
        ipv4Servers: ["8.8.8.8", "8.8.4.4"],
        ipv6Servers: ["2001:4860:4860::8888", "2001:4860:4860::8844"],
        notes: "DNS over TLS endpoint metadata for Google Public DNS.",
        hasUpstreamFiltering: false,
        transport: .dnsOverTLS,
        dotEndpoint: DNSOverTLSEndpoint(
            hostname: "dns.google",
            bootstrapIPv4Servers: ["8.8.8.8", "8.8.4.4"],
            bootstrapIPv6Servers: ["2001:4860:4860::8888", "2001:4860:4860::8844"]
        )
    )

    public static let cloudflareDoT = DNSResolverPreset(
        id: "cloudflare-1111-dot",
        displayName: "Cloudflare 1.1.1.1 (DoT)",
        ipv4Servers: ["1.1.1.1", "1.0.0.1"],
        ipv6Servers: ["2606:4700:4700::1111", "2606:4700:4700::1001"],
        notes: "DNS over TLS endpoint metadata for Cloudflare 1.1.1.1.",
        hasUpstreamFiltering: false,
        transport: .dnsOverTLS,
        dotEndpoint: DNSOverTLSEndpoint(
            hostname: "one.one.one.one",
            bootstrapIPv4Servers: ["1.1.1.1", "1.0.0.1"],
            bootstrapIPv6Servers: ["2606:4700:4700::1111", "2606:4700:4700::1001"]
        )
    )

    public static let quad9SecureDoT = DNSResolverPreset(
        id: "quad9-secure-dot",
        displayName: "Quad9 Secure (DoT)",
        ipv4Servers: ["9.9.9.9", "149.112.112.112"],
        ipv6Servers: ["2620:fe::fe", "2620:fe::9"],
        notes: "DNS over TLS endpoint metadata for Quad9 Secure.",
        hasUpstreamFiltering: true,
        transport: .dnsOverTLS,
        dotEndpoint: DNSOverTLSEndpoint(
            hostname: "dns.quad9.net",
            bootstrapIPv4Servers: ["9.9.9.9", "149.112.112.112"],
            bootstrapIPv6Servers: ["2620:fe::fe", "2620:fe::9"]
        )
    )

    public static let mullvadDoT = DNSResolverPreset(
        id: "mullvad-dot",
        displayName: "Mullvad (DoT)",
        ipv4Servers: ["194.242.2.2"],
        ipv6Servers: ["2a07:e340::2"],
        notes: "DNS over TLS endpoint metadata for Mullvad.",
        hasUpstreamFiltering: false,
        transport: .dnsOverTLS,
        dotEndpoint: DNSOverTLSEndpoint(
            hostname: "dns.mullvad.net",
            bootstrapIPv4Servers: ["194.242.2.2"],
            bootstrapIPv6Servers: ["2a07:e340::2"]
        )
    )

    public static let builtInPresets: [DNSResolverPreset] = [
        .device,
        .mullvad,
        .cloudflare,
        .quad9Secure,
        .google
    ]

    public static let settingsPresets: [DNSResolverPreset] = [
        .device,
        .mullvad,
        .cloudflare,
        .quad9Secure,
        .google
    ]

    public static let allPresets: [DNSResolverPreset] = [
        .device,
        .mullvad,
        .cloudflare,
        .quad9Secure,
        .google,
        .mullvadDoH,
        .cloudflareDoH,
        .quad9SecureDoH,
        .googleDoH,
        .mullvadDoT,
        .cloudflareDoT,
        .quad9SecureDoT,
        .googleDoT
    ]

    /// Maps retired preset IDs to their current equivalent so a stored selection
    /// survives a catalog change. DNS.SB was replaced by Mullvad.
    public static func migratedPresetID(_ storedID: String) -> String {
        switch storedID {
        case "dns-sb": return mullvad.id
        case "dns-sb-doh": return mullvadDoH.id
        case "dns-sb-dot": return mullvadDoT.id
        default: return storedID
        }
    }
}

private enum CustomDNSResolverValidationError: Error {
    case unsupportedFormat
    case missingDoHPath
    case credentialsNotAllowed
}

private enum DNSStampParser {
    private static let schemePrefix = "sdns://"

    static func customPreset(from rawValue: String, displayName: String) -> DNSResolverPreset? {
        guard rawValue.lowercased().hasPrefix(schemePrefix),
              let data = base64URLDecodedData(from: String(rawValue.dropFirst(schemePrefix.count))),
              data.count >= 9
        else {
            return nil
        }

        var reader = StampReader(data: data)
        guard let protocolID = reader.readByte(),
              reader.skipProperties()
        else {
            return nil
        }

        switch protocolID {
        case 0x00:
            return plainDNSPreset(reader: &reader, displayName: displayName)
        case 0x02:
            return dohPreset(reader: &reader, displayName: displayName)
        case 0x03:
            return dotPreset(reader: &reader, displayName: displayName)
        case 0x04:
            return doqPreset(reader: &reader, displayName: displayName)
        default:
            return nil
        }
    }

    private static func plainDNSPreset(reader: inout StampReader, displayName: String) -> DNSResolverPreset? {
        guard let addressValue = reader.readString(),
              !reader.hasRemaining,
              let parsedAddress = parseAddressPort(addressValue),
              parsedAddress.port == nil || parsedAddress.port == 53,
              let addresses = DNSResolverPreset.customResolverAddresses(from: parsedAddress.host)
        else {
            return nil
        }

        return DNSResolverPreset(
            id: DNSResolverPreset.customID,
            displayName: displayName,
            ipv4Servers: addresses.ipv4,
            ipv6Servers: addresses.ipv6,
            notes: "Use your own resolver.",
            hasUpstreamFiltering: false,
            transport: .plainDNS
        )
    }

    private static func dohPreset(reader: inout StampReader, displayName: String) -> DNSResolverPreset? {
        guard let addressValue = reader.readString(),
              let hashes = reader.readValueList(),
              hashes.allSatisfy(\.isEmpty),
              let hostnameValue = reader.readString(),
              let path = reader.readString(),
              let hostPort = parseAddressPort(hostnameValue),
              !hostPort.host.isEmpty,
              !path.isEmpty,
              (try? NetworkEndpointValidator.validateDNSResolverHost(hostPort.host)) != nil
        else {
            return nil
        }

        let bootstrapValues = reader.hasRemaining ? reader.readStringList() : []
        guard let bootstrapValues else {
            return nil
        }
        guard !reader.hasRemaining else {
            return nil
        }

        let bootstrap = bootstrapServers(from: [addressValue] + bootstrapValues)
        var components = URLComponents()
        components.scheme = "https"
        components.host = hostPort.host
        if let port = hostPort.port, port != 443 {
            components.port = Int(port)
        }
        components.path = path.hasPrefix("/") ? path : "/" + path

        guard let url = components.url else {
            return nil
        }

        return DNSResolverPreset(
            id: DNSResolverPreset.customID,
            displayName: displayName,
            ipv4Servers: [],
            ipv6Servers: [],
            notes: "Use your own resolver.",
            hasUpstreamFiltering: false,
            transport: .dnsOverHTTPS,
            dohEndpoint: DNSOverHTTPSEndpoint(
                url: url,
                bootstrapIPv4Servers: bootstrap.ipv4,
                bootstrapIPv6Servers: bootstrap.ipv6
            )
        )
    }

    private static func dotPreset(reader: inout StampReader, displayName: String) -> DNSResolverPreset? {
        guard let addressValue = reader.readString(),
              let hashes = reader.readValueList(),
              hashes.allSatisfy(\.isEmpty),
              let hostnameValue = reader.readString(),
              let hostPort = parseAddressPort(hostnameValue),
              !hostPort.host.isEmpty,
              (try? NetworkEndpointValidator.validateDNSResolverHost(hostPort.host)) != nil
        else {
            return nil
        }

        let bootstrapValues = reader.hasRemaining ? reader.readStringList() : []
        guard let bootstrapValues else {
            return nil
        }
        guard !reader.hasRemaining else {
            return nil
        }

        let addressPort = parseAddressPort(addressValue)
        let bootstrap = bootstrapServers(from: [addressValue] + bootstrapValues)

        return DNSResolverPreset(
            id: DNSResolverPreset.customID,
            displayName: displayName,
            ipv4Servers: bootstrap.ipv4,
            ipv6Servers: bootstrap.ipv6,
            notes: "Use your own resolver.",
            hasUpstreamFiltering: false,
            transport: .dnsOverTLS,
            dotEndpoint: DNSOverTLSEndpoint(
                hostname: hostPort.host,
                port: hostPort.port ?? addressPort?.port ?? 853,
                bootstrapIPv4Servers: bootstrap.ipv4,
                bootstrapIPv6Servers: bootstrap.ipv6
            )
        )
    }

    private static func doqPreset(reader: inout StampReader, displayName: String) -> DNSResolverPreset? {
        guard let addressValue = reader.readString(),
              let hashes = reader.readValueList(),
              hashes.allSatisfy(\.isEmpty),
              let hostnameValue = reader.readString(),
              let hostPort = parseAddressPort(hostnameValue),
              !hostPort.host.isEmpty,
              (try? NetworkEndpointValidator.validateDNSResolverHost(hostPort.host)) != nil
        else {
            return nil
        }

        let bootstrapValues = reader.hasRemaining ? reader.readStringList() : []
        guard let bootstrapValues else {
            return nil
        }
        guard !reader.hasRemaining else {
            return nil
        }

        let addressPort = parseAddressPort(addressValue)
        let bootstrap = bootstrapServers(from: [addressValue] + bootstrapValues)

        return DNSResolverPreset(
            id: DNSResolverPreset.customID,
            displayName: displayName,
            ipv4Servers: bootstrap.ipv4,
            ipv6Servers: bootstrap.ipv6,
            notes: "Use your own resolver.",
            hasUpstreamFiltering: false,
            transport: .dnsOverQUIC,
            doqEndpoint: DNSOverQUICEndpoint(
                hostname: hostPort.host,
                port: hostPort.port ?? addressPort?.port ?? 853,
                bootstrapIPv4Servers: bootstrap.ipv4,
                bootstrapIPv6Servers: bootstrap.ipv6
            )
        )
    }

    private static func base64URLDecodedData(from value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: base64)
    }

    private static func bootstrapServers(from values: [String]) -> (ipv4: [String], ipv6: [String]) {
        var ipv4: [String] = []
        var ipv6: [String] = []
        var seen = Set<String>()

        for value in values {
            guard let parsed = parseAddressPort(value),
                  seen.insert(parsed.host).inserted,
                  let addresses = DNSResolverPreset.customResolverAddresses(from: parsed.host)
            else {
                continue
            }

            ipv4.append(contentsOf: addresses.ipv4)
            ipv6.append(contentsOf: addresses.ipv6)
        }

        return (ipv4, ipv6)
    }

    private static func parseAddressPort(_ value: String) -> (host: String, port: UInt16?)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("["),
           let closingBracket = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
            let remainder = trimmed[trimmed.index(after: closingBracket)...]
            if remainder.isEmpty {
                return (host, nil)
            }
            guard remainder.first == ":",
                  let port = UInt16(remainder.dropFirst())
            else {
                return nil
            }
            return (host, port)
        }

        let colonCount = trimmed.filter { $0 == ":" }.count
        if colonCount == 1,
           let colon = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[..<colon])
            guard let port = UInt16(trimmed[trimmed.index(after: colon)...]) else {
                return nil
            }
            return (host, port)
        }

        return (trimmed, nil)
    }
}

private struct StampReader {
    let data: Data
    var offset = 0

    var hasRemaining: Bool {
        offset < data.count
    }

    mutating func readByte() -> UInt8? {
        guard offset < data.count else {
            return nil
        }
        defer {
            offset += 1
        }
        return data[offset]
    }

    mutating func skipProperties() -> Bool {
        guard offset + 8 <= data.count else {
            return false
        }
        offset += 8
        return true
    }

    mutating func readString() -> String? {
        guard let bytes = readLengthPrefixedBytes() else {
            return nil
        }
        return String(data: bytes, encoding: .utf8)
    }

    mutating func readStringList() -> [String]? {
        guard let values = readValueList() else {
            return nil
        }
        return values.map { String(data: $0, encoding: .utf8) ?? "" }
    }

    mutating func readValueList() -> [Data]? {
        var values: [Data] = []
        var hasMore = true

        while hasMore {
            guard offset < data.count else {
                return nil
            }

            let lengthByte = data[offset]
            offset += 1
            hasMore = lengthByte & 0x80 != 0
            let length = Int(lengthByte & 0x7F)
            guard offset + length <= data.count else {
                return nil
            }

            values.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }

        return values
    }

    private mutating func readLengthPrefixedBytes() -> Data? {
        guard let lengthByte = readByte(),
              lengthByte & 0x80 == 0
        else {
            return nil
        }

        let length = Int(lengthByte)
        guard offset + length <= data.count else {
            return nil
        }

        let bytes = data.subdata(in: offset..<(offset + length))
        offset += length
        return bytes
    }
}
