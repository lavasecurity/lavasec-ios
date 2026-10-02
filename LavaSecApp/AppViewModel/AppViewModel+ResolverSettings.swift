import Darwin
import Foundation
import SwiftUI
import UIKit
@preconcurrency import CoreHaptics
@preconcurrency import NetworkExtension
@preconcurrency import UserNotifications
import LavaSecKit
import LavaSecFilterPipeline
import LavaSecAppServices

// One concern of `AppViewModel`, split out of the former single-file view model.
// Stored state (`@Published` and otherwise) lives in LavaSecApp/AppViewModel.swift (extensions
// cannot declare stored properties); every file under AppViewModel/ is one `// MARK:` section.

extension AppViewModel {
    // MARK: - Resolver settings

    /// An event-driven read, shared by native and RN settings. Refresh after
    /// authorization/foreground/profile mutation, not from the five-second poll.
    func refreshDNSSettingsPresentation() {
        #if DEBUG || LAVA_QA_TOOLS
        dnsSettingsProfileStatus = chainedUpstreamSurfaceStatus
        #endif
    }

    var dnsSettingsPresentation: ChainedDNSSettingsPresentation {
        #if DEBUG || LAVA_QA_TOOLS
        return dnsSettingsPresentation(from: dnsSettingsProfileStatus)
        #else
        return ChainedDNSSettingsPresentation(chainingEnabled: false,
            fallbackPreference: configuration.chainedTierOneFallbackEnabled, storedIsSplitTunnel: nil)
        #endif
    }

    #if DEBUG || LAVA_QA_TOOLS
    func dnsSettingsPresentation(from status: ChainedUpstreamSurfaceStatus?) -> ChainedDNSSettingsPresentation {
        ChainedDNSSettingsPresentation(chainingEnabled: configuration.chainedUpstreamEnabled,
            fallbackPreference: configuration.chainedTierOneFallbackEnabled,
            storedIsSplitTunnel: configuration.chainedUpstreamEnabled ? status?.storedConfigurationIsSplitTunnel : true)
    }
    #endif

    /// Recheck after an authorization suspension, before any DNS editor write.
    func mayEditDNSSettingsNow() -> Bool {
        refreshDNSSettingsPresentation()
        return dnsSettingsPresentation.canEditDNS
    }


