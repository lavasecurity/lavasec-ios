import Foundation
import XCTest

@testable import LavaSecDNS
@testable import LavaSecKit

final class ResolverHealthOrganicEvidenceTests: XCTestCase {
    private struct PrimaryResponseCase {
        let response: Data
        let expectedPrimaryAt: Date?
        let expectedSmokeFailures: Int
        let expectedAcceptedAt: Date?
    }

    private let start = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    func testEvidenceCanonicalizesResponseQualityAndServingRoute() {
        let failed = evidence(
            result: result(response: nil, outcome: .timeout)
        )
        XCTAssertEqual(failed.outcome, .totalFailure(reason: "timeout"))

        let accepted = evidence(
            result: result(response: acceptedAnswer(), outcome: .success)
        )
        XCTAssertEqual(
            accepted.outcome,
            .resolved(.selectedResolver(.acceptedAnswer))
        )

        let negative = evidence(
            result: result(response: response(flags: 0x8183), outcome: .success)
        )
        XCTAssertEqual(
            negative.outcome,
            .resolved(.selectedResolver(.servedAnswer))
        )

        for flags in [UInt16(0x8182), UInt16(0x8185)] {
            let rejected = evidence(
                result: result(response: response(flags: flags), outcome: .success)
            )
            XCTAssertEqual(
                rejected.outcome,
                .resolved(.selectedResolver(.clientFailureResponse))
            )
        }
        let malformed = evidence(
            result: result(
                response: response(flags: 0x8180, answerCount: 1),
                outcome: .success
            )
        )
        guard case .resolved(let malformedResolution) = malformed.outcome else {
            return XCTFail("Expected malformed response classification")
        }
        XCTAssertEqual(malformedResolution, .selectedResolver(.clientFailureResponse))

        let encryptedFallback = evidence(
            result: result(
                response: acceptedAnswer(),
                outcome: .success,
                transport: .dnsOverHTTPS,
                usedEncryptedFallback: true
            )
        )
        guard case .resolved(let encryptedResolution) = encryptedFallback.outcome else {
            return XCTFail("Expected resolved encrypted fallback")
        }
        XCTAssertEqual(encryptedResolution, .encryptedFallback)

        let deviceFallback = evidence(
            result: result(
                response: acceptedAnswer(),
                outcome: .success,
                transport: .deviceDNS,
                attemptTransport: .dnsOverHTTPS,
                deviceDNSFallbackAttempted: true,
                deviceDNSFallbackSucceeded: true
            )
        )
        guard case .resolved(let deviceResolution) = deviceFallback.outcome else {
            return XCTFail("Expected resolved Device-DNS fallback")
        }
        XCTAssertEqual(
            deviceResolution,
            .deviceDNSFallback(primaryHadFallbackActivationEvidence: true)
        )
    }

    func testStateGatewayConvertsOrganicEncryptedFallbackCarry() {
        let encryptedResult = result(
            response: acceptedAnswer(),
            outcome: .success,
            transport: .dnsOverHTTPS,
            usedEncryptedFallback: true
        )
        var state = ResolverHealthEvidenceState()
        state.identity.primaryIdentifier = "primary-a"
        let reduction = ResolverHealthGateway.reduce(
            state: state,
            event: .organicUpstreamCompleted(
                ResolverHealthOrganicUpstreamCompletion(
                    occurredAt: later,
                    result: encryptedResult
                )
            ),
            projectingOnto: providerBase()
        )
        let transition = reduction.transition
        var projected = providerBase()
        transition.projection.apply(to: &projected)

        XCTAssertEqual(reduction.state.session.upstreamSuccessCount, 1)
        XCTAssertEqual(reduction.state.episode.lastEncryptedFallbackSuccessAt, later)
        XCTAssertEqual(projected.upstreamSuccessCount, 1)
        XCTAssertEqual(projected.lastEncryptedFallbackSuccessAt, later)
        XCTAssertEqual(
            transition.effects,
            [
                .scheduleWedgeRecoveryProbe,
                .signalConnectivityProjectionChanged,
                .persistHealth(.deferred),
                .recordEncryptedFallbackCarry(
                    ResolverHealthGatewayEncryptedFallbackCarry(
                        occurredAt: later,
                        transport: .dnsOverHTTPS,
                        resolverAddress: "192.0.2.1"
                    )
                ),
                .evaluateQAConnectivityLog(reason: "upstream-success", at: later),
                .evaluateProtectionNotification(at: later),
            ]
        )
    }

