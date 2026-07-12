import Foundation
import LavaSecKit

// Resolver execution/backoff and the provider-owned network-kind envelope update
// remain caller-owned. This reducer consumes one completed result summary and owns
// only session/episode evidence plus ordered semantic effects.

// Organic response bytes are classified once at the provider boundary. Resolution
// is a sum type: only a selected-resolver response has a quality bar, so fallback
// carriers cannot accidentally be interpreted as primary health evidence.
struct ResolverOrganicUpstreamEvidence: Equatable, Sendable {
    enum ResponseQuality: Equatable, Sendable {
        case acceptedAnswer
        case servedAnswer
        case clientFailureResponse
    }

    enum Resolution: Equatable, Sendable {
        case selectedResolver(ResponseQuality)
        case encryptedFallback
        case deviceDNSFallback(primaryHadFallbackActivationEvidence: Bool)
    }

    enum AttemptOutcome: Equatable, Sendable {
        case success
        case timeout
        case httpStatusFailure
        case otherFailure

        init(_ outcome: ResolverAttemptOutcome) {
            switch outcome {
            case .success:
                self = .success
            case .timeout:
                self = .timeout
            case .httpStatusFailure:
                self = .httpStatusFailure
            case .backedOff,
                .sendFailed,
                .receiveFailed,
                .invalidAddress,
                .unsupported,
                .socketUnavailable,
                .mismatchedResponse,
                .deviceDNSUnavailable:
                self = .otherFailure
            }
        }
    }

    struct Attempt: Equatable, Sendable {
        let address: String
        let outcome: AttemptOutcome
        let transport: DNSResolverTransport
        let negotiatedDoHProtocol: String?
    }

    enum Outcome: Equatable, Sendable {
        case totalFailure(reason: String?)
        case resolved(Resolution)
    }

    let occurredAt: Date
    let outcome: Outcome
    let successfulResolverAddress: String?
    let observedResolverAddress: String?
    let transport: DNSResolverTransport
    let durationMilliseconds: Int?
    let udpTruncated: Bool
    let tcpFallbackAttempted: Bool
    let tcpFallbackSucceeded: Bool
    let deviceDNSFallbackAttempted: Bool
    let deviceDNSUnavailable: Bool
    let attempts: [Attempt]

    init(occurredAt: Date, result: DNSResolutionResult) {
        self.occurredAt = occurredAt
        successfulResolverAddress = result.successfulResolverAddress
        observedResolverAddress =
            result.successfulResolverAddress
            ?? result.attempts.last?.address
        transport = result.transport
        durationMilliseconds = result.durationMilliseconds
        udpTruncated = result.udpTruncated
        tcpFallbackAttempted = result.tcpFallbackAttempted
        tcpFallbackSucceeded = result.tcpFallbackSucceeded
        deviceDNSFallbackAttempted = result.deviceDNSFallbackAttempted
        deviceDNSUnavailable = result.deviceDNSUnavailable
        attempts = result.attempts.map { attempt in
            Attempt(
                address: attempt.address,
                outcome: AttemptOutcome(attempt.outcome),
                transport: attempt.transport,
                negotiatedDoHProtocol: attempt.negotiatedDoHProtocol
            )
        }

        guard result.response != nil else {
            outcome = .totalFailure(reason: result.failureSummary)
            return
        }

        let resolution: Resolution
        if result.usedEncryptedFallback {
            resolution = .encryptedFallback
        } else if result.deviceDNSFallbackSucceeded {
            resolution = .deviceDNSFallback(
                primaryHadFallbackActivationEvidence:
                    result.hasFallbackActivationEvidence
            )
        } else {
            let responseQuality: ResponseQuality
            if DNSResolverSmokeProbe.indicatesAcceptedAnswer(result.response) {
                responseQuality = .acceptedAnswer
            } else if DNSResolverSmokeProbe.indicatesServedAnswer(result.response) {
                responseQuality = .servedAnswer
            } else {
                responseQuality = .clientFailureResponse
            }
            resolution = .selectedResolver(responseQuality)
        }
        outcome = .resolved(resolution)
    }
}

enum ResolverOrganicEvidenceReducer {
    private static let encryptedFallbackCoverageClearFailureThreshold = 3
    private static let slowUpstreamResponseThresholdMilliseconds = 2_500

