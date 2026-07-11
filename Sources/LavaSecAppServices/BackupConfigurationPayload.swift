import Foundation
import LavaSecFilterPipeline
import LavaSecKit

/// Why a backup payload could not be decoded/restored on this build.
public enum BackupConfigurationPayloadError: Error, Equatable, Sendable {
    /// The payload advertises a schema newer than this build understands. Restoring it
    /// would decode a lossy subset and then re-seal a downgraded (schema-1) envelope over
    /// the newer single-envelope backup, permanently clobbering it — so we refuse instead.
    case unsupportedSchemaVersion(Int)
}

/// Portable settings snapshot stored inside an encrypted backup envelope.
public struct BackupConfigurationPayload: Codable, Equatable, Sendable {
    /// Bumped only when the wire format changes in a way an older reader cannot safely
    /// restore. A payload whose `schemaVersion` exceeds this is rejected at decode time
    /// (mirrors `ShareableFilterConfiguration.decode(configurationCode:)`) so a future
    /// vN+1 backup is never silently downgraded on a vN device.
    package static let currentSupportedSchemaVersion = 1

    /// Schema version stored with this payload; direct initialization preserves the supplied value.
    public let schemaVersion: Int
    /// Identifiers of curated blocklists selected when the snapshot was made.
    public let enabledBlocklistIDs: Set<String>
    /// User domains allowed by the backed-up configuration.
    public let allowedDomains: Set<String>
    /// User domains blocked by the backed-up configuration.
    public let blockedDomains: Set<String>
    /// Identifier of the selected primary resolver preset.
    public let resolverPresetID: String
    /// Primary custom-resolver address, when one was configured.
    public let customResolverAddress: String?
    /// Secondary primary-resolver address, when one was configured.
    public let customResolverSecondaryAddress: String?
    /// User-facing name of the primary custom resolver.
    public let customResolverName: String?
    /// Whether unresolved primary lookups may fall back to device DNS.
    public let fallbackToDeviceDNS: Bool
    /// Whether device-DNS fallback should prefer an encrypted system resolver.
    public let usesEncryptedDeviceDNSFallback: Bool
    /// Identifier of the selected fallback resolver preset.
    public let fallbackResolverPresetID: String
    /// Fallback custom-resolver address, when one was configured.
    public let fallbackCustomResolverAddress: String?
    /// Secondary fallback-resolver address, when one was configured.
    public let fallbackCustomResolverSecondaryAddress: String?
    /// User-facing name of the fallback custom resolver.
    public let fallbackCustomResolverName: String?
    /// Whether filtering counters were enabled when the snapshot was made.
    public let keepFilteringCounts: Bool
    /// Whether domain-level diagnostics were enabled when the snapshot was made.
    public let keepDomainDiagnostics: Bool
    /// Whether network-activity recording was enabled when the snapshot was made.
    public let keepNetworkActivity: Bool
    /// Whether Lava Guard progress recording was enabled when the snapshot was made.
    public let keepLavaGuardProgress: Bool
    /// Lava Guard achievement progress included in the snapshot.
    public let lavaGuardUnlocks: LavaGuardAchievementLedger
    /// Advisory protection-enabled state captured for restoration.
    public let protectionEnabledHint: Bool
    /// Catalog version observed when the snapshot was made, when available.
    public let catalogVersionHint: String?
    /// Custom blocklist definitions included in the snapshot.
    public let customBlocklists: [CustomBlocklistSource]
    /// The full multi-filter library (hosted filters + active selection). Optional so
    /// pre-multi-filter backups decode to `nil` and restore as a single "Default" filter.
    public let filterLibrary: FilterLibrary?

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
        case filterLibrary
    }

    /// Stores the supplied backup fields without validating cross-field coherence.
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
        customBlocklists: [CustomBlocklistSource] = [],
        filterLibrary: FilterLibrary? = nil
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
        self.filterLibrary = filterLibrary
    }

    /// Decodes supported payloads, applying legacy defaults and rejecting a future schema.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        // Reject a future-schema payload BEFORE reading any other field, so a vN+1 backup
        // restored on a vN device throws here instead of decoding a lossy subset that a
        // later re-seal would then write back as a downgraded schema-1 envelope. Older/current
        // schemas still decode (additive fields are already tolerant of absence above/below).
        guard decodedSchemaVersion <= Self.currentSupportedSchemaVersion else {
            throw BackupConfigurationPayloadError.unsupportedSchemaVersion(decodedSchemaVersion)
        }
        self.schemaVersion = decodedSchemaVersion
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
        self.filterLibrary = try container.decodeIfPresent(FilterLibrary.self, forKey: .filterLibrary)
    }

    /// Captures backup-eligible configuration and strips device-local cache state from the library.
    public init(
        configuration: AppConfiguration,
        catalogVersionHint: String? = nil,
        filterLibrary: FilterLibrary? = nil
    ) {
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
            customBlocklists: configuration.customBlocklists,
            // Strip every hosted filter's device-LOCAL cache fields (compile tokens,
            // freshness timestamps) before they enter the portable payload: they describe
            // THIS device's artifact directories, are useless on a restore target, and would
            // otherwise make a maintenance persist that only restamps a token look like a
            // content change and churn the backup's upload marker.
            filterLibrary: filterLibrary?.strippingLocalCacheState()
        )
    }

    /// Whether two payloads carry the same backed-up CONTENT, ignoring
    /// `protectionEnabledHint`. Protection is toggled constantly (pause/resume, the Live
    /// Activity button) and is only an advisory restore hint, so a toggle on its own must
    /// not re-seal the envelope and flip an already-uploaded backup to "not uploaded". Every
    /// other field still defines content; `filterLibrary` is cache-stripped at construction,
    /// so library equality here is true content equality.
    ///
    /// Consequence (intended, best-effort): because a lone protection toggle is skipped, the
    /// sealed/uploaded `protectionEnabledHint` only refreshes at the next CONTENT change, so a
    /// restore can land on a slightly stale protection state. This is fail-closed — the worst case
    /// is protection restored OFF when the source had it ON (one tap to re-enable), never the
    /// reverse — and on a fresh device the hint is largely inert anyway (`restoreProtectionIfNeeded`
    /// is onboarding-gated and can't auto-start the VPN). The currency win (no marker churn on
    /// pause/resume) outweighs the hint lag.
    public func hasSameBackupContent(as other: BackupConfigurationPayload) -> Bool {
        schemaVersion == other.schemaVersion
            && enabledBlocklistIDs == other.enabledBlocklistIDs
            && allowedDomains == other.allowedDomains
            && blockedDomains == other.blockedDomains
            && resolverPresetID == other.resolverPresetID
            && customResolverAddress == other.customResolverAddress
            && customResolverSecondaryAddress == other.customResolverSecondaryAddress
            && customResolverName == other.customResolverName
            && fallbackToDeviceDNS == other.fallbackToDeviceDNS
            && usesEncryptedDeviceDNSFallback == other.usesEncryptedDeviceDNSFallback
            && fallbackResolverPresetID == other.fallbackResolverPresetID
            && fallbackCustomResolverAddress == other.fallbackCustomResolverAddress
            && fallbackCustomResolverSecondaryAddress == other.fallbackCustomResolverSecondaryAddress
            && fallbackCustomResolverName == other.fallbackCustomResolverName
            && keepFilteringCounts == other.keepFilteringCounts
            && keepDomainDiagnostics == other.keepDomainDiagnostics
            && keepNetworkActivity == other.keepNetworkActivity
            && keepLavaGuardProgress == other.keepLavaGuardProgress
            && lavaGuardUnlocks == other.lavaGuardUnlocks
            && catalogVersionHint == other.catalogVersionHint
            && customBlocklists == other.customBlocklists
            && filterLibrary == other.filterLibrary
    }

    /// The restored multi-filter library, or `nil` for a pre-multi-filter backup (the
    /// caller then migrates `restoredConfiguration()` into a single "Default" filter).
    public func restoredFilterLibrary() -> FilterLibrary? {
        filterLibrary
    }

    /// Rebuilds an app configuration and migrates known custom-list URLs to catalog selections.
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
