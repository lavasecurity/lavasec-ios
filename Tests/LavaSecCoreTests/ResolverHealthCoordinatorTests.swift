import Dispatch
import Foundation
import XCTest

@testable import LavaSecDNS
@testable import LavaSecKit

final class ResolverHealthCoordinatorTests: XCTestCase {
    private let queue = DispatchSerialQueue(label: "resolver-health-coordinator-tests")
    private let occurredAt = Date(timeIntervalSince1970: 2_000)

    func testAssumeIsolatedProvidesSynchronousDNSQueueAccess() {
        let coordinator = ResolverHealthCoordinator(queue: queue)
        let snapshot = resolverHealthProviderSnapshot()
        let occurredAt = self.occurredAt

        queue.sync {
            coordinator.assumeIsolated { isolated in
                let transition = isolated.apply(
                    .networkPathObserved(
                        previousKind: nil,
                        previousIsSatisfied: nil,
                        kind: .wifi,
                        isSatisfied: false,
                        observedAt: occurredAt
                    ),
                    projectingOnto: snapshot
                )
                var projected = snapshot
                transition.projection.apply(to: &projected)

                XCTAssertFalse(projected.networkPathIsSatisfied)
                XCTAssertFalse(isolated.schedulingView.networkPathIsSatisfied)
            }
        }
    }

    func testOverlappingBeginsMoveOwnershipAndCurrentCompletionAdvancesTheFence() {
        let coordinator = ResolverHealthCoordinator(queue: queue)
        let snapshot = resolverHealthProviderSnapshot()
        let completion = failedResolverSmokeCompletion(at: occurredAt)

        queue.sync {
            coordinator.assumeIsolated { isolated in
                let first = isolated.beginSmokeProbe()
                let second = isolated.beginSmokeProbe()

                XCTAssertNotEqual(first.token, second.token)
                XCTAssertEqual(second.rotationSequence, first.rotationSequence + 1)
                XCTAssertNil(
                    isolated.completeSmokeProbe(
                        completion,
                        token: first.token,
                        projectingOnto: snapshot
                    )
                )

                let transition = isolated.completeSmokeProbe(
                    completion,
                    token: second.token,
                    projectingOnto: snapshot
                )
                XCTAssertNotNil(transition)
                XCTAssertNil(
                    isolated.completeSmokeProbe(
                        completion,
                        token: second.token,
                        projectingOnto: snapshot
                    )
                )

                let third = isolated.beginSmokeProbe()
                XCTAssertEqual(third.rotationSequence, second.rotationSequence + 2)
            }
        }
    }

    func testCurrentCompletionAppliesExactlyOnce() {
        let coordinator = ResolverHealthCoordinator(queue: queue)
        let snapshot = resolverHealthProviderSnapshot()
        let completion = failedResolverSmokeCompletion(at: occurredAt)

        queue.sync {
            coordinator.assumeIsolated { isolated in
                let start = isolated.beginSmokeProbe()
                let transition = isolated.completeSmokeProbe(
                    completion,
                    token: start.token,
                    projectingOnto: snapshot
                )
                var projected = snapshot
                transition?.projection.apply(to: &projected)

                XCTAssertEqual(projected.dnsSmokeProbeFailureCount, 1)
                XCTAssertEqual(projected.consecutiveDNSSmokeProbeFailureCount, 1)
                XCTAssertNil(
                    isolated.completeSmokeProbe(
                        completion,
                        token: start.token,
                        projectingOnto: snapshot
                    )
                )
            }
        }
    }