    func saveDNSResolutionSelections(_ selections: [DNSResolutionSelection]) throws {
        let previous = configuration
        var next = previous
        try next.applyDNSResolutionSelections(selections, allowsCustom: configuration.limits.allowsCustomDNS)
        configuration = next
        do { try persistConfigurationOnly() }
        catch { configuration = previous; throw error }
        appendAppNetworkActivity(.changeResolver)
        Task { await self.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage) }
    }

    func setResolver(_ preset: DNSResolverPreset) {
        guard configuration.resolverPresetID != preset.id else {
            return
        }

        configuration.resolverPresetID = preset.id
        persistResolverSettings(activity: .changeResolver)
    }

    func setCustomResolverAddresses(primary rawPrimaryValue: String, secondary rawSecondaryValue: String) {
        let trimmedPrimaryValue = rawPrimaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecondaryValue = rawSecondaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSecondaryValue = trimmedSecondaryValue.isEmpty ? nil : trimmedSecondaryValue
        if let validationMessage = DNSResolverPreset.customValidationMessage(
            primaryRawValue: trimmedPrimaryValue,
            secondaryRawValue: trimmedSecondaryValue,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        ) {
            vpnMessage = validationMessage
            vpnMessageIsError = true
            return
        }

        guard configuration.resolverPresetID != DNSResolverPreset.customID
            || configuration.customResolverAddress != trimmedPrimaryValue
            || configuration.customResolverSecondaryAddress != normalizedSecondaryValue
        else {
            return
        }

        configuration.resolverPresetID = DNSResolverPreset.customID
        configuration.customResolverAddress = trimmedPrimaryValue
        configuration.customResolverSecondaryAddress = normalizedSecondaryValue
        persistResolverSettings(activity: .changeResolver)
    }

    func clearCustomResolver(fallback preset: DNSResolverPreset) {
        let fallbackPreset = preset.id == DNSResolverPreset.customID ? DNSResolverPreset.google : preset
        let hasSavedCustomResolver = configuration.customResolverAddress != nil
            || configuration.customResolverSecondaryAddress != nil
            || configuration.customResolverName != nil
        let resolverNeedsFallback = configuration.resolverPresetID == DNSResolverPreset.customID
        guard hasSavedCustomResolver || resolverNeedsFallback else {
            return
        }

        configuration.customResolverAddress = nil
        configuration.customResolverSecondaryAddress = nil
        configuration.customResolverName = nil
        if configuration.resolverPresetID == DNSResolverPreset.customID {
            configuration.resolverPresetID = fallbackPreset.id
        }
        persistResolverSettings(activity: .changeResolver)
    }

    func setCustomResolverAddress(_ rawValue: String) {
        setCustomResolverAddresses(primary: rawValue, secondary: configuration.customResolverSecondaryAddress ?? "")
    }

    func setCustomResolverName(_ rawValue: String) {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextValue = trimmedValue.isEmpty ? nil : trimmedValue
        let currentValue = configuration.customResolverName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrentValue = currentValue?.isEmpty == true ? nil : currentValue
        guard normalizedCurrentValue != nextValue else {
            return
        }

        configuration.customResolverName = nextValue
        do {
            try persistConfigurationOnly()
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }
    }

    func persistResolverSettings(activity: NetworkActivityUserAction) {
        do {
            try persistConfigurationOnly()
            appendAppNetworkActivity(activity)
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }
    }

    func setFallbackToDeviceDNS(_ fallbackToDeviceDNS: Bool) {
        guard configuration.fallbackToDeviceDNS != fallbackToDeviceDNS else {
            return
        }

        configuration.fallbackToDeviceDNS = fallbackToDeviceDNS
        do {
            try persistConfigurationOnly()
            appendAppNetworkActivity(.toggleDeviceDNSFallback)
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }
    }

    func setUsesEncryptedDeviceDNSFallback(_ usesEncryptedDeviceDNSFallback: Bool) {
        guard configuration.usesEncryptedDeviceDNSFallback != usesEncryptedDeviceDNSFallback else {
            return
        }

        configuration.usesEncryptedDeviceDNSFallback = usesEncryptedDeviceDNSFallback
        do {
            try persistConfigurationOnly()
            appendAppNetworkActivity(.toggleDeviceDNSFallback)
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }
    }

    func setFallbackResolver(_ preset: DNSResolverPreset) {
        guard configuration.fallbackResolverPresetID != preset.id else {
            return
        }

        configuration.fallbackResolverPresetID = preset.id
        persistResolverSettings(activity: .changeResolver)
    }

    func setFallbackCustomResolverAddresses(primary rawPrimaryValue: String, secondary rawSecondaryValue: String) {
        let trimmedPrimaryValue = rawPrimaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecondaryValue = rawSecondaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSecondaryValue = trimmedSecondaryValue.isEmpty ? nil : trimmedSecondaryValue
        if let validationMessage = DNSResolverPreset.customValidationMessage(
            primaryRawValue: trimmedPrimaryValue,
            secondaryRawValue: trimmedSecondaryValue,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        ) {
            vpnMessage = validationMessage
            vpnMessageIsError = true
            return
        }

        guard configuration.fallbackResolverPresetID != DNSResolverPreset.customID
            || configuration.fallbackCustomResolverAddress != trimmedPrimaryValue
            || configuration.fallbackCustomResolverSecondaryAddress != normalizedSecondaryValue
        else {
            return
        }

        configuration.fallbackResolverPresetID = DNSResolverPreset.customID
        configuration.fallbackCustomResolverAddress = trimmedPrimaryValue
        configuration.fallbackCustomResolverSecondaryAddress = normalizedSecondaryValue
        persistResolverSettings(activity: .changeResolver)
    }

    func clearFallbackCustomResolver(fallback preset: DNSResolverPreset) {
        let fallbackPreset = preset.id == DNSResolverPreset.customID ? DNSResolverPreset.quad9UnfilteredDoH : preset
        let hasSavedCustomResolver = configuration.fallbackCustomResolverAddress != nil
            || configuration.fallbackCustomResolverSecondaryAddress != nil
            || configuration.fallbackCustomResolverName != nil
        let resolverNeedsFallback = configuration.fallbackResolverPresetID == DNSResolverPreset.customID
        guard hasSavedCustomResolver || resolverNeedsFallback else {
            return
        }

        configuration.fallbackCustomResolverAddress = nil
        configuration.fallbackCustomResolverSecondaryAddress = nil
        configuration.fallbackCustomResolverName = nil
        if configuration.fallbackResolverPresetID == DNSResolverPreset.customID {
            configuration.fallbackResolverPresetID = fallbackPreset.id
        }
        persistResolverSettings(activity: .changeResolver)
    }

    func setFallbackCustomResolverAddress(_ rawValue: String) {
        setFallbackCustomResolverAddresses(primary: rawValue, secondary: configuration.fallbackCustomResolverSecondaryAddress ?? "")
    }

    func setFallbackCustomResolverName(_ rawValue: String) {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextValue = trimmedValue.isEmpty ? nil : trimmedValue
        let currentValue = configuration.fallbackCustomResolverName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrentValue = currentValue?.isEmpty == true ? nil : currentValue
        guard normalizedCurrentValue != nextValue else {
            return
        }

        configuration.fallbackCustomResolverName = nextValue
        do {
            try persistConfigurationOnly()
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }
    }
}

