import Foundation
import UIKit
@preconcurrency import NetworkExtension
import LavaSecKit
import LavaSecAppServices

extension LavaAppBridge {
    // Metadata-only, event-refreshed snapshot. No configuration content crosses the RN bridge.
    func vpnSettingsState() -> [String: Any] {
        guard let status = model.dnsSettingsProfileStatus else { return [:] }
        let presentation = model.dnsSettingsPresentation(from: status)
        let state = model.chainedOperationalState(from: status)
        let inputs = model.chainedSurfaceInputs(from: status)
        let restriction: String?
        if ChainedSetupPolicy.canEditConfiguration(inputs), let issue = ChainedSetupPolicy.configurationIssue(inputs) {
            restriction = issue == .missingConfiguration ? "Save a configuration above to enable chaining." : issue.message
        }
        else {
            restriction = switch state {
            case .notEntitled: "Chaining is part of Lava Security Plus."
            case .unsupportedDevice: "This device doesn't have enough memory for chaining."
            case .deviceStateUnreadable: "Lava can't check this device right now. Unlock it and try again."
            case .suspendedAfterStartupFailure: "Guard stopped after VPN chaining failed during startup. Turn Guard on to retry."
            case .suspendedAfterSurrender: "Guard stopped because VPN chaining could not keep forwarding. Turn Guard on to retry."
            default: nil
            }
        }
        let storedRotation: ChainedUpstreamRotationFreshness.StoredRotation = status.storedConfigurationGeneration.map {
            .present(generation: $0)
        } ?? (status.storeUnavailableReason == nil ? .absent : .unreadable)
        let rotation = ChainedUpstreamRotationFreshness.verdict(
            runningGeneration: model.tunnelHealth.isChainedUpstreamActive ? model.tunnelHealth.runningChainedUpstreamGeneration : 0,
            storedRotation: storedRotation)
        let applying = model.chainedSettingsApplyState.pending != nil || model.chainedSettingsApplyState.applying != nil
        return ["rotationNote": rotation.deservesSurfacing && !applying ? rotation.detail.lavaLocalized : "",
            "draft": wireGuardDraft.map(wireGuardDraftMetadata) ?? NSNull(),
            "needsRepair": wireGuardCleanupPending || status.hasConfigurationWithoutKey || status.storeUnavailableReason != nil,
            "setup": model.configuration.wireGuardSetupEnabled, "enabled": model.configuration.chainedUpstreamEnabled,
            "canEnable": model.canEnableChainedUpstream(from: status), "canEdit": ChainedSetupPolicy.canEditConfiguration(inputs),
            "fallback": presentation.canChangeFallback && model.configuration.chainedTierOneFallbackEnabled,
            "canChangeFallback": presentation.canChangeFallback, "needsPlus": state == .notEntitled,
            "busy": model.isStagingChainedUpstreamForQA, "restriction": restriction?.lavaLocalized ?? "",
            "error": model.chainedSettingsApplyError ?? "", "unavailable": status.storeUnavailableReason != nil,
            "generation": status.storedConfigurationGeneration.map(String.init) ?? "",
            "rows": status.storedConfigurationRows.enumerated().map { index, row in
                ["name": row.displayName.isEmpty ? "Configuration %d".lavaLocalizedFormat(index + 1) : row.displayName,
                 "isEnabled": row.isEnabled,
                 "mode": (row.routingPolicy == .fullTunnel ? "Full tunnel" : "Split tunnel").lavaLocalized]
            }]
    }

    private func wireGuardDraftMetadata(_ draft: ChainedUpstreamEditDraft) -> [String: Any] {
        ["id": draft.id, "revision": draft.revision, "changed": draft.hasChanges, "containsFullTunnel": draft.containsFullTunnel,
         "rows": draft.rows.enumerated().map { index, row in
             ["name": row.configuration.displayName.isEmpty ? "Configuration %d".lavaLocalizedFormat(index + 1) : row.configuration.displayName,
              "isEnabled": row.configuration.isEnabled,
              "mode": (row.configuration.routingPolicy == .fullTunnel ? "Full tunnel" : "Split tunnel").lavaLocalized]
         }]
    }

