import Foundation

public struct BackupConfigurationPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let enabledBlocklistIDs: Set<String>
    public let allowedDomains: Set<String>
    public let blockedDomains: Set<String>
    public let resolverPresetID: String
    public let customResolverAddress: String?
    public let customResolverSecondaryAddress: String?
    public let customResolverName: String?
    public let fallbackToDeviceDNS: Bool
    public let usesEncryptedDeviceDNSFallback: Bool
    public let fallbackResolverPresetID: String
    public let fallbackCustomResolverAddress: String?
    public let fallbackCustomResolverSecondaryAddress: String?
    public let fallbackCustomResolverName: String?
    public let keepFilteringCounts: Bool
    public let keepDomainDiagnostics: Bool
    public let keepNetworkActivity: Bool
    public let keepLavaGuardProgress: Bool
    public let lavaGuardUnlocks: LavaGuardAchievementLedger
    public let protectionEnabledHint: Bool
    public let catalogVersionHint: String?
    public let customBlocklists: [CustomBlocklistSource]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enabledBlocklistIDs
        case allowedDomains
        case blockedDomains
        case resolverPresetID
        case customResolverAddress
        case customResolverSecondaryAddress
        case customResolverName
        case fallbackToDeviceDNS
        case usesEncryptedDeviceDNSFallback
        case fallbackResolverPresetID
        case fallbackCustomResolverAddress
        case fallbackCustomResolverSecondaryAddress
        case fallbackCustomResolverName
        case keepFilteringCounts
        case keepDomainDiagnostics
        case keepNetworkActivity
        case keepLavaGuardProgress
        case lavaGuardUnlocks
        case protectionEnabledHint
        case catalogVersionHint
        case customBlocklists
    }

    public init(
        schemaVersion: Int = 1,
        enabledBlocklistIDs: Set<String>,
        allowedDomains: Set<String>,
        blockedDomains: Set<String>,
        resolverPresetID: String,
        customResolverAddress: String? = nil,
        customResolverSecondaryAddress: String? = nil,
        customResolverName: String? = nil,
        fallbackToDeviceDNS: Bool = false,
        usesEncryptedDeviceDNSFallback: Bool = false,
        fallbackResolverPresetID: String = DNSResolverPreset.mullvadDoH.id,
        fallbackCustomResolverAddress: String? = nil,
        fallbackCustomResolverSecondaryAddress: String? = nil,
        fallbackCustomResolverName: String? = nil,
        keepFilteringCounts: Bool = true,
        keepDomainDiagnostics: Bool,
        keepNetworkActivity: Bool = true,
        keepLavaGuardProgress: Bool = true,
        lavaGuardUnlocks: LavaGuardAchievementLedger = LavaGuardAchievementLedger(),
        protectionEnabledHint: Bool,
        catalogVersionHint: String? = nil,
        customBlocklists: [CustomBlocklistSource] = []
    ) {
        self.schemaVersion = schemaVersion
        self.enabledBlocklistIDs = enabledBlocklistIDs
        self.allowedDomains = allowedDomains
        self.blockedDomains = blockedDomains
        self.resolverPresetID = resolverPresetID
        self.customResolverAddress = customResolverAddress
        self.customResolverSecondaryAddress = customResolverSecondaryAddress
        self.customResolverName = customResolverName
        self.fallbackToDeviceDNS = fallbackToDeviceDNS
        self.usesEncryptedDeviceDNSFallback = usesEncryptedDeviceDNSFallback
        self.fallbackResolverPresetID = fallbackResolverPresetID
        self.fallbackCustomResolverAddress = fallbackCustomResolverAddress
        self.fallbackCustomResolverSecondaryAddress = fallbackCustomResolverSecondaryAddress
        self.fallbackCustomResolverName = fallbackCustomResolverName
        self.keepFilteringCounts = keepFilteringCounts
        self.keepDomainDiagnostics = keepDomainDiagnostics
        self.keepNetworkActivity = keepNetworkActivity
        self.keepLavaGuardProgress = keepLavaGuardProgress
        self.lavaGuardUnlocks = lavaGuardUnlocks
        self.protectionEnabledHint = protectionEnabledHint
        self.catalogVersionHint = catalogVersionHint
        self.customBlocklists = customBlocklists
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.enabledBlocklistIDs = try container.decode(Set<String>.self, forKey: .enabledBlocklistIDs)
        self.allowedDomains = try container.decode(Set<String>.self, forKey: .allowedDomains)
        self.blockedDomains = try container.decode(Set<String>.self, forKey: .blockedDomains)
        self.resolverPresetID = try container.decode(String.self, forKey: .resolverPresetID)
        self.customResolverAddress = try container.decodeIfPresent(String.self, forKey: .customResolverAddress)
        self.customResolverSecondaryAddress = try container.decodeIfPresent(String.self, forKey: .customResolverSecondaryAddress)
        self.customResolverName = try container.decodeIfPresent(String.self, forKey: .customResolverName)
        self.fallbackToDeviceDNS = try container.decodeIfPresent(Bool.self, forKey: .fallbackToDeviceDNS) ?? false
        self.usesEncryptedDeviceDNSFallback = try container.decodeIfPresent(Bool.self, forKey: .usesEncryptedDeviceDNSFallback) ?? false
        self.fallbackResolverPresetID = DNSResolverPreset.migratedPresetID(try container.decodeIfPresent(String.self, forKey: .fallbackResolverPresetID) ?? DNSResolverPreset.mullvadDoH.id)
        self.fallbackCustomResolverAddress = try container.decodeIfPresent(String.self, forKey: .fallbackCustomResolverAddress)
        self.fallbackCustomResolverSecondaryAddress = try container.decodeIfPresent(String.self, forKey: .fallbackCustomResolverSecondaryAddress)
        self.fallbackCustomResolverName = try container.decodeIfPresent(String.self, forKey: .fallbackCustomResolverName)
        self.keepFilteringCounts = try container.decodeIfPresent(Bool.self, forKey: .keepFilteringCounts) ?? true
        self.keepDomainDiagnostics = try container.decode(Bool.self, forKey: .keepDomainDiagnostics)
        self.keepNetworkActivity = try container.decodeIfPresent(Bool.self, forKey: .keepNetworkActivity) ?? true
        self.keepLavaGuardProgress = try container.decodeIfPresent(Bool.self, forKey: .keepLavaGuardProgress) ?? true
        self.lavaGuardUnlocks = try container.decodeIfPresent(
            LavaGuardAchievementLedger.self,
            forKey: .lavaGuardUnlocks
        ) ?? LavaGuardAchievementLedger()
        self.protectionEnabledHint = try container.decode(Bool.self, forKey: .protectionEnabledHint)
        self.catalogVersionHint = try container.decodeIfPresent(String.self, forKey: .catalogVersionHint)
        self.customBlocklists = try container.decodeIfPresent([CustomBlocklistSource].self, forKey: .customBlocklists) ?? []
    }

    public init(configuration: AppConfiguration, catalogVersionHint: String? = nil) {
        self.init(
            enabledBlocklistIDs: configuration.enabledBlocklistIDs,
            allowedDomains: configuration.allowedDomains,
            blockedDomains: configuration.blockedDomains,
            resolverPresetID: configuration.resolverPresetID,
            customResolverAddress: configuration.customResolverAddress,
            customResolverSecondaryAddress: configuration.customResolverSecondaryAddress,
            customResolverName: configuration.customResolverName,
            fallbackToDeviceDNS: configuration.fallbackToDeviceDNS,
            usesEncryptedDeviceDNSFallback: configuration.usesEncryptedDeviceDNSFallback,
            fallbackResolverPresetID: configuration.fallbackResolverPresetID,
            fallbackCustomResolverAddress: configuration.fallbackCustomResolverAddress,
            fallbackCustomResolverSecondaryAddress: configuration.fallbackCustomResolverSecondaryAddress,
            fallbackCustomResolverName: configuration.fallbackCustomResolverName,
            keepFilteringCounts: configuration.keepFilteringCounts,
            keepDomainDiagnostics: configuration.keepDomainDiagnostics,
            keepNetworkActivity: configuration.keepNetworkActivity,
            keepLavaGuardProgress: configuration.keepLavaGuardProgress,
            lavaGuardUnlocks: configuration.lavaGuardUnlocks,
            protectionEnabledHint: configuration.protectionEnabled,
            catalogVersionHint: catalogVersionHint,
            customBlocklists: configuration.customBlocklists
        )
    }

    public func restoredConfiguration() -> AppConfiguration {
        AppConfiguration(
            protectionEnabled: protectionEnabledHint,
            enabledBlocklistIDs: enabledBlocklistIDs,
            allowedDomains: allowedDomains,
            blockedDomains: blockedDomains,
            resolverPresetID: DNSResolverPreset.migratedPresetID(resolverPresetID),
            customResolverAddress: customResolverAddress,
            customResolverSecondaryAddress: customResolverSecondaryAddress,
            customResolverName: customResolverName,
            fallbackToDeviceDNS: fallbackToDeviceDNS,
            usesEncryptedDeviceDNSFallback: usesEncryptedDeviceDNSFallback,
            fallbackResolverPresetID: fallbackResolverPresetID,
            fallbackCustomResolverAddress: fallbackCustomResolverAddress,
            fallbackCustomResolverSecondaryAddress: fallbackCustomResolverSecondaryAddress,
            fallbackCustomResolverName: fallbackCustomResolverName,
            keepFilteringCounts: keepFilteringCounts,
            keepDomainDiagnostics: keepDomainDiagnostics,
            keepNetworkActivity: keepNetworkActivity,
            keepLavaGuardProgress: keepLavaGuardProgress,
            customBlocklists: customBlocklists,
            lavaGuardUnlocks: lavaGuardUnlocks
        )
        .migratingKnownCustomBlocklistsToCatalogSources()
    }
}
