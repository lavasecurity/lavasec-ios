import Foundation

public struct AppConfiguration: Equatable, Codable, Sendable {
    public var protectionEnabled: Bool
    public var enabledBlocklistIDs: Set<String>
    public var allowedDomains: Set<String>
    public var blockedDomains: Set<String>
    public var resolverPresetID: String
    public var customResolverAddress: String?
    public var customResolverSecondaryAddress: String?
    public var customResolverName: String?
    public var fallbackToDeviceDNS: Bool
    // Opt-in (default off) encrypted safety net for a Device-DNS *primary*: when the
    // local resolver wedges, queries are carried transiently over an encrypted
    // resolver (Mullvad DoH). Decoupled from `fallbackToDeviceDNS` (which is the
    // inverse, on-by-default direction) so enabling a third-party encrypted resolver
    // is always an explicit choice. The in-preset toggle that flips this ships
    // separately; until then it stays off.
    public var usesEncryptedDeviceDNSFallback: Bool
    // The resolver the encrypted Device-DNS fallback routes to when engaged. Mirrors
    // the primary resolver selection (a preset ID plus optional Custom fields) so the
    // user can pick any provider/transport, Custom included (Plus-gated). Defaults to
    // Mullvad DoH (top of the catalog). Only consulted when usesEncryptedDeviceDNSFallback
    // is on and the primary is Device DNS.
    public var fallbackResolverPresetID: String
    public var fallbackCustomResolverAddress: String?
    public var fallbackCustomResolverSecondaryAddress: String?
    public var fallbackCustomResolverName: String?
    public var keepFilteringCounts: Bool
    public var keepDomainDiagnostics: Bool
    public var keepNetworkActivity: Bool
    public var keepLavaGuardProgress: Bool
    public var isPaid: Bool
    public var qaProbeSet: QADomainProbeSet?
    public var customBlocklists: [CustomBlocklistSource]
    public var lavaGuardUnlocks: LavaGuardAchievementLedger
    /// Monotonic supersession token, bumped on every foreground config write
    /// (`persistSharedState`/`persistConfigurationOnly`). A background catalog
    /// refresh captures this value when it builds, then — inside the publish lock —
    /// re-reads the on-disk value and ABORTS the pointer flip if it changed, so a
    /// background publish can never clobber a newer foreground edit. Kept in the
    /// config file so the token and the config it guards are written atomically
    /// (a sidecar would reintroduce a config-vs-token TOCTOU). NOT a filter-content
    /// input, so it is excluded from `PreparedFilterSnapshotIdentity`.
    public var configurationGeneration: Int

    public init(
        protectionEnabled: Bool = false,
        enabledBlocklistIDs: Set<String> = [],
        allowedDomains: Set<String> = [],
        blockedDomains: Set<String> = [],
        resolverPresetID: String = DNSResolverPreset.mullvadDoH.id,
        customResolverAddress: String? = nil,
        customResolverSecondaryAddress: String? = nil,
        customResolverName: String? = nil,
        fallbackToDeviceDNS: Bool = true,
        usesEncryptedDeviceDNSFallback: Bool = false,
        fallbackResolverPresetID: String = DNSResolverPreset.mullvadDoH.id,
        fallbackCustomResolverAddress: String? = nil,
        fallbackCustomResolverSecondaryAddress: String? = nil,
        fallbackCustomResolverName: String? = nil,
        keepFilteringCounts: Bool = true,
        keepDomainDiagnostics: Bool = true,
        keepNetworkActivity: Bool = true,
        keepLavaGuardProgress: Bool = true,
        isPaid: Bool = false,
        qaProbeSet: QADomainProbeSet? = nil,
        customBlocklists: [CustomBlocklistSource] = [],
        lavaGuardUnlocks: LavaGuardAchievementLedger = LavaGuardAchievementLedger(),
        configurationGeneration: Int = 0
    ) {
        self.protectionEnabled = protectionEnabled
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
        self.isPaid = isPaid
        self.qaProbeSet = qaProbeSet
        self.customBlocklists = customBlocklists
        self.lavaGuardUnlocks = lavaGuardUnlocks
        self.configurationGeneration = configurationGeneration
    }

