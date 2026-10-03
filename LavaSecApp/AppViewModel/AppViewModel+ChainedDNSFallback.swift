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
    // MARK: - Chained DNS fallback (T1)
    #if DEBUG || LAVA_QA_TOOLS
    /// A settings commit never implies Guard ON. Coalesce commits for half a second,
    /// then use the same action gate and cross-process fence as an ordinary reconnect.
    /// The worker outlives the page; new input cannot cancel a restart mid-teardown.
    func requestChainedSettingsApply() {
        #if !targetEnvironment(simulator)
        chainedSettingsApplyError = nil
        let externalRestartGeneration: ProtectionExternalRestartGenerationSnapshot
        do {
            externalRestartGeneration = try LavaProtectionCommandService.captureExternalRestartGeneration()
        } catch {
            chainedSettingsApplyState.cancelPending()
            chainedSettingsApplyError = error.localizedDescription
            return
        }
        chainedSettingsApplyState.recordChange(
            now: ProcessInfo.processInfo.systemUptime,
            intent: userProtectionIntent, externalRestartGeneration: externalRestartGeneration,
            hasRunningProtection: isProtectionEnabledStatus(vpnStatus) || isAwaitingOnDemandReconnect)
        guard chainedSettingsApplyState.pending != nil, chainedSettingsApplyTask == nil else { return }
        chainedSettingsApplyTask = Task { [weak self] in
            guard let self else { return }
            defer {
                chainedSettingsApplyTask = nil
                if Task.isCancelled { chainedSettingsApplyState.cancelPending() }
            }
            while !Task.isCancelled {
                guard chainedSettingsApplyState.pending != nil else { return }
                let currentExternalRestartGeneration: ProtectionExternalRestartGenerationSnapshot
                do {
                    currentExternalRestartGeneration = try LavaProtectionCommandService.captureExternalRestartGeneration()
                } catch {
                    chainedSettingsApplyState.cancelPending()
                    chainedSettingsApplyError = error.localizedDescription
                    return
                }
                // A newer Live Activity Restart already consumes the saved settings. Match
                // its durable generation before waiting and again inside the mutation fence.
                // pinned: ProtectionSettingsApplySourceTests.testWorkerChecksTheExternalRestartGenerationAndClearsSuccessfulErrors
                chainedSettingsApplyState.discardSuperseded(
                    intent: userProtectionIntent, externalRestartGeneration: currentExternalRestartGeneration)
                guard let deadline = chainedSettingsApplyState.deadline else { return }
                let delay = deadline - ProcessInfo.processInfo.systemUptime
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    continue
                }
                // Staging may still be replacing the saved rotation, and another lifecycle
                // action may already own the manager. Neither condition drops the latest edit.
                if isStagingChainedUpstreamForQA || protectionActionOrchestrator.isActionInFlight
                    || UIApplication.shared.applicationState != .active {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    continue
                }
                guard let ticket = chainedSettingsApplyState.beginIfReady(
                    now: ProcessInfo.processInfo.systemUptime,
                    intent: userProtectionIntent, externalRestartGeneration: currentExternalRestartGeneration,
                    lifecycleIsAvailable: true)
                else { continue }
                guard protectionActionOrchestrator.claim(.reconnect) else {
                    chainedSettingsApplyState.finish(ticket)
                    return
                }
                var continuationReadError: String?
                await reconnectProtectionNow(
                    playsOutcomeHaptic: false,
                    continueIfCurrent: { [weak self] in
                        guard let self, !Task.isCancelled,
                              let containerURL = LavaSecAppGroup.containerURL else { return false }
                        let latestExternalRestartGeneration: ProtectionExternalRestartGenerationSnapshot
                        do {
                            latestExternalRestartGeneration = try LavaProtectionCommandService.captureExternalRestartGeneration()
                        } catch {
                            // A refused read is not a newer Restart. Fail closed but retain its
                            // error through completion so saved settings cannot silently stay stale.
                            // pinned: ProtectionSettingsApplySourceTests.testWorkerChecksTheExternalRestartGenerationAndClearsSuccessfulErrors
                            continuationReadError = error.localizedDescription
                            return false
                        }
                        guard chainedSettingsApplyState.mayContinue(
                            ticket, intent: userProtectionIntent,
                            externalRestartGeneration: latestExternalRestartGeneration) else { return false }
                        return ProtectionRestoreIntentStore.read(containerURL: containerURL)
                            .resolvedIntent(fallingBackTo: userProtectionIntent.isEnabled)
                    },
                    requiresActiveSession: true)
                chainedSettingsApplyError = continuationReadError ?? (vpnMessageIsError ? vpnMessage : nil)
                await sampleTunnelHealth()
                chainedSettingsApplyState.finish(ticket)
                protectionActionOrchestrator.release(.reconnect)
            }
        }
        #endif
    }
    //
    // ONE SETTER, WHERE THERE WERE THREE. This section held an enable toggle, a preset picker
    // coerced through `plainDNSVariant`, and a custom-IPv4 field that rejected every encrypted
    // form — plus the five `AppConfiguration` fields behind them.
    //
    // The two PICKERS are gone for good: they existed because the T1 rung rode the WireGuard
    // tunnel, which carries plain UDP :53 and nothing else, and PR #590 moved the rung to the
    // physical interface where all four transports work. The user's ONE resolver selection
    // (`setResolverPreset` and friends, above) IS T1, in both modes — chaining inserts T0 above
    // it rather than renumbering it (`docs/architecture/dns-tiers.md`, the plan's S4).
    //
    // The ENABLE toggle came back, because "may my DNS leave the tunnel" is a consent question
    // and it had no control. See `AppConfiguration.chainedTierOneFallbackEnabled`.

    /// Turns the chained T1 fallback on or off.
    ///
    /// Shaped exactly like `setChainedUpstreamEnabled` (AppViewModel+QATooling.swift, the section
    /// immediately before this one), including the rollback: a stored
    /// value that disagrees with the toggle on screen is the divergence that made
    /// `chaining-disabled` unreadable from the app side during S9, and this flag governs whether
    /// DNS may leave the tunnel — so a silent disagreement here is a privacy surface lying about
    /// its own state.
    ///
    /// The tunnel is told, because the rung is derived from the LATCHED configuration: without
    /// the reload the running session keeps the value it started with and the switch appears to
    /// do nothing until the next connect.
    /// pinned: ChainedUpstreamStagingWiringSourceTests.testTheFallbackToggleIsPersistedAndPushedToTheTunnel
    func setChainedTierOneFallbackEnabled(_ enabled: Bool) {
        guard configuration.chainedTierOneFallbackEnabled != enabled else { return }
        configuration.chainedTierOneFallbackEnabled = enabled
        do {
            try persistConfigurationOnly()
            requestChainedSettingsApply()
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            configuration.chainedTierOneFallbackEnabled = !enabled
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }
    }

    /// The editor submits only a new draft; existing keys never leave this store operation.
    func saveWireGuardHop(index: Int, name: String, conf: String?, expectedGeneration: UInt64?) -> Bool {
        guard !isStagingChainedUpstreamForQA, configuration.wireGuardSetupEnabled,
              ChainedSetupPolicy.canEditConfiguration(chainedSurfaceInputs(from: chainedUpstreamSurfaceStatus)) else {
            adminQAStatusMessage = "VPN chaining isn't available. Review its settings.".lavaLocalized
            return false
        }
        isStagingChainedUpstreamForQA = true
        defer { isStagingChainedUpstreamForQA = false; refreshDNSSettingsPresentation() }
        do {
            let store = try editableWireGuardStore()
            let replacement = try conf.map { try ChainedUpstreamStagingRequest(conf: $0,
                identity: LavaSecAppGroup.chainedUpstreamStoreIdentity,
                accessGroup: LavaSecAppGroup.chainedUpstreamKeychainAccessGroup ?? "").rotation }
            _ = try store.saveHop(index: index, name: name, replacement: replacement, expectedGeneration: expectedGeneration)
            clearChainedConfigurationStartIssue()
            if configuration.chainedUpstreamEnabled { requestChainedSettingsApply() }
            adminQAStatusMessage = nil
            return true
        } catch { adminQAStatusMessage = error.localizedDescription; return false }
    }

    func removeWireGuardHop(index: Int, expectedGeneration: UInt64) -> Bool {
        guard !isStagingChainedUpstreamForQA else { return false }
        defer { refreshDNSSettingsPresentation() }
        do {
            let store = try editableWireGuardStore()
            guard let record = try store.loadStoredConfigurationRecord(), record.generation == expectedGeneration,
                  record.configuration.orderedHops.indices.contains(index) else { throw WireGuardChainFailure.changed }
            if record.configuration.orderedHops.count == 1 {
                return clearStagedChainedUpstreamForQA(keepingConfiguration: false)
            }
            isStagingChainedUpstreamForQA = true
            defer { isStagingChainedUpstreamForQA = false }
            _ = try store.removeHop(index: index, expectedGeneration: expectedGeneration)
            clearChainedConfigurationStartIssue()
            if configuration.chainedUpstreamEnabled { requestChainedSettingsApply() }
            return true
        } catch { adminQAStatusMessage = error.localizedDescription; return false }
    }

    /// An explicit row switch is an immediate transaction; draft operations never call it.
    /// The existing commit/reconnect boundary preserves a stopped Guard's intent.
    func setWireGuardRowEnabled(_ value: Bool, index: Int, expectedGeneration: UInt64?) throws {
        let status = chainedUpstreamSurfaceStatus
        guard configuration.wireGuardSetupEnabled, status.storedConfigurationGeneration == expectedGeneration,
              status.storedConfigurationRows.indices.contains(index),
              ChainedSetupPolicy.canEditConfiguration(chainedSurfaceInputs(from: status)) else { throw WireGuardChainFailure.changed }
        let current = configuration.chainedUpstreamEnabled && status.storedConfigurationRows[index].isEnabled
        guard current != value else { return }
        var draft = try ChainedUpstreamEditDraft(id: "row-toggle", generation: expectedGeneration, configurations: status.storedConfigurationRows)
        if !configuration.chainedUpstreamEnabled {
            for row in draft.rows.indices { try draft.setEnabled(false, index: row) }
        }
        try draft.setEnabled(value, index: index)
        let enabled = draft.rows.contains { $0.configuration.isEnabled }
        try commitWireGuardPage(&draft, routingEnabled: enabled)
    }

    /// Page Save commits only profiles. Settings switches retain their independent setters.
    /// Sheet saves and row removals operate on ChainedUpstreamEditDraft instead.
    func commitWireGuardPage(_ draft: inout ChainedUpstreamEditDraft, routingEnabled: Bool? = nil) throws {
        guard draft.hasChanges || routingEnabled != nil else { return }
        // Read current switches at commit time: a profile edit never rolls back an
        // independently saved toggle, including an explicit OFF during editing.
        let setup = configuration.wireGuardSetupEnabled
        let enabled = routingEnabled ?? configuration.chainedUpstreamEnabled
        let fallback = configuration.chainedTierOneFallbackEnabled
        guard !isStagingChainedUpstreamForQA else { throw WireGuardChainFailure.changed }
        let status = chainedUpstreamSurfaceStatus
        guard status.storedConfigurationGeneration == draft.generation else { throw WireGuardChainFailure.changed }
        let wantsEnabled = setup && enabled && draft.rows.contains { $0.configuration.isEnabled }
        if wantsEnabled || (draft.hasChanges && !draft.rows.isEmpty) {
            guard ChainedSetupPolicy.canEditConfiguration(chainedSurfaceInputs(from: status)) else {
                throw ChainedConfigurationIssue.unavailable
            }
            if !draft.hasChanges, let issue = ChainedSetupPolicy.configurationIssue(chainedSurfaceInputs(from: status)) { throw issue }
        }
        isStagingChainedUpstreamForQA = true
        let oldEnabled = configuration.chainedUpstreamEnabled
        let oldFallback = configuration.chainedTierOneFallbackEnabled
        var profilesCommitted = false
        defer {
            isStagingChainedUpstreamForQA = false
            refreshDNSSettingsPresentation()
            if oldEnabled != configuration.chainedUpstreamEnabled
                || (configuration.chainedUpstreamEnabled && (profilesCommitted || oldFallback != configuration.chainedTierOneFallbackEnabled))
                || (profilesCommitted && draft.rows.isEmpty && tunnelHealth.isChainedUpstreamActive) {
                requestChainedSettingsApply()
            }
        }
        // Turning the final active row OFF is durable before changing the profile
        // selection, just like deletion. A failed preference write must not leave a
        // stored empty active stack behind an ON control-plane request.
        if !wantsEnabled && oldEnabled {
            configuration.chainedUpstreamEnabled = false
            do { try persistConfigurationOnly() }
            catch { configuration.chainedUpstreamEnabled = oldEnabled; throw error }
        }
        if draft.hasProfileChanges {
            let store = try editableWireGuardStore()
            if draft.rows.isEmpty {
                if draft.resetsStorage && status.storeUnavailableReason != nil { try store.removeAll() }
                else { try store.removeAll(expectedGeneration: draft.generation) }
                draft.didCommitProfiles(generation: nil, awaitingSettings: true)
            } else {
                let generation = try store.commitEdits(draft)
                draft.didCommitProfiles(generation: generation, awaitingSettings: true)
            }
            profilesCommitted = true
        }
        let beforeSettings = (configuration.wireGuardSetupEnabled, configuration.chainedUpstreamEnabled,
                              configuration.chainedTierOneFallbackEnabled)
        configuration.wireGuardSetupEnabled = setup
        configuration.chainedUpstreamEnabled = wantsEnabled
        configuration.chainedTierOneFallbackEnabled = fallback && !draft.containsFullTunnel
        if beforeSettings.0 != setup || beforeSettings.1 != wantsEnabled || beforeSettings.2 != configuration.chainedTierOneFallbackEnabled {
            do { try persistConfigurationOnly() }
            catch {
                configuration.wireGuardSetupEnabled = beforeSettings.0
                configuration.chainedUpstreamEnabled = beforeSettings.1
                configuration.chainedTierOneFallbackEnabled = beforeSettings.2
                throw error
            }
        }
        draft.didCommitSettings()
        clearChainedConfigurationStartIssue()
    }

    private func editableWireGuardStore() throws -> ChainedUpstreamKeychainStore {
        guard let container = LavaSecAppGroup.containerURL,
              let group = LavaSecAppGroup.chainedUpstreamKeychainAccessGroup else { throw WireGuardChainFailure.missingSecret }
        let identity = LavaSecAppGroup.chainedUpstreamStoreIdentity
        guard identity != .production else { throw ChainedUpstreamStagingRefusal.buildMayNotStage(identity) }
        guard ChainedUpstreamStoreIdentity.identity(forKeychainGroup: group) == identity else {
            throw ChainedUpstreamStagingRefusal.buildIdentityIsInconsistent(identity: identity, group: group)
        }
        return ChainedUpstreamKeychainStore(containerURL: container, identity: identity,
            keyItems: ChainedUpstreamKeychainKeyItemStore(accessGroup: group))
    }

    /// - Parameter enablesChaining: true for the explicit Admin QA staging action;
    ///   the user-facing editor passes false to preserve its separate routing choice.
    /// - Returns: whether the requested operation committed. With `enablesChaining`,
    ///   both storage and enablement must finish before the caller clears the draft.
    ///
    /// ASYNC because the enablement half is. `persistFilterChanges()` fires a task and
    /// swallows its failure asynchronously, so a synchronous version returned `true`,
    /// cleared the pasted private key, and said "chaining enabled" while the write was
    /// still in flight — and if it failed (a shared store unreadable at load, an app
    /// killed before the task ran) the flag stayed false, the next start logged
    /// `chaining-disabled`, and the operator had already lost the text they would need to
    /// try again (Codex, PR #519).
    @discardableResult
    func stageChainedUpstreamForQA(conf: String, enablesChaining: Bool = true) async -> Bool {
        // ONE AT A TIME, and the CHECK is the gate — the assignment alone was not one.
        // Setting the flag unconditionally made it a progress indicator: two Stage taps
        // queued before SwiftUI renders the disabled state both enter here, and whichever
        // finishes first runs its `defer` and re-enables the clear actions while the other
        // is still suspended in the enablement half — so a clear can delete the rotation
        // that second call has already committed, and it still reports success
        // (Codex, PR #519). Guarding here is also what makes the flag safe to read from the
        // view: `disabled(...)` is a hint the operator can outrun, never the enforcement.
        //
        // The check and the set are ONE critical section by `@MainActor` confinement —
        // there is no `await` between them, so no second call can observe `false` after the
        // first has passed the guard.
        guard !isStagingChainedUpstreamForQA else {
            adminQAStatusMessage = "Staging already in progress — wait for it to finish."
            return false
        }
        isStagingChainedUpstreamForQA = true
        var didCommitConfiguration = false
        defer {
            isStagingChainedUpstreamForQA = false
            if didCommitConfiguration { requestChainedSettingsApply() }
        }
        guard let containerURL = LavaSecAppGroup.containerURL,
            let group = LavaSecAppGroup.chainedUpstreamKeychainAccessGroup
        else {
            adminQAStatusMessage = "Staging unavailable: no app group or keychain access group."
            return false
        }
        do {
            let request = try ChainedUpstreamStagingRequest(
                conf: conf,
                identity: LavaSecAppGroup.chainedUpstreamStoreIdentity,
                accessGroup: group)
            let store = ChainedUpstreamKeychainStore(
                containerURL: containerURL,
                identity: request.identity,
                keyItems: ChainedUpstreamKeychainKeyItemStore(accessGroup: group))
            // The user-facing editor saves credentials without changing routing intent.
            // The explicit Admin QA staging action retains its historical enable request.
            if !enablesChaining {
                guard configuration.wireGuardSetupEnabled,
                    ChainedSetupPolicy.canEditConfiguration(chainedSurfaceInputs(from: chainedUpstreamSurfaceStatus)) else {
                    adminQAStatusMessage = "VPN chaining isn't available. Review its settings.".lavaLocalized
                    return false
                }
                _ = try store.commit(request.rotation)
                clearChainedConfigurationStartIssue()
                adminQAStatusMessage = "Configuration saved.".lavaLocalized
                didCommitConfiguration = configuration.chainedUpstreamEnabled
                return true
            }
            let generation = try store.commit(request.rotation)
            // Admin QA's explicit Stage action still means import AND enable. The
            // ordinary editor returned above after storage and never reaches this branch.
            // Only the secret half lives in the rotation store; setup and routing intent
            // are persisted together below through the normal configuration writer.
            let wasChainedEnabled = configuration.chainedUpstreamEnabled
            let wasSetupEnabled = configuration.wireGuardSetupEnabled
            configuration.wireGuardSetupEnabled = true
            configuration.chainedUpstreamEnabled = true
            do {
                // `rewritesRuleArtifacts: false` — this write changes ONE configuration
                // flag and no filter rule, so there are no artifacts to republish. It is
                // also what keeps the catch below honest: the default funnel writes the
                // configuration and THEN awaits the artifact publish, so an artifact
                // error would surface here with `chainedUpstreamEnabled` already durable,
                // and this handler would report "chaining stays off" about a device whose
                // next start reads it as ON (Codex, PR #519). Narrowing the write to the
                // half this method actually changes removes the divergence rather than
                // trying to describe it.
                try await persistSharedState(rewritesRuleArtifacts: false)
                await notifyTunnelSnapshotUpdated()
                // REVALIDATE ACROSS THE SUSPENSIONS. `@MainActor` stops these awaits running
                // CONCURRENTLY with anything else on the model, not from INTERLEAVING at
                // them — and `persistPaidPlanFlag(false)` is the interleaver that matters:
                // an entitlement lapse calls
                // `reconcileChainedUpstreamAfterEligibilityChange`, which clears and
                // persists this very flag in one write (INV-CHAIN-2 convergence). Staging
                // would then resume, report "chaining enabled", return `true`, and the
                // sheet would erase the only copy of the pasted configuration — while the
                // stored rotation cannot latch, because staging is the sole pre-Phase-4
                // producer of this flag and the QA "Set Paid" action does not restore it
                // (Codex, PR #519). Returning failure here is what keeps the pasted key.
                guard configuration.chainedUpstreamEnabled else {
                    adminQAStatusMessage =
                        "Upstream stored, but chaining was switched off while staging finished "
                        + "(entitlement lapse). Keep this text: restore Plus, then stage again "
                        + "to re-enable it."
                    return false
                }
            } catch {
                // ROLL THE IN-MEMORY FLAG BACK. `persistSharedState` can throw BEFORE it
                // writes (its `sharedStateUnavailableAtLoad` guard), leaving the true
                // value sitting in `configuration` for the next unrelated save to persist
                // — which would enable the already-stored upstream later, silently, after
                // this operation reported that chaining stays off (Codex, PR #519). The
                // message below is only honest if the state matches it.
                configuration.chainedUpstreamEnabled = wasChainedEnabled
                configuration.wireGuardSetupEnabled = wasSetupEnabled
                // WHAT THE FAILED WRITE ACTUALLY CHANGED depends on what was already on
                // disk, and the two cases have opposite outcomes.
                //
                // Already enabled — the ordinary REPLACE, staging a second upstream over a
                // first: the rotation above is durable, the stored flag is still true, and
                // the next start latches the new rotation. The operation succeeded; the
                // write that failed would have written the value already there. Reporting
                // "chaining stays off" and keeping the pasted key would send the operator
                // to retry something that is already done — while leaving a private key on
                // screen (Codex, PR #519).
                guard !wasChainedEnabled else {
                    // Mirrors the success copy deliberately, including its caveat: this
                    // branch had said the restart "latches this rotation", which is the
                    // unconditional claim the success path exists to refuse — latching
                    // additionally needs an IP-literal endpoint, a usable IPv4 resolver
                    // and Plus, none of which staging can judge (Kilo, PR #519).
                    adminQAStatusMessage =
                        "Stored \(request.rotation.configuration.endpointHost) "
                        + "(generation \(generation)). Chaining was already enabled on "
                        + "disk, so the flag write failed but had nothing to change"
                        + (configuration.hasLavaSecurityPlus
                            ? "" : " — NO PLUS, latch will refuse")
                        + ". An active Guard reconnects after settings settle; read data-path-latched."
                    didCommitConfiguration = true
                    return true
                }
                // Not previously enabled: the rotation IS stored and the flag is not, and
                // the two halves fail independently — an operator who reads "stored" and
                // restarts would otherwise meet `chaining-disabled` with no explanation.
                // Returning false keeps the pasted text for the retry.
                adminQAStatusMessage =
                    "Stored the upstream, but ENABLING FAILED (\(error)) — chaining stays "
                    + "off. Stage again once the shared store is writable."
                return false
            }
            // "STORED", never "will latch". Staging validates the FILE; latching additionally
            // requires what only the tunnel's readiness gate can judge — an IP-literal
            // endpoint (S1 has no hostname executor, so a hostname config can never latch)
            // and at least one usable IPv4 resolver. Those gates live in
            // LavaSecChainedUpstream, which this process must not link (it would pull the
            // engine into the app binary), and duplicating them here is the two-validators
            // drift this codebase refuses elsewhere. So the copy points at the authority
            // instead of guessing: `data-path-latched` carries the verdict, including
            // `upstream-not-ready-endpointNotYetResolvable` and `-noUsableTunnelDNS`.
            adminQAStatusMessage =
                "Stored \(request.rotation.configuration.endpointHost) "
                + "(generation \(generation)), chaining enabled"
                + (configuration.hasLavaSecurityPlus ? "" : " — NO PLUS, latch will refuse")
                + ". An active Guard reconnects after settings settle; read data-path-latched."
            didCommitConfiguration = true
            return true
        } catch let refusal as ChainedUpstreamStagingRefusal {
            adminQAStatusMessage = "Staging refused: \(refusal.logValue)"
        } catch {
            adminQAStatusMessage = "Staging failed: \(error)"
        }
        return false
    }

    /// Deletes the staged chained upstream so the device returns to a no-configuration state
    /// (S9; also the reader half of the migration simulation — deleting only the KEY leaves
    /// the config and reproduces what a restore to another device looks like to readiness).
    @discardableResult
    func clearStagedChainedUpstreamForQA(keepingConfiguration: Bool) -> Bool {
        // THE OTHER HALF OF THE SAME MUTEX. The clear buttons carry
        // `.disabled(isStagingChainedUpstreamForQA)`, but a view-level disable is a hint the
        // operator can outrun: taps queued before SwiftUI renders the new state still
        // arrive, and this one deletes a rotation a suspended staging call has already
        // committed. Enforcing it here — where the deletion happens — is what makes the
        // guard true rather than merely likely, the same reason staging checks the flag
        // instead of only writing it.
        guard !isStagingChainedUpstreamForQA else {
            adminQAStatusMessage = "Clear refused: a staging call is still in progress."
            return false
        }
        guard let containerURL = LavaSecAppGroup.containerURL,
            let group = LavaSecAppGroup.chainedUpstreamKeychainAccessGroup
        else {
            adminQAStatusMessage = "Clear unavailable: no app group or keychain access group."
            return false
        }
        let identity = LavaSecAppGroup.chainedUpstreamStoreIdentity
        // BOTH HALVES, exactly as staging validates them — this guard checked only the
        // identity and was the same defect one surface over (Codex, PR #519). In a build
        // flagged `-D LAVA_QA_TOOLS` outside the QA configuration the identity reads `.qa`
        // while the group is production, so the key-only delete would have enumerated and
        // removed every chained key in the PRODUCTION group while leaving the production
        // configuration file intact — manufacturing, on a real user's device, precisely
        // the half-rotation this feature's types exist to make unrepresentable.
        //
        // TWO REASONS, TWO MESSAGES. A plain Debug build addresses the production store
        // CONSISTENTLY — the fault there is that QA tooling may not touch it at all — and
        // telling that operator the halves disagree sends them looking for a build-setting
        // problem they do not have (Kilo, PR #519).
        guard identity != .production else {
            adminQAStatusMessage = "Clear refused: this build addresses the production store."
            return false
        }
        guard ChainedUpstreamStoreIdentity.identity(forKeychainGroup: group) == identity else {
            adminQAStatusMessage =
                "Clear refused: the build's identity and keychain group disagree."
            return false
        }
        let keyItems = ChainedUpstreamKeychainKeyItemStore(accessGroup: group)
        do {
            if keepingConfiguration {
                // KEY ONLY, through the key-item store rather than a new parameter on
                // `removeAll`: leaving the configuration behind is a QA-only shape, and
                // widening a security-critical store's API to express it would put a
                // half-rotation within reach of every caller — the exact state
                // `ChainedUpstreamRotation` exists to make unrepresentable. Here it is
                // deliberate: it reproduces, on one device, what a restore to ANOTHER
                // device looks like to readiness (config present, `ThisDeviceOnly` key
                // gone) so `noPrivateKeyStored` can be observed without a second device.
                var removed = 0
                for account in try keyItems.accounts()
                where ChainedUpstreamSecretNaming.generation(fromKeyAccount: account) != nil {
                    try keyItems.delete(account: account)
                    removed += 1
                }
                adminQAStatusMessage =
                    "Removed \(removed) key item(s), configuration kept (migration shape)."
            } else {
                let store = ChainedUpstreamKeychainStore(
                    containerURL: containerURL, identity: identity, keyItems: keyItems)
                // Disable durably BEFORE removing either credential half. If persistence
                // fails, delete nothing. If key cleanup fails after that, stay safely OFF
                // and keep the editor's retry available (INV-CHAIN-2, INV-CHAIN-4).
                let wasEnabled = configuration.chainedUpstreamEnabled
                configuration.chainedUpstreamEnabled = false
                do {
                    try persistConfigurationOnly()
                } catch {
                    configuration.chainedUpstreamEnabled = wasEnabled
                    throw error
                }
                clearChainedConfigurationStartIssue()
                if wasEnabled || tunnelHealth.isChainedUpstreamActive {
                    requestChainedSettingsApply()
                }
                try store.removeAll()
                adminQAStatusMessage = "Staged chained upstream cleared."
            }
            return true
        } catch {
            adminQAStatusMessage = "Clear failed: \(error)"
            return false
        }
    }

    func prepareQAInternetNetworkCondition(_ condition: QAInternetNetworkCondition) {
        configuration.qaProbeSet = .hosted
        adminQAStatusMessage = "\(condition.title): \(condition.expectedOutcome)"
        vpnMessageIsError = false
        persistFilterChanges()
    }

    func applyQAInternetDNSSetup(_ setup: QAInternetDNSSetup) {
        configuration.resolverPresetID = setup.resolverPresetID
        configuration.customResolverAddress = setup.customResolverAddress
        configuration.customResolverSecondaryAddress = nil
        configuration.customResolverName = setup.customResolverName
        configuration.fallbackToDeviceDNS = setup.fallbackToDeviceDNS
        configuration.usesEncryptedDeviceDNSFallback = setup.usesEncryptedDeviceDNSFallback
        configuration.fallbackResolverPresetID = setup.fallbackResolverPresetID
        configuration.fallbackCustomResolverAddress = setup.fallbackCustomResolverAddress
        configuration.fallbackCustomResolverSecondaryAddress = nil
        configuration.fallbackCustomResolverName = setup.fallbackCustomResolverName
        configuration.isPaid = configuration.isPaid || setup.resolverPresetID == DNSResolverPreset.customID
        adminQAStatusMessage = "\(setup.title) saved. Verify the active tunnel before recording a result."
        vpnMessageIsError = false
        persistResolverSettings(activity: .changeResolver)
    }

    func applyQAInternetBlocklistLoad(_ load: QAInternetBlocklistLoad) {
        configuration.enabledBlocklistIDs = load.enabledBlocklistIDs
        // Compile the new selection into blockRules before persisting: persistFilterChanges
        // serializes the in-memory blockRules, so without this the QA load would persist the
        // previous load's compiled rules/counts while the UI says the new load is active.
        rebuildEnabledBlockRules()
        adminQAStatusMessage = "\(load.title) selected. Downloads and compilation may still be running."
        vpnMessageIsError = false
        persistFilterChanges()
        startQAInternetBlocklistSyncIfNeeded(for: load.enabledBlocklistIDs)
    }

    func applyQAInternetScenarioSuite(_ suite: QAInternetScenarioSuite) {
        applyQAInternetScenario(suite.startingScenario)
    }

    func applyQAInternetScenario(_ scenario: QAInternetScenario) {
        configuration.qaProbeSet = .hosted
        // Set + compile the blocklist load before applying DNS so neither tunnel reload
        // (resolver-config reload from applyQAInternetDNSSetup, snapshot reload from
        // persistFilterChanges) fires against the previous blocklist set or stale blockRules.
        configuration.enabledBlocklistIDs = scenario.blocklistLoad.enabledBlocklistIDs
        rebuildEnabledBlockRules()
        applyQAInternetDNSSetup(scenario.dnsSetup)
        adminQAStatusMessage = "\(scenario.title) selected. Complete the guided check before recording a result."
        vpnMessageIsError = false
        persistFilterChanges()
        startQAInternetBlocklistSyncIfNeeded(for: scenario.blocklistLoad.enabledBlocklistIDs)
    }

    // Mirrors the catalog sync the normal enable paths kick (see
    // startOnboardingBlocklistSyncIfNeeded): the QA apply* methods only assign
    // enabledBlocklistIDs, so any selected source missing from the rule cache must be
    // downloaded for the load (e.g. Recommended/Large/Stress) to actually materialize.
    private func startQAInternetBlocklistSyncIfNeeded(for sourceIDs: Set<String>) {
        guard sourceIDs.contains(where: { cachedBlockRuleSets[$0] == nil }) else {
            return
        }

        Task {
            // A refresh already in flight (e.g. the launch sync) captured the previous
            // selection, so wait for it to finish before syncing — otherwise the newly
            // selected QA sources never download and the load persists with missing rules.
            // The controller installs its task synchronously before the transaction starts,
            // so this also catches a queued refresh that has not reached the hub yet.
            if catalog.isSyncInFlight {
                await catalog.awaitCompletion()
            }
            // Gate on the CURRENT selection, not the captured sourceIDs, so a QA load superseded
            // mid-sync by an already-cached one does not fire a redundant refresh. Mirrors
            // startOnboardingBlocklistSyncIfNeeded. (Codex P2 on #539.)
            guard configuration.enabledBlocklistIDs.contains(where: { cachedBlockRuleSets[$0] == nil }) else {
                return
            }
            await self.syncCatalog()
        }
    }

    func applyAdminQAAction(_ action: AdminQAAction) {
        switch action {
        case .showWelcome:
            adminQAStatusMessage = "Welcome screen requested."
        case .showUserBugReport:
            adminQAStatusMessage = "Normal user bug report requested."
        case .applyHostedProbes:
            applyHostedQAProbeSet()
            adminQAStatusMessage = "Hosted probes are active."
        case .testDefaultAllow:
            configuration.qaProbeSet = .hosted
            adminQAStatusMessage = "Default allow check ready: \(QADomainProbeSet.hosted.allowedDomain) should load."
            persistFilterChanges()
        case .testAllowlist:
            configuration.qaProbeSet = .hosted
            adminQAStatusMessage = "Allow list check ready: \(QADomainProbeSet.hosted.exceptionDomain) should load."
            persistFilterChanges()
        case .testDenylist:
            configuration.qaProbeSet = .hosted
            adminQAStatusMessage = "Deny list check ready: \(QADomainProbeSet.hosted.blockedDomain) should be blocked."
            persistFilterChanges()
        case .testThreatGuardrail:
            configuration.qaProbeSet = .hosted
            adminQAStatusMessage = "Threat guardrail check ready: \(QADomainProbeSet.hosted.guardrailDomain) should stay blocked even as an exception."
            persistFilterChanges()
        case .setGoogleDNS:
            setResolver(.google)
            adminQAStatusMessage = "Google DNS is active."
        case .setCloudflareDoH:
            setResolver(.cloudflareDoH)
            adminQAStatusMessage = "Cloudflare DoH is active."
        case .setCloudflareDoT:
            setResolver(.cloudflareDoT)
            adminQAStatusMessage = "Cloudflare DoT is active."
        case .enableLocalDomainHistory:
            reports.setKeepDomainDiagnostics(true, clearHistory: false)
            adminQAStatusMessage = "Local domain history is enabled."
        case .disableLocalDomainHistory:
            reports.setKeepDomainDiagnostics(false)
            adminQAStatusMessage = "Local domain history is disabled and cleared."
        case .clearLocalActivity:
            reports.clearDiagnostics()
            adminQAStatusMessage = "Local activity rows cleared."
        case .setPaidPlan:
            setQAPlanMode(isPaid: true)
        case .setFreePlan:
            setQAPlanMode(isPaid: false)
        case .clearQAState:
            configuration.qaProbeSet = nil
            configuration.isPaid = false
            configuration.resolverPresetID = DNSResolverPreset.google.id
            configuration.keepDomainDiagnostics = false
            reports.clearDiagnostics()
            adminQAStatusMessage = "QA state cleared."
            persistFilterChanges()
        }

        vpnMessageIsError = false
    }

    func applyAdminQAVPNProfileAction(_ action: AdminQAVPNProfileAction) async {
        guard protectionActionOrchestrator.claim(.adminQAProfile) else {
            adminQAStatusMessage = "Finish the current VPN profile action first."
            return
        }

        defer {
            protectionActionOrchestrator.release(.adminQAProfile)
        }

        do {
            // The internal device controls can run while a production Live Activity exposes
            // Restart. Fence each WHOLE profile action: install's save/create, remove's stop/delete,
            // and reset's delete/recreate must not interleave with Restart's stop/start. The shared
            // helper retries with nonblocking probes, so this never blocks the MainActor on flock.
            try await LavaProtectionCommandService.withExclusiveProtectionLifecycleMutation {
                switch action {
                case .installProfile:
                    await self.installAdminQAVPNProfile()
                case .removeProfile:
                    await self.removeAdminQAVPNProfile()
                case .resetProfile:
                    await self.resetAdminQAVPNProfile()
                }
            }
        } catch {
            let prefix: String
            switch action {
            case .installProfile:
                adminQAStatusMessage = "Could not install VPN profile."
                prefix = "Could not install VPN profile"
            case .removeProfile:
                adminQAStatusMessage = "Could not remove VPN profile."
                prefix = "Could not remove VPN profile"
            case .resetProfile:
                adminQAStatusMessage = "Could not reset VPN profile."
                prefix = "Could not reset VPN profile"
            }
            vpnMessage = Self.vpnErrorMessage(prefix: prefix, error: error)
            vpnMessageIsError = true
        }
    }

    private func installAdminQAVPNProfile() async {

        #if targetEnvironment(simulator)
        adminQAStatusMessage = "VPN profile testing requires a physical device."
        vpnMessage = "Use a physical device to install the VPN profile."
        vpnMessageIsError = false
        #else
        adminQAStatusMessage = "Installing VPN profile..."
        vpnMessage = "Preparing VPN profile..."
        vpnMessageIsError = false

        do {
            try await persistSharedState()

            let existingManager = try await loadExistingTunnelManager()
            if existingManager == nil {
                vpnMessage = Self.vpnPermissionPromptMessage
                vpnMessageIsError = false
            }

            let manager = try await loadOrCreateTunnelManager(existingManager: existingManager)
            tunnelManager = manager
            updateProtectionStatus(from: manager)
            lastProtectionStatusRefresh = Date()

            adminQAStatusMessage = "VPN profile installed."
            vpnMessage = nil
            vpnMessageIsError = false
        } catch {
            adminQAStatusMessage = "Could not install VPN profile."
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not install VPN profile", error: error)
            vpnMessageIsError = true
        }
        #endif
    }

    private func removeAdminQAVPNProfile() async {

        #if targetEnvironment(simulator)
        adminQAStatusMessage = "VPN profile testing requires a physical device."
        vpnMessage = "Use a physical device to remove the VPN profile."
        vpnMessageIsError = false
        #else
        adminQAStatusMessage = "Removing VPN profile..."
        vpnMessage = "Removing VPN profile..."
        vpnMessageIsError = false

        do {
            let managers = try await matchingTunnelManagers()
            guard !managers.isEmpty else {
                tunnelManager = nil
                updateProtectionStatus(from: nil)
                lastProtectionStatusRefresh = Date()
                adminQAStatusMessage = "No VPN profile to remove."
                vpnMessage = nil
                vpnMessageIsError = false
                return
            }

            for manager in managers {
                manager.connection.stopVPNTunnel()
                try await vpnLifecycleController.removeManager(manager)
            }

            tunnelManager = nil
            updateProtectionStatus(from: nil)
            lastProtectionStatusRefresh = Date()
            adminQAStatusMessage = "VPN profile removed."
            vpnMessage = nil
            vpnMessageIsError = false
        } catch {
            adminQAStatusMessage = "Could not remove VPN profile."
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not remove VPN profile", error: error)
            vpnMessageIsError = true
        }
        #endif
    }

    private func resetAdminQAVPNProfile() async {

        #if targetEnvironment(simulator)
        adminQAStatusMessage = "VPN profile testing requires a physical device."
        vpnMessage = "Use a physical device to reset the VPN profile."
        vpnMessageIsError = false
        #else
        adminQAStatusMessage = "Resetting VPN profile..."
        vpnMessage = "Resetting VPN profile..."
        vpnMessageIsError = false

        do {
            let managers = try await matchingTunnelManagers()
            for manager in managers {
                manager.connection.stopVPNTunnel()
                try await vpnLifecycleController.removeManager(manager)
            }

            tunnelManager = nil
            updateProtectionStatus(from: nil)
            try await persistSharedState()

            let manager = try await loadOrCreateTunnelManager(existingManager: nil)
            tunnelManager = manager
            updateProtectionStatus(from: manager)
            lastProtectionStatusRefresh = Date()

            adminQAStatusMessage = "VPN profile reset."
            vpnMessage = nil
            vpnMessageIsError = false
        } catch {
            adminQAStatusMessage = "Could not reset VPN profile."
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not reset VPN profile", error: error)
            vpnMessageIsError = true
        }
        #endif
    }

    #endif
}
