import Foundation
import XCTest

@testable import LavaSecDNS
@testable import LavaSecKit

final class ResolverHealthEvidenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    func testMeaningfulNetworkChangeThenRuntimeResetClearsEpisodeButPreservesIdentityAndSession() {
        let original = seededState()
        let pathTransition = ResolverHealthReducer.reduce(
            state: original,
            event: .networkPathObserved(
                ResolverNetworkPathObservation(
                    previousKind: .wifi,
                    previousIsSatisfied: true,
                    kind: .cellular,
                    isSatisfied: true,
                    observedAt: later
                )
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertEqual(pathTransition.state.identity, original.identity)
        XCTAssertEqual(pathTransition.state.session.dnsSmokeProbeFailureCount, 9)
        XCTAssertEqual(pathTransition.state.session.deviceDNSFallbackActivationCount, 4)
        XCTAssertEqual(pathTransition.state.reconnectEpisode, original.reconnectEpisode)
        XCTAssertNil(pathTransition.state.effectDelivery.lastReconnectNeededActivityAt)
        XCTAssertNil(pathTransition.state.episode.lastFailureReason)
        XCTAssertEqual(pathTransition.state.episode.consecutiveUpstreamFailureCount, 0)
        XCTAssertEqual(pathTransition.state.episode.consecutiveSmokeProbeFailureCount, 0)
        XCTAssertEqual(pathTransition.state.episode.deviceDNSFallbackEvidenceCount, 0)
        XCTAssertFalse(pathTransition.state.episode.deviceDNSFallbackModeActive)
        XCTAssertNil(pathTransition.state.episode.lastDeviceDNSFallbackActivatedAt)
        XCTAssertEqual(pathTransition.state.episode.consecutiveCarriedQueryFailureCount, 0)
        XCTAssertEqual(pathTransition.state.episode.lastAcceptedPrimaryEvidenceAt, start)
        XCTAssertEqual(pathTransition.state.episode.lastEncryptedFallbackSuccessAt, start)
        XCTAssertEqual(pathTransition.state.session.lastDoHHTTPVersion, "h3")

        let resetTransition = ResolverHealthReducer.reduce(
            state: pathTransition.state,
            event: .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .fullRuntime(
                        currentPrimaryIdentifier: "primary-a",
                        recordsObservableReset: true
                    ),
                    reason: "network-path-changed",
                    occurredAt: later
                )
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertEqual(resetTransition.state.identity, original.identity)
        XCTAssertNil(resetTransition.state.episode.lastAcceptedPrimaryEvidenceAt)
        XCTAssertNil(resetTransition.state.episode.lastEncryptedFallbackSuccessAt)
        XCTAssertNil(resetTransition.state.session.lastDoHHTTPVersion)
        XCTAssertEqual(resetTransition.state.session.resolverRuntimeResetCount, 6)
        XCTAssertEqual(resetTransition.state.session.lastResolverRuntimeResetAt, later)
        XCTAssertEqual(
            resetTransition.state.session.lastResolverRuntimeResetReason,
            "network-path-changed"
        )
        XCTAssertEqual(resetTransition.state.reconnectEpisode, original.reconnectEpisode)
        XCTAssertEqual(
            pathTransition.effects,
            [
                .endEncryptedFallbackLogEpisode(.contextReset),
                .cancelWedgeRecoveryProbe,
                .clearDeviceDNSRecaptureRestartPending,
                .cancelFallbackRecoveryProbe,
                .requestResolverRuntimeReset(
                    .full(reason: "network-path-changed", force: true)
                ),
                .signalConnectivityProjectionChanged,
                .appendNetworkActivity(
                    .networkChanged(from: .wifi, to: .cellular, isSatisfied: true),
                    at: later
                ),
                .evaluateQAConnectivityLog(reason: "network-path-changed", at: later),
                .persistHealth(.immediate),
                .deliverPendingResolverFailures(reason: "network-path-changed"),
            ]
        )
        XCTAssertEqual(
            resetTransition.effects,
            [.endEncryptedFallbackLogEpisode(.contextReset)]
        )
    }

    func testInitialPathObservationDoesNotCountAsNetworkChangeOrResetEvidence() {
        let original = seededState()
        let transition = ResolverHealthReducer.reduce(
            state: original,
            event: .networkPathObserved(
                ResolverNetworkPathObservation(
                    previousKind: nil,
                    previousIsSatisfied: nil,
                    kind: .wifi,
                    isSatisfied: true,
                    observedAt: later
                )
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertEqual(transition.state.identity, original.identity)
        XCTAssertEqual(transition.state.episode, original.episode)
        XCTAssertEqual(transition.state.session.networkChangeCount, 7)
        XCTAssertEqual(transition.state.session.lastNetworkChangeAt, start)
        XCTAssertEqual(transition.state.session.networkPathIsSatisfied, true)
        XCTAssertEqual(
            transition.effects,
            [.signalConnectivityProjectionChanged, .persistHealth(.immediate)]
        )
    }

    func testProtectionPolicyRefreshPreservesEpisodeEvidenceExceptAcceptedPrimaryProof() {
        let original = seededState()
        let transition = ResolverHealthReducer.reduce(
            state: original,
            event: .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .protectionPolicyRefresh,
                    reason: "snapshot-or-configuration-changed",
                    occurredAt: later
                )
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertNil(transition.state.episode.lastAcceptedPrimaryEvidenceAt)
        XCTAssertEqual(transition.state.episode.lastFailureReason, "timeout")
        XCTAssertEqual(transition.state.episode.consecutiveUpstreamFailureCount, 8)
        XCTAssertEqual(transition.state.episode.consecutiveSmokeProbeFailureCount, 6)
        XCTAssertEqual(transition.state.episode.deviceDNSFallbackEvidenceCount, 2)
        XCTAssertTrue(transition.state.episode.deviceDNSFallbackModeActive)
        XCTAssertEqual(transition.state.episode.consecutiveCarriedQueryFailureCount, 2)
        XCTAssertEqual(transition.state.episode.lastEncryptedFallbackSuccessAt, start)
        XCTAssertEqual(transition.state.session.lastDoHHTTPVersion, "h3")
        XCTAssertEqual(transition.state.session.lastResolverRuntimeResetAt, later)
        XCTAssertEqual(
            transition.state.session.lastResolverRuntimeResetReason,
            "snapshot-or-configuration-changed"
        )
        XCTAssertEqual(transition.state.session.resolverRuntimeResetCount, 6)
        XCTAssertEqual(transition.state.identity, original.identity)
        XCTAssertTrue(transition.effects.isEmpty)
    }

    func testFallbackOnlyFullRuntimeResetPreservesRejectedIdentityAndGenericStreaks() {
        let original = seededState()
        let transition = ResolverHealthReducer.reduce(
            state: original,
            event: .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .fullRuntime(
                        currentPrimaryIdentifier: "primary-a",
                        recordsObservableReset: true
                    ),
                    reason: "resolver-configuration-changed",
                    occurredAt: later
                )
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertEqual(transition.state.identity, original.identity)
        XCTAssertEqual(transition.state.session.lastResolverIdentityChangeAt, start)
        XCTAssertEqual(transition.state.episode.consecutiveUpstreamFailureCount, 8)
        XCTAssertEqual(transition.state.episode.consecutiveSmokeProbeFailureCount, 6)
        XCTAssertEqual(transition.state.episode.deviceDNSFallbackEvidenceCount, 2)
        XCTAssertTrue(transition.state.episode.deviceDNSFallbackModeActive)
        XCTAssertNil(transition.state.episode.lastFailureReason)
        XCTAssertNil(transition.state.episode.lastAcceptedPrimaryEvidenceAt)
        XCTAssertNil(transition.state.episode.lastEncryptedFallbackSuccessAt)
        XCTAssertNil(transition.state.session.lastDoHHTTPVersion)
        XCTAssertEqual(transition.state.episode.consecutiveCarriedQueryFailureCount, 0)
        XCTAssertEqual(
            transition.effects,
            [.endEncryptedFallbackLogEpisode(.contextReset)]
        )
    }

    func testInitialFullActivationEstablishesPrimaryWithoutRecordingObservableReset() {
        var original = seededState()
        original.identity = ResolverIdentityEvidence()
        original.session.lastResolverIdentityChangeAt = nil

        let transition = ResolverHealthReducer.reduce(
            state: original,
            event: .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .fullRuntime(
                        currentPrimaryIdentifier: "primary-a",
                        recordsObservableReset: false
                    ),
                    reason: "resolver-configuration-changed",
                    occurredAt: later
                )
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertEqual(transition.state.identity.primaryIdentifier, "primary-a")
        XCTAssertNil(transition.state.identity.rejectedResponseResolverIdentifier)
        XCTAssertNil(transition.state.episode.lastAcceptedPrimaryEvidenceAt)
        XCTAssertNil(transition.state.session.lastDoHHTTPVersion)
        XCTAssertEqual(transition.state.episode.lastFailureReason, "timeout")
        XCTAssertEqual(transition.state.episode.lastEncryptedFallbackSuccessAt, start)
        XCTAssertEqual(transition.state.episode.consecutiveCarriedQueryFailureCount, 2)
        XCTAssertEqual(transition.state.session.lastResolverRuntimeResetAt, start)
        XCTAssertEqual(transition.state.session.lastResolverRuntimeResetReason, "earlier-reset")
        XCTAssertEqual(transition.state.session.resolverRuntimeResetCount, 5)
        XCTAssertNil(transition.state.session.lastResolverIdentityChangeAt)
        XCTAssertTrue(transition.effects.isEmpty)
    }

    func testNonObservableActivationNeverTreatsAStalePriorPrimaryAsAnIdentityChange() {
        var original = seededState()
        original.identity.primaryIdentifier = "stale-primary"
        original.identity.rejectedResponseResolverIdentifier = "stale-primary"

        let transition = ResolverHealthReducer.reduce(
            state: original,
            event: .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .fullRuntime(
                        currentPrimaryIdentifier: "primary-a",
                        recordsObservableReset: false
                    ),
                    reason: "startTunnel",
                    occurredAt: later
                )
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertEqual(transition.state.identity.primaryIdentifier, "primary-a")
        XCTAssertEqual(transition.state.identity.rejectedResponseCount, 3)
        XCTAssertEqual(
            transition.state.identity.rejectedResponseResolverIdentifier,
            "stale-primary"
        )
        XCTAssertEqual(transition.state.session.lastResolverIdentityChangeAt, start)
        XCTAssertEqual(transition.state.session.resolverRuntimeResetCount, 5)
        XCTAssertTrue(transition.effects.isEmpty)
    }

    func testConfigurationChangeClearsFallbackAndGenericUpstreamBeforeRuntimeReset() {
        let original = seededState()
        let transition = ResolverHealthReducer.reduce(
            state: original,
            event: .resolverConfigurationChanged(
                ResolverConfigurationChangedObservation(occurredAt: later)
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertEqual(transition.state.identity, original.identity)
        XCTAssertEqual(transition.state.episode.consecutiveUpstreamFailureCount, 0)
        XCTAssertEqual(transition.state.episode.consecutiveSmokeProbeFailureCount, 6)
        XCTAssertEqual(transition.state.episode.deviceDNSFallbackEvidenceCount, 0)
        XCTAssertFalse(transition.state.episode.deviceDNSFallbackModeActive)
        XCTAssertNil(transition.state.episode.lastDeviceDNSFallbackActivatedAt)
        XCTAssertEqual(transition.state.episode.lastAcceptedPrimaryEvidenceAt, start)
        XCTAssertEqual(transition.state.episode.lastEncryptedFallbackSuccessAt, start)
        XCTAssertEqual(transition.state.episode.consecutiveCarriedQueryFailureCount, 2)
        XCTAssertEqual(transition.state.episode.lastFailureReason, "timeout")
        XCTAssertEqual(transition.state.session.lastDoHHTTPVersion, "h3")
        XCTAssertEqual(transition.state.session.resolverRuntimeResetCount, 5)
        XCTAssertEqual(transition.state.reconnectEpisode, original.reconnectEpisode)
        XCTAssertEqual(transition.state.effectDelivery, original.effectDelivery)
        XCTAssertEqual(
            transition.effects,
            [
                .endEncryptedFallbackLogEpisode(.contextReset),
                .cancelFallbackRecoveryProbe,
                .signalConnectivityProjectionChanged,
                .persistHealth(.immediate),
            ]
        )
    }

    func testConfigurationChangeThenFullResetAppliesEachTransitionOnce() {
        let original = seededState()
        let configurationTransition = ResolverHealthReducer.reduce(
            state: original,
            event: .resolverConfigurationChanged(
                ResolverConfigurationChangedObservation(occurredAt: later)
            ),
            projectingOnto: providerOwnedBase()
        )

        let resetTransition = ResolverHealthReducer.reduce(
            state: configurationTransition.state,
            event: .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .fullRuntime(
                        currentPrimaryIdentifier: "primary-a",
                        recordsObservableReset: true
                    ),
                    reason: "resolver-configuration-changed",
                    occurredAt: later
                )
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertEqual(resetTransition.state.identity, original.identity)
        XCTAssertEqual(resetTransition.state.episode.consecutiveUpstreamFailureCount, 0)
        XCTAssertEqual(resetTransition.state.episode.consecutiveSmokeProbeFailureCount, 6)
        XCTAssertEqual(resetTransition.state.episode.deviceDNSFallbackEvidenceCount, 0)
        XCTAssertFalse(resetTransition.state.episode.deviceDNSFallbackModeActive)
        XCTAssertNil(resetTransition.state.episode.lastAcceptedPrimaryEvidenceAt)
        XCTAssertNil(resetTransition.state.episode.lastFailureReason)
        XCTAssertNil(resetTransition.state.episode.lastEncryptedFallbackSuccessAt)
        XCTAssertEqual(resetTransition.state.episode.consecutiveCarriedQueryFailureCount, 0)
        XCTAssertNil(resetTransition.state.session.lastDoHHTTPVersion)
        XCTAssertEqual(resetTransition.state.session.resolverRuntimeResetCount, 6)
    }

    func testSameReasonStringDoesNotConflateProtectionAndFullRuntimeResetPolicies() {
        let original = seededState()
        let protectionTransition = ResolverHealthReducer.reduce(
            state: original,
            event: .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .protectionPolicyRefresh,
                    reason: "shared-reason",
                    occurredAt: later
                )
            ),
            projectingOnto: providerOwnedBase()
        )
        let fullTransition = ResolverHealthReducer.reduce(
            state: original,
            event: .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .fullRuntime(
                        currentPrimaryIdentifier: "primary-a",
                        recordsObservableReset: true
                    ),
                    reason: "shared-reason",
                    occurredAt: later
                )
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertEqual(protectionTransition.state.episode.lastFailureReason, "timeout")
        XCTAssertEqual(protectionTransition.state.episode.lastEncryptedFallbackSuccessAt, start)
        XCTAssertEqual(protectionTransition.state.episode.consecutiveCarriedQueryFailureCount, 2)
        XCTAssertEqual(protectionTransition.state.session.lastDoHHTTPVersion, "h3")
        XCTAssertNil(fullTransition.state.episode.lastFailureReason)
        XCTAssertNil(fullTransition.state.episode.lastEncryptedFallbackSuccessAt)
        XCTAssertEqual(fullTransition.state.episode.consecutiveCarriedQueryFailureCount, 0)
        XCTAssertNil(fullTransition.state.session.lastDoHHTTPVersion)
    }

    func testPrimaryIdentityChangeClearsRejectedEvidenceButPreservesSessionCounters() {
        let original = seededState()
        let transition = ResolverHealthReducer.reduce(
            state: original,
            event: .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .fullRuntime(
                        currentPrimaryIdentifier: "primary-b",
                        recordsObservableReset: true
                    ),
                    reason: "resolver-configuration-changed",
                    occurredAt: later
                )
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertEqual(transition.state.identity.primaryIdentifier, "primary-b")
        XCTAssertEqual(transition.state.identity.rejectedResponseCount, 0)
        XCTAssertNil(transition.state.identity.rejectedResponseResolverIdentifier)
        XCTAssertEqual(transition.state.session.lastResolverIdentityChangeAt, later)
        XCTAssertEqual(transition.state.session.rejectedResponseRescopeCount, 5)
        XCTAssertEqual(transition.state.session.dnsSmokeProbeFailureCount, 9)
        XCTAssertEqual(transition.state.session.deviceDNSFallbackActivationCount, 4)
        XCTAssertEqual(transition.state.session.upstreamSuccessCount, 12)
    }

    func testNetworkSettingsFailureUpdatesSharedReasonButPreservesProviderFailureTriple() {
        let base = providerOwnedBase()
        let transition = ResolverHealthReducer.reduce(
            state: seededState(),
            event: .networkSettingsReapplyFailed(
                ResolverNetworkSettingsFailureObservation(
                    reason: "network-path-changed: denied",
                    occurredAt: later
                )
            ),
            projectingOnto: base
        )
        var projected = base
        transition.projection.apply(to: &projected)

        XCTAssertEqual(transition.state.episode.lastFailureReason, "network-path-changed: denied")
        XCTAssertEqual(projected.lastFailureReason, "network-path-changed: denied")
        XCTAssertEqual(
            projected.lastNetworkSettingsReapplyFailureAt,
            base.lastNetworkSettingsReapplyFailureAt
        )
        XCTAssertEqual(
            projected.lastNetworkSettingsReapplyFailureReason,
            base.lastNetworkSettingsReapplyFailureReason
        )
        XCTAssertEqual(
            projected.networkSettingsReapplyFailureCount,
            base.networkSettingsReapplyFailureCount
        )
        XCTAssertEqual(
            transition.effects,
            [
                .signalConnectivityProjectionChanged,
                .persistHealth(.immediate),
                .appendNetworkActivity(
                    .networkSettingsReapplyFailed(reason: "network-path-changed: denied"),
                    at: later
                ),
                .evaluateProtectionNotification(at: later),
            ]
        )
    }

    func testRepeatedPathObservationDoesNotCountOrResetEpisodeEvidence() {
        let original = seededState()
        let transition = ResolverHealthReducer.reduce(
            state: original,
            event: .networkPathObserved(
                ResolverNetworkPathObservation(
                    previousKind: .wifi,
                    previousIsSatisfied: true,
                    kind: .wifi,
                    isSatisfied: true,
                    observedAt: later
                )
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertEqual(transition.state, original)
        XCTAssertEqual(
            transition.effects,
            [.signalConnectivityProjectionChanged, .persistHealth(.deferred)]
        )
    }

    func testMeaningfulUnsatisfiedPathEvaluatesNotificationAfterPersistingTheChange() {
        let transition = ResolverHealthReducer.reduce(
            state: seededState(),
            event: .networkPathObserved(
                ResolverNetworkPathObservation(
                    previousKind: .wifi,
                    previousIsSatisfied: true,
                    kind: .wifi,
                    isSatisfied: false,
                    observedAt: later
                )
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertFalse(transition.state.session.networkPathIsSatisfied)
        XCTAssertEqual(
            transition.effects,
            [
                .endEncryptedFallbackLogEpisode(.contextReset),
                .cancelWedgeRecoveryProbe,
                .clearDeviceDNSRecaptureRestartPending,
                .cancelFallbackRecoveryProbe,
                .requestResolverRuntimeReset(
                    .full(reason: "network-path-changed", force: true)
                ),
                .signalConnectivityProjectionChanged,
                .appendNetworkActivity(
                    .networkChanged(from: .wifi, to: .wifi, isSatisfied: false),
                    at: later
                ),
                .evaluateQAConnectivityLog(reason: "network-path-changed", at: later),
                .persistHealth(.immediate),
                .evaluateProtectionNotification(at: later),
                .deliverPendingResolverFailures(reason: "network-path-changed"),
            ]
        )
    }

    func testNetworkSettingsFailureSurvivesPolicyRefreshButSharedReasonClearsOnFullReset() {
        let base = providerOwnedBase()
        let failed = ResolverHealthReducer.reduce(
            state: seededState(),
            event: .networkSettingsReapplyFailed(
                ResolverNetworkSettingsFailureObservation(
                    reason: "configuration-changed: denied",
                    occurredAt: later
                )
            ),
            projectingOnto: base
        )
        let refreshed = ResolverHealthReducer.reduce(
            state: failed.state,
            event: .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .protectionPolicyRefresh,
                    reason: "snapshot-or-configuration-changed",
                    occurredAt: later
                )
            ),
            projectingOnto: base
        )
        let fullyReset = ResolverHealthReducer.reduce(
            state: refreshed.state,
            event: .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .fullRuntime(
                        currentPrimaryIdentifier: "primary-a",
                        recordsObservableReset: true
                    ),
                    reason: "resolver-configuration-changed",
                    occurredAt: later
                )
            ),
            projectingOnto: base
        )

        XCTAssertEqual(refreshed.state.episode.lastFailureReason, "configuration-changed: denied")
        XCTAssertNil(fullyReset.state.episode.lastFailureReason)
        for transition in [failed, refreshed, fullyReset] {
            var projected = base
            transition.projection.apply(to: &projected)
            XCTAssertEqual(
                projected.lastNetworkSettingsReapplyFailureAt,
                base.lastNetworkSettingsReapplyFailureAt
            )
            XCTAssertEqual(
                projected.lastNetworkSettingsReapplyFailureReason,
                base.lastNetworkSettingsReapplyFailureReason
            )
            XCTAssertEqual(
                projected.networkSettingsReapplyFailureCount,
                base.networkSettingsReapplyFailureCount
            )
        }
    }

    func testLifecycleResetAppliesApprovedSingleOwnerCorrections() {
        let transition = ResolverHealthReducer.reduce(
            state: seededState(),
            event: .lifecycleReset(
                ResolverHealthLifecycleReset(occurredAt: later)
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertEqual(transition.state.identity, ResolverIdentityEvidence())
        XCTAssertEqual(transition.state.episode, ResolverNetworkEpisodeEvidence())
        XCTAssertEqual(
            transition.state.session,
            ResolverTunnelSessionEvidence(networkPathIsSatisfied: true)
        )
        XCTAssertNil(transition.state.reconnectEpisode)
        XCTAssertEqual(transition.state.effectDelivery, ResolverHealthEffectDeliveryState())
        XCTAssertEqual(
            transition.effects,
            [
                .endEncryptedFallbackLogEpisode(.contextReset),
                .clearDeviceDNSRecaptureRestartPending,
                .cancelFallbackRecoveryProbe,
                .cancelWedgeRecoveryProbe,
                .persistHealth(.immediate),
            ]
        )
    }

    func testLifecycleResetClearsLatencyHistogram() {
        // The latency histogram lives in `session`, so it inherits the tunnel-session reset
        // boundary (INV-DNS-4). Seed it, then confirm lifecycleReset empties it.
        var state = seededState()
        state.session.upstreamLatencyHistogram.record(durationMilliseconds: 42)
        XCTAssertEqual(state.session.upstreamLatencyHistogram.sampleCount, 1)

        let transition = ResolverHealthReducer.reduce(
            state: state,
            event: .lifecycleReset(
                ResolverHealthLifecycleReset(occurredAt: later)
            ),
            projectingOnto: providerOwnedBase()
        )

        XCTAssertEqual(transition.state.session.upstreamLatencyHistogram, DNSLatencyHistogram())
        XCTAssertEqual(transition.state.session.upstreamLatencyHistogram.sampleCount, 0)
    }

    func testEveryContextProjectionPreservesProviderOwnedEnvelopeAndTallies() {
        let base = providerOwnedBase()
        let events: [ResolverHealthEvent] = [
            .lifecycleReset(
                ResolverHealthLifecycleReset(occurredAt: later)
            ),
            .networkPathObserved(
                ResolverNetworkPathObservation(
                    previousKind: .wifi,
                    previousIsSatisfied: true,
                    kind: .cellular,
                    isSatisfied: false,
                    observedAt: later
                )
            ),
            .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .protectionPolicyRefresh,
                    reason: "snapshot-or-configuration-changed",
                    occurredAt: later
                )
            ),
            .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .fullRuntime(
                        currentPrimaryIdentifier: "primary-b",
                        recordsObservableReset: true
                    ),
                    reason: "resolver-configuration-changed",
                    occurredAt: later
                )
            ),
            .resolverConfigurationChanged(
                ResolverConfigurationChangedObservation(occurredAt: later)
            ),
            .networkSettingsReapplyFailed(
                ResolverNetworkSettingsFailureObservation(reason: "refresh: failed", occurredAt: later)
            ),
        ]

        for event in events {
            let transition = ResolverHealthReducer.reduce(
                state: seededState(),
                event: event,
                projectingOnto: base
            )
            var projected = base
            transition.projection.apply(to: &projected)
            XCTAssertResolverHealthProviderFieldsEqual(projected, base)
        }
    }

    func testContextProjectionWritesEveryCurrentReducerOwnedSnapshotField() {
        let state = seededState()
        var snapshot = TunnelHealthSnapshot()

        ResolverHealthSnapshotProjection(state: state).apply(to: &snapshot)

        XCTAssertEqual(snapshot.networkPathIsSatisfied, state.session.networkPathIsSatisfied)
        XCTAssertEqual(snapshot.lastResolverAddress, state.session.lastResolverAddress)
        XCTAssertEqual(snapshot.lastResolverTransport, state.session.lastResolverTransport)
        XCTAssertEqual(snapshot.lastFailureReason, state.episode.lastFailureReason)
        XCTAssertEqual(
            snapshot.consecutiveUpstreamFailureCount,
            state.episode.consecutiveUpstreamFailureCount
        )
        XCTAssertEqual(snapshot.lastDoHHTTPVersion, state.session.lastDoHHTTPVersion)
        XCTAssertEqual(snapshot.lastDNSSmokeProbeAt, state.session.lastDNSSmokeProbeAt)
        XCTAssertEqual(
            snapshot.lastDNSSmokeProbeSucceeded,
            state.session.lastDNSSmokeProbeSucceeded
        )
        XCTAssertEqual(snapshot.dnsSmokeProbeSuccessCount, state.session.dnsSmokeProbeSuccessCount)
        XCTAssertEqual(snapshot.lastUpstreamFailureAt, state.session.lastUpstreamFailureAt)
        XCTAssertEqual(
            snapshot.consecutiveDNSSmokeProbeFailureCount,
            state.episode.consecutiveSmokeProbeFailureCount
        )
        XCTAssertEqual(
            snapshot.consecutiveRejectedSmokeResponseCount,
            state.identity.rejectedResponseCount
        )
        XCTAssertEqual(
            snapshot.rejectedSmokeResponseResolverIdentity,
            state.identity.rejectedResponseResolverIdentifier
        )
        XCTAssertEqual(
            snapshot.rejectedSmokeResponseRescopeCount,
            state.session.rejectedResponseRescopeCount
        )
        XCTAssertEqual(
            snapshot.deviceDNSFallbackModeActive,
            state.episode.deviceDNSFallbackModeActive
        )
        XCTAssertEqual(
            snapshot.lastDeviceDNSFallbackActivatedAt,
            state.episode.lastDeviceDNSFallbackActivatedAt
        )
        XCTAssertEqual(
            snapshot.deviceDNSFallbackActivationCount,
            state.session.deviceDNSFallbackActivationCount
        )
        XCTAssertEqual(snapshot.dnsSmokeProbeFailureCount, state.session.dnsSmokeProbeFailureCount)
        XCTAssertEqual(
            snapshot.lastEncryptedFallbackSuccessAt,
            state.episode.lastEncryptedFallbackSuccessAt
        )
        XCTAssertEqual(snapshot.lastNetworkChangeAt, state.session.lastNetworkChangeAt)
        XCTAssertEqual(snapshot.networkChangeCount, state.session.networkChangeCount)
        XCTAssertEqual(
            snapshot.lastResolverRuntimeResetAt,
            state.session.lastResolverRuntimeResetAt
        )
        XCTAssertEqual(
            snapshot.lastResolverRuntimeResetReason,
            state.session.lastResolverRuntimeResetReason
        )
        XCTAssertEqual(
            snapshot.lastResolverIdentityChangeAt,
            state.session.lastResolverIdentityChangeAt
        )
        XCTAssertEqual(
            snapshot.resolverRuntimeResetCount,
            state.session.resolverRuntimeResetCount
        )
        XCTAssertEqual(snapshot.upstreamSuccessCount, state.session.upstreamSuccessCount)
        XCTAssertEqual(snapshot.upstreamFailureCount, state.session.upstreamFailureCount)
        XCTAssertEqual(snapshot.lastUpstreamSuccessAt, state.session.lastUpstreamSuccessAt)
        XCTAssertEqual(
            snapshot.lastPrimaryUpstreamSuccessAt,
            state.session.lastPrimaryUpstreamSuccessAt
        )
        XCTAssertEqual(
            snapshot.lastUpstreamDurationMilliseconds,
            state.session.lastUpstreamDurationMilliseconds
        )
        XCTAssertEqual(snapshot.slowUpstreamResponseCount, state.session.slowUpstreamResponseCount)
        XCTAssertEqual(
            snapshot.consecutiveSlowUpstreamResponseCount,
            state.session.consecutiveSlowUpstreamResponseCount
        )
        XCTAssertEqual(snapshot.lastSlowUpstreamResponseAt, state.session.lastSlowUpstreamResponseAt)
        XCTAssertEqual(snapshot.dohHTTPFailureCount, state.session.dohHTTPFailureCount)
        XCTAssertEqual(snapshot.upstreamTimeoutCount, state.session.upstreamTimeoutCount)
        XCTAssertEqual(
            snapshot.udpTruncatedResponseCount,
            state.session.udpTruncatedResponseCount
        )
        XCTAssertEqual(snapshot.tcpFallbackAttemptCount, state.session.tcpFallbackAttemptCount)
        XCTAssertEqual(snapshot.tcpFallbackSuccessCount, state.session.tcpFallbackSuccessCount)
        XCTAssertEqual(
            snapshot.deviceDNSFallbackAttemptCount,
            state.session.deviceDNSFallbackAttemptCount
        )
        XCTAssertEqual(
            snapshot.deviceDNSFallbackSuccessCount,
            state.session.deviceDNSFallbackSuccessCount
        )
        XCTAssertEqual(snapshot.deviceDNSUnavailableCount, state.session.deviceDNSUnavailableCount)
        XCTAssertEqual(snapshot.resolverAttemptCounts, state.session.resolverAttemptCounts)
        XCTAssertEqual(snapshot.resolverSuccessCounts, state.session.resolverSuccessCounts)
        XCTAssertEqual(snapshot.resolverFailureCounts, state.session.resolverFailureCounts)
    }

    func testStateGatewayReturnsNextStateAndTransitionForMeaningfulPath() {
        let state = seededState()
        var snapshot = providerOwnedBase()
        ResolverHealthSnapshotProjection(state: state).apply(to: &snapshot)

        let reduction = ResolverHealthGateway.reduce(
            state: state,
            event: .networkPathObserved(
                previousKind: .wifi,
                previousIsSatisfied: true,
                kind: .cellular,
                isSatisfied: false,
                observedAt: later
            ),
            projectingOnto: snapshot
        )
        let transition = reduction.transition

        XCTAssertEqual(reduction.state.identity.primaryIdentifier, "primary-a")
        XCTAssertEqual(reduction.state.episode.deviceDNSFallbackEvidenceCount, 0)
        XCTAssertFalse(reduction.state.episode.deviceDNSFallbackModeActive)
        XCTAssertEqual(reduction.state.episode.consecutiveCarriedQueryFailureCount, 0)
        XCTAssertEqual(reduction.state.episode.lastAcceptedPrimaryEvidenceAt, start)
        XCTAssertEqual(reduction.state.reconnectEpisode?.startedAt, start)
        XCTAssertEqual(reduction.state.reconnectEpisode?.reason, "timeout")
        XCTAssertEqual(reduction.state.reconnectEpisode?.peakUpstreamFailureCount, 11)
        XCTAssertNil(reduction.state.effectDelivery.lastReconnectNeededActivityAt)

        var projected = snapshot
        transition.projection.apply(to: &projected)
        XCTAssertEqual(projected.networkKind, .wired)
        XCTAssertEqual(projected.networkChangeCount, 8)
        XCTAssertEqual(projected.lastNetworkChangeAt, later)
        XCTAssertFalse(projected.networkPathIsSatisfied)
        XCTAssertEqual(projected.consecutiveRejectedSmokeResponseCount, 3)
        XCTAssertEqual(projected.dnsSmokeProbeFailureCount, 9)
        XCTAssertEqual(
            transition.effects,
            [
                .endEncryptedFallbackLogEpisode(.contextReset),
                .cancelWedgeRecoveryProbe,
                .clearDeviceDNSRecaptureRestartPending,
                .cancelFallbackRecoveryProbe,
                .requestResolverRuntimeReset(
                    .full(reason: "network-path-changed", force: true)
                ),
                .signalConnectivityProjectionChanged,
                .appendNetworkActivity(
                    .networkChanged(from: .wifi, to: .cellular, isSatisfied: false),
                    at: later
                ),
                .evaluateQAConnectivityLog(reason: "network-path-changed", at: later),
                .persistHealth(.immediate),
                .evaluateProtectionNotification(at: later),
                .deliverPendingResolverFailures(reason: "network-path-changed"),
            ]
        )
    }

    func testStateGatewayRoundTripsEveryReducerOwnedFieldForAnUnchangedPath() {
        let state = seededState()
        var snapshot = providerOwnedBase()
        ResolverHealthSnapshotProjection(state: state).apply(to: &snapshot)

        let reduction = ResolverHealthGateway.reduce(
            state: state,
            event: .networkPathObserved(
                previousKind: snapshot.networkKind,
                previousIsSatisfied: snapshot.networkPathIsSatisfied,
                kind: snapshot.networkKind,
                isSatisfied: snapshot.networkPathIsSatisfied,
                observedAt: later
            ),
            projectingOnto: snapshot
        )
        let transition = reduction.transition

        var projected = snapshot
        transition.projection.apply(to: &projected)
        XCTAssertEqual(projected, snapshot)
        XCTAssertEqual(reduction.state, state)
        XCTAssertEqual(
            transition.effects,
            [.signalConnectivityProjectionChanged, .persistHealth(.deferred)]
        )
    }

    private func seededState() -> ResolverHealthEvidenceState {
        ResolverHealthEvidenceState(
            identity: ResolverIdentityEvidence(
                primaryIdentifier: "primary-a",
                rejectedResponseCount: 3,
                rejectedResponseResolverIdentifier: "primary-a"
            ),
            episode: ResolverNetworkEpisodeEvidence(
                lastFailureReason: "timeout",
                consecutiveUpstreamFailureCount: 8,
                consecutiveSmokeProbeFailureCount: 6,
                deviceDNSFallbackEvidenceCount: 2,
                deviceDNSFallbackModeActive: true,
                lastDeviceDNSFallbackActivatedAt: start,
                consecutiveCarriedQueryFailureCount: 2,
                lastEncryptedFallbackSuccessAt: start,
                lastAcceptedPrimaryEvidenceAt: start
            ),
            session: ResolverTunnelSessionEvidence(
                networkPathIsSatisfied: true,
                lastResolverAddress: "https://primary.example/dns-query",
                lastResolverTransport: .dnsOverHTTPS,
                lastDoHHTTPVersion: "h3",
                lastDNSSmokeProbeAt: start,
                lastDNSSmokeProbeSucceeded: false,
                dnsSmokeProbeSuccessCount: 10,
                lastUpstreamFailureAt: start,
                lastNetworkChangeAt: start,
                networkChangeCount: 7,
                lastResolverRuntimeResetAt: start,
                lastResolverRuntimeResetReason: "earlier-reset",
                lastResolverIdentityChangeAt: start,
                resolverRuntimeResetCount: 5,
                rejectedResponseRescopeCount: 5,
                dnsSmokeProbeFailureCount: 9,
                deviceDNSFallbackActivationCount: 4,
                upstreamSuccessCount: 12,
                upstreamFailureCount: 13,
                lastUpstreamSuccessAt: start,
                lastPrimaryUpstreamSuccessAt: start,
                lastUpstreamDurationMilliseconds: 2_500,
                slowUpstreamResponseCount: 14,
                consecutiveSlowUpstreamResponseCount: 2,
                lastSlowUpstreamResponseAt: start,
                dohHTTPFailureCount: 15,
                upstreamTimeoutCount: 16,
                udpTruncatedResponseCount: 17,
                tcpFallbackAttemptCount: 18,
                tcpFallbackSuccessCount: 19,
                deviceDNSFallbackAttemptCount: 20,
                deviceDNSFallbackSuccessCount: 21,
                deviceDNSUnavailableCount: 22,
                resolverAttemptCounts: ["attempt": 23],
                resolverSuccessCounts: ["success": 24],
                resolverFailureCounts: ["failure": 25]
            ),
            reconnectEpisode: ResolverReconnectEpisodeEvidence(
                startedAt: start,
                reason: "timeout",
                peakUpstreamFailureCount: 11
            ),
            effectDelivery: ResolverHealthEffectDeliveryState(
                lastReconnectNeededActivityAt: start
            )
        )
    }

    private func providerOwnedBase() -> TunnelHealthSnapshot {
        TunnelHealthSnapshot(
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            networkKind: .wired,
            cacheHitCount: 31,
            cacheMissCount: 32,
            coalescedQueryCount: 33,
            lastNetworkSettingsReapplyFailureAt: Date(timeIntervalSince1970: 300),
            lastNetworkSettingsReapplyFailureReason: "provider-owned",
            networkSettingsReapplyFailureCount: 34,
            failClosedServedQueryCount: 35,
            lastFailClosedAt: Date(timeIntervalSince1970: 400),
            lastFailClosedReason: "snapshot-unavailable"
        )
    }

}