    public init(
        protectionEnabled: Bool,
        enabledBlocklistIDs: Set<String>,
        allowedDomains: Set<String>,
        blockedDomains: Set<String>,
        resolverPresetID: String,
        fallbackToDeviceDNS: Bool,
        keepFilteringCounts: Bool,
        keepDomainDiagnostics: Bool,
        keepNetworkActivity: Bool,
        keepLavaGuardProgress: Bool = true,
        isPaid: Bool,
        qaProbeSet: QADomainProbeSet?,
        customBlocklists: [CustomBlocklistSource],
        lavaGuardUnlocks: LavaGuardAchievementLedger = LavaGuardAchievementLedger()
    ) {
        self.init(
            protectionEnabled: protectionEnabled,
            enabledBlocklistIDs: enabledBlocklistIDs,
            allowedDomains: allowedDomains,
            blockedDomains: blockedDomains,
            resolverPresetID: resolverPresetID,
            customResolverAddress: nil,
            customResolverSecondaryAddress: nil,
            customResolverName: nil,
            fallbackToDeviceDNS: fallbackToDeviceDNS,
            keepFilteringCounts: keepFilteringCounts,
            keepDomainDiagnostics: keepDomainDiagnostics,
            keepNetworkActivity: keepNetworkActivity,
            keepLavaGuardProgress: keepLavaGuardProgress,
            isPaid: isPaid,
            qaProbeSet: qaProbeSet,
            customBlocklists: customBlocklists,
            lavaGuardUnlocks: lavaGuardUnlocks
        )
    }

    enum CodingKeys: String, CodingKey {
        case protectionEnabled
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
        case isPaid
        case qaProbeSet
        case customBlocklists
        case lavaGuardUnlocks
        case configurationGeneration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .protectionEnabled) ?? false
        enabledBlocklistIDs = try container.decodeIfPresent(Set<String>.self, forKey: .enabledBlocklistIDs) ?? []
        allowedDomains = try container.decodeIfPresent(Set<String>.self, forKey: .allowedDomains) ?? []
        blockedDomains = try container.decodeIfPresent(Set<String>.self, forKey: .blockedDomains) ?? []
        resolverPresetID = DNSResolverPreset.migratedPresetID(try container.decodeIfPresent(String.self, forKey: .resolverPresetID) ?? DNSResolverPreset.mullvadDoH.id)
        customResolverAddress = try container.decodeIfPresent(String.self, forKey: .customResolverAddress)
        customResolverSecondaryAddress = try container.decodeIfPresent(String.self, forKey: .customResolverSecondaryAddress)
        customResolverName = try container.decodeIfPresent(String.self, forKey: .customResolverName)
        fallbackToDeviceDNS = try container.decodeIfPresent(Bool.self, forKey: .fallbackToDeviceDNS) ?? true
        usesEncryptedDeviceDNSFallback = try container.decodeIfPresent(Bool.self, forKey: .usesEncryptedDeviceDNSFallback) ?? false
        fallbackResolverPresetID = DNSResolverPreset.migratedPresetID(try container.decodeIfPresent(String.self, forKey: .fallbackResolverPresetID) ?? DNSResolverPreset.mullvadDoH.id)
        fallbackCustomResolverAddress = try container.decodeIfPresent(String.self, forKey: .fallbackCustomResolverAddress)
        fallbackCustomResolverSecondaryAddress = try container.decodeIfPresent(String.self, forKey: .fallbackCustomResolverSecondaryAddress)
        fallbackCustomResolverName = try container.decodeIfPresent(String.self, forKey: .fallbackCustomResolverName)
        keepFilteringCounts = try container.decodeIfPresent(Bool.self, forKey: .keepFilteringCounts) ?? true
        keepDomainDiagnostics = try container.decodeIfPresent(Bool.self, forKey: .keepDomainDiagnostics) ?? false
        keepNetworkActivity = try container.decodeIfPresent(Bool.self, forKey: .keepNetworkActivity) ?? true
        keepLavaGuardProgress = try container.decodeIfPresent(Bool.self, forKey: .keepLavaGuardProgress) ?? true
        isPaid = try container.decodeIfPresent(Bool.self, forKey: .isPaid) ?? false
        #if DEBUG || LAVA_QA_TOOLS
        qaProbeSet = try container.decodeIfPresent(QADomainProbeSet.self, forKey: .qaProbeSet)
        #else
        qaProbeSet = nil
        #endif
        customBlocklists = try container.decodeIfPresent([CustomBlocklistSource].self, forKey: .customBlocklists) ?? []
        lavaGuardUnlocks = try container.decodeIfPresent(
            LavaGuardAchievementLedger.self,
            forKey: .lavaGuardUnlocks
        ) ?? LavaGuardAchievementLedger()
        configurationGeneration = try container.decodeIfPresent(Int.self, forKey: .configurationGeneration) ?? 0
    }

    public var limits: FeatureLimits {
        hasLavaSecurityPlus ? .plus : .free
    }

    public var hasLavaSecurityPlus: Bool {
        isPaid
    }

    public var resolverPreset: DNSResolverPreset {
        if resolverPresetID == DNSResolverPreset.customID,
           let customResolver = DNSResolverPreset.custom(
                primaryRawValue: customResolverAddress,
                secondaryRawValue: customResolverSecondaryAddress,
                displayName: customResolverName
           ) {
            return customResolver
        }

        return DNSResolverPreset.allPresets.first { $0.id == resolverPresetID } ?? .mullvadDoH
    }

    /// The resolver the encrypted Device-DNS fallback routes to, resolved the same
    /// way as `resolverPreset` (Custom → built custom preset, else catalog lookup).
    public var fallbackResolverPreset: DNSResolverPreset {
        if fallbackResolverPresetID == DNSResolverPreset.customID,
           let customResolver = DNSResolverPreset.custom(
                primaryRawValue: fallbackCustomResolverAddress,
                secondaryRawValue: fallbackCustomResolverSecondaryAddress,
                displayName: fallbackCustomResolverName
           ) {
            return customResolver
        }

        return DNSResolverPreset.allPresets.first { $0.id == fallbackResolverPresetID } ?? .mullvadDoH
    }

    public var resolverDiagnosticDisplayName: String {
        resolverPresetID == DNSResolverPreset.customID ? "Custom DNS" : resolverPreset.displayName
    }
}

