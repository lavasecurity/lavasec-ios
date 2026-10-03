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
    // MARK: - Onboarding

    func installLocalVPNProfileForOnboarding() async -> Bool {
        guard protectionActionOrchestrator.claim(.installProfile) else {
            // Rendered verbatim by the onboarding VPN step (Text(variable)) — localize at
            // the producer (i18n round-3 render-path class).
            vpnMessage = "Finish the current VPN setup first.".lavaLocalized
            vpnMessageIsError = false
            return false
        }

        defer {
            protectionActionOrchestrator.release(.installProfile)
        }

        #if targetEnvironment(simulator)
        vpnMessage = "Use a physical device to install the VPN profile."
        vpnMessageIsError = false
        return true
        #else
        vpnMessage = "Preparing local VPN...".lavaLocalized
        vpnMessageIsError = false

        do {
            try await persistSharedState()

            let existingManager = try await loadExistingTunnelManager()
            let manager = try await loadOrCreateTunnelManager(existingManager: existingManager)
            tunnelManager = manager
            updateProtectionStatus(from: manager)
            lastProtectionStatusRefresh = Date()

            vpnMessage = nil
            vpnMessageIsError = false
            return true
        } catch {
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not install VPN profile".lavaLocalized, error: error)
            vpnMessageIsError = true
            return false
        }
        #endif
    }

    func requestProtectionNotificationAuthorizationForOnboarding() async -> Bool {
        await protectionUserNotifications.requestAuthorization()
    }

    func applyOnboardingRecommendedDefaults(protectionLevel: OnboardingProtectionLevel = .recommended) {
        let defaults = AppConfiguration.lavaRecommendedDefaults
        // The surfaced choices are owned by their steps: the protection level by the
        // protection-level step and the resolver + encrypted-fallback fields by the
        // connection-quality step (applyOnboardingConnectionPreferences). Only the non-surfaced
        // residual (local logging retention) is applied here as setup wraps up.
        configuration.keepFilteringCounts = defaults.keepFilteringCounts
        configuration.keepDomainDiagnostics = defaults.keepDomainDiagnostics
        configuration.keepNetworkActivity = defaults.keepNetworkActivity
        // Seed the three default filters (Core / Balanced / Extra) into "Your filters" with the
        // chosen level loaded; mirror its blocklist set into the live config so the active filter
        // and config agree.
        library = .seededDefaults(active: protectionLevel)
        // The onboarding seed is the user's explicit protection-level choice, so the launch-reseed
        // automatic-backup suppression lifts — but, like restoreFiltersToDefault and
        // restoreFromBackup, the DURABLE marker drops only AFTER the reseed pair reaches disk
        // (INV-PERSIST-2 marker consequence). Lift the IN-MEMORY flag now so this persist's backup
        // hook runs unsuppressed; a persist that fails before the pair lands keeps the durable marker
        // so the next launch still suppresses over the un-replaced on-disk reseed instead of
        // clobbering the last good server copy (Codex P1 round 4 on #376). Unlike restoreFiltersToDefault,
        // this runs inside OnboardingFlowView.go(to: .done) right after the leaving step's choice is
        // applied — so that choice is folded into THIS single persist (go(to:) passes
        // persistImmediately: false) rather than firing a sibling fire-and-forget persist that could
        // land the seeded pair ahead of this one's deferred marker clear (Codex P2 on #386).
        // pinned: RebootFirstUnlockGuardSourceTests.testExplicitReseedDefersDurableMarkerDropUntilPersistLands
        // pinned: RebootFirstUnlockGuardSourceTests.testOnboardingCompletionCoalescesToASingleMarkerClearingPersist
        libraryOriginatesFromLaunchReseed = false
        mirrorActiveFilterIntoConfiguration()
        rebuildEnabledBlockRules()
        persistFilterReseedDroppingDurableMarkerWhenLanded()
        startOnboardingDefaultBlocklistSyncIfNeeded()
    }

    /// Apply only the encrypted-fallback toggle shown during onboarding. Saved
    /// primary DNS, fallback providers and custom endpoints remain unchanged.
    /// - Parameter persistImmediately: pass `false` when the SAME onboarding transition also
    ///   seeds the recommended defaults (leaving the last surfaced step for `.done`), so this
    ///   choice is folded into `applyOnboardingRecommendedDefaults`'s single marker-clearing
    ///   persist instead of firing its own. A separate fire-and-forget persist here would be a
    ///   second task that can land the seeded pair while the durable reseed marker is still
    ///   present; a kill before the deferred clear then relaunches the onboarded defaults as a
    ///   suppressed reseed (Codex P2 on #386). See `OnboardingFlowView.go(to:)`.
    /// - pinned: RebootFirstUnlockGuardSourceTests.testOnboardingCompletionCoalescesToASingleMarkerClearingPersist
    func applyOnboardingConnectionPreferences(useEncryptedFallback: Bool, persistImmediately: Bool = true) {
        configuration.applyOnboardingEncryptedFallback(useEncryptedFallback)
        if persistImmediately {
            persistFilterChanges()
        }
    }

    /// - Parameter persistImmediately: see `applyOnboardingConnectionPreferences` — `false`
    ///   folds this choice into the onboarding-completion reseed persist so no second persist
    ///   races the durable-marker clear (Codex P2 on #386).
    /// - pinned: RebootFirstUnlockGuardSourceTests.testOnboardingCompletionCoalescesToASingleMarkerClearingPersist
    func selectOnboardingBlocklists(_ sourceIDs: Set<String>, persistImmediately: Bool = true) {
        guard !sourceIDs.isEmpty else {
            return
        }

        guard configuration.enabledBlocklistIDs != sourceIDs else {
            return
        }

        configuration.enabledBlocklistIDs = sourceIDs
        rebuildEnabledBlockRules()
        catalogStatusMessage = "Blocklist selection updated."
        catalogStatusIsError = false
        if persistImmediately {
            persistFilterChanges()
        }
        startOnboardingBlocklistSyncIfNeeded(for: sourceIDs)
    }

    func startOnboardingDefaultBlocklistSyncIfNeeded() {
        startOnboardingBlocklistSyncIfNeeded(for: configuration.enabledBlocklistIDs)
    }

    func startOnboardingBlocklistSyncIfNeeded(for sourceIDs: Set<String>) {
        guard sourceIDs.contains(where: { cachedBlockRuleSets[$0] == nil }) else {
            return
        }

        Task {
            // A superseding selection (an onboarding pick, the restore-to-defaults button, or
            // the QA LavaQAResetFilters reset) can land while the launch/staleness sync that
            // captured the PREVIOUS selection is still in flight. CatalogController coalesces new
            // callers onto that transaction, so kicking a sync now would only finish against the
            // old sources and leave this selection's missing defaults uncached until a later
            // staleness/foreground sync. Wait for the in-flight transaction to drain, then sync
            // the sources this selection is still missing. The controller installs its task
            // synchronously before the transaction starts, so this also catches a queued refresh
            // that has not reached the hub yet; and when two selections arrive during one sync
            // both follow-ups coalesce onto a single second transaction (catalog.sync joins the
            // in-flight task, which captures the current selection) — no double sync. Mirrors
            // startQAInternetBlocklistSyncIfNeeded. (Codex, #531.)
            if catalog.isSyncInFlight {
                await catalog.awaitCompletion()
            }
            // Gate on the CURRENT selection, not the captured sourceIDs: if this selection was
            // superseded mid-sync by one that is already fully cached, the abandoned selection
            // must not kick a redundant refresh (network + a syncing-UI flash) for a set the user
            // no longer has. A superseding selection that still has missing sources fetches them
            // through its own task. (Codex P2 on #539.)
            guard configuration.enabledBlocklistIDs.contains(where: { cachedBlockRuleSets[$0] == nil }) else {
                return
            }
            await self.syncCatalog()
        }
    }

    func selectOnboardingBlocklist(_ blocklist: BlocklistSource) {
        guard configuration.enabledBlocklistIDs != Set([blocklist.id]) else {
            return
        }

        configuration.enabledBlocklistIDs = [blocklist.id]
        rebuildEnabledBlockRules()
        catalogStatusMessage = "\(blocklist.name) selected."
        catalogStatusIsError = false
        persistFilterChanges()

        guard cachedBlockRuleSets[blocklist.id] == nil, !catalog.isSyncInFlight else {
            return
        }

        Task {
            await self.syncCatalog()
        }
    }

    /// Reason an in-place blocklist edit must be deferred right now, or nil if it may proceed. Today
    /// the only blocker is a pending warm-switch cache rehydration: editing while `cachedBlockRuleSets`
    /// still describes the previous filter would rebuild + publish the target filter from the wrong
    /// filter's rule sets (Codex #133). Callers surface the reason (String?-returning callers return
    /// it; void callers show it via catalogStatusMessage) so the edit is refused, not silently wrong.
    private func deferralReasonForInPlaceBlocklistEdit() -> String? {
        guard hasPendingWarmSwitchCacheRehydration else { return nil }
        return "Finishing the filter switch. Try again in a moment."
    }

    func toggleBlocklist(_ blocklist: BlocklistSource) {
        if let reason = deferralReasonForInPlaceBlocklistEdit() {
            catalogStatusMessage = reason
            catalogStatusIsError = false
            ProtectionHapticFeedback.play(.selectionRejected)
            return
        }
        if configuration.enabledBlocklistIDs.contains(blocklist.id) {
            configuration.enabledBlocklistIDs.remove(blocklist.id)
            rebuildEnabledBlockRules()
            catalogStatusMessage = "Disabled \(blocklist.name)."
            catalogStatusIsError = false
            persistFilterChanges()
            ProtectionHapticFeedback.play(.selectionConfirmed)
            return
        }

        guard catalogSourcesByID[blocklist.id] != nil else {
            catalogStatusMessage = "This source is not available yet."
            catalogStatusIsError = true
            ProtectionHapticFeedback.play(.selectionRejected)
            return
        }

        guard !catalog.isSyncInFlight else {
            catalogStatusMessage = "Finish the current filter update first."
            catalogStatusIsError = false
            ProtectionHapticFeedback.play(.selectionRejected)
            return
        }

        guard !enabledIDsExceedSoftRuleBudget(configuration.enabledBlocklistIDs.union([blocklist.id])) else {
            surfaceTierBudgetStatusMessage()
            ProtectionHapticFeedback.play(.selectionRejected)
            return
        }

        guard cachedBlockRuleSets[blocklist.id] != nil else {
            configuration.enabledBlocklistIDs.insert(blocklist.id)
            catalogStatusMessage = "Downloading \(blocklist.name)..."
            catalogStatusIsError = false
            ProtectionHapticFeedback.play(.selectionConfirmed)
            Task {
                await syncCatalog()
            }
            return
        }

        configuration.enabledBlocklistIDs.insert(blocklist.id)
        rebuildEnabledBlockRules()

        // INV-TIER-1 exact-union check: the soft gate above binds the per-list SUM (with its
        // ×1.10 estimate margin), so a low-overlap selection can pass it while the deduped
        // union exceeds the budget — and this cached-enable path runs NO cold prepare, so
        // without this check the over-budget selection would persist, hit the silent flip
        // veto, and fail closed unexplained on the next NE restart. The union is already
        // rebuilt, so reject exactly, revert, and reuse the soft gate's rejection UX.
        guard FilterRuleBudget.fitsTierBudget(
            compiledTotal: liveCompiledTierBudgetRuleCount,
            maxFilterRules: configuration.limits.maxFilterRules
        ) else {
            configuration.enabledBlocklistIDs.remove(blocklist.id)
            rebuildEnabledBlockRules()
            surfaceTierBudgetStatusMessage()
            ProtectionHapticFeedback.play(.selectionRejected)
            return
        }

        catalogStatusMessage = "Enabled \(blocklist.name)."
        catalogStatusIsError = false
        persistFilterChanges()
        ProtectionHapticFeedback.play(.selectionConfirmed)
    }

    func addCustomBlocklist(displayName: String, rawURL: String) -> String? {
        if let reason = deferralReasonForInPlaceBlocklistEdit() {
            return reason
        }
        guard configuration.limits.allowsCustomBlocklists else {
            return "Custom blocklist URLs are included with Lava Plus."
        }

        do {
            let source = try CustomBlocklistSource(displayName: displayName, rawURL: rawURL)
            if let catalogSourceID = KnownBlocklistURLMatcher.catalogSourceID(for: source.sourceURL) {
                guard catalogSourcesByID[catalogSourceID] != nil || configuration.enabledBlocklistIDs.contains(catalogSourceID) else {
                    return "A selected blocklist is no longer available. Choose another list and try again."
                }
                if !configuration.enabledBlocklistIDs.contains(catalogSourceID),
                   enabledIDsExceedSoftRuleBudget(configuration.enabledBlocklistIDs.union([catalogSourceID])) {
                    return filterRuleBudgetMessage()
                }

                let customBlocklistsBeforeEnable = configuration.customBlocklists
                let wasAlreadyEnabled = configuration.enabledBlocklistIDs.contains(catalogSourceID)
                configuration.customBlocklists.removeAll {
                    $0.sourceURL == source.sourceURL
                        || KnownBlocklistURLMatcher.catalogSourceID(for: $0.sourceURL) == catalogSourceID
                }
                configuration.enabledBlocklistIDs.insert(catalogSourceID)
                rebuildEnabledBlockRules()

                // INV-TIER-1 exact-union check, mirroring toggleBlocklist's: the soft gate above
                // binds the estimate SUM (×1.10 margin), so a pasted known-catalog URL can pass
                // it while the deduped union exceeds the budget — and this cached-enable path
                // runs no cold prepare, so without this the over-budget selection would persist
                // into the silent flip veto and fail closed later instead of reverting here.
                // (An uncached source under-counts and defers to the post-sync surface + flip
                // veto, same as toggleBlocklist's download branch.) Revert BOTH mutations and
                // return the message through this API's own error surface.
                guard FilterRuleBudget.fitsTierBudget(
                    compiledTotal: liveCompiledTierBudgetRuleCount,
                    maxFilterRules: configuration.limits.maxFilterRules
                ) else {
                    configuration.customBlocklists = customBlocklistsBeforeEnable
                    if !wasAlreadyEnabled {
                        configuration.enabledBlocklistIDs.remove(catalogSourceID)
                    }
                    rebuildEnabledBlockRules()
                    return filterRuleBudgetMessage()
                }

                persistFilterChanges()
                catalogStatusMessage = "Enabled \(blocklistName(for: catalogSourceID))."
                catalogStatusIsError = false

                guard !catalog.isSyncInFlight else {
                    return nil
                }

                Task {
                    await syncCatalog()
                }

                return nil
            }

            guard !configuration.customBlocklists.contains(where: { $0.sourceURL == source.sourceURL }) else {
                return "That custom URL is already added."
            }

            let displayKey = customBlocklistDisplayKey(for: source)
            guard !configuration.customBlocklists.contains(where: { existingSource in
                existingSource.sourceURL != source.sourceURL
                    && customBlocklistDisplayKey(for: existingSource) == displayKey
            }) else {
                return "A custom list with that name already exists."
            }

            let updatedIDs = configuration.enabledBlocklistIDs.union([source.id])
            guard !enabledIDsExceedSoftRuleBudget(updatedIDs) else {
                return filterRuleBudgetMessage()
            }

            configuration.customBlocklists.append(source)
            configuration.enabledBlocklistIDs = updatedIDs
            rebuildEnabledBlockRules()
            persistFilterChanges()
            catalogStatusMessage = "Added custom blocklist."
            catalogStatusIsError = false

            guard !catalog.isSyncInFlight else {
                return nil
            }

            Task {
                await syncCatalog()
            }

            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeCustomBlocklist(id: String) {
        if let reason = deferralReasonForInPlaceBlocklistEdit() {
            catalogStatusMessage = reason
            catalogStatusIsError = false
            ProtectionHapticFeedback.play(.selectionRejected)
            return
        }
        configuration.customBlocklists.removeAll { $0.id == id }
        configuration.enabledBlocklistIDs.remove(id)
        cachedBlockRuleSets[id] = nil
        rebuildEnabledBlockRules()
        catalogStatusMessage = "Removed custom blocklist."
        catalogStatusIsError = false
        persistFilterChanges()
    }

    func addAllowlistDraft() {
        let validator = AllowlistValidator(nonAllowableThreatRules: threatGuardrail)
        let result = validator.validate(allowlistDraft)

        guard result.isAllowed, let domain = result.normalizedDomain else {
            lastAllowlistMessage = result.message
            return
        }

        guard configuration.allowedDomains.count < configuration.limits.maxAllowedDomains else {
            lastAllowlistMessage = "Free protection includes \(configuration.limits.maxAllowedDomains) allowed domains."
            return
        }

        configuration.allowedDomains.insert(domain)
        allowlistDraft = ""
        lastAllowlistMessage = "Added \(domain)."
        persistFilterChanges()
    }

    func removeAllowedDomain(_ domain: String) {
        if configuration.allowedDomains.remove(domain) != nil {
            lastAllowlistMessage = "Removed \(domain)."
            persistFilterChanges()
        }
    }
}
