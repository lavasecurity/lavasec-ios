import Foundation
import LavaSecKit

// INV-DNS-4: Resolver health separates identity, network-episode, and tunnel-session
// state. Rejected-response identity evidence survives network churn until a primary
// identity change or accepted-primary recovery. Episode evidence follows the current
// runtime/network context. Session state combines tunnel-lifetime cumulative metrics
// with runtime-scoped observations; the tested reset matrix defines each boundary.
// pinned: ResolverHealthEvidenceTests.testMeaningfulNetworkChangeThenRuntimeResetClearsEpisodeButPreservesIdentityAndSession
// pinned: ResolverHealthSmokeEvidenceTests.testAcceptedPrimaryClearsScopedEvidenceAndCapturesRecoveryBeforeReset

struct ResolverIdentityEvidence: Equatable, Sendable {
    var primaryIdentifier: String?
    var rejectedResponseCount = 0
    var rejectedResponseResolverIdentifier: String?
}

struct ResolverNetworkEpisodeEvidence: Equatable, Sendable {
    var lastFailureReason: String?
    var consecutiveUpstreamFailureCount = 0
    var consecutiveSmokeProbeFailureCount = 0
    var deviceDNSFallbackEvidenceCount = 0
    var deviceDNSFallbackModeActive = false
    var lastDeviceDNSFallbackActivatedAt: Date?
    var consecutiveCarriedQueryFailureCount = 0
    var lastEncryptedFallbackSuccessAt: Date?
    var lastAcceptedPrimaryEvidenceAt: Date?
}

struct ResolverTunnelSessionEvidence: Equatable, Sendable {
    var networkPathIsSatisfied = true
    var lastResolverAddress: String?
    var lastResolverTransport: DNSResolverTransport = .plainDNS
    var lastDoHHTTPVersion: String?
    var lastDNSSmokeProbeAt: Date?
    var lastDNSSmokeProbeSucceeded: Bool?
    var dnsSmokeProbeSuccessCount = 0
    var lastUpstreamFailureAt: Date?
    var lastNetworkChangeAt: Date?
    var networkChangeCount = 0
    var lastResolverRuntimeResetAt: Date?
    var lastResolverRuntimeResetReason: String?
    var lastResolverIdentityChangeAt: Date?
    var resolverRuntimeResetCount = 0
    var rejectedResponseRescopeCount = 0
    var dnsSmokeProbeFailureCount = 0
    var deviceDNSFallbackActivationCount = 0
    var upstreamSuccessCount = 0
    var upstreamFailureCount = 0
    var lastUpstreamSuccessAt: Date?
    var lastPrimaryUpstreamSuccessAt: Date?
    var lastUpstreamDurationMilliseconds: Int?
    var lastUpstreamSuccessDurationMilliseconds: Int?
    var upstreamLatencyHistogram = DNSLatencyHistogram()
    var slowUpstreamResponseCount = 0
    var consecutiveSlowUpstreamResponseCount = 0
    var lastSlowUpstreamResponseAt: Date?
    var dohHTTPFailureCount = 0
    var upstreamTimeoutCount = 0
    var udpTruncatedResponseCount = 0
    var tcpFallbackAttemptCount = 0
    var tcpFallbackSuccessCount = 0
    var deviceDNSFallbackAttemptCount = 0
    var deviceDNSFallbackSuccessCount = 0
    var deviceDNSUnavailableCount = 0
    var resolverAttemptCounts: [String: Int] = [:]
    var resolverSuccessCounts: [String: Int] = [:]
    var resolverFailureCounts: [String: Int] = [:]
}

struct ResolverReconnectEpisodeEvidence: Equatable, Sendable {
    var startedAt: Date
    var reason: String
    var peakUpstreamFailureCount: Int
}

struct ResolverHealthEffectDeliveryState: Equatable, Sendable {
    var lastReconnectNeededActivityAt: Date?
}