public struct AllowlistValidationResult: Equatable, Sendable {
    public let normalizedDomain: String?
    public let isAllowed: Bool
    public let message: String

    public static func allowed(_ domain: String) -> AllowlistValidationResult {
        AllowlistValidationResult(normalizedDomain: domain, isAllowed: true, message: "Allowed domain can be added.")
    }

    public static func rejected(_ message: String) -> AllowlistValidationResult {
        AllowlistValidationResult(normalizedDomain: nil, isAllowed: false, message: message)
    }
}

public struct AllowlistValidator: Sendable {
    public let nonAllowableThreatRules: DomainRuleSet
    public let protectedDomains: DomainRuleSet

    public init(nonAllowableThreatRules: DomainRuleSet, protectedDomains: DomainRuleSet = .lavaSecProtectedDomains) {
        self.nonAllowableThreatRules = nonAllowableThreatRules
        self.protectedDomains = protectedDomains
    }

    public func validate(_ rawDomain: String) -> AllowlistValidationResult {
        do {
            let normalized = try DomainName.normalize(rawDomain)
            if nonAllowableThreatRules.containsNormalized(normalized) {
                return .rejected("Some dangerous domains cannot be allowed.")
            }
            if protectedDomains.containsNormalized(normalized) {
                return .rejected("This domain is protected so Lava can keep essential services working.")
            }
            return .allowed(normalized)
        } catch {
            return .rejected(error.localizedDescription)
        }
    }
}

public extension DomainRuleSet {
    static let lavaSecProtectedDomains: DomainRuleSet = {
        var set = DomainRuleSet()
        let domains = [
            "apple.com",
            "icloud.com",
            "mzstatic.com",
            "itunes.apple.com",
            "apps.apple.com",
            "lavasecurity.com",
            "lavasecurity.app",
            "api.lavasecurity.app",
            "lavasec.app",
            "lavasec.example",
            "accounts.google.com",
            "google.com"
        ]

        for domain in domains {
            try? set.insert(domain: domain, matchesSubdomains: true)
        }

        return set
    }()
}