    func vpnCommand(_ action: String, _ input: [String: Any]) async throws -> Any {
        // Discard belongs to the originating visit and never mutates saved settings.
        if action == "vpn.cancel" {
            if wireGuardDraft?.id == input["id"] as? String { wireGuardDraft = nil }
            return NSNull()
        }
        try await authorize(.appSettings, "Edit VPN chaining")
        guard UIApplication.shared.applicationState == .active else { throw CommandError("Authentication cancelled.") }
        model.refreshDNSSettingsPresentation()
        defer { model.refreshDNSSettingsPresentation() }
        let status = model.chainedUpstreamSurfaceStatus
        if action == "vpn.toggle" {
            guard let key = input["key"] as? String, let value = input["value"] as? Bool,
                  !model.isStagingChainedUpstreamForQA else { throw WireGuardChainFailure.changed }
            let applied: Bool
            switch key {
            case "setup":
                model.setWireGuardSetupEnabled(value)
                applied = model.configuration.wireGuardSetupEnabled == value
            case "enabled":
                model.setChainedUpstreamEnabled(value)
                applied = model.configuration.chainedUpstreamEnabled == value
            case "fallback":
                guard model.dnsSettingsPresentation(from: status).canChangeFallback else { throw CommandError("DNS fallback is unavailable with an active full-tunnel VPN.".lavaLocalized) }
                model.setChainedTierOneFallbackEnabled(value)
                applied = model.configuration.chainedTierOneFallbackEnabled == value
            default: throw WireGuardChainFailure.changed
            }
            guard applied else { throw CommandError(model.vpnMessage ?? ChainedConfigurationIssue.unavailable.message) }
            return NSNull()
        }
        if action == "vpn.rowToggle" {
            guard wireGuardDraft == nil, let index = input["index"] as? Int,
                  let value = input["value"] as? Bool,
                  input["generation"] as? String == status.storedConfigurationGeneration.map(String.init) else { throw WireGuardChainFailure.changed }
            try model.setWireGuardRowEnabled(value, index: index, expectedGeneration: status.storedConfigurationGeneration)
            return NSNull()
        }
        if action == "vpn.begin" {
            guard let id = input["id"] as? String,
                  (input["generation"] as? String ?? "") == (status.storedConfigurationGeneration.map(String.init) ?? "") else { throw WireGuardChainFailure.changed }
            let draft = try ChainedUpstreamEditDraft(id: id, generation: status.storedConfigurationGeneration,
                configurations: status.storedConfigurationRows)
            wireGuardDraft = draft
            return wireGuardDraftMetadata(draft)
        }
        guard var draft = wireGuardDraft, draft.id == input["id"] as? String,
              !model.isStagingChainedUpstreamForQA else { throw WireGuardChainFailure.changed }
        if action == "vpn.commit" {
            do {
                try model.commitWireGuardPage(&draft)
                wireGuardDraft = nil; wireGuardCleanupPending = false
            } catch {
                // A successful profile write followed by a failed settings write is retryable
                // against its new generation; never silently resubmit the old credential draft.
                wireGuardDraft = draft
                if draft.rows.isEmpty { wireGuardCleanupPending = true }
                throw error
            }
            return NSNull()
        }
        if action == "vpn.reset" {
            guard wireGuardCleanupPending || status.hasConfigurationWithoutKey || status.storeUnavailableReason != nil else { throw WireGuardChainFailure.changed }
            draft.reset(); wireGuardDraft = draft
            return wireGuardDraftMetadata(draft)
        }
        // pinned: ProtectionSettingsApplySourceTests.testDraftBridgeActionsCannotPersistOrRequestRestart
        if action == "vpn.swap" {
            guard ChainedSetupPolicy.canEditConfiguration(model.chainedSurfaceInputs(from: status)) else { throw ChainedConfigurationIssue.unavailable }
            try draft.swapOrder(); wireGuardDraft = draft
            return wireGuardDraftMetadata(draft)
        }
        guard let index = input["index"] as? Int, index >= 0, index < 2 else { throw WireGuardChainFailure.changed }
        if action == "vpn.edit" {
            guard ChainedSetupPolicy.canEditConfiguration(model.chainedSurfaceInputs(from: status)), index <= draft.rows.count else { throw WireGuardChainFailure.changed }
            var editor = LavaAppNativeFlow(name: "vpnConfiguration")
            editor.wireGuardIndex = index
            editor.wireGuardName = draft.rows.indices.contains(index) ? draft.rows[index].configuration.displayName : ""
            editor.wireGuardExists = index < draft.rows.count
            let sessionID = draft.id
            editor.saveWireGuardDraft = { [weak self] name, conf in
                guard let self, var current = self.wireGuardDraft, current.id == sessionID else { return WireGuardChainFailure.changed.localizedDescription }
                do {
                    let replacement = try conf.map { try ChainedUpstreamConfParser.rotation(from: $0) }
                    try current.save(index: index, name: name, replacement: replacement)
                    self.wireGuardDraft = current; self.publish()
                    return nil
                } catch { return error.localizedDescription }
            }
            flow = editor
        } else if action == "vpn.remove" {
            try draft.remove(index: index); wireGuardDraft = draft
        } else { throw CommandError("Unknown VPN action.") }
        return wireGuardDraftMetadata(draft)
    }
    func dnsChoice(_ selection: DNSResolutionSelection) -> [String: Any] {
        let preset = selection.resolver ?? .device
        let metadata = preset.transport == .deviceDNS ? "" : resolverMetadata(preset)
        return ["id": selection.id, "name": selection.id != DNSResolverPreset.customID || selection.name.isEmpty ? preset.settingsBasePreset.displayName : selection.name,
            "primary": selection.primary, "secondary": selection.secondary, "isEnabled": selection.isEnabled,
            "transport": preset.transport == .deviceDNS ? "Device" : transportLabel(preset.transport),
            "metadata": metadata]
    }

