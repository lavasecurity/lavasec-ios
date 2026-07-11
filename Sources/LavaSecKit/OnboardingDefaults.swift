import Foundation

/// The three cumulative stops on the onboarding "protection level" lever. Each stop's
/// blocklist set is DERIVED from the catalog (its `defaultEnabled` flags + categories),
/// never a hardcoded source list, so a catalog change can't silently desync the lever —
/// the same codegen discipline as `DefaultCatalog.recommendedDefaultSourceIDs`.
public enum OnboardingProtectionLevel: String, CaseIterable, Sendable {
    /// Security only — phishing / scam / malware / threat-intel. Never false-positives on
    /// normal browsing.
    case essential
    /// Security + the curated multi-purpose default (spam/fraud/abuse-adjacent). The
    /// recommended one-tap default.
    case balanced
    /// Balanced + the dedicated ads & trackers lists. Broadest, small breakage chance —
    /// opt-in.
    case comprehensive

    /// The recommended default stop. Its set equals `DefaultCatalog.recommendedDefaultSourceIDs`,
    /// so the one-tap path yields the fresh-install recommended config (see the test lock).
    public static let recommended: OnboardingProtectionLevel = .balanced
}

/// Derives each onboarding level's catalog selection and seeded filter.
public extension OnboardingProtectionLevel {
    /// The blocklist IDs this stop enables, derived from the catalog:
    /// - `.essential`: the `.security`-category subset of the catalog defaults.
    /// - `.balanced`: the catalog defaults (security defaults + the one curated multi-purpose
    ///   default) — equal to `DefaultCatalog.recommendedDefaultSourceIDs`.
    /// - `.comprehensive`: balanced ∪ the whole `.adsTracking` category.
    ///
    /// Cumulative by construction: `essential ⊆ balanced ⊆ comprehensive`.
    func enabledBlocklistIDs(catalog: [BlocklistSource] = DefaultCatalog.curatedSources) -> Set<String> {
        let defaults = Set(catalog.filter(\.defaultEnabled).map(\.id))
        switch self {
        case .essential:
            return Set(catalog.filter { $0.defaultEnabled && $0.category == .security }.map(\.id))
        case .balanced:
            return defaults
        case .comprehensive:
            let adsTracking = Set(catalog.filter { $0.category == .adsTracking }.map(\.id))
            return defaults.union(adsTracking)
        }
    }

    /// The categories this stop turns on, in display order — drives the "what this enables"
    /// list shown under the lever. Derived from `enabledBlocklistIDs` so it can't drift.
    func enabledCategories(catalog: [BlocklistSource] = DefaultCatalog.curatedSources) -> [BlocklistCategory] {
        let ids = enabledBlocklistIDs(catalog: catalog)
        let cats = Set(catalog.filter { ids.contains($0.id) }.map(\.category))
        return BlocklistCategory.allCases
            .sorted { $0.sortOrder < $1.sortOrder }
            .filter(cats.contains)
    }

    /// Stable library id for this level's seeded filter (deterministic, so seeding /
    /// restore-to-default / migration are idempotent).
    var filterID: String { "filter-\(rawValue)" }

    /// User-facing name of this level's filter, shown both in the onboarding lever and in
    /// "Your filters" (single source of truth so setup and the library match). "Extra" reads
    /// as "extra blocking on top of Balanced" — no over-promise of completeness.
    var displayName: String {
        switch self {
        case .essential: return "Core"
        case .balanced: return "Balanced"
        case .comprehensive: return "Extra"
        }
    }

    /// This level as a library filter (name + its derived blocklist set).
    func seededFilter(catalog: [BlocklistSource] = DefaultCatalog.curatedSources) -> Filter {
        Filter(id: filterID, name: displayName, enabledBlocklistIDs: enabledBlocklistIDs(catalog: catalog))
    }
}

/// Builds the default filter library presented during onboarding and reset flows.
public extension FilterLibrary {
    /// The three default filters — one per protection level (Core / Balanced / Extra), in
    /// cumulative order — with `active` loaded. The single source for the free tier's three
    /// seeded filters: used by the onboarding seed, the on-upgrade migration, and
    /// "Restore to default".
    static func seededDefaults(
        active: OnboardingProtectionLevel = .recommended,
        catalog: [BlocklistSource] = DefaultCatalog.curatedSources
    ) -> FilterLibrary {
        FilterLibrary(
            filters: OnboardingProtectionLevel.allCases.map { $0.seededFilter(catalog: catalog) },
            activeFilterID: active.filterID
        )
    }
}

/// Supplies the recommended fresh-install configuration.
public extension AppConfiguration {
    /// Protection defaults used before the user customizes onboarding selections.
    static var lavaRecommendedDefaults: AppConfiguration {
        AppConfiguration(
            protectionEnabled: false,
            enabledBlocklistIDs: DefaultCatalog.recommendedDefaultSourceIDs,
            resolverPresetID: DNSResolverPreset.device.id,
            fallbackToDeviceDNS: true,
            // Device DNS is the primary resolver; if it stops answering, allowed
            // lookups are carried over Mullvad DoH (the default encrypted fallback)
            // and return to the device's own DNS once its recovery probes succeed
            // again. That return path exists because the captured resolver is never
            // discarded on masked-read evidence alone (UR-55 / INV-DNS-5); after a
            // real network change the NEW network's resolver is only learnable at
            // the next tunnel start (Phase 0 — no in-place read exists).
            usesEncryptedDeviceDNSFallback: true,
            fallbackResolverPresetID: DNSResolverPreset.mullvadDoH.id,
            keepFilteringCounts: true,
            keepDomainDiagnostics: true,
            keepNetworkActivity: true
        )
    }
}

package struct OnboardingDefaultsSummary: Equatable, Sendable {
    package let blocklistText: String
    package let resolverText: String
    package let deviceDNSFallbackText: String
    package let localLoggingText: String
    package let accountText: String

    package init(
        configuration: AppConfiguration,
        catalog: [BlocklistSource] = DefaultCatalog.curatedSources
    ) {
        blocklistText = Self.blocklistText(for: configuration.enabledBlocklistIDs, catalog: catalog)
        resolverText = configuration.resolverPreset.displayName
        deviceDNSFallbackText = Self.deviceDNSFallbackText(for: configuration)
        localLoggingText = Self.localLoggingText(
            keepFilteringCounts: configuration.keepFilteringCounts,
            keepDomainDiagnostics: configuration.keepDomainDiagnostics,
            keepNetworkActivity: configuration.keepNetworkActivity
        )
        accountText = "Continue without account"
    }

    // When Device DNS is the primary resolver the meaningful safety net is the
    // encrypted fallback (Mullvad DoH by default), so the summary names that
    // resolver; for an encrypted primary it's the device-DNS net (On/Off) instead.
    private static func deviceDNSFallbackText(for configuration: AppConfiguration) -> String {
        guard configuration.resolverPreset.transport == .deviceDNS else {
            return configuration.fallbackToDeviceDNS ? "On" : "Off"
        }

        guard configuration.usesEncryptedDeviceDNSFallback else {
            return "Off"
        }

        return configuration.fallbackResolverPreset.shortDisplayName
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