struct ResolverHealthEvidenceState: Equatable, Sendable {
    var identity = ResolverIdentityEvidence()
    var episode = ResolverNetworkEpisodeEvidence()
    var session = ResolverTunnelSessionEvidence()
    var reconnectEpisode: ResolverReconnectEpisodeEvidence?
    var effectDelivery = ResolverHealthEffectDeliveryState()
}

enum ResolverHealthPersistenceUrgency: Equatable, Sendable {
    case deferred
    case immediate
}

struct ResolverHealthIncident: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case rejectedResponseStreak
        case wedgeDetected
        case wedgeRecovered
        case selfReconnectCredited
    }

    var kind: Kind
    var occurredAt: Date
    var reason: String?
    var durationMilliseconds: Int?
    var verifiedBy: String?
}

struct ResolverHealthRecovery: Equatable, Sendable {
    var startedAt: Date
    var recoveredAt: Date
    var durationMilliseconds: Int
    var reason: String
    var peakUpstreamFailureCount: Int
    var transport: DNSResolverTransport
    var verifiedBy: String
    // Recovery activity is emitted before some later mutations in the same event.
    // Its executor must use this frozen health context instead of re-deriving the
    // entry from the transition's final snapshot projection.
    var activityContext: ResolverHealthActivityContext
}

struct ResolverHealthActivityContext: Equatable, Sendable {
    var connectivitySeverity: ProtectionConnectivitySeverity
    var networkKind: TunnelNetworkKind
    var networkPathIsSatisfied: Bool
    var resolverTransport: DNSResolverTransport
    var deviceDNSFallbackActive: Bool
}

enum ResolverHealthLogEvent: Equatable, Sendable {
    case smokeProbeSucceeded(
        reason: String,
        transport: DNSResolverTransport,
        resolverAddress: String?,
        dohHTTPVersion: String?,
        occurredAt: Date
    )
    case smokeProbeDeviceFallback(
        reason: String,
        evidenceCount: Int,
        fallbackModeActive: Bool,
        resolverAddress: String?,
        occurredAt: Date
    )
    case smokeProbeFailed(
        reason: String,
        failure: String,
        consecutiveSmokeFailures: Int,
        consecutiveRejectedResponses: Int,
        occurredAt: Date
    )
}

enum ResolverRuntimeResetRequest: Equatable, Sendable {
    case full(reason: String, force: Bool)
}

enum ResolverFallbackLogEnd: Equatable, Sendable {
    case episodeEnd
    case contextReset
}

struct ResolverEncryptedFallbackCarry: Equatable, Sendable {
    var occurredAt: Date
    var transport: DNSResolverTransport
    var resolverAddress: String?
}

enum ResolverHealthEffect: Equatable, Sendable {
    case persistHealth(ResolverHealthPersistenceUrgency)
    case evaluateProtectionNotification(at: Date)
    // The provider executor emits the assessment only in QA-capable builds and
    // otherwise treats this ordering marker as a no-op.
    case evaluateQAConnectivityLog(reason: String, at: Date)
    case appendNetworkActivity(NetworkActivityEvent, at: Date)
    case recordIncident(ResolverHealthIncident)
    case deviceLog(ResolverHealthLogEvent)
    // Recovery reporting is deliberately composite: its executor appends the
    // recovery activity, device log, and incident exactly once, then clears the
    // provider-owned self-reconnect suppression signature and log timestamps.
    // Recovery branches must not also emit those primitive effects or cleanup.
    case reportConnectivityRecovery(ResolverHealthRecovery)
    case creditProductiveSelfReconnect(at: Date)
    case evaluateSelfReconnect(at: Date)
    case scheduleFallbackRecoveryProbe
    case cancelFallbackRecoveryProbe
    case scheduleWedgeRecoveryProbe
    case cancelWedgeRecoveryProbe
    // The request executor collects pending responses and reports the resulting
    // runtime-reset observation without retaining the responses in reducer state.
    // Delivery is separate so health persistence/notification ordering stays exact.
    case requestResolverRuntimeReset(ResolverRuntimeResetRequest)
    case deliverPendingResolverFailures(reason: String)
    case recordEncryptedFallbackCarry(ResolverEncryptedFallbackCarry)
    case endEncryptedFallbackLogEpisode(ResolverFallbackLogEnd)
    case clearDeviceDNSRecaptureRestartPending
    case signalConnectivityProjectionChanged
}

