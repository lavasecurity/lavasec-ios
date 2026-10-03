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
    /// Explicit external controls enter the same action gate and lifecycle primitives as Guard.
    /// The caller must satisfy Lava's existing authentication before invoking this entry point.
    func performProtectionShortcut(enabled: Bool) async throws -> String {
        do {
            try await ProtectionShortcutCoordinator.perform(enabled: enabled,
                gate: protectionActionOrchestrator,
                authorize: { true }, // The caller already satisfied the existing Lava gates.
                readState: {
                    let manager = try await LavaProtectionStatusReader.loadManager()
                    if enabled, manager == nil || manager?.connection.status == .invalid {
                        throw LavaShortcutFailure("Open Lava to complete setup.")
                    }
                    var paused = false
                    if enabled, manager?.connection.status == .connected {
                        let observation = await LavaProtectionStatusReader.read()
                        if case .paused = observation { paused = true }
                        if observation == .unavailable { throw LavaShortcutFailure("Status unavailable") }
                    }
                    return (manager?.connection.status.protectionLifecycleStatus ?? .invalid, paused)
                },
                accept: {
                    // Acceptance is after cancellation/state checks, before any lifecycle refresh.
                    // The durable write shares the cross-process fence with all protection writers.
                    try await LavaProtectionCommandService.withExclusiveProtectionLifecycleMutation {
                        try Task.checkCancellation()
                        try self.persistExplicitProtectionIntent(isEnabled: enabled)
                        self.userProtectionIntent.recordUserIntent(isEnabled: enabled)
                    }
                },
                connect: {
                    let completed = await self.enableProtection(persistsExplicitIntent: true)
                    try ProtectionShortcutCoordinator.validateStartResult(
                        completed: completed, hasError: self.vpnMessageIsError)
                },
                resume: {
                    try await LavaProtectionCommandService.perform(.resume)
                    self.loadTemporaryProtectionPause()
                    self.reconcileLiveActivity()
                },
                disconnect: {
                    await self.disableProtection(persistsExplicitIntent: true)
                    if self.vpnMessageIsError {
                        throw LavaShortcutFailure(self.vpnMessage ?? "Could not stop protection")
                    }
                })
        } catch ProtectionShortcutError.busy {
            throw LavaShortcutFailure("Lava is busy. Try again.")
        } catch ProtectionShortcutError.authenticationRequired {
            throw LavaShortcutFailure("Open Lava to authenticate.")
        } catch ProtectionShortcutError.startFailed {
            throw LavaShortcutFailure(vpnMessage ?? "Could not start protection")
        }
        return (await LavaProtectionStatusReader.read()).title.lavaLocalized
    }

    // MARK: - Protection toggle & VPN lifecycle

    @discardableResult
    func enableProtection(
        logUserAction: Bool = true,
        playsOutcomeHaptic: Bool = true,
        persistsExplicitIntent: Bool = false,
        operationID: LatencyOperationID = .make(),
        continueIfLifecycleLeaseOwned: (@MainActor () -> Bool)? = nil,
        lifecycleMutationFenceIsOwned: Bool = false
    ) async -> Bool {
        // Ordinary app actions and direct App Intent restart have independent in-process
        // coordinators, so the shared kernel fence is their only common exclusion boundary. Take
        // it before publishing action UI or touching NetworkExtension. Automatic restore keeps its
        // renewable logical lease + per-callback fence so long filter preparation does not hold the
        // kernel lock; a whole reconnect/descendant passes ownership explicitly to avoid re-locking
        // the same flock from this process.
        if continueIfLifecycleLeaseOwned == nil, !lifecycleMutationFenceIsOwned {
            do {
                return try await LavaProtectionCommandService
                    .withExclusiveProtectionLifecycleMutation {
                        await self.enableProtection(
                            logUserAction: logUserAction,
                            playsOutcomeHaptic: playsOutcomeHaptic,
                            persistsExplicitIntent: persistsExplicitIntent,
                            operationID: operationID,
                            lifecycleMutationFenceIsOwned: true
                        )
                    }
            } catch {
                // This is an ordinary foreground action (automatic restore never enters this
                // wrapper). A coordination/open/protection-class failure after explicit ON intent
                // must be visible; returning false alone is ignored by the toggle task and would
                // leave intent ON with a running action that appeared to do nothing.
                vpnMessage = Self.vpnErrorMessage(
                    prefix: "Could not start protection".lavaLocalized,
                    error: error
                )
                vpnMessageIsError = true
                if playsOutcomeHaptic {
                    playProtectionStartFailedHaptic()
                }
                return false
            }
        }

        func shouldContinueProtectionLifecycle() -> Bool {
            continueIfLifecycleLeaseOwned?() ?? true
        }

        func performWhileProtectionLifecycleOwned(
            _ operation: @escaping @MainActor () async throws -> Void
        ) async throws {
            if lifecycleMutationFenceIsOwned {
                try await operation()
                return
            }
            guard continueIfLifecycleLeaseOwned != nil else {
                try await operation()
                return
            }
            try await LavaProtectionCommandService.withProtectionLifecyclePreferenceMutation(
                validateOwnership: shouldContinueProtectionLifecycle,
                operation: operation
            )
        }

        guard shouldContinueProtectionLifecycle() else {
            return false
        }
        #if DEBUG || LAVA_QA_TOOLS
        guard validateChainedConfigurationForStart() else { return false }
        #endif
        if persistsExplicitIntent {
            // The user action synchronously advanced the in-memory revision before its Task
            // began. Commit the matching durable direction only after the shared lifecycle fence
            // is owned and before clearing surrender, persisting snapshots, or touching the VPN
            // manager; a failed barrier must not start or tear down any lifecycle state.
            do {
                try persistExplicitProtectionIntent(isEnabled: true)
            } catch {
                vpnMessage = Self.vpnErrorMessage(
                    prefix: "Could not start protection".lavaLocalized,
                    error: error
                )
                vpnMessageIsError = true
                if playsOutcomeHaptic {
                    playProtectionStartFailedHaptic()
                }
                return false
            }
        }
        if logUserAction {
            // The explicit toggle is a clean recovery boundary. Automatic restore/reconnect
            // callers pass `logUserAction: false` and cannot erase crash-loop evidence.
            do {
                try prepareChainedStateForExplicitGuardStart()
            } catch {
                vpnMessage = Self.vpnErrorMessage(
                    prefix: "Could not start protection".lavaLocalized,
                    error: error
                )
                vpnMessageIsError = true
                if playsOutcomeHaptic {
                    playProtectionStartFailedHaptic()
                }
                return false
            }
        }
        let trace = makeLatencyTrace(operationID: operationID, operationKind: "turnOn")
        let span = trace.beginSpan("action.turnOn", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus),
            "catalogVersion": catalogVersion ?? "nil",
            "compiledRuleCount": "\(compiledRuleCount)"
        ])
        var actionStatus = "started"
        func abortSupersededProtectionLifecycle() -> Bool {
            actionStatus = "superseded"
            return false
        }
        defer {
            span.end(details: ["status": actionStatus, "vpnStatus": vpnStatusDebugDescription(vpnStatus)])
        }

        #if DEBUG
        logVPNDebugEvent("enable-begin", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus),
            "catalogVersion": catalogVersion ?? "nil",
            "compiledRuleCount": "\(compiledRuleCount)"
        ])
        #endif

        vpnMessage = "Preparing local protection..."
        vpnMessageIsError = false
        if playsOutcomeHaptic {
            awaitsProtectionOnHaptic = true
        } else {
            awaitsProtectionOnHaptic = false
        }

        do {
            // Cache-first turn-on: when a confirmed-reusable prepared artifact
            // exists for the *current* configuration, the VPN can come up
            // immediately from cache while any in-flight catalog sync keeps
            // refreshing in the background — performCatalogSyncTransaction reconciles the
            // running tunnel on completion (notifyTunnelSnapshotUpdated +
            // restoreProtectionIfNeeded, which single-flights against this
            // turn-on). We only block on the sync when there is nothing valid
            // to start from, e.g. the user just changed the enabled-list set,
            // which invalidates the cached artifact's identity.
            if catalog.isSyncInFlight {
                if await hasReusableArtifactForCurrentConfiguration() {
                    #if DEBUG
                    logVPNDebugEvent("enable-cache-first-skip-sync-wait")
                    #endif
                } else {
                    #if DEBUG
                    logVPNDebugEvent("enable-waiting-for-catalog-sync")
                    #endif

                    vpnMessage = "Finishing filter update..."
                    await catalog.awaitCompletion()
                }
            }

            guard shouldContinueProtectionLifecycle() else {
                return abortSupersededProtectionLifecycle()
            }
            let prepareSpan = trace.beginSpan("turnOn.prepareSnapshot", parent: span)
            let startup = try await preparedSnapshotForProtectionStartup(trace: trace, parentSpan: prepareSpan)
            guard shouldContinueProtectionLifecycle() else {
                prepareSpan.end(details: ["status": "superseded"])
                return abortSupersededProtectionLifecycle()
            }
            let preparedSnapshot = startup.preparedSnapshot
            prepareSpan.end(details: [
                "reusedPersistedArtifacts": "\(startup.reusedPersistedArtifacts)"
            ])

            let persistSpan = trace.beginSpan("turnOn.persistArtifacts", parent: span)
            try await persistSharedState(
                preparedSnapshot: preparedSnapshot,
                rewritesRuleArtifacts: !startup.reusedPersistedArtifacts
            )
            guard shouldContinueProtectionLifecycle() else {
                persistSpan.end(details: ["status": "superseded"])
                return abortSupersededProtectionLifecycle()
            }
            persistSpan.end(details: [
                "rewroteRuleArtifacts": "\(!startup.reusedPersistedArtifacts)"
            ])
            #if DEBUG
            logVPNDebugEvent("enable-persisted-shared-state", details: [
                "compiledRuleCount": "\(compiledRuleCount)",
                "catalogVersion": catalogVersion ?? "nil",
                "fingerprint": preparedSnapshot.identity.fingerprint
            ])
            #endif

            let managerSpan = trace.beginSpan("turnOn.managerSetup", parent: span)
            let existingManager = try await loadExistingTunnelManager()
            guard shouldContinueProtectionLifecycle() else {
                managerSpan.end(details: ["status": "superseded"])
                return abortSupersededProtectionLifecycle()
            }
            #if DEBUG
            logVPNDebugEvent("enable-loaded-existing-manager", details: tunnelManagerDebugDetails(existingManager))
            #endif

            if existingManager == nil {
                vpnMessage = Self.vpnPermissionPromptMessage
                vpnMessageIsError = false
            }

            var manager = try await loadOrCreateTunnelManager(
                existingManager: existingManager,
                continueIfLifecycleLeaseOwned: shouldContinueProtectionLifecycle,
                performPreferenceMutation: performWhileProtectionLifecycleOwned
            )
            guard shouldContinueProtectionLifecycle() else {
                managerSpan.end(details: ["status": "superseded"])
                return abortSupersededProtectionLifecycle()
            }
            managerSpan.end(details: ["hadExistingManager": "\(existingManager != nil)"])
            tunnelManager = manager
            updateProtectionStatus(from: manager)

            if manager.connection.status == .disconnecting {
                vpnMessage = "Waiting for iOS to finish stopping the local VPN..."
                vpnMessageIsError = false
                let didStop = await waitForProtectionToStop(timeout: Self.protectionRestartStopWaitTimeout)
                guard shouldContinueProtectionLifecycle() else {
                    return abortSupersededProtectionLifecycle()
                }
                guard didStop else {
                    throw LavaSecAppError.vpnStillStopping
                }
                let refreshedManager = try await loadExistingTunnelManager()
                guard shouldContinueProtectionLifecycle() else {
                    return abortSupersededProtectionLifecycle()
                }
                if let refreshedManager {
                    manager = refreshedManager
                } else {
                    manager = try await loadOrCreateTunnelManager(
                        continueIfLifecycleLeaseOwned: shouldContinueProtectionLifecycle,
                        performPreferenceMutation: performWhileProtectionLifecycleOwned
                    )
                    guard shouldContinueProtectionLifecycle() else {
                        return abortSupersededProtectionLifecycle()
                    }
                }
                tunnelManager = manager
                updateProtectionStatus(from: manager)
            }

            if manager.connection.status != .connected && manager.connection.status != .connecting {
                guard shouldContinueProtectionLifecycle() else {
                    return abortSupersededProtectionLifecycle()
                }
                #if DEBUG
                logVPNDebugEvent("enable-start-vpn-request", details: tunnelManagerDebugDetails(manager))
                #endif

                // Mint the app-side session only at the final owned boundary. Everything before
                // this point may suspend; after this synchronous write the start request follows
                // immediately, so a superseded preparation cannot strand a never-started session.
                try await performWhileProtectionLifecycleOwned {
                    self.beginFreshProtectionVPNSession()
                    try manager.connection.startVPNTunnel(options: [
                        LavaSecAppGroup.latencyOperationIDOptionKeyName: operationID.rawValue as NSString
                    ])
                }
                if logUserAction {
                    appendAppNetworkActivity(.turnProtectionOn)
                }

                #if DEBUG
                logVPNDebugEvent("enable-start-vpn-returned", details: tunnelManagerDebugDetails(manager))
                #endif
            } else if logUserAction {
                appendAppNetworkActivity(.turnProtectionOn)
            }

            updateProtectionStatus(from: manager)
            lastProtectionStatusRefresh = Date()
            if vpnStatus != .connected {
                vpnMessage = "Waiting for iOS to finish starting the local VPN..."
                vpnMessageIsError = false
                let statusWaitSpan = trace.beginSpan("turnOn.statusWait", parent: span)
                let didConnect = await waitForProtectionToConnect(timeout: Self.protectionStartWaitTimeout)
                guard shouldContinueProtectionLifecycle() else {
                    statusWaitSpan.end(details: ["status": "superseded"])
                    return abortSupersededProtectionLifecycle()
                }
                guard didConnect else {
                    statusWaitSpan.end(details: ["status": "timeout"])
                    // If the start timed out but Connect-On-Demand is armed (e.g. no network yet), keep
                    // the enabled hint true — iOS will connect when the path returns. Deriving it from
                    // vpnStatus alone would persist false and suppress the self-reconnect (mirrors the
                    // updateProtectionStatus derivation).
                    configuration.protectionEnabled = isProtectionEnabledStatus(vpnStatus) || isAwaitingOnDemandReconnect
                    // Rule artifacts were already persisted (or validly reused)
                    // above; only the configuration state changed here.
                    _ = try? await persistSharedState(preparedSnapshot: preparedSnapshot, rewritesRuleArtifacts: false)
                    guard shouldContinueProtectionLifecycle() else {
                        return abortSupersededProtectionLifecycle()
                    }
                    #if DEBUG || LAVA_QA_TOOLS
                    logVPNDebugEvent("enable-start-wait-timeout", details: [
                        "vpnStatus": vpnStatusDebugDescription(vpnStatus)
                    ])
                    #endif
                    actionStatus = "timeout"
                    return true
                }
                statusWaitSpan.end(details: ["status": "connected"])

                let refreshedManager = try await loadExistingTunnelManager()
                guard shouldContinueProtectionLifecycle() else {
                    return abortSupersededProtectionLifecycle()
                }
                if let refreshedManager {
                    manager = refreshedManager
                    tunnelManager = manager
                    updateProtectionStatus(from: manager)
                }
            }

            guard shouldContinueProtectionLifecycle() else {
                return abortSupersededProtectionLifecycle()
            }
            configuration.protectionEnabled = true
            // Notification authorization is requested only at the onboarding
            // notifications step (requestProtectionNotificationAuthorizationForOnboarding)
            // and, contextually, the first time a protection notification is
            // actually delivered. Enabling/restoring protection must NOT prompt
            // for notifications as a side effect — doing so surfaced the system
            // dialog at the wrong moment (e.g. during onboarding before the
            // notifications step, or on auto-restore at launch).
            _ = try? await persistSharedState(preparedSnapshot: preparedSnapshot, rewritesRuleArtifacts: false)
            guard shouldContinueProtectionLifecycle() else {
                return abortSupersededProtectionLifecycle()
            }
            vpnMessage = nil
            vpnMessageIsError = false
            scheduleBackgroundCustomBlocklistRefresh()

            #if DEBUG
            logVPNDebugEvent("enable-finished", details: tunnelManagerDebugDetails(manager))
            #endif
            actionStatus = "connected"
            return true
        } catch is ProtectionLifecycleMutationFenceError {
            // A direct restart owns the non-cancellable mutation boundary, or this automatic
            // owner expired while its callback was suspended. Retain any freshly minted session
            // for the successor and abort without publishing a stale error/disabled state.
            return abortSupersededProtectionLifecycle()
        } catch {
            guard shouldContinueProtectionLifecycle() else {
                return abortSupersededProtectionLifecycle()
            }
            actionStatus = "error"
            endProtectionVPNSession()
            configuration.protectionEnabled = false
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not start protection".lavaLocalized, error: error)
            vpnMessageIsError = true
            await refreshProtectionStatus(force: true)
            if playsOutcomeHaptic {
                playProtectionStartFailedHaptic()
            }

            #if DEBUG
            logVPNDebugEvent("enable-error", details: errorDebugDetails(error))
            #endif
            return true
        }
    }

    func disableProtection(operationID: LatencyOperationID = .make(),
                                   outcomeHaptic: ProtectionHapticFeedback = .protectionTurnedOff,
                                   completionMessage: String? = nil,
                                   completionMessageIsError: Bool = false,
                                   persistsExplicitIntent: Bool = false,
                                   lifecycleMutationFenceIsOwned: Bool = false) async {
        if !lifecycleMutationFenceIsOwned {
            // Close reducer sampling and every producer of delayed Connect-On-Demand work before
            // competing for the process-wide mutation fence. An arm callback may already own that
            // fence while its non-cancellable save is suspended; draining first lets it finish,
            // while the teardown edge prevents a replacement arm from appearing during the wait.
            beginProtectionTeardown()
            defer { endProtectionTeardown() }
            await drainChainedOnDemandArm()
            do {
                try await LavaProtectionCommandService.withExclusiveProtectionLifecycleMutation {
                    await self.disableProtection(
                        operationID: operationID,
                        outcomeHaptic: outcomeHaptic,
                        completionMessage: completionMessage,
                        completionMessageIsError: completionMessageIsError,
                        persistsExplicitIntent: persistsExplicitIntent,
                        lifecycleMutationFenceIsOwned: true
                    )
                }
            } catch {
                // Cancellation or coordination/storage failure is the only way the asynchronous
                // handoff can fail. Never fall back to an unfenced teardown or report success.
                vpnMessage = Self.vpnErrorMessage(
                    prefix: "Could not stop protection".lavaLocalized,
                    error: error
                )
                vpnMessageIsError = true
            }
            return
        }

        let trace = makeLatencyTrace(operationID: operationID, operationKind: "turnOff")
        let span = trace.beginSpan("action.turnOff", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus)
        ])
        var actionStatus = "started"
        defer {
            span.end(details: ["status": actionStatus, "vpnStatus": vpnStatusDebugDescription(vpnStatus)])
        }

        vpnMessage = "Stopping local protection..."
        vpnMessageIsError = false

        // Set when the normal stop did not complete and we had to delete the VPN
        // profile to restore connectivity (see forceRemoveStuckProtectionProfile).
        var stoppedViaProfileRemoval = false

        do {
            if persistsExplicitIntent {
                // The user action synchronously advanced the in-memory revision before its Task
                // began. The durable OFF is the first lifecycle operation once this shared fence
                // is owned: a persistence failure throws into the visible error path below and
                // prevents every session/on-demand/profile/stop side effect that follows.
                try persistExplicitProtectionIntent(isEnabled: false)
                if let markerURL = LavaSecAppGroup.chainedStartupFailureMarkerURL {
                    do {
                        _ = try ChainedStartupFailureMarker.beginExplicitRetry(
                            storageURL: markerURL,
                            lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL)
                    } catch {
                        logVPNDebugEvent(
                            "chained-explicit-stop-marker-advance-failed",
                            details: errorIdentityDetails(error))
                    }
                } else {
                    logVPNDebugEvent("chained-explicit-stop-marker-url-missing")
                }
            }
            let manager: NETunnelProviderManager?
            if let tunnelManager {
                manager = tunnelManager
            } else {
                manager = try await loadExistingTunnelManager()
            }

            if manager != nil {
                endProtectionVPNSession()
            }

            // Disable Connect-On-Demand and persist it before stopping, or iOS
            // would immediately reconnect the tunnel and the user could not turn
            // protection off. A failed disable is exactly what wedges turn-off,
            // so retry briefly (disableOnDemandWithRetry) rather than swallowing
            // the first error; a persistent failure still falls through to the
            // stop, backstopped by forceRemoveStuckProtectionProfile().
            // Capture whether on-demand actually got disabled: a persistent failure means the SAVED
            // profile is still armed, so iOS will reconnect the tunnel even from a stopped/disconnected
            // state — the force-remove backstop below must run in that case too, not only when the
            // tunnel is stuck running (see the reconnecting turn-off path below).
            // CANCELLED **AND AWAITED**, before the disable. Cancellation alone does not stop it:
            // `setManagerOnDemand` wraps `saveToPreferences` in `withCheckedThrowingContinuation`,
            // a callback API that no more observes `Task.isCancelled` than it can be interrupted —
            // and it records the confirmed-armed bit unconditionally once that continuation
            // resumes. So a task already past its final guard completes regardless, and without
            // awaiting it here its save can land AFTER the disable and re-arm the profile the user
            // just turned off (Codex P1 twice, Kilo once, PR #594).
            //
            // Awaiting is bounded by that one save and cannot deadlock: the task never re-enters
            // `disableProtection`, and it is `Task<Void, Never>` so `value` cannot throw.
            //
            // SHARED WITH THE RECONNECT PATH, which had the identical hole: see
            // ``drainChainedOnDemandArm()``.
            //
            await drainChainedOnDemandArm()
            var onDemandDisabled = true
            if let manager {
                onDemandDisabled = await disableOnDemandWithRetry(on: manager, clearsStrictRouting: persistsExplicitIntent)
            }

            manager?.connection.stopVPNTunnel()
            updateProtectionStatus(from: manager)
            if manager == nil {
                endProtectionVPNSession()
                tunnelManager = nil
                vpnStatus = .disconnected
            } else {
                // Force-remove when EITHER on-demand could not be disabled OR the tunnel never reached
                // a stopped state. The `!onDemandDisabled` arm is load-bearing for the reconnecting
                // turn-off (an armed-but-dropped tunnel routed here via toggleProtection): the manager
                // is already `.disconnected`, so `waitForProtectionToStop()` returns true immediately
                // and would skip this backstop — yet the still-armed profile means iOS re-arms the
                // tunnel and the user can't actually turn protection off. The usual stuck-RUNNING cause
                // is the same best-effort-disable failure leaving a dead tunnel with no working internet
                // and no in-app way out (UR-31/UR-32: "couldn't connect to the internet and Lava
                // wouldn't turn off either"). Last resort either way: delete the VPN profile so its
                // on-demand rules go away and connectivity is restored. The profile (and the system VPN
                // permission prompt) is recreated next time protection is enabled.
                //
                // Branch explicitly rather than `!onDemandDisabled || await …` — `await` may not sit in
                // the RHS autoclosure of `||` — and this also preserves the short-circuit: when the
                // disable already failed we go straight to force-remove without waiting for a clean stop
                // that the still-armed profile won't allow anyway.
                var mustForceRemoveProfile = !onDemandDisabled
                if !mustForceRemoveProfile {
                    mustForceRemoveProfile = await waitForProtectionToStop() == false
                }
                if mustForceRemoveProfile {
                    guard await forceRemoveStuckProtectionProfile() else {
                        throw LavaSecAppError.vpnStillStopping
                    }
                    stoppedViaProfileRemoval = true
                }
            }
            lastProtectionStatusRefresh = Date()
            configuration.protectionEnabled = false
            appendAppNetworkActivity(.turnProtectionOff)
            // A caller may override the outcome (the chained-establishment failure turns OFF but wants
            // the failure haptic + "couldn't establish" message, not the neutral turned-off pair). The
            // failure message wins over the force-stopped notice — it is the more relevant reason.
            vpnMessage = completionMessage
                ?? (stoppedViaProfileRemoval ? Self.protectionForceStoppedMessage : nil)
            vpnMessageIsError = completionMessageIsError
            awaitsProtectionOnHaptic = false
            ProtectionHapticFeedback.play(outcomeHaptic)
            actionStatus = "stopped"
            #if DEBUG || LAVA_QA_TOOLS
            if persistsExplicitIntent {
                await logQAVPNProfileAudit(reason: "explicit-off")
            }
            #endif
        } catch {
            actionStatus = "error"
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not stop protection".lavaLocalized, error: error)
            vpnMessageIsError = true
        }
    }

    func reconnectProtectionNow(
        playsOutcomeHaptic: Bool = true,
        persistsExplicitIntent: Bool = false,
        lifecycleMutationFenceIsOwned: Bool = false,
        protectionTeardownIsOwned: Bool = false,
        continueIfCurrent: (@MainActor () -> Bool)? = nil,
        requiresActiveSession: Bool = false
    ) async {
        // A fenced caller may have transferred teardown before any asynchronous
        // revalidation. Release it even when that revalidation refuses the restart.
        var inheritedTeardownIsActive = protectionTeardownIsOwned
        defer {
            if inheritedTeardownIsActive { endProtectionTeardown() }
        }
        guard continueIfCurrent?() ?? true else { return }
        if !lifecycleMutationFenceIsOwned {
            // Cancel and transitively drain a delayed arm before waiting for the outer fence. This
            // lets a callback already suspended in saveToPreferences finish under its fence, then
            // hands the fence to this explicit reconnect without losing either operation. Reducer
            // teardown stays asserted while a direct Restart finishes so no replacement arm appears.
            var preflightTeardownIsActive = true
            beginProtectionTeardown()
            defer {
                if preflightTeardownIsActive {
                    endProtectionTeardown()
                }
            }
            await drainChainedOnDemandArm()
            do {
                try await LavaProtectionCommandService.withExclusiveProtectionLifecycleMutation {
                    // Fence acquired: synchronously transfer the already-active reducer teardown
                    // edge to the inner stop scope. No false edge is emitted between the handoff,
                    // so a fast terminal cannot create a replacement arm in the seam.
                    preflightTeardownIsActive = false
                    await self.reconnectProtectionNow(
                        playsOutcomeHaptic: playsOutcomeHaptic,
                        persistsExplicitIntent: persistsExplicitIntent,
                        lifecycleMutationFenceIsOwned: true,
                        protectionTeardownIsOwned: true,
                        continueIfCurrent: continueIfCurrent,
                        requiresActiveSession: requiresActiveSession
                    )
                }
            } catch {
                vpnMessage = Self.vpnErrorMessage(
                    prefix: "Could not reconnect protection".lavaLocalized,
                    error: error
                )
                vpnMessageIsError = true
                if playsOutcomeHaptic {
                    playProtectionStartFailedHaptic()
                }
            }
            return
        }

        #if DEBUG || LAVA_QA_TOOLS
        guard validateChainedConfigurationForStart() else { return }
        #endif

        if persistsExplicitIntent {
            // A user-selected reconnect is a fresh explicit ON. Commit it under the same fence
            // before the reconnect's stop/disarm edge, so an earlier durable OFF cannot survive
            // after this accepted choice. QA/system reconnects leave this false and remain
            // read-only with respect to user intent.
            do {
                try persistExplicitProtectionIntent(isEnabled: true)
            } catch {
                vpnMessage = Self.vpnErrorMessage(
                    prefix: "Could not reconnect protection".lavaLocalized,
                    error: error
                )
                vpnMessageIsError = true
                if playsOutcomeHaptic {
                    playProtectionStartFailedHaptic()
                }
                return
            }
            // Reconnect is an explicit recovery boundary too: do not carry a provider's terminal
            // chained-start marker (or its saved surrender) into the user-requested retry.
            do {
                try prepareChainedStateForExplicitGuardStart()
            } catch {
                vpnMessage = Self.vpnErrorMessage(
                    prefix: "Could not reconnect protection".lavaLocalized,
                    error: error
                )
                vpnMessageIsError = true
                if playsOutcomeHaptic {
                    playProtectionStartFailedHaptic()
                }
                return
            }
        }

        #if DEBUG
        logVPNDebugEvent("reconnect-begin", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus),
            "networkKind": tunnelHealth.networkKind.rawValue,
            "lastFailureReason": tunnelHealth.lastFailureReason ?? "nil"
        ])
        #endif

        do {
            // THE SAME DRAIN TURN-OFF DOES, and for a sharper reason. A deferred arm suspended in
            // `saveToPreferences` is not stopped by cancellation, so without this its save lands
            // AFTER the disable below, re-enables Connect-On-Demand, and iOS reconnects the tunnel
            // during `waitForProtectionToStop` — which then times out and throws
            // `vpnStillStopping`, turning a routine reconnect into a visible failure. Turn-off's
            // version of this bug left a profile armed; this one breaks the restart outright
            // (Codex P1, PR #594, on a retro review of the merged code).
            // The reducer teardown spans the stop, not just the drain, and is released before
            // enableProtection so the replacement connection may sample and arm normally. The
            // ordinary wrapper transfers its already-active edge; already-fenced internal callers
            // create one here.
            do {
                if protectionTeardownIsOwned {
                    precondition(isTearingDownProtection)
                    inheritedTeardownIsActive = false
                } else {
                    beginProtectionTeardown()
                }
                defer { endProtectionTeardown() }

                let manager: NETunnelProviderManager?
                if requiresActiveSession {
                    // A settings edit is not a new ON intent. Re-read the manager under
                    // the lifecycle fence so an earlier stop cannot be undone by the
                    // connected observation captured before the debounce window.
                    manager = try await loadExistingTunnelManager()
                } else if let tunnelManager {
                    manager = tunnelManager
                } else {
                    manager = try await loadExistingTunnelManager()
                }
                if requiresActiveSession {
                    guard let manager, isProtectionEnabledStatus(manager.connection.status),
                          continueIfCurrent?() ?? true else { return }
                    tunnelManager = manager
                }
                vpnMessage = "Reconnecting local protection..."
                vpnMessageIsError = false
                await drainChainedOnDemandArm()
                guard continueIfCurrent?() ?? true else { return }
                // Disable on-demand before the reset-stop so iOS does not reconnect mid-wait.
                // After the new tunnel reports connected, the lifecycle reducer emits the new arm.
                if let manager {
                    await disableOnDemandWithRetry(on: manager)
                }
                guard continueIfCurrent?() ?? true else { return }
                manager?.connection.stopVPNTunnel()
                updateProtectionStatus(from: manager)
                guard await waitForProtectionToStop(timeout: Self.protectionRestartStopWaitTimeout)
                else {
                    throw LavaSecAppError.vpnStillStopping
                }
            }
            guard continueIfCurrent?() ?? true else { return }
            await enableProtection(
                logUserAction: false,
                playsOutcomeHaptic: playsOutcomeHaptic,
                persistsExplicitIntent: false,
                continueIfLifecycleLeaseOwned: continueIfCurrent,
                lifecycleMutationFenceIsOwned: true
            )

            #if DEBUG
            logVPNDebugEvent("reconnect-finished", details: [
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])
            #endif
        } catch {
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not reconnect protection".lavaLocalized, error: error)
            vpnMessageIsError = true
            if playsOutcomeHaptic {
                playProtectionStartFailedHaptic()
            }

            #if DEBUG
            logVPNDebugEvent("reconnect-error", details: errorDebugDetails(error))
            #endif
        }
    }

    @discardableResult
    // Wait behavior (deadlines, status polling, manager reloads while pending)
    // lives in VPNLifecycleController and is covered by behavior tests; these
    // wrappers keep published state current via the observation callback.
    private func waitForProtectionToConnect(timeout: TimeInterval = AppViewModel.protectionStartWaitTimeout) async -> Bool {
        await vpnLifecycleController.waitForConnect(timeout: timeout, initialManager: tunnelManager) { [weak self] manager in
            self?.tunnelManager = manager
            self?.updateProtectionStatus(from: manager)
        }
    }

    @discardableResult
    private func waitForProtectionToStop(timeout: TimeInterval = AppViewModel.protectionStopWaitTimeout) async -> Bool {
        await vpnLifecycleController.waitForStop(timeout: timeout, initialManager: tunnelManager) { [weak self] manager in
            self?.tunnelManager = manager
            self?.updateProtectionStatus(from: manager)
        }
    }

    static let protectionForceStoppedMessage =
        "Protection was force-stopped to restore your connection. You may need to allow the VPN again the next time you turn it on."

    /// Last-resort recovery for a turn-off that did not complete: deletes every
    /// matching tunnel profile so its Connect-On-Demand rules are removed and the
    /// device's internet path is restored, then resets local protection state.
    ///
    /// This exists because Connect-On-Demand is disabled best-effort before a
    /// stop; if that save fails (or the provider has already exited while the
    /// rules remain installed), iOS keeps reasserting a dead tunnel and the user
    /// is stranded offline with no way to turn protection off (UR-31/UR-32).
    /// Removing the profile is heavier than a normal stop — the system VPN
    /// permission is re-requested when protection is next enabled — but it is the
    /// only in-app action that reliably clears stuck on-demand rules.
    ///
    /// Returns `true` once no matching profile remains (including the case where
    /// the profile was already gone), `false` if removal itself failed.
    private func forceRemoveStuckProtectionProfile() async -> Bool {
        do {
            let managers = try await matchingTunnelManagers()
            for manager in managers {
                manager.connection.stopVPNTunnel()
                try await vpnLifecycleController.removeManager(manager)
            }
            // The profile (and its on-demand arming) is gone — drop the confirmed
            // signal so a later recreate can't inherit a stale `true`.
            Self.setOnDemandConfirmedEnabled(false)
            endProtectionVPNSession()
            tunnelManager = nil
            // Funnel the manager disappearance instead of mutating vpnStatus directly. The
            // connected edge is what cancels any still-open chained establishment diagnostics.
            updateProtectionStatus(from: nil)
            return true
        } catch {
            #if DEBUG || LAVA_QA_TOOLS
            logVPNDebugEvent("turn-off-force-remove-failed", details: errorDebugDetails(error))
            #endif
            return false
        }
    }

    func resumeTemporaryProtectionIfExpired(now: Date = Date()) async {
        guard let until = temporaryProtectionPauseUntil else {
            return
        }

        guard now >= until else {
            scheduleTemporaryProtectionResume()
            return
        }

        guard protectionActionOrchestrator.claim(.resume) else {
            return
        }

        await restoreFiltersAfterTemporaryProtectionPause(configurationAlreadyClaimed: true)
    }

    @discardableResult
    func restoreFiltersAfterTemporaryProtectionPause(
        configurationAlreadyClaimed: Bool = false,
        operationID: LatencyOperationID = .make()
    ) async -> Bool {
        if !configurationAlreadyClaimed {
            guard isProtectionTemporarilyPaused else {
                return false
            }

            guard protectionActionOrchestrator.claim(.resume) else {
                return false
            }
        }

        vpnMessage = "Resuming protection..."
        vpnMessageIsError = false
        defer {
            protectionActionOrchestrator.release(.resume)
        }

        let trace = makeLatencyTrace(operationID: operationID, operationKind: "resume")
        let span = trace.beginSpan("action.resume", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus)
        ])
        var actionStatus = "started"
        defer {
            span.end(details: ["status": actionStatus, "vpnStatus": vpnStatusDebugDescription(vpnStatus)])
        }

        do {
            try await LavaProtectionCommandService.perform(.resume, commandID: operationID.rawValue)
            loadTemporaryProtectionPause()
            await notifyTunnelProtectionPauseUpdated(operationID: operationID)
            let startup = try await preparedSnapshotForProtectionStartup()
            let preparedSnapshot = startup.preparedSnapshot
            if !startup.reusedPersistedArtifacts {
                // Only rewrite artifacts and reload the tunnel snapshot when the
                // resume actually produced different rules; the tunnel kept its
                // snapshot loaded during pause, so a reused snapshot needs no
                // reload (plan resume target: no restart, no rebuild).
                try await persistPreparedSnapshotArtifacts(preparedSnapshot)
                await notifyTunnelSnapshotUpdated(operationID: operationID)
            }
            vpnMessage = nil
            vpnMessageIsError = false
            actionStatus = "resumed"
            return true
        } catch {
            actionStatus = "error"
            vpnMessage = Self.vpnErrorMessage(prefix: "Resumed protection, but could not refresh filter".lavaLocalized, error: error)
            vpnMessageIsError = true
            return false
        }
    }

    func clearTemporaryProtectionPause() {
        temporaryProtectionPauseUntil = nil
        pauseController.clear()
    }

    // Manager selection, save/reload, and duplicate cleanup live in
    // VPNLifecycleController (behavior-tested with fakes); these wrappers keep
    // the existing call sites stable.
    func loadExistingTunnelManager() async throws -> NETunnelProviderManager? {
        try await vpnLifecycleController.loadExistingManager()
    }

    func matchingTunnelManagers() async throws -> [NETunnelProviderManager] {
        try await vpnLifecycleController.matchingManagers()
    }

    func loadOrCreateTunnelManager(
        existingManager: NETunnelProviderManager? = nil,
        continueIfLifecycleLeaseOwned: @escaping @MainActor () -> Bool = { true },
        performPreferenceMutation: @escaping (
            @escaping @MainActor () async throws -> Void
        ) async throws -> Void = { operation in
            try await operation()
        }
    ) async throws -> NETunnelProviderManager {
        try await vpnLifecycleController.loadOrCreateManager(
            existing: existingManager,
            continueIfOwned: continueIfLifecycleLeaseOwned,
            performPreferenceMutation: performPreferenceMutation
        )
    }

    // Toggle Connect-On-Demand and persist it. Turn-off and reconnect call this with false before
    // stopVPNTunnel so iOS does not immediately reconnect; the lifecycle reducer emits the true arm
    // only after observing the replacement tunnel connected. Saving is required for iOS to honor it.
    func setManagerOnDemand(_ enabled: Bool, on manager: NETunnelProviderManager) async throws {
        if enabled {
            let connectRule = NEOnDemandRuleConnect()
            connectRule.interfaceTypeMatch = .any
            manager.onDemandRules = [connectRule]
        }
        manager.isOnDemandEnabled = enabled
        // Invalidate the confirmed-armed signal up front, then re-assert it only after saved-rule
        // readback. The reducer's arm task catches a failed true save and completes its token false while
        // leaving the connected tunnel up, so a stale true from a prior profile must not survive.
        Self.setOnDemandConfirmedEnabled(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        if enabled {
            try await reloadManagerFromPreferences(manager)
            let hasConnectRule = Self.managerHasUniversalOnDemandRule(manager)
            logVPNDebugEvent("on-demand-arm-readback", details: [
                "phase": "readback",
                "onDemandConfirmed": String(manager.isOnDemandEnabled && hasConnectRule),
                "reason": !manager.isOnDemandEnabled ? "disabled"
                    : hasConnectRule ? "unconditional-connect" : "non-universal-rule",
            ])
            // A save callback confirms persistence completion, not the policy iOS will apply on
            // the next boot. Confirm only the reloaded enabled any-interface connect rule.
            // pinned: ProtectionOnDemandSourceTests.testOnDemandConfirmationWaitsForSavedRuleReadback
            guard manager.isOnDemandEnabled, hasConnectRule else {
                throw ProtectionOnDemandArm.Failure.verificationFailed
            }
        }
        Self.setOnDemandConfirmedEnabled(enabled)
    }

    /// Map only the saved rule shape: conditional values never enter diagnostics or core policy.
    static func managerHasUniversalOnDemandRule(_ manager: NETunnelProviderManager) -> Bool {
        ProtectionOnDemandArm.hasUniversalConnectRule((manager.onDemandRules ?? []).map { rule in
            .init(isConnectRule: rule is NEOnDemandRuleConnect,
                matchesAnyInterface: rule.interfaceTypeMatch == .any,
                hasConditions: rule.probeURL != nil || rule.dnsSearchDomainMatch != nil
                    || rule.dnsServerAddressMatch != nil || rule.ssidMatch != nil)
        })
    }

    /// Records whether Connect-On-Demand is confirmed armed for the *current*
    /// profile, read by the tunnel to gate self-reconnect (a self-cancel only
    /// recovers if on-demand will bring the tunnel back). Cleared whenever the
    /// profile is removed or an arming save/readback is in flight so the bit can't outlive
    /// the manager it describes.
    private static func setOnDemandConfirmedEnabled(_ enabled: Bool) {
        LavaSecAppGroup.sharedDefaults.set(
            enabled,
            forKey: LavaSecAppGroup.protectionOnDemandConfirmedEnabledDefaultsKeyName
        )
    }

    #if DEBUG || LAVA_QA_TOOLS
    /// QA leak-rig (#8): arm the DNS leak canary. Persists a fresh nonce + the target resolver IP to
    /// the App Group so the tunnel fires ONE cleartext DNS query for
    /// `<nonce>.leak-canary.lavasec.invalid` on the PHYSICAL path at the next chained establishment,
    /// and surfaces the nonce to pass to the offline analyzer (`--canary-nonce`). Writes sharedDefaults
    /// directly — not the filter-config path.
    func armDNSLeakCanaryForQA(resolverIP: String) {
        let trimmed = resolverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isNumericIPAddress(trimmed) else {
            adminQAStatusMessage = "Leak canary: '\(trimmed)' is not a numeric IPv4/IPv6 address."
            return
        }
        let nonce = Self.freshLeakCanaryNonce()
        let defaults = LavaSecAppGroup.sharedDefaults
        defaults.set(nonce, forKey: LavaSecAppGroup.leakCanaryArmedNonceKey)
        defaults.set(trimmed, forKey: LavaSecAppGroup.leakCanaryResolverIPKey)
        adminQAStatusMessage =
            "Leak canary ARMED → fires once at next chained connect. resolver=\(trimmed). "
            + "Run the analyzer with  --canary-nonce \(nonce)"
    }

    /// QA leak-rig (#8): disarm the canary (clears the armed nonce + resolver).
    func disarmDNSLeakCanaryForQA() {
        let defaults = LavaSecAppGroup.sharedDefaults
        defaults.removeObject(forKey: LavaSecAppGroup.leakCanaryArmedNonceKey)
        defaults.removeObject(forKey: LavaSecAppGroup.leakCanaryResolverIPKey)
        adminQAStatusMessage = "Leak canary disarmed."
    }

    /// A DNS-label-safe, greppable per-run nonce (lowercased hex) — the analyzer's `--canary-nonce`.
    private static func freshLeakCanaryNonce() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
    }

    /// Real numeric-IP validation at arm time — the SAME `inet_pton` check the extension's
    /// `ResolverEndpoint(address:)` applies at fire time, so a malformed literal (e.g. `1:2`, `::::`)
    /// is rejected here instead of arming "successfully" and then silently failing to fire (Codex #563).
    private static func isNumericIPAddress(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var v4 = in_addr()
        if s.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
        var v6 = in6_addr()
        return s.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1
    }
    #endif

    /// Reads the confirmed-on-demand bit (the same one the tunnel gates self-reconnect on). Absent
    /// key ⇒ false. Used by the UI to tell a temporarily-dropped-but-armed tunnel (which iOS will
    /// auto-reconnect) apart from a genuine off state, so a `.disconnected` status while armed shows
    /// "Reconnecting" rather than the fully-off "Turn On" surface.
    static func isOnDemandConfirmedEnabled() -> Bool {
        LavaSecAppGroup.sharedDefaults.bool(
            forKey: LavaSecAppGroup.protectionOnDemandConfirmedEnabledDefaultsKeyName
        )
    }

    /// Seeds the confirmed-on-demand bit from a freshly loaded manager's actual
    /// enabled unconditional connect rule only when the bit has never been written. This backfills the
    /// common upgrade/auto-start case — an existing profile whose protection is
    /// already running, where `setManagerOnDemand` never runs — so self-reconnect
    /// isn't suppressed until the user manually toggles protection. Once the bit
    /// exists, `setManagerOnDemand` owns it (seeding here would otherwise race a
    /// pre-clear during an in-flight arming save).
    private static func seedOnDemandConfirmedIfAbsent(from manager: NETunnelProviderManager) {
        guard LavaSecAppGroup.sharedDefaults.object(
            forKey: LavaSecAppGroup.protectionOnDemandConfirmedEnabledDefaultsKeyName
        ) == nil else {
            return
        }
        setOnDemandConfirmedEnabled(manager.isOnDemandEnabled && managerHasUniversalOnDemandRule(manager))
    }

    private static let onDemandDisableRetryDelayNanoseconds: UInt64 = 200_000_000

    /// Disables Connect-On-Demand with a few retries before falling through.
    /// `saveToPreferences` can fail transiently (e.g. a racing configuration
    /// change), and a failed disable is precisely what wedges turn-off: iOS
    /// keeps reasserting the tunnel and, if the provider has already exited, the
    /// user is stranded offline with no way to stop protection (UR-31/UR-32).
    /// Retrying lets the common transient failure self-heal; a persistent
    /// failure still falls through to the stop, which is backstopped by
    /// forceRemoveStuckProtectionProfile(). Returns true once on-demand is
    /// confirmed disabled.
    @discardableResult
    private func disableOnDemandWithRetry(
        on manager: NETunnelProviderManager,
        clearsStrictRouting: Bool = false,
        attempts: Int = 3
    ) async -> Bool {
        for attempt in 1...max(1, attempts) {
            do {
                if clearsStrictRouting {
                    // An explicit OFF authorizes releasing strict routing as well as stopping
                    // forwarding. Persist both flags together BEFORE stopVPNTunnel, clearing
                    // the saved strict policy before a subsequent controlled app replacement.
                    // Keep the QA preference so a later explicit ON can deliberately restore it.
                    // Every retry must reload/verify, even if a failed save already mutated the
                    // in-memory protocol to false. Reconnects never take this branch.
                    try await StrictRoutingStopPreparation.perform(
                        clearAndSave: {
                            guard let provider = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                                throw StrictRoutingStopPreparation.VerificationError.unreadableProtocol
                            }
                            provider.includeAllNetworks = false
                            manager.protocolConfiguration = provider
                            try await self.setManagerOnDemand(false, on: manager)
                        },
                        reloadAndRead: {
                            try await self.reloadManagerFromPreferences(manager)
                            return .init(
                                onDemandEnabled: manager.isOnDemandEnabled,
                                includesAllNetworks: (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                                    .includeAllNetworks)
                        })
                } else {
                    try await setManagerOnDemand(false, on: manager)
                }
                return true
            } catch {
                #if DEBUG || LAVA_QA_TOOLS
                logVPNDebugEvent("turn-off-ondemand-disable-failed", details: errorDebugDetails(error))
                #endif
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: Self.onDemandDisableRetryDelayNanoseconds)
                    // The common transient failure is a stale in-memory
                    // configuration: saveToPreferences rejects an out-of-date
                    // manager (NEVPNError.configurationStale). Reload it from
                    // on-disk preferences so the next attempt saves against the
                    // current configuration version — retrying the same stale
                    // object would just repeat the same failure.
                    try? await reloadManagerFromPreferences(manager)
                }
            }
        }
        return false
    }

    /// Refreshes an `NETunnelProviderManager` in place from on-disk preferences,
    /// so a subsequent save targets the current configuration version.
    private func reloadManagerFromPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func updateProtectionStatusFromCachedManager() {
        updateProtectionStatus(from: tunnelManager)
    }

    func updateProtectionStatus(from manager: NETunnelProviderManager?) {
        let currentStatus = manager?.connection.status ?? .invalid
        let previousStatus = vpnStatus
        let isInstalled = manager != nil
        let installedStateChanged = isVPNConfigurationInstalled != isInstalled

        // Seed upgrades from the installed profile, then clear a stale confirmation if the live
        // manager is no longer armed. This reconciliation runs before the lifecycle reduction so
        // every status observation carries the freshest recovery truth.
        if let manager {
            Self.seedOnDemandConfirmedIfAbsent(from: manager)
            let hasArmedRecoveryRule = manager.isOnDemandEnabled && Self.managerHasUniversalOnDemandRule(manager)
            if !hasArmedRecoveryRule, Self.isOnDemandConfirmedEnabled() {
                Self.setOnDemandConfirmedEnabled(false)
            }
        }

        if installedStateChanged {
            isVPNConfigurationInstalled = isInstalled
        }
        if vpnStatus != currentStatus {
            vpnStatus = currentStatus
        }

        let markerObservation = chainedStartupFailureMarkerObservation
        // Fail closed: a recorded chained refusal is disclosed, never projected as OFF. The
        // provider starts the latched DNS-only path under any refusal, so protection keeps
        // filtering and the user's intent, profile and Connect-On-Demand all stay as they were.
        // Only an explicit user action turns protection off
        // (plans/2026-09-18-fail-closed-protection-startup-failures-plan.md).
        // pinned: ProtectionOnDemandSourceTests.testAChainedStartupFailureDisclosesWithoutDisarmingOnDemand
        if configuration.chainedUpstreamEnabled, case .marked = markerObservation {
            chainedStartupFailureNotice = Self.chainedStartupFailureMessage.lavaLocalized
        } else {
            chainedStartupFailureNotice = nil
        }

        let protectionEnabled = isProtectionEnabledStatus(vpnStatus) || isAwaitingOnDemandReconnect
        if case .unavailable = markerObservation {
            // The marker may be briefly unreadable while the tunnel is down. Automatic restore
            // remains fail-closed, but do not project that transient read fault as an authoritative
            // OFF intent or overwrite the user's armed protection hint. A connected tunnel may
            // still refresh the hint from its live status; a disconnected one keeps its prior value
            // until the marker read becomes trustworthy again.
            if currentStatus == .connected, configuration.protectionEnabled != protectionEnabled {
                configuration.protectionEnabled = protectionEnabled
            }
        } else if configuration.protectionEnabled != protectionEnabled {
            configuration.protectionEnabled = protectionEnabled
        }
        synchronizeLocalProtectionUptime(currentStatus: currentStatus)
        reconcileLiveActivity()

        let isFreshConnected = previousStatus != .connected && currentStatus == .connected
        let userInitiated = isFreshConnected && awaitsProtectionOnHaptic
        if isFreshConnected {
            // Transfer this one-shot intent before reducing. The reducer owns eventual success,
            // including late proof, and the connection/intent fence prevents stale feedback.
            awaitsProtectionOnHaptic = false
            beginChainedEstablishmentDiagnostics()
            appendNetworkActivity(.protectionConnected)
        } else if previousStatus == .connected, currentStatus != .connected {
            // Invalidate delayed work before reducing the departure. A direct Restart may rotate
            // the shared generation in another process, while OFF/reconnect already advanced the
            // sticky intent revision synchronously; neither may let this connection publish later.
            chainedLifecycleMutationIdentity = nil
            cancelChainedEstablishmentDiagnostics()
        }

        // Restart can be initiated outside this AppViewModel (for example from the Dynamic Island).
        // Suspend only its first outbound status reduction so the intentional replacement cannot
        // publish a vanish notice. End the pulse immediately: the replacement connection must be
        // free to start sampling and arm on demand while the shared restart marker is still alive.
        let isIntentionalRestartDeparture =
            isRestartInFlight && previousStatus == .connected && currentStatus != .connected
        if isIntentionalRestartDeparture {
            beginProtectionTeardown()
        }
        let effects = reduceChainedConnectLifecycleState(
            .statusChanged(
                currentStatus.protectionLifecycleStatus,
                onDemandConfirmed: Self.isOnDemandConfirmedEnabled(),
                userInitiated: userInitiated,
                now: Self.chainedObservationNow))
        executeChainedConnectLifecycleEffects(effects)
        if isIntentionalRestartDeparture {
            endProtectionTeardown()
        }

        if awaitsProtectionOnHaptic,
            [.invalid, .disconnected].contains(currentStatus),
            [.connecting, .reasserting].contains(previousStatus)
        {
            playProtectionStartFailedHaptic()
        }

        #if DEBUG
        if previousStatus != currentStatus || installedStateChanged {
            logVPNDebugEvent("status-updated", details: tunnelManagerDebugDetails(manager))
        }
        #endif
    }

    private func playProtectionStartFailedHaptic() {
        awaitsProtectionOnHaptic = false
        ProtectionHapticFeedback.play(.protectionStartFailed)
    }

    func refreshProtectionStatus(force: Bool = false) async {
        #if targetEnvironment(simulator)
        vpnStatus = .invalid
        isVPNConfigurationInstalled = false
        configuration.protectionEnabled = false
        reconcileLiveActivity()
        vpnMessage = "VPN testing requires a physical device."
        vpnMessageIsError = false
        return
        #else
        if !force, let tunnelManager {
            updateProtectionStatus(from: tunnelManager)

            if let lastProtectionStatusRefresh,
               Date().timeIntervalSince(lastProtectionStatusRefresh) < protectionStatusRefreshInterval,
               !isProtectionTransitionStatus(vpnStatus) {
                return
            }
        }

        // Forced followers must not return to a post-refresh predicate while the owner's manager
        // load is still suspended. The coordinator makes them await the same task and retains the
        // existing one-follow-up bound, so loadAllFromPreferences notifications cannot self-post an
        // unbounded refresh storm.
        await protectionStatusRefreshCoordinator.run { [self] in
            do {
                let manager = try await self.loadExistingTunnelManager()
                self.tunnelManager = manager
                self.updateProtectionStatus(from: manager)
                self.lastProtectionStatusRefresh = Date()
                if self.vpnStatus == .connected {
                    await self.requestTunnelHealthFlush()
                }
                self.refreshTunnelHealth()
            } catch {
                self.vpnMessage = error.localizedDescription
                self.vpnMessageIsError = true

                #if DEBUG || LAVA_QA_TOOLS
                self.logVPNDebugEvent("refresh-status-error", details: self.errorDebugDetails(error))
                #endif
            }
        }
        // Outside the refresh coordinator: reconnect itself refreshes status while waiting.
        await reconcileDNSRouteEnforcementIfNeeded()
        #endif
    }

}