    static func reduce(
        state: ResolverHealthEvidenceState,
        evidence: ResolverOrganicUpstreamEvidence,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthTransition {
        var next = state
        next.session.lastResolverAddress = evidence.observedResolverAddress
        next.session.lastResolverTransport = evidence.transport
        next.session.lastUpstreamDurationMilliseconds = evidence.durationMilliseconds

        switch evidence.outcome {
        case .totalFailure(let reason):
            return reduceTotalFailure(
                state: &next,
                evidence: evidence,
                reason: reason,
                projectingOnto: snapshot
            )

        case .resolved(let resolution):
            return reduceResolved(
                state: &next,
                evidence: evidence,
                resolution: resolution,
                projectingOnto: snapshot
            )
        }
    }

    private static func reduceTotalFailure(
        state: inout ResolverHealthEvidenceState,
        evidence: ResolverOrganicUpstreamEvidence,
        reason: String?,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthTransition {
        // INV-DNS-4: candidate evidence resets on a total failure, but an active network-
        // episode mode stays latched until recovery or a real context reset.
        // pinned: ResolverHealthSmokeEvidenceTests.testActiveFallbackModeRemainsStickyAfterOrganicFailureClearsCandidateCount
        state.episode.deviceDNSFallbackEvidenceCount = 0
        state.session.consecutiveSlowUpstreamResponseCount = 0
        state.session.upstreamFailureCount += 1
        state.episode.consecutiveUpstreamFailureCount += 1
        state.episode.lastFailureReason = reason
        state.session.lastUpstreamFailureAt = evidence.occurredAt
        state.episode.consecutiveCarriedQueryFailureCount += 1
        if state.episode.consecutiveCarriedQueryFailureCount
            >= encryptedFallbackCoverageClearFailureThreshold
        {
            state.episode.lastEncryptedFallbackSuccessAt = nil
        }
        state.episode.lastAcceptedPrimaryEvidenceAt = nil
        applyAttemptMetrics(evidence, to: &state)

        var effects: [ResolverHealthEffect] = [
            .signalConnectivityProjectionChanged,
            .persistHealth(.deferred),
        ]
        ResolverHealthTransitionSupport.appendReconnectEffects(
            to: &effects,
            state: &state,
            projectingOnto: snapshot,
            at: evidence.occurredAt,
            rearmWedgeProbeForExistingEvidence: false
        )
        effects.append(
            .evaluateQAConnectivityLog(reason: "upstream-failure", at: evidence.occurredAt)
        )
        return ResolverHealthTransitionSupport.transition(state: state, effects: effects)
    }

    private static func reduceResolved(
        state: inout ResolverHealthEvidenceState,
        evidence: ResolverOrganicUpstreamEvidence,
        resolution: ResolverOrganicUpstreamEvidence.Resolution,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthTransition {
        let wasFallbackModeActive = state.episode.deviceDNSFallbackModeActive
        let isDeviceDNSQueryFallback: Bool
        if case .deviceDNSFallback = resolution {
            isDeviceDNSQueryFallback = true
        } else {
            isDeviceDNSQueryFallback = false
        }
        state.session.upstreamSuccessCount += 1
        state.session.lastUpstreamSuccessAt = evidence.occurredAt
        state.episode.lastFailureReason = nil
        state.episode.consecutiveUpstreamFailureCount = 0
        state.episode.consecutiveCarriedQueryFailureCount = 0

        var effects: [ResolverHealthEffect] = []
        var endedFallbackLogEpisode = false
        var activatedFallbackMode = false
        switch resolution {
        case .encryptedFallback:
            state.episode.lastAcceptedPrimaryEvidenceAt = nil
            state.episode.lastEncryptedFallbackSuccessAt = evidence.occurredAt
            effects.append(.scheduleWedgeRecoveryProbe)

        case .selectedResolver(let responseQuality):
            let resolvedThroughFallbackMode =
                evidence.transport == .deviceDNS && wasFallbackModeActive
            if !resolvedThroughFallbackMode {
                applySelectedPrimaryEvidence(
                    responseQuality,
                    occurredAt: evidence.occurredAt,
                    to: &state
                )
                state.episode.lastEncryptedFallbackSuccessAt = nil
            }
            endedFallbackLogEpisode = appendNonEncryptedRecoveryEffects(
                to: &effects,
                state: &state,
                transport: evidence.transport,
                recoveredAt: evidence.occurredAt,
                projectingOnto: snapshot
            )

        case .deviceDNSFallback(let primaryHadFallbackActivationEvidence):
            endedFallbackLogEpisode = appendNonEncryptedRecoveryEffects(
                to: &effects,
                state: &state,
                transport: evidence.transport,
                recoveredAt: evidence.occurredAt,
                projectingOnto: snapshot
            )
            state.episode.lastAcceptedPrimaryEvidenceAt = nil
            state.session.deviceDNSFallbackSuccessCount += 1
            state.episode.deviceDNSFallbackEvidenceCount =
                DeviceDNSFallbackPolicy.nextConsecutiveFallbackEvidenceCount(
                    currentCount: state.episode.deviceDNSFallbackEvidenceCount,
                    primaryResolverWasAttempted:
                        primaryHadFallbackActivationEvidence
                )
            if wasFallbackModeActive {
                state.episode.deviceDNSFallbackModeActive = true
            } else if DeviceDNSFallbackPolicy.shouldActivateFallbackMode(
                consecutiveQueryFallbackSuccesses:
                    state.episode.deviceDNSFallbackEvidenceCount
            ) {
                state.episode.deviceDNSFallbackModeActive = true
                state.episode.lastDeviceDNSFallbackActivatedAt = evidence.occurredAt
                state.session.deviceDNSFallbackActivationCount += 1
                activatedFallbackMode = true
            }
        }

        applyLatencyMetrics(evidence, to: &state)
        if !isDeviceDNSQueryFallback, evidence.transport != .deviceDNS {
            state.episode.deviceDNSFallbackEvidenceCount = 0
        }
        applyAttemptMetrics(evidence, to: &state)

        let recoveredFallbackMode: Bool
        if wasFallbackModeActive,
            evidence.transport != .deviceDNS,
            !isDeviceDNSQueryFallback
        {
            state.episode.deviceDNSFallbackModeActive = false
            state.episode.lastDeviceDNSFallbackActivatedAt = nil
            state.episode.deviceDNSFallbackEvidenceCount = 0
            effects.append(.cancelFallbackRecoveryProbe)
            recoveredFallbackMode = true
        } else {
            recoveredFallbackMode = false
        }

        effects.append(contentsOf: [
            .signalConnectivityProjectionChanged,
            .persistHealth(.deferred),
        ])
        if recoveredFallbackMode {
            effects.append(
                .appendNetworkActivity(.deviceDNSFallbackRecovered, at: evidence.occurredAt)
            )
        }
        if activatedFallbackMode {
            effects.append(
                .appendNetworkActivity(
                    .deviceDNSFallbackActivated(reason: "query-fallback"),
                    at: evidence.occurredAt
                )
            )
        }
        if isDeviceDNSQueryFallback {
            effects.append(.scheduleFallbackRecoveryProbe)
        }
        switch resolution {
        case .encryptedFallback:
            effects.append(
                .recordEncryptedFallbackCarry(
                    ResolverEncryptedFallbackCarry(
                        occurredAt: evidence.occurredAt,
                        transport: evidence.transport,
                        resolverAddress: evidence.successfulResolverAddress
                    )
                )
            )
        case .selectedResolver,
            .deviceDNSFallback:
            break
        }
        if case .selectedResolver = resolution,
            !endedFallbackLogEpisode
        {
            effects.append(.endEncryptedFallbackLogEpisode(.episodeEnd))
        }
        effects.append(
            .evaluateQAConnectivityLog(reason: "upstream-success", at: evidence.occurredAt)
        )
        effects.append(.evaluateProtectionNotification(at: evidence.occurredAt))
        return ResolverHealthTransitionSupport.transition(state: state, effects: effects)
    }

    private static func applySelectedPrimaryEvidence(
        _ responseQuality: ResolverOrganicUpstreamEvidence.ResponseQuality,
        occurredAt: Date,
        to state: inout ResolverHealthEvidenceState
    ) {
        switch responseQuality {
        case .acceptedAnswer:
            state.session.lastPrimaryUpstreamSuccessAt = occurredAt
            state.episode.lastAcceptedPrimaryEvidenceAt = occurredAt
            state.episode.consecutiveSmokeProbeFailureCount = 0
        case .servedAnswer:
            state.session.lastPrimaryUpstreamSuccessAt = occurredAt
            state.episode.consecutiveSmokeProbeFailureCount = 0
        case .clientFailureResponse:
            state.episode.lastAcceptedPrimaryEvidenceAt = nil
        }
    }

    private static func appendNonEncryptedRecoveryEffects(
        to effects: inout [ResolverHealthEffect],
        state: inout ResolverHealthEvidenceState,
        transport: DNSResolverTransport,
        recoveredAt: Date,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> Bool {
        var endedFallbackLogEpisode = false
        if let recovery = ResolverHealthTransitionSupport.takeRecovery(
            from: &state,
            transport: transport,
            recoveredAt: recoveredAt,
            verifiedBy: "forwarding",
            projectingOnto: snapshot
        ) {
            effects.append(.reportConnectivityRecovery(recovery))
            effects.append(.endEncryptedFallbackLogEpisode(.episodeEnd))
            endedFallbackLogEpisode = true
        }
        state.effectDelivery.lastReconnectNeededActivityAt = nil
        effects.append(.cancelWedgeRecoveryProbe)
        effects.append(.clearDeviceDNSRecaptureRestartPending)
        return endedFallbackLogEpisode
    }

    private static func applyLatencyMetrics(
        _ evidence: ResolverOrganicUpstreamEvidence,
        to state: inout ResolverHealthEvidenceState
    ) {
        // Fold resolved-query round-trip latency into the session histogram AND record it
        // as the last *successful* response duration for the Nerd Stats rows
        // (plans/2026-07-11-nerd-stats-dns-latency-plan.md). Only resolved queries reach
        // here (reduceResolved), matching the slow-response metrics below — total failures
        // stay in the failure counters and never skew the distribution or the "Last DNS
        // response" row. `lastUpstreamDurationMilliseconds` (set for failures too, earlier)
        // is a separate raw "what just happened" readout and is unaffected.
        if let durationMilliseconds = evidence.durationMilliseconds {
            state.session.upstreamLatencyHistogram.record(durationMilliseconds: durationMilliseconds)
            state.session.lastUpstreamSuccessDurationMilliseconds = durationMilliseconds
        }
        if let durationMilliseconds = evidence.durationMilliseconds,
            durationMilliseconds >= slowUpstreamResponseThresholdMilliseconds
        {
            state.session.slowUpstreamResponseCount += 1
            state.session.consecutiveSlowUpstreamResponseCount += 1
            state.session.lastSlowUpstreamResponseAt = evidence.occurredAt
        } else {
            state.session.consecutiveSlowUpstreamResponseCount = 0
        }
    }

    private static func applyAttemptMetrics(
        _ evidence: ResolverOrganicUpstreamEvidence,
        to state: inout ResolverHealthEvidenceState
    ) {
        if evidence.udpTruncated {
            state.session.udpTruncatedResponseCount += 1
        }
        if evidence.tcpFallbackAttempted {
            state.session.tcpFallbackAttemptCount += 1
        }
        if evidence.tcpFallbackSucceeded {
            state.session.tcpFallbackSuccessCount += 1
        }
        if evidence.deviceDNSFallbackAttempted {
            state.session.deviceDNSFallbackAttemptCount += 1
        }
        if evidence.deviceDNSUnavailable {
            state.session.deviceDNSUnavailableCount += 1
        }

        for attempt in evidence.attempts {
            state.session.resolverAttemptCounts[attempt.address, default: 0] += 1
            switch attempt.outcome {
            case .success:
                state.session.resolverSuccessCounts[attempt.address, default: 0] += 1
                if attempt.transport == .dnsOverHTTPS,
                    let negotiatedDoHProtocol = attempt.negotiatedDoHProtocol
                {
                    state.session.lastDoHHTTPVersion = negotiatedDoHProtocol
                }
            case .timeout:
                state.session.upstreamTimeoutCount += 1
                state.session.resolverFailureCounts[attempt.address, default: 0] += 1
            case .httpStatusFailure:
                state.session.dohHTTPFailureCount += 1
                state.session.resolverFailureCounts[attempt.address, default: 0] += 1
            case .otherFailure:
                state.session.resolverFailureCounts[attempt.address, default: 0] += 1
            }
        }
    }

}