struct ResolverHealthLifecycleReset: Equatable, Sendable {
    var occurredAt: Date
}

struct ResolverNetworkPathObservation: Equatable, Sendable {
    var previousKind: TunnelNetworkKind?
    var previousIsSatisfied: Bool?
    var kind: TunnelNetworkKind
    var isSatisfied: Bool
    var observedAt: Date
}

struct ResolverRuntimeResetObservation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case protectionPolicyRefresh
        case fullRuntime(
            currentPrimaryIdentifier: String,
            recordsObservableReset: Bool
        )
    }

    var kind: Kind
    var reason: String
    var occurredAt: Date
}

struct ResolverConfigurationChangedObservation: Equatable, Sendable {
    var occurredAt: Date
}

struct ResolverNetworkSettingsFailureObservation: Equatable, Sendable {
    var reason: String
    var occurredAt: Date
}

struct ResolverSmokeProbeEvidence: Equatable, Sendable {
    struct PrimaryAccepted: Equatable, Sendable {
        let resolverAddress: String?
        let transport: DNSResolverTransport
        let dohHTTPVersion: String?
    }

    struct DeviceDNSFallbackAccepted: Equatable, Sendable {
        let resolverAddress: String?
        let primaryHadFallbackActivationEvidence: Bool
    }

    struct Failure: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case rejectedResponse
            case transport(String)
        }

        let kind: Kind
        let resolverAddress: String?
        let transport: DNSResolverTransport
    }

    enum Outcome: Equatable, Sendable {
        case primaryAccepted(PrimaryAccepted)
        case deviceDNSFallbackAccepted(DeviceDNSFallbackAccepted)
        case neitherAccepted(Failure)
    }

    let occurredAt: Date
    let reason: String
    let modeInsensitivePrimaryIdentifier: String
    let configuredResolverDisplayName: String
    let outcome: Outcome

    init(
        occurredAt: Date,
        reason: String,
        primaryResult: DNSResolutionResult,
        primaryAccepted: Bool,
        fallbackResult: DNSResolutionResult?,
        fallbackAccepted: Bool,
        modeInsensitivePrimaryIdentifier: String,
        configuredResolverDisplayName: String
    ) {
        self.occurredAt = occurredAt
        self.reason = reason
        self.modeInsensitivePrimaryIdentifier = modeInsensitivePrimaryIdentifier
        self.configuredResolverDisplayName = configuredResolverDisplayName

        if primaryAccepted {
            outcome = .primaryAccepted(
                PrimaryAccepted(
                    resolverAddress: primaryResult.successfulResolverAddress,
                    transport: primaryResult.transport,
                    dohHTTPVersion: primaryResult.negotiatedDoHProtocol
                )
            )
        } else if fallbackAccepted, let fallbackResult {
            outcome = .deviceDNSFallbackAccepted(
                DeviceDNSFallbackAccepted(
                    resolverAddress: fallbackResult.successfulResolverAddress,
                    primaryHadFallbackActivationEvidence:
                        primaryResult.hasFallbackActivationEvidence
                )
            )
        } else {
            let failureKind: Failure.Kind
            if primaryResult.response != nil {
                failureKind = .rejectedResponse
            } else {
                failureKind = .transport(
                    primaryResult.failureSummary
                        ?? fallbackResult?.failureSummary
                        ?? "dns-smoke-failed"
                )
            }
            outcome = .neitherAccepted(
                Failure(
                    kind: failureKind,
                    resolverAddress: primaryResult.successfulResolverAddress
                        ?? primaryResult.attempts.last?.address,
                    transport: primaryResult.transport
                )
            )
        }
    }
}