    func testBriefWakeInvalidationRejectsStaleCompletionWithoutResettingEvidence() {
        let state = resolverHealthCoordinatorSeededState(at: occurredAt)
        let coordinator = ResolverHealthCoordinator(queue: queue, state: state)
        let snapshot = resolverHealthProviderSnapshot()
        let completion = failedResolverSmokeCompletion(at: occurredAt)
        let followUpEvent = ResolverHealthGatewayEvent.networkPathObserved(
            previousKind: .wifi,
            previousIsSatisfied: false,
            kind: .wifi,
            isSatisfied: false,
            observedAt: occurredAt.addingTimeInterval(1)
        )
        let expectedFollowUp = ResolverHealthGateway.reduce(
            state: state,
            event: followUpEvent,
            projectingOnto: snapshot
        )

        queue.sync {
            coordinator.assumeIsolated { isolated in
                let viewBeforeInvalidation = isolated.schedulingView
                let start = isolated.beginSmokeProbe()

                isolated.invalidateInFlightSmokeProbe()

                XCTAssertNil(
                    isolated.completeSmokeProbe(
                        completion,
                        token: start.token,
                        projectingOnto: snapshot
                    )
                )
                XCTAssertEqual(isolated.schedulingView, viewBeforeInvalidation)

                let followUp = isolated.apply(
                    followUpEvent,
                    projectingOnto: snapshot
                )
                XCTAssertEqual(followUp.projection.evidenceState, expectedFollowUp.state)
                XCTAssertEqual(followUp.effects, expectedFollowUp.transition.effects)

                var projected = snapshot
                followUp.projection.apply(to: &projected)
                var expectedProjection = snapshot
                expectedFollowUp.transition.projection.apply(to: &expectedProjection)
                XCTAssertEqual(projected, expectedProjection)
            }
        }
    }

    func testLifecycleResetClearsEvidenceAndRetiresTheCurrentProbe() {
        let occurredAt = self.occurredAt
        let coordinator = ResolverHealthCoordinator(
            queue: queue,
            state: resolverHealthCoordinatorSeededState(at: occurredAt)
        )
        let snapshot = resolverHealthProviderSnapshot()
        let completion = failedResolverSmokeCompletion(at: occurredAt)

        queue.sync {
            coordinator.assumeIsolated { isolated in
                let start = isolated.beginSmokeProbe()
                _ = isolated.apply(
                    .lifecycleReset(occurredAt: occurredAt),
                    projectingOnto: snapshot
                )

                XCTAssertNil(
                    isolated.completeSmokeProbe(
                        completion,
                        token: start.token,
                        projectingOnto: snapshot
                    )
                )
                XCTAssertEqual(
                    isolated.schedulingView,
                    ResolverHealthSchedulingView(
                        networkPathIsSatisfied: true,
                        consecutiveUpstreamFailureCount: 0,
                        consecutiveSmokeProbeFailureCount: 0,
                        consecutiveRejectedResponseCount: 0,
                        deviceDNSFallbackEvidenceCount: 0,
                        deviceDNSFallbackModeActive: false,
                        lastAcceptedPrimaryEvidenceAt: nil,
                        reconnectEpisodeIsActive: false
                    )
                )
            }
        }
    }

    func testCoordinatorAccumulatesStateWithoutProviderRoundTrip() {
        let coordinator = ResolverHealthCoordinator(queue: queue)
        let staleSnapshot = resolverHealthProviderSnapshot()
        let occurredAt = self.occurredAt

        queue.sync {
            coordinator.assumeIsolated { isolated in
                _ = isolated.apply(
                    .networkPathObserved(
                        previousKind: nil,
                        previousIsSatisfied: nil,
                        kind: .wifi,
                        isSatisfied: true,
                        observedAt: occurredAt
                    ),
                    projectingOnto: staleSnapshot
                )
                _ = isolated.apply(
                    .networkPathObserved(
                        previousKind: .wifi,
                        previousIsSatisfied: true,
                        kind: .cellular,
                        isSatisfied: true,
                        observedAt: occurredAt.addingTimeInterval(1)
                    ),
                    projectingOnto: staleSnapshot
                )
                let transition = isolated.apply(
                    .networkPathObserved(
                        previousKind: .cellular,
                        previousIsSatisfied: true,
                        kind: .wired,
                        isSatisfied: true,
                        observedAt: occurredAt.addingTimeInterval(2)
                    ),
                    projectingOnto: staleSnapshot
                )
                var projected = staleSnapshot
                transition.projection.apply(to: &projected)

                XCTAssertEqual(projected.networkChangeCount, 2)
            }
        }
    }

    func testSchedulingViewMapsEveryProviderGuardInput() {
        let occurredAt = self.occurredAt
        let state = resolverHealthCoordinatorSeededState(at: occurredAt)
        let coordinator = ResolverHealthCoordinator(queue: queue, state: state)

        queue.sync {
            coordinator.assumeIsolated { isolated in
                XCTAssertEqual(
                    isolated.schedulingView,
                    ResolverHealthSchedulingView(
                        networkPathIsSatisfied: false,
                        consecutiveUpstreamFailureCount: 3,
                        consecutiveSmokeProbeFailureCount: 4,
                        consecutiveRejectedResponseCount: 2,
                        deviceDNSFallbackEvidenceCount: 5,
                        deviceDNSFallbackModeActive: true,
                        lastAcceptedPrimaryEvidenceAt: occurredAt,
                        reconnectEpisodeIsActive: true
                    )
                )
            }
        }
    }
}

