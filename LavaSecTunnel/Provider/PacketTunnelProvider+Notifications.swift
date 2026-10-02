@preconcurrency import ActivityKit
import Foundation
import Darwin
import Network
@preconcurrency import NetworkExtension
import Security
@preconcurrency import UserNotifications
import LavaSecChainedUpstream
import LavaSecDNS
import LavaSecFilterPipeline
import LavaSecKit

// One concern of `PacketTunnelProvider`, split out of the former single-file provider.
// Stored state lives in LavaSecTunnel/PacketTunnelProvider.swift (extensions cannot declare
// stored properties, so a property declared beside its concern moved there); the other
// `PacketTunnelProvider+*.swift` files each hold one `// MARK:` section of the class, and the
// remaining files under Provider/ hold the types the single file declared outside it.

extension PacketTunnelProvider {
    // MARK: - Protection notifications & network activity log

    func scheduleProtectionNotificationIfNeeded(now: Date = Date()) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in self?.scheduleProtectionNotificationIfNeeded(now: now) }
            return
        }
        let posture = currentProtectionNotificationPosture(now: now)
        protectionNotificationDelivery.update(posture)
        let defaults = LavaSecAppGroup.sharedDefaults
        LavaSecAppGroup.migrateProtectionNotificationStateIfNeeded(defaults)
        guard let reconciliation = ProtectionConnectivityNotificationStore.reconcile(
            at: LavaSecAppGroup.protectionNotificationHistoryURL,
            legacyHistory: LavaSecAppGroup.legacyProtectionNotificationHistory(in: defaults),
            assessment: posture.assessment, health: posture.health, filteringUnavailable: posture.filteringUnavailable,
            filteringUnavailableSince: posture.filteringUnavailableSince,
            filteringIntervention: posture.filteringIntervention, now: now) else {
            if tunnelLifecycleIsActive,
               let deadline = protectionNotificationDelivery.deferEvaluation(now: now) {
                scheduleProtectionNotificationRetry(at: deadline)
            }
            return
        }
        protectionNotificationDelivery.reconciledHistory()
        let notificationCenter = UNUserNotificationCenter.current()
        Self.removeProtectionNotifications(reconciliation.resolvedIdentifiers, notificationCenter: notificationCenter)
        guard let candidate = reconciliation.notification, protectionNotificationIsPermitted(candidate.kind),
              let attempt = protectionNotificationDelivery.prepare(history: reconciliation.history, now: now,
                  languageCode: LavaNotificationLanguage.pinnedCode(in: defaults)) else { return }
        notificationCenter.getNotificationSettings { [weak self] settings in
            let authorized: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: authorized = true
            default: authorized = false
            }
            guard let self else { return }
            self.dnsStateQueue.async {
                self.protectionNotificationDelivery.update(self.currentProtectionNotificationPosture())
                let history = self.protectionNotificationHistory(defaults: LavaSecAppGroup.sharedDefaults)
                let permitted = authorized && self.protectionNotificationIsPermitted(attempt.notification.kind)
                guard let submission = self.protectionNotificationDelivery.authorized(attempt, permitted: permitted && history != nil,
                    history: history ?? .empty,
                    languageCode: LavaNotificationLanguage.pinnedCode(in: LavaSecAppGroup.sharedDefaults)) else {
                    if permitted {
                        if history != nil { self.scheduleProtectionNotificationIfNeeded() }
                        else if let deadline = self.protectionNotificationDelivery.deferEvaluation() {
                            self.scheduleProtectionNotificationRetry(at: deadline)
                        }
                    }
                    return
                }
                let notification = submission.notification
                let content = UNMutableNotificationContent()
                content.title = notification.title
                content.body = notification.body
                content.interruptionLevel = .passive
                content.userInfo = [
                    LavaSecAppGroup.protectionNotificationRouteUserInfoKeyName: LavaSecAppGroup.protectionNotificationGuardRouteValue,
                    LavaSecAppGroup.protectionNotificationKindUserInfoKeyName: notification.kind.rawValue,
                    LavaSecAppGroup.protectionNotificationIDUserInfoKeyName: notification.identifier
                ]
                let request = UNNotificationRequest(
                    identifier: LavaSecAppGroup.protectionNotificationRequestIdentifier(for: submission.requestIdentifier),
                    content: content, trigger: nil)
                notificationCenter.add(request) { [weak self] error in
                    guard let self else {
                        Self.removeProtectionNotifications([submission.requestIdentifier], notificationCenter: notificationCenter)
                        return
                    }
                    self.dnsStateQueue.async {
                        self.protectionNotificationDelivery.update(self.currentProtectionNotificationPosture())
                        switch self.protectionNotificationDelivery.submitted(submission, succeeded: error == nil,
                            permitted: self.protectionNotificationIsPermitted(notification.kind)) {
                        case .discard(let removeRequest):
                            if removeRequest {
                                Self.removeProtectionNotifications([submission.requestIdentifier], notificationCenter: notificationCenter)
                            }
                            self.scheduleProtectionNotificationIfNeeded()
                        case .retry(let deadline):
                            self.scheduleProtectionNotificationRetry(at: deadline)
                        case .claim(let posture):
                            let claim = ProtectionConnectivityNotificationStore.claimDelivery(
                                notification, requestIdentifier: submission.requestIdentifier, at: LavaSecAppGroup.protectionNotificationHistoryURL,
                                legacyHistory: LavaSecAppGroup.legacyProtectionNotificationHistory(),
                                assessment: posture.assessment, health: posture.health,
                                filteringUnavailable: posture.filteringUnavailable, filteringUnavailableSince: posture.filteringUnavailableSince,
                                filteringIntervention: posture.filteringIntervention)
                            let retry = self.protectionNotificationDelivery.claimed(submission, result: claim,
                                permitted: self.protectionNotificationIsPermitted(notification.kind))
                            switch claim {
                            case .recorded(let identifiers): Self.removeProtectionNotifications(identifiers, notificationCenter: notificationCenter)
                            case .alreadyOwned: break
                            case .refused, nil: Self.removeProtectionNotifications([submission.requestIdentifier], notificationCenter: notificationCenter)
                            }
                            if let retry { self.scheduleProtectionNotificationRetry(at: retry) }
                        }
                    }
                }
            }
        }
    }

    private func scheduleProtectionNotificationRetry(at deadline: Date) {
        dnsStateQueue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) { [weak self] in
            guard let self, self.protectionNotificationDelivery.retryDeadline == deadline else { return }
            self.scheduleProtectionNotificationIfNeeded()
        }
    }

    private func currentProtectionNotificationPosture(now: Date = Date()) -> ProtectionNotificationDeliveryState.Posture {
        let unavailable = currentFilteringUnavailableForNotification()
        if !unavailable { filteringUnavailableNoticeStartedAt = nil }
        var intervention: FilterArtifactIntervention?
        if case .loaded(let configuration) = loadConfigurationClassified() {
            let repairURL = LavaSecAppGroup.containerURL.map { FilterArtifactRepairStatusStore.url(in: $0) }
            intervention = FilterArtifactRecoveryAssessment.assess(
                isServing: !unavailable,
                reloadInFlight: snapshotReloadCoordinator.assumeIsolated { $0.isReloadInFlight },
                configurationIdentity: FilterArtifactRepairStatus.identity(for: configuration,
                    snapshotFingerprint: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil).fingerprint),
                repair: FilterArtifactRepairStatusStore.load(at: repairURL),
                failureStartedAt: filteringUnavailableNoticeStartedAt, now: now).intervention
        }
        return .init(assessment: ProtectionConnectivityPolicy.assessment(isConnected: true, health: health, now: now),
            health: health, filteringUnavailable: unavailable, filteringUnavailableSince: filteringUnavailableNoticeStartedAt,
            filteringIntervention: intervention)
    }

    private func protectionNotificationIsPermitted(_ kind: ProtectionConnectivityNotificationKind) -> Bool {
        let defaults = LavaSecAppGroup.sharedDefaults
        return tunnelLifecycleIsActive && LavaNotificationPreferences.isEnabled(.connectivity, in: defaults)
            && (kind != .filteringUnavailable || !LavaAppForegroundPublication.isForegroundActive(in: defaults))
    }

    /// Debounces actual client impact; triage separately establishes whether the user can help.
    // pinned: PacketTunnelDNSRuntimeSourceTests.testFilterRepairNoticeRequiresFailedRecoveryAndClientImpact
    func recordUnavailableFilteringForNotification(now: Date) {
        guard filteringUnavailableNoticeStartedAt == nil,
              currentFilteringUnavailableForNotification() else { return }
        filteringUnavailableNoticeStartedAt = now
        let lifecycle = tunnelLifecycleGeneration
        dnsStateQueue.asyncAfter(deadline: .now() + ProtectionConnectivityNotificationPolicy.filteringUnavailableGraceInterval) { [weak self] in
            guard let self, self.isCurrentTunnelLifecycle(lifecycle),
                  self.filteringUnavailableNoticeStartedAt == now else { return }
            self.scheduleProtectionNotificationIfNeeded()
        }
    }

    private func currentFilteringUnavailableForNotification() -> Bool {
        guard tunnelLifecycleIsActive else { return false }
        // The pause reader may enter dnsStateQueue, so keep it outside the snapshot lock.
        guard !isTemporaryProtectionPauseActive(synchronizesDefaults: false) else { return false }
        return snapshotQueue.sync { snapshot.blocksEveryLookup && residentFailClosedDueToUnavailableSnapshot }
    }

    private func protectionNotificationHistory(
        defaults: UserDefaults
    ) -> ProtectionConnectivityNotificationHistory? {
        ProtectionConnectivityNotificationStore.load(
            at: LavaSecAppGroup.protectionNotificationHistoryURL,
            legacyHistory: LavaSecAppGroup.legacyProtectionNotificationHistory(in: defaults))
    }

    /// Cancels the current lifecycle's submission and invalidates delayed completions/retries.
    func cancelPendingProtectionNotification() {
        Self.removeProtectionNotifications(protectionNotificationDelivery.invalidate(), notificationCenter: .current())
    }

    private static func removeProtectionNotifications(_ identifiers: [String], notificationCenter: UNUserNotificationCenter) {
        let requestIdentifiers = identifiers.map {
            LavaSecAppGroup.protectionNotificationRequestIdentifier(for: $0)
        }
        guard !requestIdentifiers.isEmpty else { return }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: requestIdentifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: requestIdentifiers)
    }

    func appendNetworkActivity(
        event: NetworkActivityEvent,
        now: Date = Date(),
        frozenHealthContext: ResolverHealthGatewayActivityContext? = nil
    ) {
        let configuration = currentAppConfiguration()
        guard configuration.keepNetworkActivity else {
            return
        }

        guard let networkActivityLogURL else {
            return
        }

        let connectivitySeverity = frozenHealthContext?.connectivitySeverity
            ?? ProtectionConnectivityPolicy.assessment(
                isConnected: true,
                health: health,
                now: now
            ).severity
        let entry = NetworkActivityLogEntry(
            timestamp: now,
            event: event,
            lavaState: LavaStateSnapshot(
                protectionStatus: "Connected",
                connectivityStatus: connectivitySeverity.diagnosticLabel,
                networkKind: frozenHealthContext?.networkKind ?? health.networkKind,
                networkPathIsSatisfied: frozenHealthContext?.networkPathIsSatisfied
                    ?? health.networkPathIsSatisfied,
                resolverDisplayName: configuration.resolverPreset.displayName,
                resolverTransport: frozenHealthContext?.resolverTransport
                    ?? health.lastResolverTransport,
                fallbackToDeviceDNS: configuration.fallbackToDeviceDNS,
                deviceDNSFallbackActive: frozenHealthContext?.deviceDNSFallbackActive
                    ?? currentDeviceDNSFallbackModeActive(),
                usesEncryptedDeviceDNSFallback: configuration.usesEncryptedDeviceDNSFallback,
                // A DEVICE-DNS primary's live fallback is the ENCRYPTED one, and it carries its
                // own severity. `deviceDNSFallbackActive` above tracks `.usingDeviceDNSFallback`,
                // which that episode never sets — so without this term the one state a
                // Device-DNS user most needs to see reports as a mere toggle position
                // (Codex P2, PR #597).
                encryptedFallbackActive: connectivitySeverity == .usingEncryptedFallback,
                // The SELECTED preset's transport, not the frozen/last-used one above — the state
                // line names the toggle the DNS page showed, which follows the selection.
                configuredResolverTransport: configuration.resolverPreset.transport
            )
        )
        // The entry is built synchronously on the calling (DNS-serving) queue from
        // queue-confined state, but the disk write hops off it (CON-1): a serial IO queue
        // + non-blocking bounded lock means a suspended app holding the app-group lock can
        // never wedge DNS. Serial ⇒ entries land in submission (timestamp) order. This is the
        // network-activity queue, kept separate from the incident ledger's (Codex #200 P2).
        let logURL = networkActivityLogURL
        Self.networkActivityLogIOQueue.async {
            // tryAppend = non-blocking + drop-on-contention (tunnel only). The app uses the
            // blocking `append` so its user-action writes are never dropped (CON-1 P2).
            NetworkActivityLogPersistence.tryAppend(entry, to: logURL)
        }
    }
}
