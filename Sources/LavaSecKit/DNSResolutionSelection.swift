import Foundation

/// One provider/transport choice. Custom endpoints stay in a draft until the whole tier list is saved.
public struct DNSResolutionSelection: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var primary: String
    public var secondary: String
    /// Disabled choices remain saved in their original numbered row.
    public var isEnabled: Bool

    public init(id: String, name: String = "", primary: String = "", secondary: String = "", isEnabled: Bool = true) {
        self.id = id; self.name = name; self.primary = primary; self.secondary = secondary; self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey { case id, name, primary, secondary, isEnabled }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                  primary: try c.decodeIfPresent(String.self, forKey: .primary) ?? "",
                  secondary: try c.decodeIfPresent(String.self, forKey: .secondary) ?? "",
                  isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true)
    }

    public var resolver: DNSResolverPreset? {
        if id == DNSResolverPreset.customID {
            return DNSResolverPreset.custom(primaryRawValue: primary, secondaryRawValue: secondary)
        }
        return DNSResolverPreset.allPresets.first { $0.id == id }
    }
}

extension AppConfiguration {
    /// The original saved row supplying the effective primary resolver.
    /// Disabled rows retain their tier number even when the other row runs alone.
    public var configuredPrimaryDNSResolverTier: DNSResolverTier {
        guard let saved = savedDNSResolutionSelections, saved.count == 2,
              !saved[0].isEnabled, saved[1].isEnabled else { return .tierOne }
        // Validate against the effective legacy projection without calling
        // dnsResolutionSelections: its getter consults resolverLadderInputs, which
        // includes this origin. Direct setters must still invalidate stale saved rows.
        let hasActiveFallback = resolverPreset.transport == .deviceDNS
            ? usesEncryptedDeviceDNSFallback
            : fallbackToDeviceDNS || (usesExplicitDNSTiers && usesEncryptedDeviceDNSFallback)
        guard !hasActiveFallback else { return .tierOne }
        let effective = DNSResolutionSelection(
            id: resolverPresetID, name: customResolverName ?? "",
            primary: customResolverAddress ?? "", secondary: customResolverSecondaryAddress ?? "")
        let selected = saved[1]
        let matches = selected.id == DNSResolverPreset.customID
            ? selected == effective
            : selected.id == effective.id
        return matches ? .tierTwo : .tierOne
    }

    /// The ordered, editable T1/T2 pair. T0 remains owned by the WireGuard configuration.
    public var dnsResolutionSelections: [DNSResolutionSelection] {
        // Legacy setters and restored backups may change effective fields independently.
        // Retain disabled rows only while their active projection matches those fields.
        let legacy = legacyDNSResolutionSelections
        func normalized(_ rows: [DNSResolutionSelection]) -> [DNSResolutionSelection] {
            rows.map { $0.id == DNSResolverPreset.customID ? $0 : DNSResolutionSelection(id: $0.id) }
        }
        if let saved = savedDNSResolutionSelections, normalized(saved.filter(\.isEnabled)) == normalized(legacy) { return saved }
        return legacy
    }
    private var legacyDNSResolutionSelections: [DNSResolutionSelection] {
        let first = DNSResolutionSelection(id: resolverPresetID, name: customResolverName ?? "",
            primary: customResolverAddress ?? "", secondary: customResolverSecondaryAddress ?? "")
        let ladder = resolverLadderInputs
        guard ladder.isConfiguredFallbackEnabled else { return [first] }
        let fallback = ladder.configuredFallbackResolver
        return [first, DNSResolutionSelection(id: fallback.id, name: fallbackCustomResolverName ?? "",
            primary: fallbackCustomResolverAddress ?? "", secondary: fallbackCustomResolverSecondaryAddress ?? "")]
    }

    /// Applies a complete validated ladder at once; no intermediate duplicate or empty primary is published.
    public mutating func applyDNSResolutionSelections(_ selections: [DNSResolutionSelection], allowsCustom: Bool) throws {
        guard (1...2).contains(selections.count) else { throw DNSSelectionError.invalidCount }
        let resolvers = try selections.map { selection -> DNSResolverPreset in
            guard let resolver = selection.resolver else { throw DNSSelectionError.invalidResolver }
            guard !selection.isEnabled || selection.id != DNSResolverPreset.customID || allowsCustom else { throw DNSSelectionError.customRequiresPlus }
            return resolver
        }
        guard resolvers.count < 2 || AppConfiguration.resolverIdentity(of: resolvers[0]).split(separator: "|", omittingEmptySubsequences: false).dropFirst() != AppConfiguration.resolverIdentity(of: resolvers[1]).split(separator: "|", omittingEmptySubsequences: false).dropFirst() else {
            throw DNSSelectionError.duplicate
        }
        let active = selections.filter(\.isEnabled)
        guard !active.isEmpty else { throw DNSSelectionError.invalidCount }
        let activeResolvers = active.compactMap(\.resolver)
        let first = active[0]
        resolverPresetID = first.id
        if first.id == DNSResolverPreset.customID {
            customResolverName = first.name; customResolverAddress = first.primary; customResolverSecondaryAddress = first.secondary
        }
        usesExplicitDNSTiers = true
        fallbackToDeviceDNS = activeResolvers.count == 2 && activeResolvers[1].transport == .deviceDNS
        usesEncryptedDeviceDNSFallback = activeResolvers.count == 2 && activeResolvers[1].transport != .deviceDNS
        if usesEncryptedDeviceDNSFallback {
            let second = active[1]
            fallbackResolverPresetID = second.id
            if second.id == DNSResolverPreset.customID {
                fallbackCustomResolverName = second.name; fallbackCustomResolverAddress = second.primary; fallbackCustomResolverSecondaryAddress = second.secondary
            }
        }
        savedDNSResolutionSelections = selections
    }

    /// Toggle one saved row, refusing the last-active OFF atomically.
    /// pinned: DNSResolutionSelectionTests.testRowSwitchesRetainOrderAndNeverDisableTheLastResolver
    public mutating func setDNSResolutionEnabled(_ enabled: Bool, index: Int) throws {
        var rows = dnsResolutionSelections
        guard rows.indices.contains(index) else { throw DNSSelectionError.invalidCount }
        rows[index].isEnabled = enabled
        try applyDNSResolutionSelections(rows, allowsCustom: limits.allowsCustomDNS)
    }
}

/// Validation failures shared by native commands and executable tests.
public enum DNSSelectionError: String, Error, LocalizedError {
    case invalidCount = "Keep one primary DNS and, optionally, one secondary DNS."
    case invalidResolver = "Choose a valid DNS provider and transport."
    case duplicate = "Choose a different DNS for the second tier."
    case customRequiresPlus = "Custom DNS requires Lava Plus."
    public var errorDescription: String? { LavaCoreStrings.localized(rawValue) }
}
