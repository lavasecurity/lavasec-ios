import Foundation
import LavaSecKit

// Recovery capture and reconnect escalation are shared by smoke and organic
// evidence. Keeping their clocks, throttles, and incident ordering here prevents
// the two event families from drifting as provider wiring evolves.

enum ResolverHealthTransitionSupport {
    private static let reconnectActivityReminderInterval: TimeInterval = 300

    static func transition(
        state: ResolverHealthEvidenceState,
        effects: [ResolverHealthEffect]
    ) -> ResolverHealthTransition {
        ResolverHealthTransition(
            state: state,
            projection: ResolverHealthSnapshotProjection(state: state),
            effects: effects
        )
    }

    static func takeRecovery(
        from state: inout ResolverHealthEvidenceState,
        transport: DNSResolverTransport,
        recoveredAt: Date,
        verifiedBy: String,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthRecovery? {
        guard let episode = state.reconnectEpisode else {
            return nil
        }
        var activityHealth = snapshot
        ResolverHealthSnapshotProjection(state: state).apply(to: &activityHealth)
        let activityContext = ResolverHealthActivityContext(
            connectivitySeverity: ProtectionConnectivityPolicy.assessment(
                isConnected: true,
                health: activityHealth,
                now: recoveredAt
            ).severity,
            networkKind: activityHealth.networkKind,
            networkPathIsSatisfied: activityHealth.networkPathIsSatisfied,
            resolverTransport: activityHealth.lastResolverTransport,
            deviceDNSFallbackActive: activityHealth.deviceDNSFallbackModeActive
        )
        state.reconnectEpisode = nil
        return ResolverHealthRecovery(
            startedAt: episode.startedAt,
            recoveredAt: recoveredAt,
            durationMilliseconds: max(
                0,
                Int((recoveredAt.timeIntervalSince(episode.startedAt) * 1_000).rounded())
            ),
            reason: episode.reason,
            peakUpstreamFailureCount: episode.peakUpstreamFailureCount,
            transport: transport,
            verifiedBy: verifiedBy,
            activityContext: activityContext
        )
    }

    static func appendReconnectEffects(
        to effects: inout [ResolverHealthEffect],
        state: inout ResolverHealthEvidenceState,
        projectingOnto snapshot: TunnelHealthSnapshot,
        at occurredAt: Date,
        rearmWedgeProbeForExistingEvidence: Bool
    ) {
        var projectedHealth = snapshot
        ResolverHealthSnapshotProjection(state: state).apply(to: &projectedHealth)
        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: projectedHealth,
            now: occurredAt
        )

        var scheduledWedgeRecovery = false
        if assessment.primaryAction == .reconnect {
            if state.reconnectEpisode == nil {
                let reason = state.episode.lastFailureReason ?? "upstream-failed"
                state.reconnectEpisode = ResolverReconnectEpisodeEvidence(
                    startedAt: occurredAt,
                    reason: reason,
                    peakUpstreamFailureCount: state.episode.consecutiveUpstreamFailureCount
                )
                effects.append(
                    .recordIncident(
                        ResolverHealthIncident(
                            kind: .wedgeDetected,
                            occurredAt: occurredAt,
                            reason: reason,
                            durationMilliseconds: nil,
                            verifiedBy: nil
                        )
                    )
                )
            }
            if var reconnectEpisode = state.reconnectEpisode {
                reconnectEpisode.peakUpstreamFailureCount = max(
                    reconnectEpisode.peakUpstreamFailureCount,
                    state.episode.consecutiveUpstreamFailureCount
                )
                state.reconnectEpisode = reconnectEpisode
            }

            let shouldAppendReconnectActivity =
                state.effectDelivery.lastReconnectNeededActivityAt.map {
                    occurredAt.timeIntervalSince($0) >= reconnectActivityReminderInterval
                } ?? true
            if shouldAppendReconnectActivity {
                effects.append(
                    .appendNetworkActivity(
                        .reconnectNeeded(
                            reason: state.episode.lastFailureReason ?? "upstream-failed"
                        ),
                        at: occurredAt
                    )
                )
                state.effectDelivery.lastReconnectNeededActivityAt = occurredAt
            }
            effects.append(.evaluateSelfReconnect(at: occurredAt))
            effects.append(.scheduleWedgeRecoveryProbe)
            scheduledWedgeRecovery = true
        }

        // A failed smoke probe may be the recovery probe that just consumed the
        // pending timer, so it explicitly re-arms an existing marker/coverage loop.
        // Organic forwarding failures preserve the provider's assessment-only arm.
        if rearmWedgeProbeForExistingEvidence,
            !scheduledWedgeRecovery,
            state.reconnectEpisode != nil
                || ProtectionConnectivityPolicy.isEncryptedFallbackCarryingWedge(
                    health: projectedHealth,
                    now: occurredAt
                )
        {
            effects.append(.scheduleWedgeRecoveryProbe)
        }
    }
}