    func testTotalFailuresPreserveActiveModeAndClearEncryptedCoverageOnlyAtThree() {
        var state = ResolverHealthEvidenceState()
        state.identity.rejectedResponseCount = 2
        state.identity.rejectedResponseResolverIdentifier = "primary-a"
        state.episode.consecutiveSmokeProbeFailureCount = 2
        state.episode.deviceDNSFallbackEvidenceCount = 3
        state.episode.deviceDNSFallbackModeActive = true
        state.episode.lastDeviceDNSFallbackActivatedAt = start
        state.episode.lastEncryptedFallbackSuccessAt = start
        state.episode.lastAcceptedPrimaryEvidenceAt = start
        state.session.upstreamSuccessCount = 7
        state.session.upstreamFailureCount = 10
        state.session.consecutiveSlowUpstreamResponseCount = 2

        for failureIndex in 1...3 {
            let occurredAt = later.addingTimeInterval(TimeInterval(failureIndex - 1))
            let transition = ResolverHealthReducer.reduce(
                state: state,
                event: .organicUpstreamCompleted(
                    evidence(
                        occurredAt: occurredAt,
                        result: result(response: nil, outcome: .timeout)
                    )
                ),
                projectingOnto: providerBase()
            )
            state = transition.state

            XCTAssertEqual(state.session.upstreamSuccessCount, 7)
            XCTAssertEqual(state.session.upstreamFailureCount, 10 + failureIndex)
            XCTAssertEqual(state.episode.consecutiveUpstreamFailureCount, failureIndex)
            XCTAssertEqual(state.episode.consecutiveSmokeProbeFailureCount, 2)
            XCTAssertEqual(state.episode.consecutiveCarriedQueryFailureCount, failureIndex)
            XCTAssertEqual(state.episode.deviceDNSFallbackEvidenceCount, 0)
            XCTAssertTrue(state.episode.deviceDNSFallbackModeActive)
            XCTAssertEqual(state.episode.lastDeviceDNSFallbackActivatedAt, start)
            XCTAssertNil(state.episode.lastAcceptedPrimaryEvidenceAt)
            XCTAssertEqual(state.episode.lastFailureReason, "timeout")
            XCTAssertEqual(state.session.lastUpstreamFailureAt, occurredAt)
            XCTAssertEqual(state.session.lastResolverAddress, "192.0.2.1")
            XCTAssertEqual(state.session.lastResolverTransport, .plainDNS)
            XCTAssertEqual(state.session.consecutiveSlowUpstreamResponseCount, 0)
            XCTAssertEqual(state.session.upstreamTimeoutCount, failureIndex)
            XCTAssertEqual(state.session.resolverAttemptCounts, ["192.0.2.1": failureIndex])
            XCTAssertEqual(state.session.resolverFailureCounts, ["192.0.2.1": failureIndex])
            XCTAssertEqual(state.identity.rejectedResponseCount, 2)
            XCTAssertEqual(state.identity.rejectedResponseResolverIdentifier, "primary-a")
            XCTAssertEqual(
                state.episode.lastEncryptedFallbackSuccessAt,
                failureIndex < 3 ? start : nil
            )

            if failureIndex < 3 {
                XCTAssertEqual(
                    transition.effects,
                    [
                        .signalConnectivityProjectionChanged,
                        .persistHealth(.deferred),
                        .evaluateQAConnectivityLog(reason: "upstream-failure", at: occurredAt),
                    ]
                )
            } else {
                XCTAssertEqual(
                    transition.effects,
                    [
                        .signalConnectivityProjectionChanged,
                        .persistHealth(.deferred),
                        .recordIncident(
                            ResolverHealthIncident(
                                kind: .wedgeDetected,
                                occurredAt: occurredAt,
                                reason: "timeout",
                                durationMilliseconds: nil,
                                verifiedBy: nil
                            )
                        ),
                        .appendNetworkActivity(.reconnectNeeded(reason: "timeout"), at: occurredAt),
                        .evaluateSelfReconnect(at: occurredAt),
                        .scheduleWedgeRecoveryProbe,
                        .evaluateQAConnectivityLog(reason: "upstream-failure", at: occurredAt),
                    ]
                )
                XCTAssertEqual(state.reconnectEpisode?.startedAt, occurredAt)
                XCTAssertEqual(state.reconnectEpisode?.reason, "timeout")
                XCTAssertEqual(state.reconnectEpisode?.peakUpstreamFailureCount, 3)
            }
        }
    }

