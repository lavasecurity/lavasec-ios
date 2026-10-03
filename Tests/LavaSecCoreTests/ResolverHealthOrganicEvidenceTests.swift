import Foundation
import XCTest

@testable import LavaSecDNS
@testable import LavaSecKit

final class ResolverHealthOrganicEvidenceTests: XCTestCase {
    private struct PrimaryResponseCase {
        let response: Data
        let isServed: Bool
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
                .totalFailure(reason: "upstream-response-failed")
            )
        }
        let malformed = evidence(
            result: result(
                response: response(flags: 0x8180, answerCount: 1),
                outcome: .success
            )
        )
        XCTAssertEqual(malformed.outcome, .totalFailure(reason: "upstream-response-failed"))

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

    func testClientExpiryPreservesFailureEvidenceWithoutServiceCredit() {
        let timeoutThenExpiry = result(response: nil, outcome: .timeout, attempts: [
            ResolverAttempt(address: "192.0.2.1", outcome: .timeout),
            ResolverAttempt(address: "192.0.2.2", outcome: .expiredBeforeSend)
        ])
        let latePrimary = result(response: acceptedAnswer(), outcome: .success)
        let lateFallback = result(response: acceptedAnswer(), outcome: .success,
            transport: .dnsOverHTTPS, usedEncryptedFallback: true)
        for sample in [timeoutThenExpiry, latePrimary, lateFallback] {
            let completion = ResolverHealthOrganicUpstreamCompletion(
                occurredAt: later, result: sample, clientDeadlineExpired: true)
            let reduction = ResolverHealthGateway.reduce(
                state: ResolverHealthEvidenceState(), event: .organicUpstreamCompleted(completion),
                projectingOnto: providerBase())
            XCTAssertEqual(reduction.state.session.upstreamFailureCount, 1)
            XCTAssertEqual(reduction.state.session.upstreamSuccessCount, 0)
            XCTAssertEqual(reduction.state.episode.consecutiveUpstreamFailureCount, 1)
            XCTAssertNil(reduction.state.episode.lastEncryptedFallbackSuccessAt)
        }
        let timedOut = ResolverOrganicUpstreamEvidence(
            occurredAt: later, result: timeoutThenExpiry, clientDeadlineExpired: true)
        XCTAssertEqual(timedOut.attempts.map(\.outcome), [.timeout, .notAttempted])
        XCTAssertEqual(timedOut.outcome, .totalFailure(reason: "query-deadline-expired"))

        let unsent = result(response: nil, outcome: .expiredBeforeSend)
        let neutral = ResolverHealthGateway.reduce(state: ResolverHealthEvidenceState(),
            event: .organicUpstreamCompleted(ResolverHealthOrganicUpstreamCompletion(
                occurredAt: later, result: unsent, clientDeadlineExpired: true)),
            projectingOnto: providerBase())
        XCTAssertEqual(neutral.state.session.upstreamFailureCount, 0)
        XCTAssertEqual(neutral.state.session.resolverFailureCounts, [:])
        XCTAssertEqual(ResolverOrganicUpstreamEvidence(occurredAt: later, result: timeoutThenExpiry,
            chainedDataPathLatched: true, clientDeadlineExpired: true).outcome, .governedByOutageSupervisor)
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

    func testResolvedQueryFoldsDurationIntoLatencyHistogram() {
        let transition = ResolverHealthReducer.reduce(
            state: ResolverHealthEvidenceState(),
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(
                        response: acceptedAnswer(),
                        outcome: .success,
                        durationMilliseconds: 30 // (25,50] -> bucket 2
                    )
                )
            ),
            projectingOnto: providerBase()
        )
        let histogram = transition.state.session.upstreamLatencyHistogram
        XCTAssertEqual(histogram.sampleCount, 1)
        XCTAssertEqual(histogram.bucketCounts[2], 1)
        // The successful resolution is also recorded as the last response duration.
        XCTAssertEqual(transition.state.session.lastUpstreamSuccessDurationMilliseconds, 30)
    }

    func testTimedOutUpstreamDoesNotRecordLatencyOrSuccessDuration() {
        let transition = ResolverHealthReducer.reduce(
            state: ResolverHealthEvidenceState(),
            event: .organicUpstreamCompleted(
                evidence(result: result(response: nil, outcome: .timeout, durationMilliseconds: 5_000))
            ),
            projectingOnto: providerBase()
        )
        // Failures never reach reduceResolved: they must not skew the distribution, and a
        // timeout's duration must never masquerade as a "Last DNS response" (Codex, #360).
        XCTAssertEqual(transition.state.session.upstreamLatencyHistogram.sampleCount, 0)
        XCTAssertNil(transition.state.session.lastUpstreamSuccessDurationMilliseconds)
        XCTAssertEqual(transition.state.session.lastUpstreamDurationMilliseconds, 5_000)
    }

    func testResolvedQueryWithoutDurationRecordsNoLatencySample() {
        let transition = ResolverHealthReducer.reduce(
            state: ResolverHealthEvidenceState(),
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(response: acceptedAnswer(), outcome: .success, durationMilliseconds: nil)
                )
            ),
            projectingOnto: providerBase()
        )
        XCTAssertEqual(transition.state.session.upstreamSuccessCount, 1)
        XCTAssertEqual(transition.state.session.upstreamLatencyHistogram.sampleCount, 0)
        XCTAssertNil(transition.state.session.lastUpstreamSuccessDurationMilliseconds)
    }

    func testConfiguredPrimaryResponseQualitySeparatesServiceFromFailure() {
        let cases = [
            PrimaryResponseCase(
                response: acceptedAnswer(),
                isServed: true,
                expectedPrimaryAt: later,
                expectedSmokeFailures: 0,
                expectedAcceptedAt: later
            ),
            PrimaryResponseCase(
                response: response(flags: 0x8180),
                isServed: true,
                expectedPrimaryAt: later,
                expectedSmokeFailures: 0,
                expectedAcceptedAt: start
            ),
            PrimaryResponseCase(
                response: response(flags: 0x8182),
                isServed: false,
                expectedPrimaryAt: start,
                expectedSmokeFailures: 4,
                expectedAcceptedAt: nil
            ),
            PrimaryResponseCase(
                response: response(flags: 0x8180, answerCount: 1),
                isServed: false,
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

            XCTAssertEqual(transition.state.session.upstreamSuccessCount, testCase.isServed ? 6 : 5)
            XCTAssertEqual(transition.state.session.upstreamFailureCount, testCase.isServed ? 2 : 3)
            XCTAssertEqual(transition.state.session.lastUpstreamSuccessAt, testCase.isServed ? later : nil)
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
            XCTAssertEqual(transition.state.episode.consecutiveUpstreamFailureCount, testCase.isServed ? 0 : 4)
            XCTAssertEqual(transition.state.episode.consecutiveCarriedQueryFailureCount, testCase.isServed ? 0 : 3)
            XCTAssertEqual(transition.state.episode.deviceDNSFallbackEvidenceCount, 0)
            XCTAssertEqual(transition.state.episode.lastFailureReason, testCase.isServed ? nil : "upstream-response-failed")
            XCTAssertEqual(transition.state.session.consecutiveSlowUpstreamResponseCount, 0)
            XCTAssertEqual(transition.state.identity.rejectedResponseCount, 2)
            XCTAssertEqual(
                transition.state.identity.rejectedResponseResolverIdentifier,
                "primary-a"
            )
            XCTAssertEqual(
                transition.effects,
                testCase.isServed ? [
                    .cancelWedgeRecoveryProbe,
                    .clearDeviceDNSRecaptureRestartPending,
                    .signalConnectivityProjectionChanged,
                    .persistHealth(.deferred),
                    .endEncryptedFallbackLogEpisode(.episodeEnd),
                    .evaluateQAConnectivityLog(reason: "upstream-success", at: later),
                    .evaluateProtectionNotification(at: later),
                ] : [
                    .signalConnectivityProjectionChanged,
                    .persistHealth(.deferred),
                    .evaluateQAConnectivityLog(reason: "upstream-failure", at: later),
                ]
            )
        }
    }

    func testClientFailureResponsePreservesWedgeAndActiveFallbackMode() {
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

        XCTAssertEqual(transition.state.session.upstreamSuccessCount, 5)
        XCTAssertNil(transition.state.session.lastUpstreamSuccessAt)
        XCTAssertEqual(transition.state.session.upstreamFailureCount, 1)
        XCTAssertEqual(transition.state.session.lastPrimaryUpstreamSuccessAt, start)
        XCTAssertEqual(transition.state.episode.consecutiveSmokeProbeFailureCount, 4)
        XCTAssertNil(transition.state.episode.lastAcceptedPrimaryEvidenceAt)
        XCTAssertEqual(transition.state.episode.lastEncryptedFallbackSuccessAt, start,
                       "one failed query does not erase the existing bounded coverage window")
        XCTAssertTrue(transition.state.episode.deviceDNSFallbackModeActive)
        XCTAssertEqual(transition.state.episode.deviceDNSFallbackEvidenceCount, 0)
        XCTAssertEqual(transition.state.episode.lastDeviceDNSFallbackActivatedAt, start)
        XCTAssertEqual(transition.state.identity.rejectedResponseCount, 2)
        XCTAssertEqual(transition.state.identity.rejectedResponseResolverIdentifier, "primary-a")
        XCTAssertEqual(transition.state.reconnectEpisode, state.reconnectEpisode)
        XCTAssertEqual(transition.state.effectDelivery.lastReconnectNeededActivityAt, start)
        XCTAssertEqual(transition.effects, [
            .signalConnectivityProjectionChanged,
            .persistHealth(.deferred),
            .evaluateQAConnectivityLog(reason: "upstream-failure", at: later),
        ])

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

    func testErrorRepliesNeverEarnPrimaryOrFallbackServiceCredit() {
        for code in [1, 2, 4, 5, 16, 32] {
            var reply = response(flags: 0x8180 | UInt16(code & 15))
            if code >= 16 {
                reply[11] = 1
                reply.append(contentsOf: [0, 0, 41, 4, 208, UInt8(code >> 4), 0, 0, 0, 0, 0])
            }
            for route in ["primary", "encrypted-fallback", "device-fallback"] {
                var state = ResolverHealthEvidenceState()
                state.session.lastPrimaryUpstreamSuccessAt = start
                state.episode.consecutiveSmokeProbeFailureCount = 3
                state.episode.consecutiveUpstreamFailureCount = 2
                state.episode.lastAcceptedPrimaryEvidenceAt = start
                state.episode.deviceDNSFallbackEvidenceCount = 2
                let completion = result(
                    response: reply, outcome: .success,
                    transport: route == "device-fallback" ? .deviceDNS : .dnsOverHTTPS,
                    deviceDNSFallbackAttempted: route == "device-fallback",
                    deviceDNSFallbackSucceeded: route == "device-fallback",
                    usedEncryptedFallback: route == "encrypted-fallback")
                let transition = ResolverHealthReducer.reduce(
                    state: state, event: .organicUpstreamCompleted(evidence(result: completion)),
                    projectingOnto: providerBase())
                let note = "RCODE \(code), \(route)"
                XCTAssertEqual(transition.state.session.lastPrimaryUpstreamSuccessAt, start, note)
                XCTAssertEqual(transition.state.episode.consecutiveSmokeProbeFailureCount, 3, note)
                XCTAssertEqual(transition.state.episode.consecutiveUpstreamFailureCount, 3, note)
                XCTAssertEqual(transition.state.session.upstreamSuccessCount, 0, note)
                XCTAssertNil(transition.state.episode.lastAcceptedPrimaryEvidenceAt, note)
                XCTAssertNil(transition.state.episode.lastEncryptedFallbackSuccessAt, note)
                XCTAssertFalse(transition.state.episode.deviceDNSFallbackModeActive, note)
                XCTAssertEqual(transition.state.session.deviceDNSFallbackSuccessCount, 0, note)
            }
        }
    }

    private func evidence(
        occurredAt: Date? = nil,
        result: DNSResolutionResult,
        chainedDataPathLatched: Bool = false
    ) -> ResolverOrganicUpstreamEvidence {
        ResolverOrganicUpstreamEvidence(
            occurredAt: occurredAt ?? later,
            result: result,
            chainedDataPathLatched: chainedDataPathLatched)
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


    func testAnEgressPolicyRefusalIsScoredAsNeitherSuccessNorFailure() {
        // A deliberate refusal must count as neither. Scoring it as `otherFailure` increments
        // `resolverFailureCounts` against the user's OWN resolver, so a session spent in
        // chained mode would leave that resolver backed off once the tunnel returns to
        // DNS-only — punishing a resolver that never misbehaved, for a decision we made about
        // it.
        //
        // Asserted on the bridges rather than through a full recording, because these two
        // mappings are where the classification is decided and the only places a future
        // outcome can be mis-filed.
        XCTAssertEqual(
            ResolverOrganicUpstreamEvidence.AttemptOutcome(.refusedByEgressPolicy),
            .notAttempted)
        XCTAssertNotEqual(
            ResolverOrganicUpstreamEvidence.AttemptOutcome(.refusedByEgressPolicy),
            .otherFailure)
        XCTAssertEqual(
            ResolverBackoffPolicy.AttemptOutcome(.refusedByEgressPolicy), .backedOff,
            "backoff must treat a refusal as suppression, not as an endpoint fault")
        // F2's missing physical pin is a refusal of the same class, but its own outcome — neither
        // bridge may fold it into the tunnel-interface one or into a resolver failure (Kilo, PR #747).
        XCTAssertEqual(
            ResolverOrganicUpstreamEvidence.AttemptOutcome(.physicalInterfaceUnavailable),
            .notAttempted)
        XCTAssertNotEqual(
            ResolverOrganicUpstreamEvidence.AttemptOutcome(.physicalInterfaceUnavailable),
            .otherFailure)
        XCTAssertEqual(
            ResolverBackoffPolicy.AttemptOutcome(.physicalInterfaceUnavailable),
            .physicalInterfaceUnavailable,
            "the bridge keeps the missing physical pin distinct from the missing tunnel interface")
    }

    // MARK: - Chained resolutions are the outage supervisor's, not the physical coordinator's

    func testAChainedResolutionIsGovernedByTheOutageSupervisorRegardlessOfOutcome() {
        // While chained, the resolution was carried through the tunnel to the conf's own
        // resolver; its verdict is the outage supervisor's, so the physical classification is
        // withheld whatever the underlying attempt did — a fail-closed `.backedOff` (the shape
        // that tripped the false reconnect on device), a timeout, or even a served answer.
        for outcome in [ResolverAttemptOutcome.backedOff, .timeout, .success] {
            let response: Data? = outcome == .success ? acceptedAnswer() : nil
            let classified = evidence(
                result: result(response: response, outcome: outcome),
                chainedDataPathLatched: true
            ).outcome
            XCTAssertEqual(
                classified, .governedByOutageSupervisor,
                "a chained \(outcome) resolution must not enter the physical verdict")
        }
    }

    func testAChainedResolutionClearsAndDoesNotAccumulateThePhysicalReconnectWedge() {
        // The device bug (chimmy, 2026-08-14): a single conf resolver briefly backed off, every
        // tunnelled query fail-closed `.backedOff`, and three in a row drove the PHYSICAL
        // reconnect wedge to `needsReconnect` — so the app showed "reconnect" while DNS worked
        // (148 successes) and the self-reconnect actor, correctly gated off while chained, could
        // not act on it. A chained resolution must both refuse to accumulate that wedge AND clear
        // one already standing, because while chained the physical path is not in use and a VPN
        // restart cannot fix a conf resolver.
        var state = ResolverHealthEvidenceState()
        state.episode.consecutiveUpstreamFailureCount = 3
        state.episode.lastFailureReason = "backed-off"
        state.session.lastUpstreamFailureAt = start
        state.session.upstreamFailureCount = 11
        state.session.upstreamSuccessCount = 148
        state.session.consecutiveSlowUpstreamResponseCount = 2
        state.reconnectEpisode = ResolverReconnectEpisodeEvidence(
            startedAt: start,
            reason: "backed-off",
            peakUpstreamFailureCount: 3
        )

        let transition = ResolverHealthReducer.reduce(
            state: state,
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(response: nil, outcome: .backedOff),
                    chainedDataPathLatched: true
                )
            ),
            projectingOnto: providerBase()
        )

        XCTAssertEqual(transition.state.episode.consecutiveUpstreamFailureCount, 0)
        XCTAssertEqual(transition.state.session.consecutiveSlowUpstreamResponseCount, 0)
        XCTAssertNil(transition.state.reconnectEpisode)
        // The physical-failure remnants the app surfaces are cleared, not left stale.
        XCTAssertNil(transition.state.episode.lastFailureReason)
        XCTAssertNil(transition.state.session.lastUpstreamFailureAt)
        // The session totals are the physical path's ledger and are left untouched — a chained
        // resolution is neither a physical success nor a physical failure.
        XCTAssertEqual(transition.state.session.upstreamFailureCount, 11)
        XCTAssertEqual(transition.state.session.upstreamSuccessCount, 148)
        // Clearing the wedge is a connectivity-relevant change, so the projection is re-signalled
        // and persisted — the app recomputes its own assessment from the snapshot and drops the
        // false "reconnect".
        XCTAssertEqual(
            transition.effects,
            [.signalConnectivityProjectionChanged, .persistHealth(.deferred)])
    }

    func testAChainedResolutionWithNoStandingWedgeStaysSilent() {
        // No wedge to clear and nothing to accumulate: the steady chained case must not repost an
        // unchanged projection on every served query (the DNS hot path runs under the NE jetsam
        // ceiling, INV-MEM-1).
        let transition = ResolverHealthReducer.reduce(
            state: ResolverHealthEvidenceState(),
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(response: acceptedAnswer(), outcome: .success),
                    chainedDataPathLatched: true
                )
            ),
            projectingOnto: providerBase()
        )
        XCTAssertEqual(transition.state.episode.consecutiveUpstreamFailureCount, 0)
        XCTAssertNil(transition.state.reconnectEpisode)
        XCTAssertTrue(transition.effects.isEmpty)
    }

    func testAChainedResolutionPreservesANonWedgeFailureReason() {
        // A `lastFailureReason` with NO physical wedge behind it belongs to another subsystem —
        // e.g. a `.networkSettingsReapplyFailed` that has not recovered. A chained organic
        // completion must not erase it while neutralising the (absent) reconnect wedge; only a
        // reason a real wedge produced is cleared (Codex P2). No wedge here, so nothing is
        // cleared and nothing is re-signalled.
        var state = ResolverHealthEvidenceState()
        state.episode.lastFailureReason = "network-settings-reapply-failed"

        let transition = ResolverHealthReducer.reduce(
            state: state,
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(response: nil, outcome: .backedOff),
                    chainedDataPathLatched: true
                )
            ),
            projectingOnto: providerBase()
        )
        XCTAssertEqual(
            transition.state.episode.lastFailureReason, "network-settings-reapply-failed")
        XCTAssertTrue(transition.effects.isEmpty)
    }

    func testADNSOnlyBackedOffResolutionStillAccumulatesTheWedge() {
        // The pairing that proves the chained gate is load-bearing: the SAME fail-closed
        // `.backedOff` result WITHOUT the chained latch is a real physical-DNS failure and must
        // still advance the reconnect ladder. Deleting the `chainedDataPathLatched` short-circuit
        // makes the chained tests above pass this DNS-only way too, so this is the mutation catch.
        var state = ResolverHealthEvidenceState()
        state.episode.consecutiveUpstreamFailureCount = 2

        let transition = ResolverHealthReducer.reduce(
            state: state,
            event: .organicUpstreamCompleted(
                evidence(
                    result: result(response: nil, outcome: .backedOff),
                    chainedDataPathLatched: false
                )
            ),
            projectingOnto: providerBase()
        )
        XCTAssertEqual(transition.state.episode.consecutiveUpstreamFailureCount, 3)
    }

    func testATruncatedTunnelAnswerIsResolverLivenessNotFailure() {
        // S6, resolved decision 3: a TC answer is the resolver replying — promptly and
        // correctly — that the response does not fit UDP. The query provably reached the
        // upstream through the tunnel and came back. Scoring it as failure at either
        // bridge would count one large-response domain against the resolver itself.
        XCTAssertEqual(
            ResolverOrganicUpstreamEvidence.AttemptOutcome(.truncatedAnswer), .success)
        XCTAssertNotEqual(
            ResolverOrganicUpstreamEvidence.AttemptOutcome(.truncatedAnswer), .otherFailure)
        XCTAssertEqual(
            ResolverBackoffPolicy.AttemptOutcome(.truncatedAnswer), .success,
            "benching a resolver for ANSWERING would suppress a working upstream over one domain's answer size")
    }

    func testATruncatedTunnelResultIsNotAggregateFailure() {
        // Codex (PR #511): the per-attempt bridges were one frame too shallow — a truncated
        // result carries a nil response (the TC answer is never relayed), so the
        // nil-response guard swept it into `.totalFailure`, spending upstream and
        // consecutive failure counters plus reconnect effects on a resolver that ANSWERED.
        // The aggregate classification now has its own outcome: neutral for failure
        // scoring, still recorded at the attempt metrics.
        let truncated = evidence(
            result: result(
                response: nil, outcome: .truncatedAnswer,
                attempts: [
                    ResolverAttempt(
                        address: "10.64.0.1", outcome: .truncatedAnswer, transport: .plainDNS),
                    ResolverAttempt(
                        address: "doh", outcome: .refusedByEgressPolicy,
                        transport: .dnsOverHTTPS),
                ],
                udpTruncated: true))
        XCTAssertEqual(truncated.outcome, ResolverOrganicUpstreamEvidence.Outcome.truncatedAnswer)

        let transition = ResolverHealthReducer.reduce(
            state: ResolverHealthEvidenceState(),
            event: .organicUpstreamCompleted(truncated),
            projectingOnto: providerBase())
        XCTAssertEqual(transition.state.session.upstreamFailureCount, 0)
        XCTAssertEqual(transition.state.episode.consecutiveUpstreamFailureCount, 0)
        // Neutral for SCORING, not silent: the arm moved counters, so it persists them (see
        // `testATruncatedResultPersistsTheCountersItMoved`). What must stay absent is every
        // recovery/ladder effect.
        XCTAssertFalse(
            transition.effects.contains(.scheduleWedgeRecoveryProbe),
            "a truncated answer evaluated the recovery ladder")
        XCTAssertNil(
            transition.effects.first(where: { if case .evaluateProtectionNotification = $0 { return true } else { return false } }),
            "a truncated answer drove a protection notification")
        XCTAssertEqual(
            transition.state.session.udpTruncatedResponseCount, 1,
            "the truncation fact must keep recording — neutral is not invisible")
        XCTAssertEqual(transition.state.session.resolverAttemptCounts, ["10.64.0.1": 1])
        XCTAssertEqual(transition.state.session.resolverSuccessCounts, ["10.64.0.1": 1])
    }

    func testAGenuineFailureSharingAResultWithATruncationIsStillFailure() {
        // The neutral arm must not become a shield: with `contains`, one truncated attempt
        // beside a timeout and a receive failure classified the whole result neutral, so
        // health reported a fine upstream while every transport failed.
        let mixed = evidence(
            result: result(
                response: nil, outcome: .timeout,
                attempts: [
                    ResolverAttempt(
                        address: "10.64.0.1", outcome: .truncatedAnswer, transport: .plainDNS),
                    ResolverAttempt(
                        address: "192.0.2.9", outcome: .timeout, transport: .deviceDNS),
                ]))
        guard case .totalFailure = mixed.outcome else {
            return XCTFail("a genuine failure was shielded by a truncated attempt: \(mixed.outcome)")
        }

        let transition = ResolverHealthReducer.reduce(
            state: ResolverHealthEvidenceState(),
            event: .organicUpstreamCompleted(mixed),
            projectingOnto: providerBase())
        XCTAssertEqual(transition.state.session.upstreamFailureCount, 1)
    }

    func testATruncatedResultPersistsTheCountersItMoved() {
        // Neutral for scoring is not the same as invisible: the arm increments the
        // truncation and per-resolver tallies, so the snapshot is dirty and must be
        // persisted — a TC burst followed by process death otherwise loses them.
        let truncated = evidence(
            result: result(
                response: nil, outcome: .truncatedAnswer,
                attempts: [
                    ResolverAttempt(
                        address: "10.64.0.1", outcome: .truncatedAnswer, transport: .plainDNS)
                ],
                udpTruncated: true))
        let transition = ResolverHealthReducer.reduce(
            state: ResolverHealthEvidenceState(),
            event: .organicUpstreamCompleted(truncated),
            projectingOnto: providerBase())
        XCTAssertTrue(transition.effects.contains(.persistHealth(.deferred)))
        XCTAssertTrue(transition.effects.contains(.signalConnectivityProjectionChanged))
        XCTAssertFalse(
            transition.effects.contains(.scheduleWedgeRecoveryProbe),
            "a truncated answer evaluated the recovery ladder")
    }

    func testAFailoverEndingInTruncationIsNotAggregateFailure() {
        // Ordinary failover already treats `[.timeout, .success]` as a resolution and scores
        // the timeout per-resolver. `[.timeout, .truncatedAnswer]` is the same shape: the
        // later resolver ANSWERED, proving the chained path alive, so spending the aggregate
        // outage budget on it would surrender a usable session over repeated large answers
        // (Codex, PR #511).
        let failover = evidence(
            result: result(
                response: nil, outcome: .truncatedAnswer,
                attempts: [
                    ResolverAttempt(
                        address: "10.64.0.1", outcome: .timeout, transport: .plainDNS),
                    ResolverAttempt(
                        address: "10.64.0.2", outcome: .truncatedAnswer, transport: .plainDNS),
                ],
                udpTruncated: true))
        XCTAssertEqual(
            failover.outcome, ResolverOrganicUpstreamEvidence.Outcome.truncatedAnswer)

        let transition = ResolverHealthReducer.reduce(
            state: ResolverHealthEvidenceState(),
            event: .organicUpstreamCompleted(failover),
            projectingOnto: providerBase())
        XCTAssertEqual(transition.state.session.upstreamFailureCount, 0)
        // The earlier timeout is still scored where it belongs — against the resolver that
        // timed out, not against the session.
        XCTAssertEqual(transition.state.session.resolverFailureCounts["10.64.0.1"], 1)
        XCTAssertEqual(transition.state.session.resolverSuccessCounts["10.64.0.2"], 1)
    }

    func testAServedResponseAfterATruncatedAttemptIsStillAResolution() {
        // The other direction: a failover where one endpoint answered TC and a LATER one
        // served real bytes carries a response, and that result is a resolution — the
        // truncated attempt must not eclipse it.
        let served = evidence(
            result: result(
                response: acceptedAnswer(), outcome: .success,
                attempts: [
                    ResolverAttempt(
                        address: "10.64.0.1", outcome: .truncatedAnswer, transport: .plainDNS),
                    ResolverAttempt(
                        address: "10.64.0.2", outcome: .success, transport: .plainDNS),
                ],
                udpTruncated: true))
        guard case .resolved = served.outcome else {
            return XCTFail("a served response classified as \(served.outcome)")
        }
    }

    func testARefusedRungBesideARealAttemptStaysOutOfTheDenominator() {
        // S6 is the mode the old comment here predicted: it refuses SOME transports while
        // attempting others, so a tunnelled `.plainDNS` attempt can sit beside a refused
        // fallback rung in ONE result. The all-refusals shape still diverts to
        // `.declinedByPolicy`; this mixed shape reaches the attempt metrics, where the
        // refusal must join neither the denominator nor any failure count — or a healthy
        // resolver reads as intermittent.
        let mixed = result(
            response: acceptedAnswer(),
            outcome: .success,
            attempts: [
                ResolverAttempt(address: "10.64.0.1", outcome: .success, transport: .plainDNS),
                ResolverAttempt(
                    address: "doh.example", outcome: .refusedByEgressPolicy,
                    transport: .dnsOverHTTPS),
            ])

        let transition = ResolverHealthReducer.reduce(
            state: ResolverHealthEvidenceState(),
            event: .organicUpstreamCompleted(evidence(result: mixed)),
            projectingOnto: providerBase())

        XCTAssertEqual(transition.state.session.resolverAttemptCounts, ["10.64.0.1": 1])
        XCTAssertEqual(transition.state.session.resolverSuccessCounts, ["10.64.0.1": 1])
        XCTAssertNil(transition.state.session.resolverFailureCounts["doh.example"])
    }

    func testAnEgressRefusalIsNeutralAtTheAGGREGATELevelToo() {
        // Marking the per-attempt outcome `.notAttempted` was NOT enough, and that is the
        // whole point of this test. A refusal always has a nil response, so the evidence still
        // entered the total-failure path on that basis alone — incrementing the upstream and
        // consecutive failure counters, clearing accepted candidate evidence, and evaluating
        // the recovery ladder. A deliberate refusal remained aggregate failure evidence; it
        // had merely stopped naming an address.
        let refusal = ResolverOrganicUpstreamEvidence(
            occurredAt: Date(timeIntervalSince1970: 1_000),
            result: DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: [
                    ResolverAttempt(
                        address: "doh.example",
                        outcome: .refusedByEgressPolicy,
                        transport: .dnsOverHTTPS)
                ],
                transport: .dnsOverHTTPS,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false))

        XCTAssertEqual(
            refusal.outcome, ResolverOrganicUpstreamEvidence.Outcome.declinedByPolicy)

        let before = ResolverHealthEvidenceState()
        let after = ResolverOrganicEvidenceReducer.reduce(
            state: before,
            evidence: refusal,
            projectingOnto: TunnelHealthSnapshot()
        )

        XCTAssertEqual(
            after.state.session.resolverAttemptCounts["doh.example"], nil,
            "a refusal counted as an attempt inflates every success-rate denominator")
        XCTAssertEqual(
            after.state.session.resolverFailureCounts["doh.example"], nil,
            "a refusal must not be scored against the resolver")
        XCTAssertTrue(
            after.effects.isEmpty,
            "a refusal must not drive the recovery ladder — nothing was asked of the upstream")
    }

    func testAnAllRefusedSmokeProbeIsNeutralRatherThanAFailure() {
        // The third level the same neutrality had to reach. The resolution result and the
        // ORGANIC evidence path both treat a policy refusal as neither success nor failure;
        // the SMOKE-probe path classifies completions on its own, and an all-refused
        // completion fell into `.neitherAccepted(.transport("refused-by-egress-policy"))`.
        // The reducer then incremented the smoke and upstream failure streaks and invoked the
        // recovery ladder — so while chained, every startup and periodic probe reported a
        // synthetic outage and could drive a reconnect, for a decision the tunnel made
        // deliberately.
        let refused = DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: [
                ResolverAttempt(
                    address: "doh.example", outcome: .refusedByEgressPolicy,
                    transport: .dnsOverHTTPS)
            ],
            transport: .dnsOverHTTPS,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false)
        let declinedFallback = DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: [
                ResolverAttempt(
                    address: "192.168.1.1", outcome: .refusedByEgressPolicy,
                    transport: .deviceDNS)
            ],
            transport: .deviceDNS,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false)

        let evidence = ResolverSmokeProbeEvidence(
            occurredAt: Date(timeIntervalSince1970: 2_000),
            reason: "startTunnel",
            primaryResult: refused,
            primaryAccepted: false,
            fallbackResult: declinedFallback,
            fallbackAccepted: false,
            modeInsensitivePrimaryIdentifier: "doh",
            configuredResolverDisplayName: "Test")

        XCTAssertEqual(evidence.outcome, .declinedByPolicy)

        let after = ResolverSmokeEvidenceReducer.reduce(
            state: ResolverHealthEvidenceState(),
            evidence: evidence,
            projectingOnto: TunnelHealthSnapshot())
        XCTAssertTrue(
            after.effects.isEmpty,
            "a declined probe drove the recovery ladder — nothing was contacted")
        XCTAssertEqual(
            after.state.session.lastDNSSmokeProbeAt, evidence.occurredAt,
            "the probe still ran, so its cadence must still be recorded")
    }

    func testASmokeProbeWithNoAttemptsIsStillAFailure() {
        // The guard on the neutral path: an EMPTY attempt list means nothing was tried for
        // some other reason, and reading that as "declined" would silence real failures — the
        // exact shape of the bug where an empty `attempts` array rendered a refusal as
        // "success".
        let empty = DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: [],
            transport: .dnsOverHTTPS,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false)
        let evidence = ResolverSmokeProbeEvidence(
            occurredAt: Date(timeIntervalSince1970: 3_000),
            reason: "periodic",
            primaryResult: empty,
            primaryAccepted: false,
            fallbackResult: nil,
            fallbackAccepted: false,
            modeInsensitivePrimaryIdentifier: "doh",
            configuredResolverDisplayName: "Test")
        XCTAssertNotEqual(evidence.outcome, .declinedByPolicy)
    }
}
