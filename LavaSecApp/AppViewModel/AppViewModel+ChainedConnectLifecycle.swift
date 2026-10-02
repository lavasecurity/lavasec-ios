import Darwin
import Foundation
import Combine
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
    // MARK: - Chained-connect lifecycle

    static let chainedEstablishingMessage = "Setting up VPN chaining."
    static let chainedForwardingUnconfirmedMessage =
        "DNS filtering is on. Waiting to confirm VPN traffic."
    private static let chainedEstablishFailedMessage = "Couldn't establish the VPN connection"
    static let chainedStartupFailureMessage =
        "DNS filtering is on. Reconnect to retry VPN forwarding."
    private static let chainedEstablishmentPollInterval: UInt64 = 1_000_000_000  // 1 s
    private static let chainedMonitoringPollInterval: UInt64 = 5_000_000_000  // 5 s

    /// UIKit posts these notifications on the main thread. Cancel synchronously, before
    /// suspension can queue an expired IPC deadline ahead of SwiftUI's scene update.
    /// Both native and RN hosts share this model owner; scene callbacks own their other work.
    /// pinned: ChainedConnectFlowSourceTests.testUIKitOwnsObservationLifetimeSynchronously
    func startObservingChainedApplicationLifecycle() {
        guard !isHeadless, chainedApplicationLifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.willResignActiveNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.setChainedObservationActive(false) }
        }.store(in: &chainedApplicationLifecycleObservers)
        center.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.setChainedObservationActive(false) }
        }.store(in: &chainedApplicationLifecycleObservers)
        center.publisher(for: UIApplication.willEnterForegroundNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.beginChainedForegroundEntryPrefetch() }
        }.store(in: &chainedApplicationLifecycleObservers)
        center.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setChainedObservationActive(UIApplication.shared.applicationState == .active)
            }
        }.store(in: &chainedApplicationLifecycleObservers)
        setChainedObservationActive(UIApplication.shared.applicationState == .active)
    }

    private func logChainedEstablishmentGate(
        _ phase: String,
        startedAt: Date,
        polls: Int,
        unknownReplies: Int,
        receivedDelta: UInt64?
    ) {
        logVPNDebugEvent("chained-establish-gate", details: [
            "phase": phase,
            "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))",
            "polls": "\(polls)",
            "unknownReplies": "\(unknownReplies)",
            "receivedDelta": receivedDelta.map { "\($0)" } ?? "nil"
        ])
    }

    // ContinuousClock includes device sleep. Provider outage timing intentionally uses a
    // different clock; app evidence freshness must not freeze during physical sleep.
    private static let chainedClockOrigin = ContinuousClock.now
    static var chainedObservationNow: TimeInterval {
        let duration = chainedClockOrigin.duration(to: ContinuousClock.now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    private func projectChainedConnectLifecycleState() {
        let next = chainedConnectLifecycleState.projection
        if chainedProjection != next {
            chainedProjectionRevision &+= 1
            chainedProjection = next
        }
    }

    private func scheduleChainedObservationDeadline() {
        chainedObservationDeadlineTask?.cancel()
        chainedObservationDeadlineTask = nil
        chainedObservationDeadlineGeneration &+= 1
        guard chainedObservationActive, let connection = chainedSamplingConnection,
              let deadline = chainedConnectLifecycleState.graceDeadline,
              deadline > Self.chainedObservationNow else { return }
        let generation = chainedObservationDeadlineGeneration
        chainedObservationDeadlineTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(max(0, deadline - Self.chainedObservationNow)))
                guard let self, !Task.isCancelled, self.chainedObservationActive,
                      self.chainedObservationDeadlineGeneration == generation,
                      self.chainedSamplingConnection == connection else { return }
                self.executeChainedConnectLifecycleEffects(self.reduceChainedConnectLifecycleState(
                    .observationDeadline(connection: connection, deadline: deadline, now: Self.chainedObservationNow)))
            } catch { /* Cancellation invalidates this deadline generation. */ }
        }
    }

    @discardableResult
    func reduceChainedConnectLifecycleState(
        _ event: ChainedConnectLifecyclePolicy.Event
    ) -> [ChainedConnectLifecyclePolicy.Effect] {
        switch event {
        case .observed, .teardownChanged(isActive: true):
            cancelChainedForegroundEntryPrefetch()
        case let .statusChanged(status, _, _, _) where status != .connected:
            cancelChainedForegroundEntryPrefetch()
        default: break
        }
        let previousClaim = chainedConnectLifecycleState.claim
        let previousStatus = protectionStatus
        let previousProjection = chainedProjection
        let previousMilestone = chainedConnectLifecycleState.milestone
        let effects = ChainedConnectLifecyclePolicy.reduce(
            state: &chainedConnectLifecycleState,
            event: event)
        projectChainedConnectLifecycleState()
        scheduleChainedObservationDeadline()
        if previousProjection != chainedProjection || previousMilestone != chainedConnectLifecycleState.milestone {
            var details = [
                "previous": String(describing: previousClaim),
                "current": String(describing: chainedConnectLifecycleState.claim),
                "foreground": String(chainedObservationActive),
                "event": String(describing: event).components(separatedBy: "(").first ?? "unknown",
                "previousMilestone": previousMilestone.rawValue,
                "milestone": chainedConnectLifecycleState.milestone.rawValue,
                "setupReady": String(chainedProjection.setupReady),
                "projectionRevision": String(chainedProjectionRevision),
                "previousStatus": String(describing: previousStatus),
                "status": String(describing: protectionStatus),
                "gapDeadline": chainedConnectLifecycleState.graceDeadline.map(String.init(describing:)) ?? "none",
                "sampleAge": chainedConnectLifecycleState.lastAcceptedAt.map { String(Self.chainedObservationNow - $0) } ?? "none"
            ]
            switch event {
            case let .observed(connection, observation, _):
                details["connection"] = String(connection)
                switch observation {
                case let .chained(session?):
                    details["observation"] = "chained"
                    details["sessionGeneration"] = String(session.generation)
                    details["transportGeneration"] = String(session.transportGeneration)
                    details["verificationEpoch"] = session.verificationEpoch.map(String.init) ?? "legacy"
                    details["providerIdentityPresent"] = String(session.providerLifecycleID != nil)
                    details["runtimeCondition"] = session.runtimeCondition.rawValue
                    details["healthOwned"] = String(chainedProjection.ownsHealth)
                    details["forwardedBytes"] = String(session.forwardedBytes)
                case .chained(nil)?: details["observation"] = "runner-absent"
                case .dnsOnly?: details["observation"] = "dns-only"
                case .inactive?: details["observation"] = "inactive"
                case nil: details["observation"] = "unavailable"
                }
            case let .statusChanged(status, _, userInitiated, _):
                details["lifecycle"] = String(describing: status)
                details["userInitiated"] = String(userInitiated)
            default: break
            }
            logVPNDebugEvent("chained-claim-transition", details: details)
        }
        return effects
    }

    func executeChainedConnectLifecycleEffects(
        _ effects: [ChainedConnectLifecyclePolicy.Effect]
    ) {
        for effect in effects {
            switch effect {
            case .stopSampling:
                stopChainedLifecycleSampling()
            case let .startSampling(connection):
                startChainedLifecycleSampling(connection: connection)
            case let .ensureOnDemand(id, connection):
                startChainedOnDemandArm(id: id, connection: connection)
            case let .resolveInitialClaim(connection, confirmed, userInitiated, receivedByteDelta):
                resolveInitialChainedClaim(
                    connection: connection,
                    confirmed: confirmed,
                    userInitiated: userInitiated,
                    receivedByteDelta: receivedByteDelta)
            case let .resolveSetupReady(connection, userInitiated):
                logVPNDebugEvent("chained-setup-ready", details: ["connection": String(connection)])
                resolveInitialChainedClaim(connection: connection, confirmed: false,
                    userInitiated: userInitiated, receivedByteDelta: 0, setupReady: true)
            case let .resolveDeferredSuccess(connection, receivedByteDelta):
                logVPNDebugEvent("chained-deferred-success", details: ["connection": "\(connection)"])
                resolveInitialChainedClaim(connection: connection, confirmed: true,
                    userInitiated: true, receivedByteDelta: receivedByteDelta)
            case .reconcileProtectionStatus:
                Task { [weak self] in
                    await self?.refreshProtectionStatus(force: true)
                }
            }
        }
    }

    /// Starts with an immediate prompt reply, then keeps sampling for the entire connected epoch.
    /// Establishing and unconfirmed use a one-second cadence to consume real proof promptly;
    /// confirmed chained claims use a five-second monitoring cadence so runner loss, generation replacement, or a counter reset can
    /// revoke an earlier confirmation. DNS-only is authoritative and makes the reducer stop the loop.
    private func startChainedLifecycleSampling(connection: UInt64) {
        stopChainedLifecycleSampling()
        chainedSamplingConnection = connection
        if chainedLifecycleMutationIdentity?.connection != connection {
            // Capture before the sampler's first suspension. A read failure is retained as nil in
            // this connection identity; delayed work cannot substitute a later restart generation.
            // Capture even while observation is inactive: recovery arming belongs to the connected
            // lifecycle, not UI visibility. A fresh foreground repair may create a new epoch after
            // rereading the current saved manager and durable intent, never rebase this identity.
            // pinned: ProtectionOnDemandSourceTests.testRecoveryIdentityIsCapturedEvenWhileApplicationObservationIsInactive
            chainedLifecycleMutationIdentity = ChainedLifecycleMutationIdentity(
                connection: connection,
                protectionIntentRevision: userProtectionIntent.revision,
                externalRestartGeneration: try? LavaProtectionCommandService
                    .captureExternalRestartGeneration()
            )
        }
        guard let generation = chainedObservationLifetime.beginSampling() else { return }
        chainedLifecycleSamplingTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let self else { return }
                    // A suspended app cannot measure a two-second IPC deadline.
                    // Its cancelled pre-background reply must never reach the reducer.
                    guard self.chainedObservationLifetime.accepts(generation) else { return }
                    let queryStartedAt = Self.chainedObservationNow
                    let result = await self.queryChainedHandshakeObservation()
                    let reply = result.reply
                    guard !Task.isCancelled,
                          self.chainedObservationLifetime.accepts(generation),
                          UIApplication.shared.applicationState == .active else {
                        self.logVPNDebugEvent("chained-observation-discarded", details: [
                            "connection": String(connection), "samplingGeneration": String(generation),
                            "currentGeneration": String(self.chainedObservationLifetime.generation),
                            "cancelled": String(Task.isCancelled),
                            "applicationActive": String(UIApplication.shared.applicationState == .active)
                        ])
                        return
                    }
                    try Task.checkCancellation()
                    let observation = ChainedRuntimeObservation.fromTunnelReply(reply)
                    if observation == nil {
                        self.logVPNDebugEvent("chained-observation-unavailable", details: [
                            "connection": String(connection), "samplingGeneration": String(generation),
                            "reason": result.reason.rawValue
                        ])
                    }
                    self.recordChainedEstablishmentPoll(observation: observation)
                    let effects = self.reduceChainedConnectLifecycleState(
                        .observed(
                            connection: connection,
                            observation: observation,
                            now: Self.chainedObservationNow))
                    self.executeChainedConnectLifecycleEffects(effects)
                    if result.reason == .sessionUnavailable {
                        // An observable manager lifecycle is decisive, while a missing manager
                        // remains unknown. Reconciliation is read-only and uses the existing gate.
                        await self.refreshProtectionStatus(force: true)
                    }
                    try Task.checkCancellation()

                    // Retry a first lost query promptly, at most once per second. A normal
                    // five-second confirmed cadence must not consume the entire grace window.
                    if observation == nil {
                        let delay = max(0, 1 - (Self.chainedObservationNow - queryStartedAt))
                        try await ContinuousClock().sleep(for: .seconds(delay))
                        continue
                    }
                    let interval: UInt64
                    switch self.chainedConnectLifecycleState.claim {
                    case .establishing, .checking, .unconfirmed:
                        interval = Self.chainedEstablishmentPollInterval
                    case .confirmed:
                        interval = Self.chainedMonitoringPollInterval
                    case .inactive:
                        return
                    }
                    try await Task.sleep(nanoseconds: interval)
                }
            } catch is CancellationError {
                // Cancellation is the lifecycle boundary, not a failed observation.
            } catch {
                // Task.sleep and checkCancellation currently throw only cancellation.
            }
        }
    }

    /// Suspend only observation, not the tunnel lifecycle, recovery arm or its proof.
    /// Resume with an immediate fresh sample of the same connected epoch.
    private func setChainedObservationActive(_ active: Bool) {
        if !active { cancelChainedForegroundEntryPrefetch() }
        guard chainedObservationLifetime.setActive(active) else { return }
        logVPNDebugEvent("chained-observation-lifecycle", details: [
            "active": String(active), "generation": String(chainedObservationLifetime.generation),
            "connection": chainedSamplingConnection.map(String.init) ?? "none"
        ])
        if active, let candidate = consumeChainedForegroundEntryPrefetch(),
           let connection = chainedSamplingConnection {
            // This is a fresh provider observation, not renewed grace for the old claim.
            // Admit before publishing an expired resume gap; preserve its actual receipt time.
            executeChainedConnectLifecycleEffects(reduceChainedConnectLifecycleState(
                .observed(connection: connection, observation: candidate.observation, now: candidate.receivedAt)))
        } else {
            _ = reduceChainedConnectLifecycleState(active
                ? .observationResumed(now: Self.chainedObservationNow)
                : .observationSuspended(now: Self.chainedObservationNow))
        }
        if active, let connection = chainedSamplingConnection {
            startChainedLifecycleSampling(connection: connection)
            scheduleChainedObservationDeadline()
        } else if !active {
            chainedLifecycleSamplingTask?.cancel()
            chainedLifecycleSamplingTask = nil
        }
        if active { requestForegroundOnDemandRepair() }
    }

    /// A foreground boundary supplies one useful retry even when forwarding remains steadily
    /// confirmed or the DNS-only sampler has stopped. Re-read the saved manager before minting a
    /// repair. Read, cache publication and reducer admission share the arm's mutation fence; an
    /// accepted OFF/background while waiting or reading retires the request (INV-PERSIST-3).
    /// pinned: ProtectionOnDemandSourceTests.testForegroundRecoveryRevalidatesDurableIntentAndUsesANewEpochForMissingGeneration
    private func requestForegroundOnDemandRepair() {
        guard let connection = chainedConnectLifecycleState.onDemandRepairConnection,
              userProtectionIntent.isEnabled, !isTearingDownProtection else { return }
        let intentRevision = userProtectionIntent.revision
        let activityGeneration = chainedObservationLifetime.activityGeneration
        Task { [weak self] in
            guard let self else { return }
            var savedManagerReadFailed = false
            do {
                // A load outside this fence can correctly read disabled preferences while an
                // arm's save is pending, then replace the manager that arm verifies. A cached
                // status notification would erase its confirmation after a successful readback.
                // pinned: ProtectionOnDemandSourceTests.testForegroundReadAndPublicationUseTheArmMutationFence
                try await LavaProtectionCommandService.refreshOnDemandStateForForegroundRepair(
                    validateOwnership: {
                        guard !Task.isCancelled, self.chainedObservationActive,
                              self.chainedObservationLifetime.activityGeneration == activityGeneration,
                              self.userProtectionIntent.isEnabled,
                              self.userProtectionIntent.revision == intentRevision,
                              !self.isTearingDownProtection,
                              self.chainedConnectLifecycleState.onDemandRepairConnection == connection,
                              let containerURL = LavaSecAppGroup.containerURL else { return false }
                        return ProtectionRestoreIntentStore.read(containerURL: containerURL)
                            .resolvedIntent(fallingBackTo: self.userProtectionIntent.isEnabled)
                    },
                    readState: {
                        do {
                            return try await self.loadExistingTunnelManager()
                        } catch {
                            // A cached fallback cannot authorize a new ownership epoch.
                            // pinned: ProtectionOnDemandSourceTests.testForegroundRecoveryRequiresASuccessfulSavedManagerRead
                            savedManagerReadFailed = true
                            var details = self.errorIdentityDetails(error)
                            details["phase"] = "skipped"
                            details["reason"] = "saved-manager-read-failed"
                            details["connection"] = String(connection)
                            self.logVPNDebugEvent("on-demand-arm-repair", details: details)
                            throw error
                        }
                    },
                    applyState: { manager in
                        self.tunnelManager = manager
                        self.updateProtectionStatus(from: manager)
                        guard self.chainedConnectLifecycleState.onDemandRepairConnection == connection,
                              manager?.connection.status == .connected,
                              let containerURL = LavaSecAppGroup.containerURL,
                              ProtectionRestoreIntentStore.read(containerURL: containerURL)
                                .resolvedIntent(fallingBackTo: self.userProtectionIntent.isEnabled)
                        else { return }

                        let startsNewObservation = self.chainedLifecycleMutationIdentity?.connection != connection
                            || self.chainedLifecycleMutationIdentity?.externalRestartGeneration == nil
                        self.logVPNDebugEvent("on-demand-arm-repair", details: [
                            "phase": "foreground",
                            "connection": String(connection),
                            "reason": startsNewObservation ? "fresh-observation-epoch" : "retry-current-epoch",
                        ])
                        // Dispatch is synchronous. A new arm waits for this fence after admission
                        // returns; awaiting it here would deadlock against the owned descriptor.
                        self.executeChainedConnectLifecycleEffects(self.reduceChainedConnectLifecycleState(
                            .onDemandRepairRequested(connection: connection,
                                startsNewObservation: startsNewObservation, now: Self.chainedObservationNow)))
                    })
            } catch {
                guard !savedManagerReadFailed else { return }
                var details = self.errorIdentityDetails(error)
                details["phase"] = "skipped"
                details["reason"] = "foreground-read-fence-failed"
                details["connection"] = String(connection)
                self.logVPNDebugEvent("on-demand-arm-repair", details: details)
            }
        }
    }

    private func stopChainedLifecycleSampling() {
        cancelChainedForegroundEntryPrefetch()
        chainedObservationDeadlineTask?.cancel()
        chainedObservationDeadlineTask = nil
        chainedObservationDeadlineGeneration &+= 1
        chainedObservationLifetime.invalidateSampling()
        chainedSamplingConnection = nil
        chainedLifecycleSamplingTask?.cancel()
        chainedLifecycleSamplingTask = nil
    }

    /// Starts during UIKit's foreground transition. It may stage evidence while inactive, but
    /// only didBecomeActive can admit it. Neither activation nor cancellation awaits this task;
    /// the existing two-second IPC deadline also bounds a provider that never replies.
    private func beginChainedForegroundEntryPrefetch() {
        cancelChainedForegroundEntryPrefetch()
        guard !chainedObservationActive, vpnStatus == .connected, !isTearingDownProtection,
              let connection = chainedSamplingConnection,
              let identity = chainedConnectLifecycleState.foregroundEntryIdentity,
              let session = tunnelManager?.connection as? NETunnelProviderSession,
              session.status == .connected,
              let mutationIdentity = chainedLifecycleMutationIdentity,
              mutationIdentity.connection == connection,
              mutationIdentity.protectionIntentRevision == userProtectionIntent.revision,
              let restartGeneration = try? LavaProtectionCommandService.captureExternalRestartGeneration(),
              mutationIdentity.externalRestartGeneration == restartGeneration else { return }
        let token = chainedForegroundEntryPrefetch.begin(connection: connection, identity: identity,
                                                         now: Self.chainedObservationNow)
        chainedForegroundEntrySession = session
        chainedForegroundEntryMutationIdentity = mutationIdentity
        logVPNDebugEvent("chained-entry-prefetch", details: [
            "phase": "begin", "connection": String(connection), "generation": String(token.generation)
        ])
        chainedForegroundEntryTask = Task { [weak self] in
            guard let self, !Task.isCancelled, !self.chainedObservationActive,
                  self.tunnelManager?.connection === session else { return }
            // A prefetch never loads/replaces a manager or writes persisted health/configuration.
            let result = await self.queryChainedHandshakeObservation(reloadMissingManager: false)
            guard !Task.isCancelled, !self.chainedObservationActive,
                  self.tunnelManager?.connection === session,
                  self.chainedForegroundEntryMutationIdentity == mutationIdentity else { return }
            let staged = self.chainedForegroundEntryPrefetch.stage(
                ChainedRuntimeObservation.fromTunnelReply(result.reply), for: token,
                now: Self.chainedObservationNow)
            self.logVPNDebugEvent("chained-entry-prefetch", details: [
                "phase": staged ? "staged" : "rejected", "connection": String(connection),
                "generation": String(token.generation), "reason": result.reason.rawValue
            ])
        }
    }

    private func consumeChainedForegroundEntryPrefetch() -> ChainedForegroundEntryPrefetch.Candidate? {
        defer { cancelChainedForegroundEntryPrefetch() }
        guard UIApplication.shared.applicationState == .active,
              vpnStatus == .connected, !isTearingDownProtection,
              let session = chainedForegroundEntrySession, session.status == .connected,
              tunnelManager?.connection === session,
              let identity = chainedForegroundEntryMutationIdentity,
              identity == chainedLifecycleMutationIdentity,
              identity.protectionIntentRevision == userProtectionIntent.revision,
              let restartGeneration = try? LavaProtectionCommandService.captureExternalRestartGeneration(),
              identity.externalRestartGeneration == restartGeneration else { return nil }
        let candidate = chainedForegroundEntryPrefetch.consume(connection: chainedSamplingConnection,
            identity: chainedConnectLifecycleState.foregroundEntryIdentity, now: Self.chainedObservationNow)
        logVPNDebugEvent("chained-entry-prefetch", details: [
            "phase": candidate == nil ? "unavailable" : "admitted",
            "connection": String(identity.connection)
        ])
        return candidate
    }

    private func cancelChainedForegroundEntryPrefetch() {
        chainedForegroundEntryPrefetch.cancel()
        chainedForegroundEntryTask?.cancel()
        chainedForegroundEntryTask = nil
        chainedForegroundEntrySession = nil
        chainedForegroundEntryMutationIdentity = nil
    }

    func beginChainedEstablishmentDiagnostics() {
        let startedAt = Date()
        chainedEstablishmentProgress = (startedAt: startedAt, polls: 0, unknownReplies: 0)
        logChainedEstablishmentGate(
            "begin", startedAt: startedAt, polls: 0, unknownReplies: 0, receivedDelta: nil)
    }

    private func recordChainedEstablishmentPoll(
        observation: ChainedRuntimeObservation?
    ) {
        guard let progress = chainedEstablishmentProgress else { return }
        chainedEstablishmentProgress = (
            startedAt: progress.startedAt,
            polls: progress.polls + 1,
            unknownReplies: progress.unknownReplies + (observation == nil ? 1 : 0))
    }

    private func resolveChainedEstablishmentDiagnostics(
        confirmed: Bool,
        receivedByteDelta: UInt64?,
        setupReady: Bool = false
    ) {
        guard let progress = chainedEstablishmentProgress else { return }
        logChainedEstablishmentGate(
            setupReady ? "ready" : (confirmed ? "confirmed" : "unconfirmed"),
            startedAt: progress.startedAt,
            polls: progress.polls,
            unknownReplies: progress.unknownReplies,
            receivedDelta: receivedByteDelta)
        chainedEstablishmentProgress = nil
    }

    func cancelChainedEstablishmentDiagnostics() {
        guard let progress = chainedEstablishmentProgress else { return }
        logChainedEstablishmentGate(
            "cancelled",
            startedAt: progress.startedAt,
            polls: progress.polls,
            unknownReplies: progress.unknownReplies,
            receivedDelta: nil)
        chainedEstablishmentProgress = nil
    }

    /// The reducer permits one success result for an explicit start, including proof arriving
    /// after the initial timeout. Ordinary wake/reconfirmation has no new success effect. A
    /// confirmed user result waits for the shared mutation fence and revalidates the exact reducer
    /// connection, sticky intent revision, and external-Restart generation before publishing.
    private func resolveInitialChainedClaim(
        connection: UInt64,
        confirmed: Bool,
        userInitiated: Bool,
        receivedByteDelta: UInt64?,
        setupReady: Bool = false
    ) {
        resolveChainedEstablishmentDiagnostics(
            confirmed: confirmed,
            receivedByteDelta: receivedByteDelta, setupReady: setupReady)
        guard confirmed || setupReady,
              userInitiated,
              let identity = chainedLifecycleMutationIdentity,
              identity.connection == connection,
              let externalRestartGeneration = identity.externalRestartGeneration
        else {
            _ = reduceChainedConnectLifecycleState(
                .successFeedbackFinished(connection: connection, retryWhenConfirmed: false))
            return
        }

        let acceptedObservationGeneration = chainedObservationLifetime.generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let delivered = try await LavaProtectionCommandService.withProtectionLifecycleDescendantMutation(
                    capturedGeneration: externalRestartGeneration,
                    validateLocalOwnership: {
                        self.isCurrentChainedLifecycleMutation(identity)
                    }
                ) {
                    guard self.isCurrentChainedLifecycleMutation(identity) else {
                        throw ProtectionLifecycleMutationFenceError.ownershipLost
                    }
                    // A missing IPC reply may temporarily hide the claim while
                    // the fence is busy. Leave this start's success available;
                    // never consume it before an actual delivery.
                    switch ChainedConnectLifecyclePolicy.successFeedbackDisposition(
                        state: self.chainedConnectLifecycleState,
                        acceptedGeneration: acceptedObservationGeneration,
                        currentGeneration: self.chainedObservationLifetime.generation,
                        isActive: self.chainedObservationActive && UIApplication.shared.applicationState == .active,
                        hasError: self.guardPanelMessageIsError,
                        status: self.protectionStatus, now: Self.chainedObservationNow) {
                    case .consumeSilently: return true
                    case .retryOnFreshEvidence: return false
                    case .deliver: break
                    }
                    ProtectionHapticFeedback.play(.protectionOnSucceeded)
                    self.logVPNDebugEvent("chained-success-feedback", details: ["connection": String(connection)])
                    self.recordUserInitiatedProtectionOnForReview()
                    return true
                }
                _ = self.reduceChainedConnectLifecycleState(
                    .successFeedbackFinished(connection: connection, retryWhenConfirmed: !delivered))
            } catch {
                // A newer OFF/reconnect/connection or accepted direct Restart owns the outcome.
                // Initial diagnostics already resolved; stale user-visible success stays silent.
                _ = self.reduceChainedConnectLifecycleState(
                    .successFeedbackFinished(connection: connection, retryWhenConfirmed: false))
            }
        }
    }

    private func isCurrentChainedLifecycleMutation(
        _ identity: ChainedLifecycleMutationIdentity,
        armID: UInt64? = nil
    ) -> Bool {
        guard chainedLifecycleMutationIdentity == identity,
              userProtectionIntent.isEnabled,
              userProtectionIntent.revision == identity.protectionIntentRevision,
              !isTearingDownProtection,
              vpnStatus == .connected
        else { return false }
        return armID.map { chainedOnDemandArmID == $0 } ?? true
    }

    /// Starts one reducer-tokened, best-effort arm. Every exit completes the exact token once. The
    /// whole manager load/save stays inside the cross-process fence, and only the exact reducer
    /// connection + arm token + sticky intent revision may publish a confirmed completion.
    /// Predecessor chaining makes the newest tracked handle transitively drain all older saves.
    private func startChainedOnDemandArm(id: UInt64, connection: UInt64) {
        let previous = chainedOnDemandArmTask
        previous?.cancel()
        let identity = chainedLifecycleMutationIdentity

        let task = Task { [self] in
            var confirmed = false
            defer {
                completeChainedOnDemandArm(id: id, confirmed: confirmed)
            }

            await previous?.value
            guard let identity, identity.connection == connection,
                  let externalRestartGeneration = identity.externalRestartGeneration else {
                logVPNDebugEvent("on-demand-arm-skipped", details: [
                    "phase": "skipped", "connection": String(connection),
                    "reason": "connection-or-restart-generation-unavailable",
                ])
                return
            }

            do {
                confirmed = try await LavaProtectionCommandService
                    .withProtectionLifecycleDescendantMutation(
                        capturedGeneration: externalRestartGeneration,
                        validateLocalOwnership: {
                            !Task.isCancelled
                                && self.isCurrentChainedLifecycleMutation(identity, armID: id)
                        }
                    ) {
                        // Every bounded retry loads the saved manager inside the same fence. A
                        // cached manager can be stale after Settings edits or a platform save.
                        var currentManager: NETunnelProviderManager?
                        return try await ProtectionOnDemandArm.perform(
                            validateOwnership: {
                                guard !Task.isCancelled,
                                      self.isCurrentChainedLifecycleMutation(identity, armID: id),
                                      let containerURL = LavaSecAppGroup.containerURL else { return false }
                                return ProtectionRestoreIntentStore.read(containerURL: containerURL)
                                    .resolvedIntent(fallingBackTo: self.userProtectionIntent.isEnabled)
                            },
                            readState: {
                                currentManager = try await self.loadExistingTunnelManager()
                                guard let manager = currentManager else {
                                    return .init(isConnected: false, isArmed: false)
                                }
                                guard self.isCurrentChainedLifecycleMutation(identity, armID: id) else {
                                    throw ProtectionOnDemandArm.Failure.ownershipLost
                                }
                                // Status notifications consult this cached object. Keep it identical
                                // to the manager being saved/reloaded, or a stale false can erase a
                                // just-verified confirmation before the forced reconciliation runs.
                                self.tunnelManager = manager
                                let hasConnectRule = Self.managerHasUniversalOnDemandRule(manager)
                                return .init(isConnected: manager.connection.status == .connected,
                                    isArmed: manager.isOnDemandEnabled && hasConnectRule
                                        && Self.isOnDemandConfirmedEnabled())
                            },
                            saveAndVerify: {
                                guard let manager = currentManager else {
                                    throw ProtectionOnDemandArm.Failure.ownershipLost
                                }
                                try await self.setManagerOnDemand(true, on: manager)
                            },
                            waitBeforeRetry: {
                                try await Task.sleep(nanoseconds: 200_000_000)
                            },
                            recordAttempt: { attempt, phase in
                                self.logVPNDebugEvent("on-demand-arm-attempt", details: [
                                    "attempt": String(attempt), "phase": phase,
                                    "connection": String(connection),
                                ])
                            })
                    }
            } catch {
                // Contention is retried asynchronously by the descendant helper. A cancelled arm,
                // stale reducer token/intent, rotated generation, or coordination failure completes
                // this exact token conservatively so OFF/drain and newer reducer work stay decisive.
                var details = self.errorIdentityDetails(error)
                details["phase"] = "failed"
                details["connection"] = String(connection)
                self.logVPNDebugEvent("on-demand-arm-failed", details: details)
                #if DEBUG || LAVA_QA_TOOLS
                self.logVPNDebugEvent("enable-ondemand-enable-failed", details: [
                    "connection": "\(connection)",
                    "error": String(describing: error)
                ])
                #endif
            }
            logVPNDebugEvent("on-demand-arm-completed", details: [
                "phase": "completed", "connection": String(connection),
                "onDemandConfirmed": String(confirmed),
            ])
        }
        chainedOnDemandArmID = id
        chainedOnDemandArmTask = task
    }

    private func completeChainedOnDemandArm(id: UInt64, confirmed: Bool) {
        if chainedOnDemandArmID == id {
            chainedOnDemandArmID = nil
            chainedOnDemandArmTask = nil
        }
        let effects = reduceChainedConnectLifecycleState(
            .onDemandArmFinished(id: id, confirmed: confirmed))
        executeChainedConnectLifecycleEffects(effects)
    }

    /// Emits reducer suspension only on depth edges, before the teardown performs any await.
    func beginProtectionTeardown() {
        let wasInactive = protectionTeardownDepth == 0
        protectionTeardownDepth += 1
        if wasInactive {
            let effects = reduceChainedConnectLifecycleState(
                .teardownChanged(isActive: true))
            executeChainedConnectLifecycleEffects(effects)
        }
    }

    func endProtectionTeardown() {
        precondition(protectionTeardownDepth > 0)
        protectionTeardownDepth -= 1
        if protectionTeardownDepth == 0 {
            let effects = reduceChainedConnectLifecycleState(
                .teardownChanged(isActive: false))
            executeChainedConnectLifecycleEffects(effects)
        }
    }

    /// Cancels and joins the newest arm. Each arm awaits its predecessor, so this drains the entire
    /// finite save chain; identity checks cannot discard a replacement installed during an await.
    func drainChainedOnDemandArm() async {
        while let task = chainedOnDemandArmTask {
            task.cancel()
            await task.value
            if chainedOnDemandArmTask == task {
                chainedOnDemandArmTask = nil
                chainedOnDemandArmID = nil
            }
        }
    }
}