enum ResolverHealthEvent: Sendable {
    case lifecycleReset(ResolverHealthLifecycleReset)
    case networkPathObserved(ResolverNetworkPathObservation)
    case resolverConfigurationChanged(ResolverConfigurationChangedObservation)
    case resolverRuntimeResetOccurred(ResolverRuntimeResetObservation)
    case networkSettingsReapplyFailed(ResolverNetworkSettingsFailureObservation)
    case smokeProbeCompleted(ResolverSmokeProbeEvidence)
    case organicUpstreamCompleted(ResolverOrganicUpstreamEvidence)
}

// Probe fencing and caller-owned context work such as Device-DNS capture and
// NetworkExtension settings are deliberately not evidence effects. The provider
// adapter performs them synchronously around the coordinator transition: a path refreshes
// Device DNS before executing its reset request, while a configuration change
// advances the probe fence after forced persistence.

struct ResolverHealthSnapshotProjection: Equatable, Sendable {
    let state: ResolverHealthEvidenceState

    init(state: ResolverHealthEvidenceState) {
        self.state = state
    }

    // This is deliberately a field-wise patch. The provider owns the persisted
    // envelope plus cache/coalescing, fail-closed, and network-settings metrics.
    func apply(to snapshot: inout TunnelHealthSnapshot) {
        snapshot.networkPathIsSatisfied = state.session.networkPathIsSatisfied
        snapshot.lastResolverAddress = state.session.lastResolverAddress
        snapshot.lastResolverTransport = state.session.lastResolverTransport
        snapshot.lastFailureReason = state.episode.lastFailureReason
        snapshot.consecutiveUpstreamFailureCount = state.episode.consecutiveUpstreamFailureCount
        snapshot.lastDoHHTTPVersion = state.session.lastDoHHTTPVersion
        snapshot.lastDNSSmokeProbeAt = state.session.lastDNSSmokeProbeAt
        snapshot.lastDNSSmokeProbeSucceeded = state.session.lastDNSSmokeProbeSucceeded
        snapshot.dnsSmokeProbeSuccessCount = state.session.dnsSmokeProbeSuccessCount
        snapshot.lastUpstreamFailureAt = state.session.lastUpstreamFailureAt
        snapshot.consecutiveDNSSmokeProbeFailureCount =
            state.episode.consecutiveSmokeProbeFailureCount
        snapshot.consecutiveRejectedSmokeResponseCount = state.identity.rejectedResponseCount
        snapshot.rejectedSmokeResponseResolverIdentity =
            state.identity.rejectedResponseResolverIdentifier
        snapshot.rejectedSmokeResponseRescopeCount = state.session.rejectedResponseRescopeCount
        snapshot.deviceDNSFallbackModeActive = state.episode.deviceDNSFallbackModeActive
        snapshot.lastDeviceDNSFallbackActivatedAt = state.episode.lastDeviceDNSFallbackActivatedAt
        snapshot.deviceDNSFallbackActivationCount = state.session.deviceDNSFallbackActivationCount
        snapshot.dnsSmokeProbeFailureCount = state.session.dnsSmokeProbeFailureCount
        snapshot.lastEncryptedFallbackSuccessAt = state.episode.lastEncryptedFallbackSuccessAt
        snapshot.lastNetworkChangeAt = state.session.lastNetworkChangeAt
        snapshot.networkChangeCount = state.session.networkChangeCount
        snapshot.lastResolverRuntimeResetAt = state.session.lastResolverRuntimeResetAt
        snapshot.lastResolverRuntimeResetReason = state.session.lastResolverRuntimeResetReason
        snapshot.lastResolverIdentityChangeAt = state.session.lastResolverIdentityChangeAt
        snapshot.resolverRuntimeResetCount = state.session.resolverRuntimeResetCount
        snapshot.upstreamSuccessCount = state.session.upstreamSuccessCount
        snapshot.upstreamFailureCount = state.session.upstreamFailureCount
        snapshot.lastUpstreamSuccessAt = state.session.lastUpstreamSuccessAt
        snapshot.lastPrimaryUpstreamSuccessAt = state.session.lastPrimaryUpstreamSuccessAt
        snapshot.lastUpstreamDurationMilliseconds =
            state.session.lastUpstreamDurationMilliseconds
        snapshot.lastUpstreamSuccessDurationMilliseconds =
            state.session.lastUpstreamSuccessDurationMilliseconds
        snapshot.upstreamLatencyHistogram = state.session.upstreamLatencyHistogram
        snapshot.slowUpstreamResponseCount = state.session.slowUpstreamResponseCount
        snapshot.consecutiveSlowUpstreamResponseCount =
            state.session.consecutiveSlowUpstreamResponseCount
        snapshot.lastSlowUpstreamResponseAt = state.session.lastSlowUpstreamResponseAt
        snapshot.dohHTTPFailureCount = state.session.dohHTTPFailureCount
        snapshot.upstreamTimeoutCount = state.session.upstreamTimeoutCount
        snapshot.udpTruncatedResponseCount = state.session.udpTruncatedResponseCount
        snapshot.tcpFallbackAttemptCount = state.session.tcpFallbackAttemptCount
        snapshot.tcpFallbackSuccessCount = state.session.tcpFallbackSuccessCount
        snapshot.deviceDNSFallbackAttemptCount = state.session.deviceDNSFallbackAttemptCount
        snapshot.deviceDNSFallbackSuccessCount = state.session.deviceDNSFallbackSuccessCount
        snapshot.deviceDNSUnavailableCount = state.session.deviceDNSUnavailableCount
        snapshot.resolverAttemptCounts = state.session.resolverAttemptCounts
        snapshot.resolverSuccessCounts = state.session.resolverSuccessCounts
        snapshot.resolverFailureCounts = state.session.resolverFailureCounts
    }
}