    func saveDNSTiers(_ input: [String: Any]) async throws -> Any {
        try await authorize(.appSettings, "Edit DNS settings")
        guard model.mayEditDNSSettingsNow() else { throw CommandError("Review VPN chaining before changing DNS tiers.") }
        guard input["context"] as? String == json(encode(model.configuration.dnsResolutionSelections)),
              let rows = input["tiers"] as? [[String: Any]] else { throw CommandError("DNS settings changed. Reopen the editor before saving.") }
        let selections = try JSONDecoder().decode([DNSResolutionSelection].self, from: JSONSerialization.data(withJSONObject: rows))
        for selection in selections where selection.id == DNSResolverPreset.customID {
            if let message = DNSResolverPreset.customValidationMessage(primaryRawValue: selection.primary,
                secondaryRawValue: selection.secondary, supportsDNSOverQUIC: model.supportsDNSOverQUIC) { throw CommandError(message) }
        }
        try model.saveDNSResolutionSelections(selections)
        return NSNull()
    }

    func toggleDNSTier(_ input: [String: Any]) async throws -> Any {
        try await authorize(.appSettings, "Edit DNS settings")
        guard model.mayEditDNSSettingsNow(),
              input["context"] as? String == json(encode(model.configuration.dnsResolutionSelections)),
              let index = input["index"] as? Int, let value = input["value"] as? Bool else {
            throw CommandError("DNS settings changed. Reopen the editor before saving.")
        }
        var next = model.configuration
        try next.setDNSResolutionEnabled(value, index: index)
        try model.saveDNSResolutionSelections(next.dnsResolutionSelections)
        return NSNull()
    }

