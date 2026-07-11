import Foundation
import LavaSecKit

// Smoke-probe admission, wire execution, and query matching remain provider-owned.
// This reducer receives one already-classified completion and owns only evidence
// mutation plus the ordered semantic work that must follow the projection commit.

enum ResolverSmokeEvidenceReducer {
    static func reduce(
        state: ResolverHealthEvidenceState,
        evidence: ResolverSmokeProbeEvidence,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthTransition {
        var next = state

        next.session.lastDNSSmokeProbeAt = evidence.occurredAt
        switch evidence.outcome {
        case .primaryAccepted(let accepted):
            return reduceAcceptedPrimary(
                state: &next,
                evidence: evidence,
                accepted: accepted,
                projectingOnto: snapshot
            )

        case .deviceDNSFallbackAccepted(let accepted):
            return reduceAcceptedFallback(
                state: &next,
                evidence: evidence,
                accepted: accepted,
                projectingOnto: snapshot
            )

        case .neitherAccepted(let failure):
            return reduceFailure(
                state: &next,
                evidence: evidence,
                failure: failure,
                projectingOnto: snapshot
            )
        }
    }

    private static func reduceAcceptedPrimary(
        state: inout ResolverHealthEvidenceState,
        evidence: ResolverSmokeProbeEvidence,
        accepted: ResolverSmokeProbeEvidence.PrimaryAccepted,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthTransition {
        let previousSmokeSucceeded = state.session.lastDNSSmokeProbeSucceeded
        let wasFallbackModeActive = state.episode.deviceDNSFallbackModeActive
        state.session.lastDNSSmokeProbeSucceeded = true
        state.session.dnsSmokeProbeSuccessCount += 1
        state.episode.consecutiveSmokeProbeFailureCount = 0
        state.episode.consecutiveUpstreamFailureCount = 0
        state.episode.deviceDNSFallbackEvidenceCount = 0
        state.episode.deviceDNSFallbackModeActive = false
        state.episode.lastDeviceDNSFallbackActivatedAt = nil
        state.episode.lastEncryptedFallbackSuccessAt = nil
        state.identity.rejectedResponseCount = 0
        state.identity.rejectedResponseResolverIdentifier = nil
        if evidence.reason != "periodic-health-check", evidence.reason != "startTunnel" {
            state.episode.lastAcceptedPrimaryEvidenceAt = evidence.occurredAt
        }
        state.episode.lastFailureReason = nil
        state.session.lastResolverAddress = accepted.resolverAddress
        state.session.lastResolverTransport = accepted.transport
        if accepted.transport == .dnsOverHTTPS,
            let negotiatedDoHProtocol = accepted.dohHTTPVersion
        {
            state.session.lastDoHHTTPVersion = negotiatedDoHProtocol
        }

        var effects: [ResolverHealthEffect] = [
            .endEncryptedFallbackLogEpisode(.episodeEnd)
        ]
        if let recovery = ResolverHealthTransitionSupport.takeRecovery(
            from: &state,
            transport: accepted.transport,
            recoveredAt: evidence.occurredAt,
            verifiedBy: "smoke-probe",
            projectingOnto: snapshot
        ) {
            effects.append(.reportConnectivityRecovery(recovery))
        }
        state.effectDelivery.lastReconnectNeededActivityAt = nil
        effects.append(contentsOf: [
            .creditProductiveSelfReconnect(at: evidence.occurredAt),
            .cancelWedgeRecoveryProbe,
            .clearDeviceDNSRecaptureRestartPending,
            .cancelFallbackRecoveryProbe,
        ])
        if wasFallbackModeActive {
            effects.append(
                .requestResolverRuntimeReset(
                    .full(reason: "device-dns-fallback-recovered", force: true)
                )
            )
        }
        effects.append(contentsOf: [
            .signalConnectivityProjectionChanged,
            .persistHealth(.deferred),
        ])
        if wasFallbackModeActive {
            effects.append(
                .appendNetworkActivity(.deviceDNSFallbackRecovered, at: evidence.occurredAt)
            )
        } else if evidence.reason == "network-path-changed" || previousSmokeSucceeded == false {
            effects.append(
                .appendNetworkActivity(
                    .dnsSmokeProbeSucceeded(
                        resolver: evidence.configuredResolverDisplayName,
                        transport: accepted.transport,
                        dohHTTPVersion: accepted.dohHTTPVersion
                    ),
                    at: evidence.occurredAt
                )
            )
        }
        effects.append(.evaluateProtectionNotification(at: evidence.occurredAt))
        if wasFallbackModeActive {
            effects.append(
                .deliverPendingResolverFailures(reason: "device-dns-fallback-recovered")
            )
        }
        effects.append(
            .evaluateQAConnectivityLog(reason: "dns-smoke-probe-success", at: evidence.occurredAt)
        )
        effects.append(
            .deviceLog(
                .smokeProbeSucceeded(
                    reason: evidence.reason,
                    transport: accepted.transport,
                    resolverAddress: accepted.resolverAddress,
                    dohHTTPVersion: accepted.dohHTTPVersion,
                    occurredAt: evidence.occurredAt
                )
            )
        )
        return ResolverHealthTransitionSupport.transition(state: state, effects: effects)
    }

    private static func reduceAcceptedFallback(
        state: inout ResolverHealthEvidenceState,
        evidence: ResolverSmokeProbeEvidence,
        accepted: ResolverSmokeProbeEvidence.DeviceDNSFallbackAccepted,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthTransition {
        let wasFallbackModeActive = state.episode.deviceDNSFallbackModeActive
        state.session.lastDNSSmokeProbeSucceeded = true
        state.session.dnsSmokeProbeSuccessCount += 1
        state.episode.consecutiveSmokeProbeFailureCount = 0
        state.episode.consecutiveUpstreamFailureCount = 0
        state.episode.deviceDNSFallbackEvidenceCount =
            DeviceDNSFallbackPolicy.nextConsecutiveFallbackEvidenceCount(
                currentCount: state.episode.deviceDNSFallbackEvidenceCount,
                primaryResolverWasAttempted:
                    accepted.primaryHadFallbackActivationEvidence
            )
        // Organic total failures reset candidate evidence without exiting an already
        // active mode. Only an explicit primary recovery or failed smoke probe exits it.
        let fallbackModeActive =
            wasFallbackModeActive
            || DeviceDNSFallbackPolicy.shouldActivateFallbackMode(
                consecutiveQueryFallbackSuccesses: state.episode.deviceDNSFallbackEvidenceCount
            )
        state.episode.deviceDNSFallbackModeActive = fallbackModeActive
        let activatedFallbackMode = fallbackModeActive && !wasFallbackModeActive
        if activatedFallbackMode {
            state.episode.lastDeviceDNSFallbackActivatedAt = evidence.occurredAt
            state.session.deviceDNSFallbackActivationCount += 1
        } else if fallbackModeActive,
            state.episode.lastDeviceDNSFallbackActivatedAt == nil
        {
            state.episode.lastDeviceDNSFallbackActivatedAt = evidence.occurredAt
        }
        state.episode.lastFailureReason = nil
        state.session.lastResolverAddress = accepted.resolverAddress
        state.session.lastResolverTransport = .deviceDNS

        var effects: [ResolverHealthEffect] = []
        if let recovery = ResolverHealthTransitionSupport.takeRecovery(
            from: &state,
            transport: .deviceDNS,
            recoveredAt: evidence.occurredAt,
            verifiedBy: "smoke-probe",
            projectingOnto: snapshot
        ) {
            effects.append(.reportConnectivityRecovery(recovery))
            effects.append(.endEncryptedFallbackLogEpisode(.episodeEnd))
        }
        state.effectDelivery.lastReconnectNeededActivityAt = nil
        effects.append(contentsOf: [
            .creditProductiveSelfReconnect(at: evidence.occurredAt),
            .cancelWedgeRecoveryProbe,
            .clearDeviceDNSRecaptureRestartPending,
        ])
        if fallbackModeActive {
            effects.append(
                .requestResolverRuntimeReset(
                    .full(reason: "device-dns-fallback-activated", force: true)
                )
            )
        }
        effects.append(.signalConnectivityProjectionChanged)
        if activatedFallbackMode {
            effects.append(
                .appendNetworkActivity(
                    .deviceDNSFallbackActivated(reason: evidence.reason),
                    at: evidence.occurredAt
                )
            )
        }
        effects.append(.scheduleFallbackRecoveryProbe)
        if fallbackModeActive {
            effects.append(.evaluateProtectionNotification(at: evidence.occurredAt))
        }
        effects.append(.persistHealth(.immediate))
        if fallbackModeActive {
            effects.append(
                .deliverPendingResolverFailures(reason: "device-dns-fallback-activated")
            )
        }
        effects.append(
            .evaluateQAConnectivityLog(
                reason: fallbackModeActive
                    ? "device-dns-fallback-activated"
                    : "device-dns-fallback-candidate",
                at: evidence.occurredAt
            )
        )
        effects.append(
            .deviceLog(
                .smokeProbeDeviceFallback(
                    reason: evidence.reason,
                    evidenceCount: state.episode.deviceDNSFallbackEvidenceCount,
                    fallbackModeActive: fallbackModeActive,
                    resolverAddress: accepted.resolverAddress,
                    occurredAt: evidence.occurredAt
                )
            )
        )
        return ResolverHealthTransitionSupport.transition(state: state, effects: effects)
    }

    private static func reduceFailure(
        state: inout ResolverHealthEvidenceState,
        evidence: ResolverSmokeProbeEvidence,
        failure: ResolverSmokeProbeEvidence.Failure,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthTransition {
        let wasFallbackModeActive = state.episode.deviceDNSFallbackModeActive
        state.session.lastDNSSmokeProbeSucceeded = false
        state.session.dnsSmokeProbeFailureCount += 1
        state.episode.consecutiveSmokeProbeFailureCount =
            DeviceDNSFallbackPolicy.nextConsecutiveSmokeProbeFailureCount(
                current: state.episode.consecutiveSmokeProbeFailureCount
            )

        var effects: [ResolverHealthEffect] = []
        if wasFallbackModeActive {
            state.episode.deviceDNSFallbackModeActive = false
            state.episode.lastDeviceDNSFallbackActivatedAt = nil
            state.episode.deviceDNSFallbackEvidenceCount = 0
        }

        let failureReason: String
        switch failure.kind {
        case .rejectedResponse:
            failureReason = "rejected-response"
        case .transport(let reason):
            failureReason = reason
        }
        state.episode.lastFailureReason = failureReason
        state.session.lastUpstreamFailureAt = evidence.occurredAt
        state.episode.consecutiveUpstreamFailureCount += 1
        state.session.lastResolverAddress = failure.resolverAddress
        state.session.lastResolverTransport = failure.transport

        if wasFallbackModeActive {
            effects.append(.cancelFallbackRecoveryProbe)
        }

        if failureReason == "rejected-response" {
            if state.identity.rejectedResponseResolverIdentifier
                == evidence.modeInsensitivePrimaryIdentifier
            {
                state.identity.rejectedResponseCount += 1
            } else {
                state.identity.rejectedResponseResolverIdentifier =
                    evidence.modeInsensitivePrimaryIdentifier
                state.identity.rejectedResponseCount = 1
                state.session.rejectedResponseRescopeCount += 1
            }
            if state.identity.rejectedResponseCount
                == ProtectionConnectivityPolicy.sustainedRejectedSmokeResponseThreshold
            {
                effects.append(
                    .recordIncident(
                        ResolverHealthIncident(
                            kind: .rejectedResponseStreak,
                            occurredAt: evidence.occurredAt,
                            reason: "rejected-response",
                            durationMilliseconds: nil,
                            verifiedBy: nil
                        )
                    )
                )
            }
        }

        effects.append(contentsOf: [
            .signalConnectivityProjectionChanged,
            .persistHealth(.deferred),
            .appendNetworkActivity(
                .dnsSmokeProbeFailed(reason: failureReason),
                at: evidence.occurredAt
            ),
        ])

        ResolverHealthTransitionSupport.appendReconnectEffects(
            to: &effects,
            state: &state,
            projectingOnto: snapshot,
            at: evidence.occurredAt,
            rearmWedgeProbeForExistingEvidence: true
        )
        effects.append(.evaluateProtectionNotification(at: evidence.occurredAt))
        effects.append(
            .evaluateQAConnectivityLog(reason: "dns-smoke-probe-failed", at: evidence.occurredAt)
        )
        effects.append(
            .deviceLog(
                .smokeProbeFailed(
                    reason: evidence.reason,
                    failure: failureReason,
                    consecutiveSmokeFailures: state.episode.consecutiveSmokeProbeFailureCount,
                    consecutiveRejectedResponses: state.identity.rejectedResponseCount,
                    occurredAt: evidence.occurredAt
                )
            )
        )
        return ResolverHealthTransitionSupport.transition(state: state, effects: effects)
    }
}