struct ResolverHealthTransition: Equatable, Sendable {
    var state: ResolverHealthEvidenceState
    var projection: ResolverHealthSnapshotProjection
    var effects: [ResolverHealthEffect]
}

enum ResolverHealthReducer {
    static func reduce(
        state: ResolverHealthEvidenceState,
        event: ResolverHealthEvent,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthTransition {
        var next = state
        let effects: [ResolverHealthEffect]

        switch event {
        case .lifecycleReset:
            next = ResolverHealthEvidenceState()
            effects = [
                .endEncryptedFallbackLogEpisode(.contextReset),
                .clearDeviceDNSRecaptureRestartPending,
                .cancelFallbackRecoveryProbe,
                .cancelWedgeRecoveryProbe,
                .persistHealth(.immediate),
            ]

        case .networkPathObserved(let observation):
            next.session.networkPathIsSatisfied = observation.isSatisfied
            let isInitial =
                observation.previousKind == nil
                && observation.previousIsSatisfied == nil
            let meaningfullyChanged =
                observation.previousKind != observation.kind
                || observation.previousIsSatisfied != observation.isSatisfied

            if isInitial {
                effects = [
                    .signalConnectivityProjectionChanged,
                    .persistHealth(.immediate),
                ]
            } else if meaningfullyChanged {
                next.session.lastNetworkChangeAt = observation.observedAt
                next.session.networkChangeCount += 1
                next.episode.lastFailureReason = nil
                next.episode.consecutiveUpstreamFailureCount = 0
                next.episode.consecutiveSmokeProbeFailureCount = 0
                next.episode.deviceDNSFallbackEvidenceCount = 0
                next.episode.deviceDNSFallbackModeActive = false
                next.episode.lastDeviceDNSFallbackActivatedAt = nil
                next.episode.consecutiveCarriedQueryFailureCount = 0
                next.effectDelivery.lastReconnectNeededActivityAt = nil

                var pathEffects: [ResolverHealthEffect] = [
                    .endEncryptedFallbackLogEpisode(.contextReset),
                    .cancelWedgeRecoveryProbe,
                    .clearDeviceDNSRecaptureRestartPending,
                    .cancelFallbackRecoveryProbe,
                    .requestResolverRuntimeReset(
                        .full(reason: "network-path-changed", force: true)
                    ),
                    .signalConnectivityProjectionChanged,
                    .appendNetworkActivity(
                        .networkChanged(
                            from: observation.previousKind,
                            to: observation.kind,
                            isSatisfied: observation.isSatisfied
                        ),
                        at: observation.observedAt
                    ),
                    .evaluateQAConnectivityLog(
                        reason: "network-path-changed",
                        at: observation.observedAt
                    ),
                    .persistHealth(.immediate),
                ]
                if !observation.isSatisfied {
                    pathEffects.append(
                        .evaluateProtectionNotification(at: observation.observedAt)
                    )
                }
                pathEffects.append(
                    .deliverPendingResolverFailures(reason: "network-path-changed")
                )
                effects = pathEffects
            } else {
                effects = [
                    .signalConnectivityProjectionChanged,
                    .persistHealth(.deferred),
                ]
            }

        case .resolverConfigurationChanged:
            next.episode.consecutiveUpstreamFailureCount = 0
            next.episode.deviceDNSFallbackEvidenceCount = 0
            next.episode.deviceDNSFallbackModeActive = false
            next.episode.lastDeviceDNSFallbackActivatedAt = nil
            effects = [
                .endEncryptedFallbackLogEpisode(.contextReset),
                .cancelFallbackRecoveryProbe,
                .signalConnectivityProjectionChanged,
                .persistHealth(.immediate),
            ]

        case .resolverRuntimeResetOccurred(let observation):
            next.episode.lastAcceptedPrimaryEvidenceAt = nil
            next.session.lastResolverRuntimeResetAt = observation.occurredAt
            next.session.lastResolverRuntimeResetReason = observation.reason
            next.session.resolverRuntimeResetCount += 1

            switch observation.kind {
            case .protectionPolicyRefresh:
                effects = []

            case .fullRuntime(
                let currentPrimaryIdentifier,
                let recordsObservableReset
            ):
                let previousPrimaryIdentifier = state.identity.primaryIdentifier
                next.identity.primaryIdentifier = currentPrimaryIdentifier
                next.session.lastDoHHTTPVersion = nil
                var runtimeEffects: [ResolverHealthEffect] = []

                if recordsObservableReset {
                    next.episode.consecutiveCarriedQueryFailureCount = 0
                    next.episode.lastFailureReason = nil
                    next.episode.lastEncryptedFallbackSuccessAt = nil
                    runtimeEffects = [
                        .endEncryptedFallbackLogEpisode(.contextReset)
                    ]
                } else {
                    // Initial activation clears runtime-scoped proof/DoH observation,
                    // but does not create a persisted reset observation.
                    next.session.lastResolverRuntimeResetAt = state.session.lastResolverRuntimeResetAt
                    next.session.lastResolverRuntimeResetReason =
                        state.session.lastResolverRuntimeResetReason
                    next.session.resolverRuntimeResetCount = state.session.resolverRuntimeResetCount
                }

                if recordsObservableReset,
                    let previousPrimaryIdentifier,
                    previousPrimaryIdentifier != currentPrimaryIdentifier
                {
                    next.identity.rejectedResponseCount = 0
                    next.identity.rejectedResponseResolverIdentifier = nil
                    next.session.lastResolverIdentityChangeAt = observation.occurredAt
                }

                effects = runtimeEffects
            }

        case .networkSettingsReapplyFailed(let observation):
            next.episode.lastFailureReason = observation.reason
            effects = [
                .signalConnectivityProjectionChanged,
                .persistHealth(.immediate),
                .appendNetworkActivity(
                    .networkSettingsReapplyFailed(reason: observation.reason),
                    at: observation.occurredAt
                ),
                .evaluateProtectionNotification(at: observation.occurredAt),
            ]

        case .smokeProbeCompleted(let evidence):
            return ResolverSmokeEvidenceReducer.reduce(
                state: state,
                evidence: evidence,
                projectingOnto: snapshot
            )

        case .organicUpstreamCompleted(let evidence):
            return ResolverOrganicEvidenceReducer.reduce(
                state: state,
                evidence: evidence,
                projectingOnto: snapshot
            )
        }

        return ResolverHealthTransition(
            state: next,
            projection: ResolverHealthSnapshotProjection(state: next),
            effects: effects
        )
    }
}