    func testEncryptedFallbackSuccessRecordsCoverageWithoutPrimaryRecovery() {
        var state = ResolverHealthEvidenceState()
        state.identity.rejectedResponseCount = 2
        state.identity.rejectedResponseResolverIdentifier = "primary-a"
        state.episode.lastFailureReason = "timeout"
        state.episode.consecutiveUpstreamFailureCount = 4
        state.episode.consecutiveSmokeProbeFailureCount = 3
        state.episode.deviceDNSFallbackEvidenceCount = 2
        state.episode.consecutiveCarriedQueryFailureCount = 2
        state.episode.lastAcceptedPrimaryEvidenceAt = start
        state.session.upstreamSuccessCount = 5
        state.session.upstreamFailureCount = 2
        state.session.lastPrimaryUpstreamSuccessAt = start
        state.session.slowUpstreamResponseCount = 4
        state.session.consecutiveSlowUpstreamResponseCount = 1
        state.reconnectEpisode = ResolverReconnectEpisodeEvidence(
            startedAt: start,
            reason: "timeout",
            peakUpstreamFailureCount: 5
        )

        let transition = ResolverHealthReducer.reduce(
            state: state,
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(
                        response: acceptedAnswer(),
                        outcome: .success,
                        transport: .dnsOverHTTPS,
                        usedEncryptedFallback: true,
                        durationMilliseconds: 3_000,
                        negotiatedDoHProtocol: "h3"
                    )
                )
            ),
            projectingOnto: providerBase()
        )

        XCTAssertEqual(transition.state.session.upstreamSuccessCount, 6)
        XCTAssertEqual(transition.state.session.upstreamFailureCount, 2)
        XCTAssertEqual(transition.state.session.lastUpstreamSuccessAt, later)
        XCTAssertEqual(transition.state.session.lastPrimaryUpstreamSuccessAt, start)
        XCTAssertEqual(transition.state.episode.consecutiveUpstreamFailureCount, 0)
        XCTAssertEqual(transition.state.episode.consecutiveSmokeProbeFailureCount, 3)
        XCTAssertEqual(transition.state.episode.consecutiveCarriedQueryFailureCount, 0)
        XCTAssertEqual(transition.state.episode.deviceDNSFallbackEvidenceCount, 0)
        XCTAssertNil(transition.state.episode.lastAcceptedPrimaryEvidenceAt)
        XCTAssertEqual(transition.state.episode.lastEncryptedFallbackSuccessAt, later)
        XCTAssertNil(transition.state.episode.lastFailureReason)
        XCTAssertEqual(transition.state.session.slowUpstreamResponseCount, 5)
        XCTAssertEqual(transition.state.session.consecutiveSlowUpstreamResponseCount, 2)
        XCTAssertEqual(transition.state.session.lastSlowUpstreamResponseAt, later)
        XCTAssertEqual(transition.state.session.lastDoHHTTPVersion, "h3")
        XCTAssertEqual(transition.state.session.resolverSuccessCounts, ["192.0.2.1": 1])
        XCTAssertEqual(transition.state.identity.rejectedResponseCount, 2)
        XCTAssertEqual(transition.state.identity.rejectedResponseResolverIdentifier, "primary-a")
        XCTAssertEqual(transition.state.reconnectEpisode, state.reconnectEpisode)
        XCTAssertEqual(
            transition.effects,
            [
                .scheduleWedgeRecoveryProbe,
                .signalConnectivityProjectionChanged,
                .persistHealth(.deferred),
                .recordEncryptedFallbackCarry(
                    ResolverEncryptedFallbackCarry(
                        occurredAt: later,
                        transport: .dnsOverHTTPS,
                        resolverAddress: "192.0.2.1"
                    )
                ),
                .evaluateQAConnectivityLog(reason: "upstream-success", at: later),
                .evaluateProtectionNotification(at: later),
            ]
        )
    }

    func testConfiguredPrimaryResponseQualityUsesThreeDistinctEvidenceBars() {
        let cases = [
            PrimaryResponseCase(
                response: acceptedAnswer(),
                expectedPrimaryAt: later,
                expectedSmokeFailures: 0,
                expectedAcceptedAt: later
            ),
            PrimaryResponseCase(
                response: response(flags: 0x8180),
                expectedPrimaryAt: later,
                expectedSmokeFailures: 0,
                expectedAcceptedAt: start
            ),
            PrimaryResponseCase(
                response: response(flags: 0x8182),
                expectedPrimaryAt: start,
                expectedSmokeFailures: 4,
                expectedAcceptedAt: nil
            ),
            PrimaryResponseCase(
                response: response(flags: 0x8180, answerCount: 1),
                expectedPrimaryAt: start,
                expectedSmokeFailures: 4,
                expectedAcceptedAt: nil
            ),
        ]

        for testCase in cases {
            var state = ResolverHealthEvidenceState()
            state.identity.rejectedResponseCount = 2
            state.identity.rejectedResponseResolverIdentifier = "primary-a"
            state.episode.lastFailureReason = "timeout"
            state.episode.consecutiveUpstreamFailureCount = 3
            state.episode.consecutiveSmokeProbeFailureCount = 4
            state.episode.deviceDNSFallbackEvidenceCount = 2
            state.episode.consecutiveCarriedQueryFailureCount = 2
            state.episode.lastEncryptedFallbackSuccessAt = start
            state.episode.lastAcceptedPrimaryEvidenceAt = start
            state.session.upstreamSuccessCount = 5
            state.session.upstreamFailureCount = 2
            state.session.lastPrimaryUpstreamSuccessAt = start
            state.session.consecutiveSlowUpstreamResponseCount = 2

            let transition = ResolverHealthReducer.reduce(
                state: state,
                event: .organicUpstreamCompleted(
                    evidence(
                        result: result(
                            response: testCase.response,
                            outcome: .success,
                            transport: .plainDNS,
                            durationMilliseconds: 250
                        )
                    )
                ),
                projectingOnto: providerBase()
            )

            XCTAssertEqual(transition.state.session.upstreamSuccessCount, 6)
            XCTAssertEqual(transition.state.session.upstreamFailureCount, 2)
            XCTAssertEqual(transition.state.session.lastUpstreamSuccessAt, later)
            XCTAssertEqual(
                transition.state.session.lastPrimaryUpstreamSuccessAt,
                testCase.expectedPrimaryAt
            )
            XCTAssertEqual(
                transition.state.episode.consecutiveSmokeProbeFailureCount,
                testCase.expectedSmokeFailures
            )
            XCTAssertEqual(
                transition.state.episode.lastAcceptedPrimaryEvidenceAt,
                testCase.expectedAcceptedAt
            )
            XCTAssertNil(transition.state.episode.lastEncryptedFallbackSuccessAt)
            XCTAssertEqual(transition.state.episode.consecutiveUpstreamFailureCount, 0)
            XCTAssertEqual(transition.state.episode.consecutiveCarriedQueryFailureCount, 0)
            XCTAssertEqual(transition.state.episode.deviceDNSFallbackEvidenceCount, 0)
            XCTAssertNil(transition.state.episode.lastFailureReason)
            XCTAssertEqual(transition.state.session.consecutiveSlowUpstreamResponseCount, 0)
            XCTAssertEqual(transition.state.identity.rejectedResponseCount, 2)
            XCTAssertEqual(
                transition.state.identity.rejectedResponseResolverIdentifier,
                "primary-a"
            )
            XCTAssertEqual(
                transition.effects,
                [
                    .cancelWedgeRecoveryProbe,
                    .clearDeviceDNSRecaptureRestartPending,
                    .signalConnectivityProjectionChanged,
                    .persistHealth(.deferred),
                    .endEncryptedFallbackLogEpisode(.episodeEnd),
                    .evaluateQAConnectivityLog(reason: "upstream-success", at: later),
                    .evaluateProtectionNotification(at: later),
                ]
            )
        }
    }

    func testClientFailureResponseStillRecoversWedgeAndExitsFallbackMode() {
        var state = ResolverHealthEvidenceState()
        state.identity.rejectedResponseCount = 2
        state.identity.rejectedResponseResolverIdentifier = "primary-a"
        state.episode.consecutiveSmokeProbeFailureCount = 4
        state.episode.deviceDNSFallbackEvidenceCount = 3
        state.episode.deviceDNSFallbackModeActive = true
        state.episode.lastDeviceDNSFallbackActivatedAt = start
        state.episode.lastEncryptedFallbackSuccessAt = start
        state.episode.lastAcceptedPrimaryEvidenceAt = start
        state.session.upstreamSuccessCount = 5
        state.session.lastPrimaryUpstreamSuccessAt = start
        state.reconnectEpisode = ResolverReconnectEpisodeEvidence(
            startedAt: start,
            reason: "rejected-response",
            peakUpstreamFailureCount: 7
        )
        state.effectDelivery.lastReconnectNeededActivityAt = start

        let transition = ResolverHealthReducer.reduce(
            state: state,
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(
                        response: response(flags: 0x8182),
                        outcome: .success,
                        transport: .plainDNS
                    )
                )
            ),
            projectingOnto: providerBase()
        )

        XCTAssertEqual(transition.state.session.upstreamSuccessCount, 6)
        XCTAssertEqual(transition.state.session.lastUpstreamSuccessAt, later)
        XCTAssertEqual(transition.state.session.lastPrimaryUpstreamSuccessAt, start)
        XCTAssertEqual(transition.state.episode.consecutiveSmokeProbeFailureCount, 4)
        XCTAssertNil(transition.state.episode.lastAcceptedPrimaryEvidenceAt)
        XCTAssertNil(transition.state.episode.lastEncryptedFallbackSuccessAt)
        XCTAssertFalse(transition.state.episode.deviceDNSFallbackModeActive)
        XCTAssertEqual(transition.state.episode.deviceDNSFallbackEvidenceCount, 0)
        XCTAssertNil(transition.state.episode.lastDeviceDNSFallbackActivatedAt)
        XCTAssertEqual(transition.state.identity.rejectedResponseCount, 2)
        XCTAssertEqual(
            transition.state.identity.rejectedResponseResolverIdentifier,
            "primary-a"
        )
        XCTAssertNil(transition.state.reconnectEpisode)
        XCTAssertNil(transition.state.effectDelivery.lastReconnectNeededActivityAt)
        XCTAssertEqual(
            transition.effects,
            [
                .reportConnectivityRecovery(
                    ResolverHealthRecovery(
                        startedAt: start,
                        recoveredAt: later,
                        durationMilliseconds: 1_000_000,
                        reason: "rejected-response",
                        peakUpstreamFailureCount: 7,
                        transport: .plainDNS,
                        verifiedBy: "forwarding",
                        activityContext: ResolverHealthActivityContext(
                            connectivitySeverity: .usingDeviceDNSFallback,
                            networkKind: .wifi,
                            networkPathIsSatisfied: true,
                            resolverTransport: .plainDNS,
                            deviceDNSFallbackActive: true
                        )
                    )
                ),
                .endEncryptedFallbackLogEpisode(.episodeEnd),
                .cancelWedgeRecoveryProbe,
                .clearDeviceDNSRecaptureRestartPending,
                .cancelFallbackRecoveryProbe,
                .signalConnectivityProjectionChanged,
                .persistHealth(.deferred),
                .appendNetworkActivity(.deviceDNSFallbackRecovered, at: later),
                .evaluateQAConnectivityLog(reason: "upstream-success", at: later),
                .evaluateProtectionNotification(at: later),
            ]
        )
        XCTAssertFalse(
            transition.effects.contains { effect in
                if case .requestResolverRuntimeReset = effect {
                    return true
                }
                if case .deliverPendingResolverFailures = effect {
                    return true
                }
                return false
            }
        )
    }

    func testDeviceDNSQueryFallbackActivatesAtThreeWithoutRuntimeReset() {
        var state = ResolverHealthEvidenceState()
        state.episode.consecutiveSmokeProbeFailureCount = 4
        state.episode.lastAcceptedPrimaryEvidenceAt = start
        state.episode.lastEncryptedFallbackSuccessAt = start
        state.session.lastPrimaryUpstreamSuccessAt = start
        state.session.upstreamSuccessCount = 5
        state.session.deviceDNSFallbackAttemptCount = 6
        state.session.deviceDNSFallbackSuccessCount = 4
        state.session.deviceDNSFallbackActivationCount = 4

        for expectedEvidenceCount in 1...3 {
            let transition = ResolverHealthReducer.reduce(
                state: state,
                event: .organicUpstreamCompleted(
                    evidence(
                        result: result(
                            response: acceptedAnswer(),
                            outcome: .success,
                            transport: .deviceDNS,
                            attemptTransport: .dnsOverHTTPS,
                            deviceDNSFallbackAttempted: true,
                            deviceDNSFallbackSucceeded: true
                        )
                    )
                ),
                projectingOnto: providerBase()
            )
            state = transition.state

            XCTAssertEqual(
                state.episode.deviceDNSFallbackEvidenceCount,
                expectedEvidenceCount
            )
            XCTAssertEqual(state.session.upstreamSuccessCount, 5 + expectedEvidenceCount)
            XCTAssertEqual(state.session.deviceDNSFallbackAttemptCount, 6 + expectedEvidenceCount)
            XCTAssertEqual(state.session.deviceDNSFallbackSuccessCount, 4 + expectedEvidenceCount)
            XCTAssertEqual(state.session.lastPrimaryUpstreamSuccessAt, start)
            XCTAssertEqual(state.episode.consecutiveSmokeProbeFailureCount, 4)
            XCTAssertNil(state.episode.lastAcceptedPrimaryEvidenceAt)
            XCTAssertEqual(state.episode.lastEncryptedFallbackSuccessAt, start)
            XCTAssertEqual(state.session.lastResolverTransport, .deviceDNS)

            var expectedEffects: [ResolverHealthEffect] = [
                .cancelWedgeRecoveryProbe,
                .clearDeviceDNSRecaptureRestartPending,
            ]
            if expectedEvidenceCount == 3 {
                XCTAssertTrue(state.episode.deviceDNSFallbackModeActive)
                XCTAssertEqual(state.episode.lastDeviceDNSFallbackActivatedAt, later)
                XCTAssertEqual(state.session.deviceDNSFallbackActivationCount, 5)
            } else {
                XCTAssertFalse(state.episode.deviceDNSFallbackModeActive)
                XCTAssertNil(state.episode.lastDeviceDNSFallbackActivatedAt)
                XCTAssertEqual(state.session.deviceDNSFallbackActivationCount, 4)
            }
            expectedEffects.append(contentsOf: [
                .signalConnectivityProjectionChanged,
                .persistHealth(.deferred),
            ])
            if expectedEvidenceCount == 3 {
                expectedEffects.append(
                    .appendNetworkActivity(
                        .deviceDNSFallbackActivated(reason: "query-fallback"),
                        at: later
                    )
                )
            }
            expectedEffects.append(contentsOf: [
                .scheduleFallbackRecoveryProbe,
                .evaluateQAConnectivityLog(reason: "upstream-success", at: later),
                .evaluateProtectionNotification(at: later),
            ])
            XCTAssertEqual(transition.effects, expectedEffects)
            XCTAssertFalse(
                transition.effects.contains { effect in
                    if case .requestResolverRuntimeReset = effect {
                        return true
                    }
                    if case .deliverPendingResolverFailures = effect {
                        return true
                    }
                    return false
                }
            )
        }
    }

    func testDeviceDNSQueryFallbackEndsEncryptedLogOnlyWhenRecoveringWedge() {
        var state = ResolverHealthEvidenceState()
        state.reconnectEpisode = ResolverReconnectEpisodeEvidence(
            startedAt: start,
            reason: "timeout",
            peakUpstreamFailureCount: 4
        )

        let transition = ResolverHealthReducer.reduce(
            state: state,
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(
                        response: acceptedAnswer(),
                        outcome: .success,
                        transport: .deviceDNS,
                        attemptTransport: .dnsOverHTTPS,
                        deviceDNSFallbackAttempted: true,
                        deviceDNSFallbackSucceeded: true
                    )
                )
            ),
            projectingOnto: providerBase()
        )

        XCTAssertEqual(
            transition.effects,
            [
                .reportConnectivityRecovery(
                    ResolverHealthRecovery(
                        startedAt: start,
                        recoveredAt: later,
                        durationMilliseconds: 1_000_000,
                        reason: "timeout",
                        peakUpstreamFailureCount: 4,
                        transport: .deviceDNS,
                        verifiedBy: "forwarding",
                        activityContext: ResolverHealthActivityContext(
                            connectivitySeverity: .healthy,
                            networkKind: .wifi,
                            networkPathIsSatisfied: true,
                            resolverTransport: .deviceDNS,
                            deviceDNSFallbackActive: false
                        )
                    )
                ),
                .endEncryptedFallbackLogEpisode(.episodeEnd),
                .cancelWedgeRecoveryProbe,
                .clearDeviceDNSRecaptureRestartPending,
                .signalConnectivityProjectionChanged,
                .persistHealth(.deferred),
                .scheduleFallbackRecoveryProbe,
                .evaluateQAConnectivityLog(reason: "upstream-success", at: later),
                .evaluateProtectionNotification(at: later),
            ]
        )
        XCTAssertEqual(
            transition.effects.filter { effect in
                if case .endEncryptedFallbackLogEpisode = effect {
                    return true
                }
                return false
            }.count,
            1
        )
    }

    func testActiveFallbackModeTrafficNeverStampsPrimaryEvidenceOrReactivates() {
        var state = ResolverHealthEvidenceState()
        state.episode.consecutiveSmokeProbeFailureCount = 4
        state.episode.deviceDNSFallbackEvidenceCount = 3
        state.episode.deviceDNSFallbackModeActive = true
        state.episode.lastDeviceDNSFallbackActivatedAt = start
        state.episode.lastAcceptedPrimaryEvidenceAt = start
        state.episode.lastEncryptedFallbackSuccessAt = start
        state.session.lastPrimaryUpstreamSuccessAt = start
        state.session.deviceDNSFallbackActivationCount = 4

        let transition = ResolverHealthReducer.reduce(
            state: state,
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(
                        response: acceptedAnswer(),
                        outcome: .success,
                        transport: .deviceDNS
                    )
                )
            ),
            projectingOnto: providerBase()
        )

        XCTAssertTrue(transition.state.episode.deviceDNSFallbackModeActive)
        XCTAssertEqual(transition.state.episode.deviceDNSFallbackEvidenceCount, 3)
        XCTAssertEqual(transition.state.episode.lastDeviceDNSFallbackActivatedAt, start)
        XCTAssertEqual(transition.state.session.deviceDNSFallbackActivationCount, 4)
        XCTAssertEqual(transition.state.session.lastPrimaryUpstreamSuccessAt, start)
        XCTAssertEqual(transition.state.episode.consecutiveSmokeProbeFailureCount, 4)
        XCTAssertEqual(transition.state.episode.lastAcceptedPrimaryEvidenceAt, start)
        XCTAssertEqual(transition.state.episode.lastEncryptedFallbackSuccessAt, start)
        XCTAssertEqual(
            transition.effects,
            [
                .cancelWedgeRecoveryProbe,
                .clearDeviceDNSRecaptureRestartPending,
                .signalConnectivityProjectionChanged,
                .persistHealth(.deferred),
                .endEncryptedFallbackLogEpisode(.episodeEnd),
                .evaluateQAConnectivityLog(reason: "upstream-success", at: later),
                .evaluateProtectionNotification(at: later),
            ]
        )
        XCTAssertFalse(
            transition.effects.contains { effect in
                if case .scheduleFallbackRecoveryProbe = effect {
                    return true
                }
                if case .requestResolverRuntimeReset = effect {
                    return true
                }
                return false
            }
        )
    }

    func testBackedOffPrimaryDoesNotAdvanceOrganicFallbackCandidate() {
        var state = ResolverHealthEvidenceState()
        state.episode.deviceDNSFallbackEvidenceCount = 1

        let transition = ResolverHealthReducer.reduce(
            state: state,
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(
                        response: acceptedAnswer(),
                        outcome: .backedOff,
                        transport: .deviceDNS,
                        attemptTransport: .dnsOverHTTPS,
                        deviceDNSFallbackAttempted: true,
                        deviceDNSFallbackSucceeded: true
                    )
                )
            ),
            projectingOnto: providerBase()
        )

        XCTAssertEqual(transition.state.episode.deviceDNSFallbackEvidenceCount, 1)
        XCTAssertFalse(transition.state.episode.deviceDNSFallbackModeActive)
        XCTAssertEqual(transition.state.session.deviceDNSFallbackSuccessCount, 1)
        XCTAssertEqual(transition.state.session.resolverFailureCounts, ["192.0.2.1": 1])
        XCTAssertTrue(transition.effects.contains(.scheduleFallbackRecoveryProbe))
    }

    func testAttemptAndTransportMetricsCountEveryOutcomeAndLastSuccessfulDoHWins() {
        let attempts = [
            ResolverAttempt(
                address: "https://a.example/dns-query",
                outcome: .success,
                transport: .dnsOverHTTPS,
                negotiatedDoHProtocol: "h2"
            ),
            ResolverAttempt(
                address: "https://a.example/dns-query",
                outcome: .success,
                transport: .dnsOverHTTPS,
                negotiatedDoHProtocol: "h3"
            ),
            ResolverAttempt(address: "192.0.2.2", outcome: .timeout),
            ResolverAttempt(address: "192.0.2.2", outcome: .httpStatusFailure),
            ResolverAttempt(address: "192.0.2.3", outcome: .backedOff),
            ResolverAttempt(address: "192.0.2.3", outcome: .sendFailed),
            ResolverAttempt(address: "192.0.2.3", outcome: .receiveFailed),
            ResolverAttempt(address: "192.0.2.3", outcome: .invalidAddress),
            ResolverAttempt(address: "192.0.2.3", outcome: .unsupported),
            ResolverAttempt(address: "192.0.2.3", outcome: .socketUnavailable),
            ResolverAttempt(address: "192.0.2.3", outcome: .mismatchedResponse),
            ResolverAttempt(address: "192.0.2.3", outcome: .deviceDNSUnavailable),
        ]

        let transition = ResolverHealthReducer.reduce(
            state: ResolverHealthEvidenceState(),
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(
                        response: acceptedAnswer(),
                        outcome: .success,
                        transport: .dnsOverHTTPS,
                        attempts: attempts,
                        udpTruncated: true,
                        tcpFallbackAttempted: true,
                        tcpFallbackSucceeded: true,
                        deviceDNSFallbackAttempted: true,
                        deviceDNSUnavailable: true
                    )
                )
            ),
            projectingOnto: providerBase()
        )

        XCTAssertEqual(
            transition.state.session.resolverAttemptCounts,
            [
                "https://a.example/dns-query": 2,
                "192.0.2.2": 2,
                "192.0.2.3": 8,
            ]
        )
        XCTAssertEqual(
            transition.state.session.resolverSuccessCounts,
            ["https://a.example/dns-query": 2]
        )
        XCTAssertEqual(
            transition.state.session.resolverFailureCounts,
            ["192.0.2.2": 2, "192.0.2.3": 8]
        )
        XCTAssertEqual(transition.state.session.lastDoHHTTPVersion, "h3")
        XCTAssertEqual(transition.state.session.upstreamTimeoutCount, 1)
        XCTAssertEqual(transition.state.session.dohHTTPFailureCount, 1)
        XCTAssertEqual(transition.state.session.udpTruncatedResponseCount, 1)
        XCTAssertEqual(transition.state.session.tcpFallbackAttemptCount, 1)
        XCTAssertEqual(transition.state.session.tcpFallbackSuccessCount, 1)
        XCTAssertEqual(transition.state.session.deviceDNSFallbackAttemptCount, 1)
        XCTAssertEqual(transition.state.session.deviceDNSUnavailableCount, 1)
    }

    func testSlowResponseThresholdAndFailureResetAreExact() {
        for duration in [2_499, 2_500] {
            var state = ResolverHealthEvidenceState()
            state.session.slowUpstreamResponseCount = 3
            state.session.consecutiveSlowUpstreamResponseCount = 2
            state.session.lastSlowUpstreamResponseAt = start

            let transition = ResolverHealthReducer.reduce(
                state: state,
                event: .organicUpstreamCompleted(
                    evidence(
                        result: result(
                            response: acceptedAnswer(),
                            outcome: .success,
                            durationMilliseconds: duration
                        )
                    )
                ),
                projectingOnto: providerBase()
            )

            XCTAssertEqual(
                transition.state.session.slowUpstreamResponseCount,
                duration == 2_500 ? 4 : 3
            )
            XCTAssertEqual(
                transition.state.session.consecutiveSlowUpstreamResponseCount,
                duration == 2_500 ? 3 : 0
            )
            XCTAssertEqual(
                transition.state.session.lastSlowUpstreamResponseAt,
                duration == 2_500 ? later : start
            )
        }

        var failureState = ResolverHealthEvidenceState()
        failureState.session.slowUpstreamResponseCount = 3
        failureState.session.consecutiveSlowUpstreamResponseCount = 2
        failureState.session.lastSlowUpstreamResponseAt = start
        let failure = ResolverHealthReducer.reduce(
            state: failureState,
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(
                        response: nil,
                        outcome: .timeout,
                        durationMilliseconds: 3_000
                    )
                )
            ),
            projectingOnto: providerBase()
        )
        XCTAssertEqual(failure.state.session.slowUpstreamResponseCount, 3)
        XCTAssertEqual(failure.state.session.consecutiveSlowUpstreamResponseCount, 0)
        XCTAssertEqual(failure.state.session.lastSlowUpstreamResponseAt, start)
        XCTAssertEqual(failure.state.session.lastUpstreamDurationMilliseconds, 3_000)

        var nilDurationState = ResolverHealthEvidenceState()
        nilDurationState.session.slowUpstreamResponseCount = 3
        nilDurationState.session.consecutiveSlowUpstreamResponseCount = 2
        nilDurationState.session.lastSlowUpstreamResponseAt = start
        let nilDuration = ResolverHealthReducer.reduce(
            state: nilDurationState,
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(
                        response: acceptedAnswer(),
                        outcome: .success,
                        durationMilliseconds: nil
                    )
                )
            ),
            projectingOnto: providerBase()
        )
        XCTAssertEqual(nilDuration.state.session.slowUpstreamResponseCount, 3)
        XCTAssertEqual(nilDuration.state.session.consecutiveSlowUpstreamResponseCount, 0)
        XCTAssertEqual(nilDuration.state.session.lastSlowUpstreamResponseAt, start)
    }

    func testRecoveryCapturesActivityContextBeforeLaterOrganicMutations() throws {
        var slowState = ResolverHealthEvidenceState()
        slowState.session.consecutiveSlowUpstreamResponseCount = 2
        slowState.session.lastSlowUpstreamResponseAt = start
        slowState.reconnectEpisode = ResolverReconnectEpisodeEvidence(
            startedAt: start,
            reason: "timeout",
            peakUpstreamFailureCount: 4
        )

        let slowTransition = ResolverHealthReducer.reduce(
            state: slowState,
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(
                        response: acceptedAnswer(),
                        outcome: .success,
                        durationMilliseconds: 2_500
                    )
                )
            ),
            projectingOnto: providerBase()
        )
        let slowRecovery = try XCTUnwrap(
            slowTransition.effects.compactMap { effect -> ResolverHealthRecovery? in
                guard case .reportConnectivityRecovery(let recovery) = effect else {
                    return nil
                }
                return recovery
            }.first
        )
        XCTAssertEqual(slowRecovery.activityContext.connectivitySeverity, .healthy)
        XCTAssertEqual(slowRecovery.activityContext.networkKind, .wifi)
        XCTAssertTrue(slowRecovery.activityContext.networkPathIsSatisfied)
        XCTAssertEqual(slowRecovery.activityContext.resolverTransport, .plainDNS)
        XCTAssertFalse(slowRecovery.activityContext.deviceDNSFallbackActive)

        var finalSlowHealth = providerBase()
        slowTransition.projection.apply(to: &finalSlowHealth)
        XCTAssertEqual(
            ProtectionConnectivityPolicy.assessment(
                isConnected: true,
                health: finalSlowHealth,
                now: later
            ).severity,
            .dnsSlow
        )

        var fallbackState = ResolverHealthEvidenceState()
        fallbackState.episode.deviceDNSFallbackEvidenceCount = 2
        fallbackState.reconnectEpisode = ResolverReconnectEpisodeEvidence(
            startedAt: start,
            reason: "timeout",
            peakUpstreamFailureCount: 4
        )

        let fallbackTransition = ResolverHealthReducer.reduce(
            state: fallbackState,
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(
                        response: acceptedAnswer(),
                        outcome: .success,
                        transport: .deviceDNS,
                        attemptTransport: .dnsOverHTTPS,
                        deviceDNSFallbackAttempted: true,
                        deviceDNSFallbackSucceeded: true
                    )
                )
            ),
            projectingOnto: providerBase()
        )
        let fallbackRecovery = try XCTUnwrap(
            fallbackTransition.effects.compactMap { effect -> ResolverHealthRecovery? in
                guard case .reportConnectivityRecovery(let recovery) = effect else {
                    return nil
                }
                return recovery
            }.first
        )
        XCTAssertEqual(fallbackRecovery.activityContext.connectivitySeverity, .healthy)
        XCTAssertEqual(fallbackRecovery.activityContext.resolverTransport, .deviceDNS)
        XCTAssertFalse(fallbackRecovery.activityContext.deviceDNSFallbackActive)

        var finalFallbackHealth = providerBase()
        fallbackTransition.projection.apply(to: &finalFallbackHealth)
        XCTAssertEqual(
            ProtectionConnectivityPolicy.assessment(
                isConnected: true,
                health: finalFallbackHealth,
                now: later
            ).severity,
            .usingDeviceDNSFallback
        )
        XCTAssertTrue(finalFallbackHealth.deviceDNSFallbackModeActive)
    }

    func testRecoveryAfterNetworkHandoffUsesOriginalWedgeEvidence() {
        var scenario = ResolverHealthTestScenario(snapshot: providerBase())
        for offset in 0...2 {
            scenario.apply(
                .smokeProbeCompleted(
                    failedSmokeEvidence(
                        occurredAt: start.addingTimeInterval(TimeInterval(offset))
                    )
                )
            )
        }
        XCTAssertEqual(
            scenario.state.reconnectEpisode,
            ResolverReconnectEpisodeEvidence(
                startedAt: start.addingTimeInterval(2),
                reason: "timeout",
                peakUpstreamFailureCount: 3
            )
        )

        let encryptedCarry = scenario.apply(
            .organicUpstreamCompleted(
                evidence(
                    occurredAt: start.addingTimeInterval(200),
                    result: result(
                        response: acceptedAnswer(),
                        outcome: .success,
                        transport: .dnsOverHTTPS,
                        usedEncryptedFallback: true
                    )
                )
            )
        )
        XCTAssertNotNil(encryptedCarry.state.reconnectEpisode)
        XCTAssertFalse(
            encryptedCarry.effects.contains { effect in
                if case .reportConnectivityRecovery = effect {
                    return true
                }
                return false
            }
        )

        let handoffAt = start.addingTimeInterval(500)
        // The provider refreshes its envelope before reducing the path observation.
        scenario.snapshot.networkKind = .cellular
        let handoff = scenario.apply(
            .networkPathObserved(
                ResolverNetworkPathObservation(
                    previousKind: .wifi,
                    previousIsSatisfied: true,
                    kind: .cellular,
                    isSatisfied: true,
                    observedAt: handoffAt
                )
            )
        )
        XCTAssertEqual(handoff.state.reconnectEpisode, encryptedCarry.state.reconnectEpisode)
        XCTAssertEqual(handoff.state.episode.consecutiveUpstreamFailureCount, 0)
        scenario.apply(
            .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .fullRuntime(
                        currentPrimaryIdentifier: "primary-a",
                        recordsObservableReset: true
                    ),
                    reason: "network-path-changed",
                    occurredAt: handoffAt
                )
            )
        )

        let recovered = scenario.apply(
            .organicUpstreamCompleted(
                evidence(
                    result: result(
                        response: acceptedAnswer(),
                        outcome: .success
                    )
                )
            )
        )

        XCTAssertNil(recovered.state.reconnectEpisode)
        XCTAssertEqual(
            recovered.effects,
            [
                .reportConnectivityRecovery(
                    ResolverHealthRecovery(
                        startedAt: start.addingTimeInterval(2),
                        recoveredAt: later,
                        durationMilliseconds: 998_000,
                        reason: "timeout",
                        peakUpstreamFailureCount: 3,
                        transport: .plainDNS,
                        verifiedBy: "forwarding",
                        activityContext: ResolverHealthActivityContext(
                            connectivitySeverity: .healthy,
                            networkKind: .cellular,
                            networkPathIsSatisfied: true,
                            resolverTransport: .plainDNS,
                            deviceDNSFallbackActive: false
                        )
                    )
                ),
                .endEncryptedFallbackLogEpisode(.episodeEnd),
                .cancelWedgeRecoveryProbe,
                .clearDeviceDNSRecaptureRestartPending,
                .signalConnectivityProjectionChanged,
                .persistHealth(.deferred),
                .evaluateQAConnectivityLog(reason: "upstream-success", at: later),
                .evaluateProtectionNotification(at: later),
            ]
        )
    }

    func testEveryOrganicProjectionPreservesProviderOwnedEnvelopeAndTallies() {
        var base = providerBase()
        base.cacheHitCount = 31
        base.cacheMissCount = 32
        base.coalescedQueryCount = 33
        base.lastNetworkSettingsReapplyFailureAt = start
        base.lastNetworkSettingsReapplyFailureReason = "provider-owned"
        base.networkSettingsReapplyFailureCount = 34
        base.failClosedServedQueryCount = 35
        base.lastFailClosedAt = start
        base.lastFailClosedReason = "snapshot-unavailable"

        let events = [
            evidence(result: result(response: nil, outcome: .timeout)),
            evidence(
                result: result(
                    response: acceptedAnswer(),
                    outcome: .success,
                    transport: .dnsOverHTTPS,
                    usedEncryptedFallback: true
                )
            ),
            evidence(
                result: result(
                    response: acceptedAnswer(),
                    outcome: .success,
                    transport: .deviceDNS,
                    attemptTransport: .dnsOverHTTPS,
                    deviceDNSFallbackAttempted: true,
                    deviceDNSFallbackSucceeded: true
                )
            ),
        ]

        for event in events {
            let transition = ResolverHealthReducer.reduce(
                state: ResolverHealthEvidenceState(),
                event: .organicUpstreamCompleted(event),
                projectingOnto: base
            )
            var projected = base
            transition.projection.apply(to: &projected)
            XCTAssertResolverHealthProviderFieldsEqual(projected, base)
        }
    }

    private func evidence(
        occurredAt: Date? = nil,
        result: DNSResolutionResult
    ) -> ResolverOrganicUpstreamEvidence {
        ResolverOrganicUpstreamEvidence(occurredAt: occurredAt ?? later, result: result)
    }

    private func failedSmokeEvidence(occurredAt: Date) -> ResolverSmokeProbeEvidence {
        ResolverSmokeProbeEvidence(
            occurredAt: occurredAt,
            reason: "resolver-wedge-recovery",
            primaryResult: result(response: nil, outcome: .timeout),
            primaryAccepted: false,
            fallbackResult: nil,
            fallbackAccepted: false,
            modeInsensitivePrimaryIdentifier: "primary-a",
            configuredResolverDisplayName: "Primary Resolver"
        )
    }

    private func result(
        response: Data?,
        outcome: ResolverAttemptOutcome,
        transport: DNSResolverTransport = .plainDNS,
        attemptTransport: DNSResolverTransport? = nil,
        attempts: [ResolverAttempt]? = nil,
        udpTruncated: Bool = false,
        tcpFallbackAttempted: Bool = false,
        tcpFallbackSucceeded: Bool = false,
        deviceDNSFallbackAttempted: Bool = false,
        deviceDNSFallbackSucceeded: Bool = false,
        deviceDNSUnavailable: Bool = false,
        usedEncryptedFallback: Bool = false,
        durationMilliseconds: Int? = nil,
        negotiatedDoHProtocol: String? = nil
    ) -> DNSResolutionResult {
        DNSResolutionResult(
            response: response,
            successfulResolverAddress: response == nil ? nil : "192.0.2.1",
            attempts: attempts ?? [
                ResolverAttempt(
                    address: "192.0.2.1",
                    outcome: outcome,
                    transport: attemptTransport ?? transport,
                    negotiatedDoHProtocol: negotiatedDoHProtocol
                )
            ],
            transport: transport,
            udpTruncated: udpTruncated,
            tcpFallbackAttempted: tcpFallbackAttempted,
            tcpFallbackSucceeded: tcpFallbackSucceeded,
            deviceDNSFallbackAttempted: deviceDNSFallbackAttempted,
            deviceDNSFallbackSucceeded: deviceDNSFallbackSucceeded,
            deviceDNSUnavailable: deviceDNSUnavailable,
            usedEncryptedFallback: usedEncryptedFallback,
            durationMilliseconds: durationMilliseconds
        )
    }

    private func acceptedAnswer() -> Data {
        var data = response(flags: 0x8180, answerCount: 1)
        data.append(0)
        DNSWireTestSupport.appendUInt16(1, to: &data)
        DNSWireTestSupport.appendUInt16(1, to: &data)
        data.append(contentsOf: [0, 0, 0, 60])
        DNSWireTestSupport.appendUInt16(4, to: &data)
        data.append(contentsOf: [192, 0, 2, 1])
        return data
    }

    private func response(flags: UInt16, answerCount: UInt16 = 0) -> Data {
        var data = Data(repeating: 0, count: 12)
        data[2] = UInt8((flags >> 8) & 0xFF)
        data[3] = UInt8(flags & 0xFF)
        data[6] = UInt8((answerCount >> 8) & 0xFF)
        data[7] = UInt8(answerCount & 0xFF)
        return data
    }

    private func providerBase() -> TunnelHealthSnapshot {
        resolverHealthProviderSnapshot()
    }

}
