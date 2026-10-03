import Foundation
import LavaSecFilterPipeline
import LavaSecKit

/// A restore that could not be prepared or no longer matches its review.
public enum BackupRestorePlanError: Error, Equatable, Sendable {
    /// The interactive resolver validator rejected stored primary or fallback settings.
    case invalidResolver(String)
    /// This device's current tier does not permit a selected custom resolver.
    case customDNSRequiresPlus
    /// Settings or the filter library changed after this review was prepared.
    case staleReview
    /// A changed DNS selection needs its own acknowledgement.
    case resolverConfirmationRequired
}

/// Validated effective settings and the changes a user must review before restoring.
/// Preparation is pure: the app retains unlock material separately until confirmation.
public struct BackupRestorePlan: Equatable, Sendable {
    /// The exact configuration described by the review, including current device-only settings.
    public let configuration: AppConfiguration
    /// The normalized, migrated library that will become authoritative on this device.
    public let library: FilterLibrary
    /// Configuration shown on the before side of the review.
    public let previousConfiguration: AppConfiguration
    /// Library shown on the before side of the review, excluding local cache metadata.
    public let previousLibrary: FilterLibrary
    /// Every added, removed or changed filter, in stable identifier order.
    public let filterChanges: [FilterReplacementSummary]
    /// Whether primary, fallback or stored custom DNS settings differ from the current settings.
    public let requiresResolverConfirmation: Bool

    /// Validates a payload and computes the effective restore without writing any state.
    public init(
        payload: BackupConfigurationPayload,
        currentConfiguration: AppConfiguration,
        currentLibrary: FilterLibrary,
        supportsDNSOverQUIC: Bool = true
    ) throws {
        guard payload.schemaVersion <= BackupConfigurationPayload.currentSupportedSchemaVersion else {
            throw BackupConfigurationPayloadError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        try Self.validateResolver(
            selectedID: payload.resolverPresetID,
            primary: payload.customResolverAddress,
            secondary: payload.customResolverSecondaryAddress,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        )
        try Self.validateResolver(
            selectedID: payload.fallbackResolverPresetID,
            primary: payload.fallbackCustomResolverAddress,
            secondary: payload.fallbackCustomResolverSecondaryAddress,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        )
        guard currentConfiguration.limits.allowsCustomDNS
            || (payload.resolverPresetID != DNSResolverPreset.customID
                && payload.fallbackResolverPresetID != DNSResolverPreset.customID) else {
            throw BackupRestorePlanError.customDNSRequiresPlus
        }

        var restored = payload.restoredConfiguration()
        // Protection and chaining intent belong to this device; entitlement is not transferable.
        restored.dnsPatchEnabled = currentConfiguration.dnsPatchEnabled
        restored.protectionEnabled = currentConfiguration.protectionEnabled
        restored.isPaid = currentConfiguration.isPaid
        restored.qaProbeSet = currentConfiguration.qaProbeSet
        restored.configurationGeneration = currentConfiguration.configurationGeneration
        restored.wireGuardSetupEnabled = currentConfiguration.wireGuardSetupEnabled
        restored.chainedUpstreamEnabled = currentConfiguration.chainedUpstreamEnabled
        restored.chainedTierOneFallbackEnabled = currentConfiguration.chainedTierOneFallbackEnabled

        var library: FilterLibrary
        if let restoredLibrary = payload.restoredFilterLibrary()?
            .strippingLocalCacheState()
            .migratingKnownCustomBlocklistsToCatalogSources()
            .normalized(), restoredLibrary.isValid {
            library = restoredLibrary
        } else {
            library = FilterLibrary(migratingLegacy: restored)
        }
        library.schemaVersion = FilterLibrary.currentSchemaVersion
        let active = library.activeFilter
        restored.enabledBlocklistIDs = active.enabledBlocklistIDs
        restored.customBlocklists = active.customBlocklists
        restored.blockedDomains = active.blockedDomains
        restored.allowedDomains = active.allowedDomains

        self.configuration = restored
        self.library = library
        self.previousConfiguration = currentConfiguration
        self.previousLibrary = currentLibrary.strippingLocalCacheState()
        let filterIDs = Set(currentLibrary.filters.map(\.id)).union(library.filters.map(\.id))
        self.filterChanges = filterIDs.sorted().map { id in
            FilterReplacementSummary(before: currentLibrary.filter(id: id), after: library.filter(id: id))
        }.filter(\.hasChanges)
        self.requiresResolverConfirmation = Self.dnsSettingsDiffer(currentConfiguration, restored)
    }

    /// Refuses stale or incompletely acknowledged reviews before the app stages any writes.
    public func validateConfirmation(
        currentConfiguration: AppConfiguration,
        currentLibrary: FilterLibrary,
        resolverChangeConfirmed: Bool
    ) throws {
        guard currentConfiguration == previousConfiguration,
              currentLibrary.strippingLocalCacheState() == previousLibrary else {
            throw BackupRestorePlanError.staleReview
        }
        guard !requiresResolverConfirmation || resolverChangeConfirmed else {
            throw BackupRestorePlanError.resolverConfirmationRequired
        }
    }

    private static func validateResolver(
        selectedID: String, primary: String?, secondary: String?, supportsDNSOverQUIC: Bool
    ) throws {
        let hasStoredAddress = [primary, secondary].contains { value in
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        guard selectedID == DNSResolverPreset.customID || hasStoredAddress else { return }
        if let message = DNSResolverPreset.customValidationMessage(
            primaryRawValue: primary, secondaryRawValue: secondary,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        ) {
            throw BackupRestorePlanError.invalidResolver(message)
        }
    }

    private static func dnsSettingsDiffer(_ before: AppConfiguration, _ after: AppConfiguration) -> Bool {
        before.resolverPresetID != after.resolverPresetID
            || before.customResolverName != after.customResolverName
            || before.customResolverAddress != after.customResolverAddress
            || before.customResolverSecondaryAddress != after.customResolverSecondaryAddress
            || before.fallbackToDeviceDNS != after.fallbackToDeviceDNS
            || before.usesEncryptedDeviceDNSFallback != after.usesEncryptedDeviceDNSFallback
            || before.usesExplicitDNSTiers != after.usesExplicitDNSTiers
            || before.dnsResolutionSelections != after.dnsResolutionSelections
            || before.fallbackResolverPresetID != after.fallbackResolverPresetID
            || before.fallbackCustomResolverName != after.fallbackCustomResolverName
            || before.fallbackCustomResolverAddress != after.fallbackCustomResolverAddress
            || before.fallbackCustomResolverSecondaryAddress != after.fallbackCustomResolverSecondaryAddress
    }
}
