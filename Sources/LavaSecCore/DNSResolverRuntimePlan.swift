import Foundation

public struct DNSResolverRuntimePlan: Equatable, Sendable {
    public let transport: DNSResolverTransport
    public let plainAddresses: [String]
    public let dohEndpoints: [DNSOverHTTPSEndpoint]
    public let dotEndpoints: [DNSOverTLSEndpoint]
    public let doqEndpoints: [DNSOverQUICEndpoint]
    public let cacheIdentifier: String
    public let deviceDNSFallbackAddresses: [String]
    public let shouldFallbackToDeviceDNS: Bool
    public let usesDeviceDNSFallbackMode: Bool

    public init(
        transport: DNSResolverTransport,
        plainAddresses: [String],
        dohEndpoints: [DNSOverHTTPSEndpoint],
        dotEndpoints: [DNSOverTLSEndpoint],
        doqEndpoints: [DNSOverQUICEndpoint],
        cacheIdentifier: String,
        deviceDNSFallbackAddresses: [String],
        shouldFallbackToDeviceDNS: Bool,
        usesDeviceDNSFallbackMode: Bool
    ) {
        self.transport = transport
        self.plainAddresses = plainAddresses
        self.dohEndpoints = dohEndpoints
        self.dotEndpoints = dotEndpoints
        self.doqEndpoints = doqEndpoints
        self.cacheIdentifier = cacheIdentifier
        self.deviceDNSFallbackAddresses = deviceDNSFallbackAddresses
        self.shouldFallbackToDeviceDNS = shouldFallbackToDeviceDNS
        self.usesDeviceDNSFallbackMode = usesDeviceDNSFallbackMode
    }

    public static func make(
        configuration: AppConfiguration,
        deviceDNSAddresses: [String],
        networkKind: TunnelNetworkKind,
        deviceDNSFallbackModeActive: Bool,
        ignoresDeviceDNSFallbackMode: Bool = false,
        allowsQueryFallback: Bool = true
    ) -> DNSResolverRuntimePlan {
        make(
            resolver: configuration.resolverPreset,
            fallbackToDeviceDNS: configuration.fallbackToDeviceDNS,
            deviceDNSAddresses: deviceDNSAddresses,
            networkKind: networkKind,
            deviceDNSFallbackModeActive: deviceDNSFallbackModeActive,
            ignoresDeviceDNSFallbackMode: ignoresDeviceDNSFallbackMode,
            allowsQueryFallback: allowsQueryFallback
        )
    }

