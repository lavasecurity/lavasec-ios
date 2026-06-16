import Foundation

public extension AppConfiguration {
    static var lavaRecommendedDefaults: AppConfiguration {
        AppConfiguration(
            protectionEnabled: false,
            enabledBlocklistIDs: DefaultCatalog.recommendedDefaultSourceIDs,
            resolverPresetID: DNSResolverPreset.google.id,
            fallbackToDeviceDNS: true,
            keepFilteringCounts: true,
            keepDomainDiagnostics: true,
            keepNetworkActivity: true
        )
    }
}

public struct OnboardingDefaultsSummary: Equatable, Sendable {
    public let blocklistText: String
    public let resolverText: String
    public let deviceDNSFallbackText: String
    public let localLoggingText: String
    public let accountText: String

    public init(configuration: AppConfiguration, catalog: [BlocklistSource] = DefaultCatalog.curatedSources) {
        blocklistText = Self.blocklistText(for: configuration.enabledBlocklistIDs, catalog: catalog)
        resolverText = configuration.resolverPreset.displayName
        deviceDNSFallbackText = configuration.fallbackToDeviceDNS ? "On" : "Off"
        localLoggingText = Self.localLoggingText(
            keepFilteringCounts: configuration.keepFilteringCounts,
            keepDomainDiagnostics: configuration.keepDomainDiagnostics,
            keepNetworkActivity: configuration.keepNetworkActivity
        )
        accountText = "Continue without account"
    }

    private static func blocklistText(for enabledIDs: Set<String>, catalog: [BlocklistSource]) -> String {
        let names = catalog
            .filter { enabledIDs.contains($0.id) }
            .map(\.name)

        guard let first = names.first else {
            return "No blocklist selected"
        }

        let extraCount = names.count - 1
        guard extraCount > 0 else {
            return first
        }

        return "\(first) + \(extraCount) more"
    }

    private static func localLoggingText(
        keepFilteringCounts: Bool,
        keepDomainDiagnostics: Bool,
        keepNetworkActivity: Bool
    ) -> String {
        var enabled = [String]()
        if keepFilteringCounts {
            enabled.append("Domain counts")
        }
        if keepDomainDiagnostics {
            enabled.append("domain history")
        }
        if keepNetworkActivity {
            enabled.append("network activity")
        }

        switch enabled.count {
        case 0:
            return "Off"
        case 1:
            return enabled[0].prefix(1).uppercased() + enabled[0].dropFirst()
        case 2:
            return "\(enabled[0]) and \(enabled[1])"
        default:
            return "\(enabled.dropLast().joined(separator: ", ")), and \(enabled.last!)"
        }
    }
}