private func resolverHealthCoordinatorSeededState(
    at occurredAt: Date
) -> ResolverHealthEvidenceState {
    ResolverHealthEvidenceState(
        identity: ResolverIdentityEvidence(
            primaryIdentifier: "primary-a",
            rejectedResponseCount: 2,
            rejectedResponseResolverIdentifier: "primary-a"
        ),
        episode: ResolverNetworkEpisodeEvidence(
            lastFailureReason: "timeout",
            consecutiveUpstreamFailureCount: 3,
            consecutiveSmokeProbeFailureCount: 4,
            deviceDNSFallbackEvidenceCount: 5,
            deviceDNSFallbackModeActive: true,
            lastDeviceDNSFallbackActivatedAt: occurredAt,
            consecutiveCarriedQueryFailureCount: 2,
            lastEncryptedFallbackSuccessAt: occurredAt,
            lastAcceptedPrimaryEvidenceAt: occurredAt
        ),
        session: ResolverTunnelSessionEvidence(
            networkPathIsSatisfied: false,
            lastResolverAddress: "https://primary.example/dns-query",
            lastResolverTransport: .dnsOverHTTPS,
            lastDoHHTTPVersion: "h3",
            lastDNSSmokeProbeAt: occurredAt,
            lastDNSSmokeProbeSucceeded: false,
            dnsSmokeProbeSuccessCount: 7,
            lastUpstreamFailureAt: occurredAt,
            lastNetworkChangeAt: occurredAt,
            networkChangeCount: 8,
            lastResolverRuntimeResetAt: occurredAt,
            lastResolverRuntimeResetReason: "earlier-reset",
            lastResolverIdentityChangeAt: occurredAt,
            resolverRuntimeResetCount: 9,
            rejectedResponseRescopeCount: 10,
            dnsSmokeProbeFailureCount: 11,
            deviceDNSFallbackActivationCount: 12,
            upstreamSuccessCount: 13,
            upstreamFailureCount: 14,
            lastUpstreamSuccessAt: occurredAt,
            lastPrimaryUpstreamSuccessAt: occurredAt,
            lastUpstreamDurationMilliseconds: 2_500,
            slowUpstreamResponseCount: 15,
            consecutiveSlowUpstreamResponseCount: 16,
            lastSlowUpstreamResponseAt: occurredAt,
            dohHTTPFailureCount: 17,
            upstreamTimeoutCount: 18,
            udpTruncatedResponseCount: 19,
            tcpFallbackAttemptCount: 20,
            tcpFallbackSuccessCount: 21,
            deviceDNSFallbackAttemptCount: 22,
            deviceDNSFallbackSuccessCount: 23,
            deviceDNSUnavailableCount: 24,
            resolverAttemptCounts: ["attempt": 25],
            resolverSuccessCounts: ["success": 26],
            resolverFailureCounts: ["failure": 27]
        ),
        reconnectEpisode: ResolverReconnectEpisodeEvidence(
            startedAt: occurredAt,
            reason: "timeout",
            peakUpstreamFailureCount: 6
        ),
        effectDelivery: ResolverHealthEffectDeliveryState(
            lastReconnectNeededActivityAt: occurredAt
        )
    )
}

private func failedResolverSmokeCompletion(
    at occurredAt: Date
) -> ResolverHealthSmokeProbeCompletion {
    ResolverHealthSmokeProbeCompletion(
        occurredAt: occurredAt,
        reason: "periodic-health-check",
        primaryResult: DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: [
                ResolverAttempt(
                    address: "192.0.2.53",
                    outcome: .timeout,
                    transport: .plainDNS
                )
            ],
            transport: .plainDNS,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false
        ),
        primaryAccepted: false,
        fallbackResult: nil,
        fallbackAccepted: false,
        modeInsensitivePrimaryIdentifier: "primary-a",
        configuredResolverDisplayName: "Device DNS"
    )
}