    public static func make(
        resolver: DNSResolverPreset,
        fallbackToDeviceDNS: Bool,
        deviceDNSAddresses: [String],
        networkKind: TunnelNetworkKind,
        deviceDNSFallbackModeActive: Bool,
        ignoresDeviceDNSFallbackMode: Bool = false,
        allowsQueryFallback: Bool = true
    ) -> DNSResolverRuntimePlan {
        let orderedDeviceDNSAddresses = orderedResolverAddresses(deviceDNSAddresses, networkKind: networkKind)
        let resolverPlainAddresses = orderedResolverAddresses(
            resolver.ipv4Servers + resolver.ipv6Servers,
            networkKind: networkKind
        )
        let defaultPlainFallback = DNSResolverPreset.google.ipv4Servers + DNSResolverPreset.google.ipv6Servers
        let usesDeviceDNSFallbackMode = !ignoresDeviceDNSFallbackMode
            && deviceDNSFallbackModeActive
            && fallbackToDeviceDNS
            && resolver.transport != .deviceDNS
            && !orderedDeviceDNSAddresses.isEmpty

        let effectiveTransport: DNSResolverTransport
        let effectivePlainAddresses: [String]
        let dohEndpoints: [DNSOverHTTPSEndpoint]
        let dotEndpoints: [DNSOverTLSEndpoint]
        let doqEndpoints: [DNSOverQUICEndpoint]

        if usesDeviceDNSFallbackMode || resolver.transport == .deviceDNS {
            effectiveTransport = .deviceDNS
            effectivePlainAddresses = orderedDeviceDNSAddresses
            dohEndpoints = []
            dotEndpoints = []
            doqEndpoints = []
        } else if resolver.transport == .dnsOverHTTPS, !resolver.dohEndpoints.isEmpty {
            effectiveTransport = .dnsOverHTTPS
            effectivePlainAddresses = resolverPlainAddresses.isEmpty ? defaultPlainFallback : resolverPlainAddresses
            dohEndpoints = resolver.dohEndpoints
            dotEndpoints = []
            doqEndpoints = []
        } else if resolver.transport == .dnsOverTLS, !resolver.dotEndpoints.isEmpty {
            effectiveTransport = .dnsOverTLS
            let bootstrapAddresses = orderedResolverAddresses(
                resolver.dotEndpoints.flatMap(\.allBootstrapServers),
                networkKind: networkKind
            )
            effectivePlainAddresses = bootstrapAddresses.isEmpty ? resolverPlainAddresses : bootstrapAddresses
            dohEndpoints = []
            dotEndpoints = resolver.dotEndpoints
            doqEndpoints = []
        } else if resolver.transport == .dnsOverQUIC, !resolver.doqEndpoints.isEmpty {
            effectiveTransport = .dnsOverQUIC
            let bootstrapAddresses = orderedResolverAddresses(
                resolver.doqEndpoints.flatMap(\.allBootstrapServers),
                networkKind: networkKind
            )
            effectivePlainAddresses = bootstrapAddresses.isEmpty ? resolverPlainAddresses : bootstrapAddresses
            dohEndpoints = []
            dotEndpoints = []
            doqEndpoints = resolver.doqEndpoints
        } else {
            effectiveTransport = .plainDNS
            effectivePlainAddresses = resolverPlainAddresses.isEmpty ? defaultPlainFallback : resolverPlainAddresses
            dohEndpoints = []
            dotEndpoints = []
            doqEndpoints = []
        }

        let primaryCacheIdentifier = cacheIdentifier(
            transport: effectiveTransport,
            plainAddresses: effectivePlainAddresses,
            dohEndpoints: dohEndpoints,
            dotEndpoints: dotEndpoints,
            doqEndpoints: doqEndpoints
        )
        let shouldFallbackToDeviceDNS = fallbackToDeviceDNS
            && allowsQueryFallback
            && effectiveTransport != .deviceDNS
            && !orderedDeviceDNSAddresses.isEmpty
        let fallbackIdentifier = shouldFallbackToDeviceDNS
            ? "|fallback:device:" + orderedDeviceDNSAddresses.joined(separator: ",")
            : ""
        let fallbackModeIdentifier = usesDeviceDNSFallbackMode ? "|mode:device-dns-fallback" : ""

        return DNSResolverRuntimePlan(
            transport: effectiveTransport,
            plainAddresses: effectivePlainAddresses,
            dohEndpoints: dohEndpoints,
            dotEndpoints: dotEndpoints,
            doqEndpoints: doqEndpoints,
            cacheIdentifier: primaryCacheIdentifier + fallbackIdentifier + fallbackModeIdentifier,
            deviceDNSFallbackAddresses: orderedDeviceDNSAddresses,
            shouldFallbackToDeviceDNS: shouldFallbackToDeviceDNS,
            usesDeviceDNSFallbackMode: usesDeviceDNSFallbackMode
        )
    }

    public static func orderedResolverAddresses(
        _ addresses: [String],
        networkKind: TunnelNetworkKind
    ) -> [String] {
        var ipv4Addresses: [String] = []
        var ipv6Addresses: [String] = []
        var otherAddresses: [String] = []

        for address in addresses {
            if let families = NetworkEndpointValidator.dnsResolverAddresses(from: address) {
                if !families.ipv4.isEmpty {
                    ipv4Addresses.append(address)
                } else if !families.ipv6.isEmpty {
                    ipv6Addresses.append(address)
                } else {
                    otherAddresses.append(address)
                }
            } else {
                otherAddresses.append(address)
            }
        }

        if networkKind == .cellular {
            return ipv6Addresses + ipv4Addresses + otherAddresses
        }

        return ipv4Addresses + ipv6Addresses + otherAddresses
    }

    private static func cacheIdentifier(
        transport: DNSResolverTransport,
        plainAddresses: [String],
        dohEndpoints: [DNSOverHTTPSEndpoint],
        dotEndpoints: [DNSOverTLSEndpoint],
        doqEndpoints: [DNSOverQUICEndpoint]
    ) -> String {
        switch transport {
        case .deviceDNS:
            "device:" + plainAddresses.joined(separator: ",")
        case .dnsOverHTTPS:
            dohEndpoints.map(\.cacheIdentifier).joined(separator: ",")
        case .dnsOverTLS:
            dotEndpoints.map(\.cacheIdentifier).joined(separator: ",")
        case .dnsOverQUIC:
            doqEndpoints.map(\.cacheIdentifier).joined(separator: ",")
        case .plainDNS:
            plainAddresses.joined(separator: ",")
        }
    }
}