    func editCustomDNSDraft(_ input: [String: Any]) async throws -> Any {
        try await authorize(.appSettings, "Edit DNS settings")
        guard model.configuration.limits.allowsCustomDNS else { throw DNSSelectionError.customRequiresPlus }
        let initial = try (input["choice"] as? [String: Any]).map {
            try JSONDecoder().decode(DNSResolutionSelection.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        var editor = LavaAppNativeFlow(name: "customDNSDraft")
        let token = editor.id.uuidString
        dnsPickerCustomChoice = nil
        dnsPickerCustomToken = token
        editor.customDNSInitial = initial
        editor.saveDNSDraft = { [weak self] selection in
            guard let self, self.pushedCustomEntry?.id.uuidString == token,
                  self.model.configuration.limits.allowsCustomDNS else { return "Reopen the DNS editor before saving." }
            if let message = DNSResolverPreset.customValidationMessage(primaryRawValue: selection.primary,
                secondaryRawValue: selection.secondary, supportsDNSOverQUIC: self.model.supportsDNSOverQUIC) { return message }
            guard selection.resolver != nil else { return "Choose a valid DNS resolver." }
            self.dnsPickerCustomChoice = selection
            self.publish()
            return nil
        }
        pushedCustomEntry = editor
        return token
    }

    func customDNSState() -> [String: Any] {
        let config = model.configuration
        let fallback = config.resolverPresetID == DNSResolverPreset.device.id
        let primary = (fallback ? config.fallbackCustomResolverAddress : config.customResolverAddress) ?? ""
        let secondary = (fallback ? config.fallbackCustomResolverSecondaryAddress : config.customResolverSecondaryAddress) ?? ""
        let name = (fallback ? config.fallbackCustomResolverName : config.customResolverName) ?? ""
        let selected = fallback ? config.fallbackResolverPreset : config.resolverPreset
        let preset = DNSResolverPreset.custom(primaryRawValue: primary, secondaryRawValue: secondary)
        let metadata = !config.limits.allowsCustomDNS ? "Upgrade to use DNS over HTTPS, TLS and QUIC" : preset.map(resolverMetadata) ?? "Supports DNS over IP, HTTPS, TLS and QUIC"
        return ["name": name, "primary": primary, "secondary": secondary, "valid": preset != nil,
                "metadata": metadata, "context": json([fallback, config.usesEncryptedDeviceDNSFallback, selected.id, selected.transport.rawValue, name, primary, secondary])]
    }
    func saveCustomDNS(_ input: [String: Any]) async throws -> Any {
        guard let name = input["name"] as? String, let rawPrimary = input["primary"] as? String, let rawSecondary = input["secondary"] as? String else { throw CommandError("Missing custom DNS values.") }
        let primary = rawPrimary.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = rawSecondary.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleared = primary.isEmpty && secondary.isEmpty && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !cleared, let validation = DNSResolverPreset.customValidationMessage(primaryRawValue: primary, secondaryRawValue: secondary, supportsDNSOverQUIC: model.supportsDNSOverQUIC) { return ["validation": validation] }
        try await authorize(.appSettings, "Edit DNS settings")
        guard model.mayEditDNSSettingsNow() else { throw CommandError("With fallback off, VPN chaining uses DNS from its WireGuard configuration.") }
        guard model.configuration.limits.allowsCustomDNS else { return ["requiresUpgrade": true] }
        guard input["context"] as? String == customDNSState()["context"] as? String else { throw CommandError("DNS settings changed. Reopen the editor before saving.") }
        let fallback = model.configuration.resolverPresetID == DNSResolverPreset.device.id
        guard !fallback || model.configuration.usesEncryptedDeviceDNSFallback else { throw CommandError("DNS settings changed. Reopen the editor before saving.") }
        let selected = fallback ? model.configuration.fallbackResolverPreset : model.configuration.resolverPreset
        if cleared {
            let base = selected.settingsBasePreset.id == DNSResolverPreset.customID ? (fallback ? DNSResolverPreset.quad9Unfiltered : .google) : selected.settingsBasePreset
            var replacement = base.resolverVariant(for: selected.transport == .deviceDNS ? .plainDNS : selected.transport)
            if fallback, selected.transport == .dnsOverQUIC, replacement.transport != .dnsOverQUIC { replacement = .quad9UnfilteredDoH }
            if fallback { model.clearFallbackCustomResolver(fallback: replacement) }
            else { model.clearCustomResolver(fallback: replacement) }
        } else if fallback {
            model.setFallbackCustomResolverName(name)
            model.setFallbackCustomResolverAddresses(primary: primary, secondary: secondary)
        } else {
            model.setCustomResolverName(name)
            model.setCustomResolverAddresses(primary: primary, secondary: secondary)
        }
        return NSNull()
    }
    func setSetting(_ input: [String: Any]) async throws {
        guard let key = input["key"] as? String else { throw CommandError("Missing setting.") }
        if key != "biometrics" && !key.hasPrefix("protectedActions.") { try await authorize(.appSettings, "Change Lava settings") }
        if ["deviceDNS", "fallback", "providerID", "provider", "transport"].contains(key), !model.mayEditDNSSettingsNow() {
            throw CommandError("With fallback off, VPN chaining uses DNS from its WireGuard configuration.")
        }
        let c = model.customization
        func boolean() throws -> Bool { guard let value = input["value"] as? Bool else { throw CommandError("Invalid setting value.") }; return value }
        func string() throws -> String { guard let value = input["value"] as? String else { throw CommandError("Invalid setting value.") }; return value }
        switch key {
        case "appearance":
            guard let value = LavaAppearancePreference(rawValue: try string()) else { throw CommandError("Invalid appearance.") }
            c.setAppearancePreference(value)
            _ = AppearanceBridge.shared.service.refresh()
        case "look":
            guard let value = GuardianShieldStyle(rawValue: try string()) else { throw CommandError("Invalid Lava Guard.") }
            guard c.lavaGuardAvailability(for: value).isSelectable else { throw CommandError("This Guard is not unlocked yet.") }
            c.setLavaGuardLook(value)
        case "matchTextSize": c.setTextSizeMatchesSystem(try boolean(), seedingFrom: Self.systemTextSize)
        case "textSize":
            guard let index = input["value"] as? Int, LavaTextSize.allCases.indices.contains(index) else { throw CommandError("Invalid text size.") }
            c.setTextSize(LavaTextSize.allCases[index])
        case "haptics": c.setUsesLavaHaptics(try boolean())
        case "liveActivityPauseMinutes":
            guard let minutes = input["value"] as? Int, LiveActivityPausePreference.minutesRange.contains(minutes) else { throw CommandError("Invalid pause duration.") }
            c.setLiveActivityPauseMinutes(minutes)
        case "liveActivities": c.setUsesLiveActivities(try boolean())
        case "matchIcon": c.setUpdatesAppIconWithLavaGuard(try boolean())
        case "biometrics":
            let enabled = try boolean()
            let revision = security.viewAuthenticationRevision
            if !enabled {
                guard await security.requireBiometricAuthentication(reason: "Turn off %@".lavaLocalizedFormat(security.biometricToggleTitle)) else { throw CommandError("Authentication cancelled.") }
            }
            guard security.viewAuthenticationRevision == revision, !Task.isCancelled else { throw CommandError("Authentication cancelled.") }
            await security.setBiometricEnabled(enabled)
            guard security.isBiometricEnabled == enabled else { throw CommandError(security.statusMessage ?? "Authentication settings could not be updated.") }
        case "backup.automatic":
            guard model.account.isAccountSignedIn, model.backup.isEncryptedBackupConfigured else { throw CommandError("Sign in to change encrypted backup settings.") }
            model.backup.setAutomaticBackupEnabled(try boolean())
        case "dnsPatchProvider": try await updateManagedDNSPatch(create: true, selectedProviderID: try string())
        case "dnsPatchSetup": try await updateManagedDNSPatch(create: true)
        case "dnsPatchCheck": await refreshManagedDNSPatch()
        case "dnsPatchRemove": try await updateManagedDNSPatch(create: false, remove: true)
        case "deviceDNS": model.setResolver(try boolean() ? .device : .quad9UnfilteredDoH)
        case "fallback":
            if model.configuration.resolverPresetID == DNSResolverPreset.device.id { model.setUsesEncryptedDeviceDNSFallback(try boolean()) }
            else { model.setFallbackToDeviceDNS(try boolean()) }
        case "provider", "providerID":
            let value = try string()
            guard let preset = DNSResolverPreset.settingsPresets.first(where: { key == "providerID" ? $0.id == value : $0.displayName == value }) else { throw CommandError("Unknown DNS provider.") }
            let fallback = model.configuration.resolverPresetID == DNSResolverPreset.device.id
            let selected = fallback ? model.configuration.fallbackResolverPreset : model.configuration.resolverPreset
            let variant = preset.resolverVariant(for: selected.transport)
            if fallback { model.setFallbackResolver(variant) } else { model.setResolver(variant) }
        case "transport":
            let values: [String: DNSResolverTransport] = ["IP": .plainDNS, "DoH": .dnsOverHTTPS, "DoT": .dnsOverTLS, "DoQ": .dnsOverQUIC]
            guard let transport = values[try string()] else { throw CommandError("Unknown DNS transport.") }
            let fallback = model.configuration.resolverPresetID == DNSResolverPreset.device.id
            let selected = fallback ? model.configuration.fallbackResolverPreset : model.configuration.resolverPreset
            guard selected.settingsBasePreset.availableTransports.contains(transport) else { throw CommandError("This transport is unavailable for this resolver.") }
            let variant = selected.settingsBasePreset.resolverVariant(for: transport)
            if fallback { model.setFallbackResolver(variant) } else { model.setResolver(variant) }
        case "logs.Filtering Counts": model.reports.setKeepFilteringCounts(try boolean())
        case "logs.Domain logs": model.reports.setKeepDomainDiagnostics(try boolean())
        case "logs.Network activity": model.setKeepNetworkActivity(try boolean())
        case "logs.Lava Guard Progress": model.setKeepLavaGuardProgress(try boolean())
        default:
            if key.hasPrefix("protectedActions."), let surface = Self.surfaces[String(key.dropFirst("protectedActions.".count))] {
                guard security.hasAuthenticationMethod, !updatingSecuritySurface else { throw CommandError("Authentication settings could not be updated.") }
                updatingSecuritySurface = true
                publish()
                defer { updatingSecuritySurface = false; publish() }
                let enabled = try boolean()
                let revision = security.viewAuthenticationRevision
                if !enabled { try await authorize(surface, "Change authentication settings", fresh: true) }
                guard security.viewAuthenticationRevision == revision, security.hasAuthenticationMethod else { throw CommandError("Authentication settings changed. Try again.") }
                security.setProtection(enabled, for: surface)
                if surface == .protectionPause { model.reconcileLiveActivity() }
            } else if key.hasPrefix("notifications.") {
                let categories: [String: LavaNotificationCategory] = ["Filter changes": .filterChanged, "Filter couldn't switch": .filterCouldNotApply,
                    "Protection resumed": .protectionResumed, "Connection updates": .connectivity]
                guard let category = categories[String(key.dropFirst("notifications.".count))] else { throw CommandError("Unknown notification category.") }
                c.setNotificationCategoryEnabled(category, try boolean())
            } else { throw CommandError("Unknown setting.") }
        }
    }
    func clearLogs(_ kind: String, fromActivity: Bool = false) async throws -> String {
        // Log pages inherit Activity authentication; Privacy owns app-settings auth.
        // Counts/progress/all are never available as Activity mutations.
        let activity = fromActivity && ["Clear domain history", "Clear network activity"].contains(kind)
        try await authorize(activity ? .activityViewing : .appSettings, "Clear local logs")
        guard let target = [LocalLogClearTarget.filteringCounts, .domainHistory, .networkActivity, .lavaGuardProgress, .all].first(where: { $0.buttonTitle == kind }) else { throw CommandError("Unknown local log.") }
        let cleared: Bool
        switch target {
        case .filteringCounts: cleared = model.reports.clearLocalFilteringCounts()
        case .domainHistory: cleared = model.reports.clearDomainHistory()
        case .networkActivity: cleared = model.clearNetworkActivityLog()
        case .lavaGuardProgress: cleared = model.clearLavaGuardProgress()
        case .all: cleared = model.reports.clearAllLocalLogs()
        }
        guard cleared else { throw CommandError("Lava could not finish clearing these logs. Please try again.") }
        // Network/progress clears need the same display retirement as history,
        // even though they do not touch the diagnostics control file.
        presentationDisplayClearGeneration &+= 1
        return target.clearedConfirmation.lavaLocalized
    }
}


extension LavaAppBridge {
    /// Readback is authoritative for app-owned settings only. Foreground/NE events
    /// never create a DNS configuration or infer selection from a previous tap.
    func refreshManagedDNSPatch() async {
        guard !dnsPatchBusy else { dnsPatchRefreshPending = true; return }
        do { try await updateManagedDNSPatch(create: false) }
        catch { /* The state row exposes an unknown/readback error, not absence. */ }
    }

    func updateManagedDNSPatch(create: Bool, remove: Bool = false, selectedProviderID: String? = nil) async throws {
        guard #available(iOS 27.0, *) else { return }
        guard !dnsPatchBusy else { throw CommandError("DNS setup is already updating.") }
        dnsPatchBusy = true
        var ownsProviderChange = false
        publish()
        defer {
            if ownsProviderChange { model.protectionActionOrchestrator.release(.reconnect) }
            dnsPatchBusy = false
            publish()
            if dnsPatchRefreshPending {
                dnsPatchRefreshPending = false
                Task { await refreshManagedDNSPatch() }
            }
        }
        do {
            let manager = NEDNSSettingsManager.shared()
            try await manager.loadFromPreferences()
            dnsPatchConfigurationExists = manager.dnsSettings != nil
            let readbackProvider = try managedDNSPatchProvider(manager)
            let targetID = selectedProviderID ?? readbackProvider?.id ?? dnsPatchProviderID
            guard let contract = try DNSPatchProviderCatalog.contract(for: targetID) else {
                throw CommandError("This DNS provider is unavailable for the patch.")
            }
            let alreadyMatches = managedDNSPatchMatches(manager, contract: contract)
            let changesExistingProvider = selectedProviderID != nil && !alreadyMatches && manager.dnsSettings != nil
            if changesExistingProvider {
                guard model.protectionActionOrchestrator.claim(.reconnect) else {
                    throw CommandError("A connection change is already in progress.")
                }
                ownsProviderChange = true
            }
            // Saving an unchanged selection must not rewrite a working system profile.
            if (create && !alreadyMatches) || changesExistingProvider {
                let settings: NEDNSSettings
                if let url = contract.serverURL {
                    let https = NEDNSOverHTTPSSettings(servers: contract.serverAddresses)
                    https.serverURL = URL(string: url)
                    settings = https
                } else {
                    let tls = NEDNSOverTLSSettings(servers: contract.serverAddresses)
                    tls.serverName = contract.serverName
                    settings = tls
                }
                settings.allowFailover = false
                manager.dnsSettings = settings
                manager.onDemandRules = [NEOnDemandRuleConnect()]
                manager.localizedDescription = contract.displayName
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            if remove {
                try await manager.removeFromPreferences()
                try await manager.loadFromPreferences()
                dnsPatchConfigurationExists = manager.dnsSettings != nil
                guard manager.dnsSettings == nil else { throw CommandError("The DNS profile could not be removed.") }
                UserDefaults.standard.removeObject(forKey: DNSPatchProviderCatalog.preferenceKey)
            }
            dnsPatchConfigurationExists = manager.dnsSettings != nil
            let installedProvider = try managedDNSPatchProvider(manager)
            let matches = managedDNSPatchMatches(manager, contract: contract)
            let nextState = manager.dnsSettings == nil ? "absent"
                : installedProvider == nil ? "different" : manager.isEnabled ? "enabled" : "disabled"
            if selectedProviderID != nil {
                // Saving a System DNS selection installs/updates the profile. Merely opening
                // the picker does not. Persist the choice only after successful readback.
                guard matches else {
                    throw CommandError("The DNS profile did not adopt the selected provider.")
                }
            }
            if let installedProvider {
                // Recover even if a prior process stopped between the system save and
                // the preference write. Capture always follows authoritative readback.
                UserDefaults.standard.set(installedProvider.id, forKey: DNSPatchProviderCatalog.preferenceKey)
            }
            // A provider replacement changes the endpoint routes even when the profile
            // remains selected. Hand off to the ordinary fenced reconnect after readback;
            // its intent checks preserve a newer Guard-off action during the save.
            if ownsProviderChange {
                model.protectionActionOrchestrator.release(.reconnect)
                ownsProviderChange = false
            }
            try await model.setDNSPatchEnabled(nextState == "enabled", forceReconnect: changesExistingProvider, installedProviderID: installedProvider?.id)
            dnsPatchState = nextState
        } catch {
            dnsPatchState = "error"
            throw error
        }
    }
    @available(iOS 27.0, *)
    private func managedDNSPatchProvider(_ manager: NEDNSSettingsManager) throws -> DNSResolverPreset? {
        guard let settings = manager.dnsSettings else { return nil }
        let rules = manager.onDemandRules ?? []
        let rule = rules.first
        let universalRule = rules.count == 1 && rule is NEOnDemandRuleConnect
            && rule?.interfaceTypeMatch == .any && rule?.probeURL == nil
            && rule?.dnsSearchDomainMatch == nil && rule?.dnsServerAddressMatch == nil
            && rule?.ssidMatch == nil
        return try DNSPatchProviderCatalog.matchingProvider(
            serverName: (settings as? NEDNSOverTLSSettings)?.serverName ?? (settings as? NEDNSOverHTTPSSettings)?.serverURL?.host,
            servers: settings.servers, matchDomains: settings.matchDomains, allowsFailover: settings.allowFailover,
            hasUniversalConnectRule: universalRule, serverURL: (settings as? NEDNSOverHTTPSSettings)?.serverURL?.absoluteString)
    }

    @available(iOS 27.0, *)
    private func managedDNSPatchMatches(_ manager: NEDNSSettingsManager, contract: DNSPatchContract) -> Bool {
        let settings = manager.dnsSettings
        let rules = manager.onDemandRules ?? []
        let rule = rules.first
        let universalRule = rules.count == 1 && rule is NEOnDemandRuleConnect
            && rule?.interfaceTypeMatch == .any && rule?.probeURL == nil
            && rule?.dnsSearchDomainMatch == nil && rule?.dnsServerAddressMatch == nil
            && rule?.ssidMatch == nil
        return settings.map {
            contract.matchesManagedSettings(serverName: ($0 as? NEDNSOverTLSSettings)?.serverName ?? ($0 as? NEDNSOverHTTPSSettings)?.serverURL?.host, servers: $0.servers,
                matchDomains: $0.matchDomains, allowsFailover: $0.allowFailover,
                hasUniversalConnectRule: universalRule, serverURL: ($0 as? NEDNSOverHTTPSSettings)?.serverURL?.absoluteString)
        } ?? false
    }

}