extension AppViewModel {
    /// Read-back profile selection controls endpoint capture. Replacing its provider also
    /// requires new routes even when selection stays enabled. Use the ordinary restart
    /// without turning a settings save into a new Guard-on intent.
    func setDNSPatchEnabled(_ enabled: Bool, forceReconnect: Bool = false, installedProviderID: String? = nil) async throws {
        var forceReconnect = forceReconnect
        if enabled, let installedProviderID, let manager = try await loadExistingTunnelManager(),
           let provider = manager.protocolConfiguration as? NETunnelProviderProtocol {
            let savedID = provider.providerConfiguration?[DNSPatchProviderCatalog.providerConfigurationKey] as? String
                ?? DNSPatchProviderCatalog.defaultID
            // Comparing contracts also handles legacy aliases without endless reconnects.
            let routesDiffer = try DNSPatchProviderCatalog.contract(for: savedID)
                != DNSPatchProviderCatalog.contract(for: installedProviderID)
            let savedPatchEnabled = provider.providerConfiguration?["dnsPatchVersion"] as? Int == 1
            forceReconnect = forceReconnect || routesDiffer || !savedPatchEnabled
        }
        guard configuration.dnsPatchEnabled != enabled || forceReconnect else { return }
        let revision = userProtectionIntent.revision
        let generation = try LavaProtectionCommandService.captureExternalRestartGeneration()
        await refreshProtectionStatus(force: true)
        guard configuration.dnsPatchEnabled != enabled || forceReconnect else { return }
        guard protectionActionOrchestrator.claim(.reconnect) else { throw LavaSecAppError.vpnStillStopping }
        defer { protectionActionOrchestrator.release(.reconnect) }
        if configuration.dnsPatchEnabled != enabled {
            let previous = configuration.dnsPatchEnabled
            configuration.dnsPatchEnabled = enabled
            do { try persistConfigurationOnly(schedulesAutomaticBackup: false) }
            catch { configuration.dnsPatchEnabled = previous; throw error }
        }
        guard userProtectionIntent.isEnabled, let container = LavaSecAppGroup.containerURL else { return }
        await reconnectProtectionNow(playsOutcomeHaptic: false, continueIfCurrent: { [weak self] in
            guard let self, !Task.isCancelled, self.userProtectionIntent.isEnabled,
                  self.userProtectionIntent.revision == revision,
                  (try? LavaProtectionCommandService.captureExternalRestartGeneration()) == generation else { return false }
            return ProtectionRestoreIntentStore.read(containerURL: container)
                .resolvedIntent(fallingBackTo: self.userProtectionIntent.isEnabled)
        }, requiresActiveSession: false)
    }
}
