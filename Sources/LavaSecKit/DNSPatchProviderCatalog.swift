import Foundation

/// Independent patch choices derived from the existing DNS catalog, never the user's resolution ladder.
public enum DNSPatchProviderCatalog {
    /// Cached selection; installed system settings remain authoritative.
    public static let preferenceKey = "LavaDNSPatchProviderID"
    /// Provider identifier recorded in the saved packet-tunnel configuration.
    public static let providerConfigurationKey = "dnsPatchProviderID"
    /// Default provider for a newly configured patch.
    public static var defaultID: String { DNSResolverPreset.quad9Unfiltered.id }

    /// Only built-in TLS endpoints with explicit bootstrap addresses can be captured by exact routes.
    /// Optional variants are intentional: resolverVariant(for:) may fall back to plain DNS.
    public static var providers: [DNSResolverPreset] {
        DNSResolverPreset.settingsPresets.filter { base in
            guard let endpoint = base.dnsOverTLSVariant?.dotEndpoint else { return false }
            return endpoint.port == 853 && !endpoint.hostname.isEmpty && !endpoint.allBootstrapServers.isEmpty
        }
    }

    /// Eligible exact provider/transport entries share the primary DNS catalog.
    public static var choices: [DNSResolverPreset] {
        DNSResolverPreset.allPresets.filter { preset in
            if let tls = preset.dotEndpoint { return tls.port == 853 && !tls.allBootstrapServers.isEmpty }
            if let https = preset.dohEndpoints.first { return https.url.scheme == "https" && !https.allBootstrapServers.isEmpty }
            return false
        }
    }

    /// Identifies a supported installed profile independently of cached app preferences.
    public static func matchingProvider(serverName: String?, servers: [String], matchDomains: [String]?,
        allowsFailover: Bool, hasUniversalConnectRule: Bool, serverURL: String?) throws -> DNSResolverPreset? {
        try choices.first { preset in
            try contract(for: preset.id)?.matchesManagedSettings(serverName: serverName, servers: servers,
                matchDomains: matchDomains, allowsFailover: allowsFailover,
                hasUniversalConnectRule: hasUniversalConnectRule, serverURL: serverURL) == true
        }
    }

    /// Profile selection and capture routes derive from the same exact transport entry.
    /// Legacy base IDs retain their TLS interpretation for installed profiles.
    public static func contract(for id: String) throws -> DNSPatchContract? {
        let baseline = try DNSPatchContract.bundled()
        if id == defaultID || id == DNSResolverPreset.quad9UnfilteredDoT.id { return baseline }
        guard let preset = choices.first(where: { $0.id == id })
            ?? providers.first(where: { $0.id == id })?.dnsOverTLSVariant else { return nil }
        if let endpoint = preset.dotEndpoint {
            return DNSPatchContract(version: baseline.version, identifier: baseline.identifier,
                displayName: baseline.displayName, organization: baseline.organization, serverName: endpoint.hostname,
                serverAddresses: [endpoint.bootstrapIPv4Servers.first, endpoint.bootstrapIPv6Servers.first].compactMap { $0 })
        }
        guard let endpoint = preset.dohEndpoints.first, let host = endpoint.url.host else { return nil }
        var contract = DNSPatchContract(version: baseline.version, identifier: baseline.identifier,
            displayName: baseline.displayName, organization: baseline.organization, serverName: host,
            serverAddresses: [endpoint.bootstrapIPv4Servers.first, endpoint.bootstrapIPv6Servers.first].compactMap { $0 })
        contract.serverURL = endpoint.url.absoluteString
        return contract
    }
}
