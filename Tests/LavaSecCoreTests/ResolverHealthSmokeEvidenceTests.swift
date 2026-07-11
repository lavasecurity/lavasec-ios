import Foundation
import XCTest

@testable import LavaSecDNS
@testable import LavaSecKit

final class ResolverHealthSmokeEvidenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    func testEvidenceFactoryCanonicalizesPrimaryPrecedenceAndMissingFallbackResult() {
        let bothAccepted = smokeEvidence(
            reason: "periodic-health-check",
            primaryResult: result(
                response: Data([1]),
                address: "https://primary.example/dns-query",
                outcome: .success,
                transport: .dnsOverHTTPS,
                negotiatedDoHProtocol: "h3"
            ),
            primaryAccepted: true,
            fallbackResult: result(
                response: Data([2]),
                address: "192.0.2.53",
                outcome: .success,
                transport: .deviceDNS
            ),
            fallbackAccepted: true
        )
        guard case .primaryAccepted(let primary) = bothAccepted.outcome else {
            return XCTFail("Primary acceptance must take precedence")
        }
        XCTAssertEqual(primary.resolverAddress, "https://primary.example/dns-query")
        XCTAssertEqual(primary.transport, .dnsOverHTTPS)
        XCTAssertEqual(primary.dohHTTPVersion, "h3")

        let primaryRejected = smokeEvidence(
            reason: "periodic-health-check",
            primaryResult: result(
                response: Data([1]),
                address: "192.0.2.1",
                outcome: .success,
                transport: .plainDNS
            ),
            primaryAccepted: false,
            fallbackResult: result(
                response: nil,
                address: "192.0.2.53",
                outcome: .timeout,
                transport: .deviceDNS
            ),
            fallbackAccepted: false
        )
        guard case .neitherAccepted(let rejected) = primaryRejected.outcome else {
            return XCTFail("Expected canonical failure outcome")
        }
        XCTAssertEqual(rejected.kind, .rejectedResponse)

        let missingFallback = ResolverSmokeProbeEvidence(
            occurredAt: later,
            reason: "periodic-health-check",
            primaryResult: result(
                response: nil,
                address: "192.0.2.1",
                outcome: .timeout,
                transport: .plainDNS
            ),
            primaryAccepted: false,
            fallbackResult: nil,
            fallbackAccepted: true,
            modeInsensitivePrimaryIdentifier: "primary-a",
            configuredResolverDisplayName: "Primary Resolver"
        )
        guard case .neitherAccepted(let failed) = missingFallback.outcome else {
            return XCTFail("A missing fallback result cannot be accepted")
        }
        XCTAssertEqual(failed.kind, .transport("timeout"))
    }

    func testStateGatewayMatchesReducerForPeriodicAcceptedPrimarySmoke() {
        var state = smokeState()
        state.episode.lastFailureReason = nil
        state.session.lastDNSSmokeProbeSucceeded = true
        var snapshot = providerBase()
        ResolverHealthSnapshotProjection(state: state).apply(to: &snapshot)
        let primaryResult = result(
            response: Data([1]),
            address: "https://primary.example/dns-query",
            outcome: .success,
            transport: .dnsOverHTTPS,
            negotiatedDoHProtocol: "h3"
        )
        let reducerEvidence = smokeEvidence(
            reason: "periodic-health-check",
            primaryResult: primaryResult,
            primaryAccepted: true
        )
        let reducerTransition = ResolverHealthReducer.reduce(
            state: state,
            event: .smokeProbeCompleted(reducerEvidence),
            projectingOnto: snapshot
        )

        let gatewayReduction = ResolverHealthGateway.reduce(
            state: state,
            event: .smokeProbeCompleted(
                ResolverHealthSmokeProbeCompletion(
                    occurredAt: later,
                    reason: "periodic-health-check",
                    primaryResult: primaryResult,
                    primaryAccepted: true,
                    fallbackResult: nil,
                    fallbackAccepted: false,
                    modeInsensitivePrimaryIdentifier: "primary-a",
                    configuredResolverDisplayName: "Primary Resolver"
                )
            ),
            projectingOnto: snapshot
        )
        let gatewayTransition = gatewayReduction.transition

        var expectedSnapshot = snapshot
        reducerTransition.projection.apply(to: &expectedSnapshot)
        var gatewaySnapshot = snapshot
        gatewayTransition.projection.apply(to: &gatewaySnapshot)
        XCTAssertEqual(gatewaySnapshot, expectedSnapshot)
        XCTAssertEqual(gatewayReduction.state, reducerTransition.state)
        XCTAssertEqual(
            reducerTransition.effects,
            [
                .endEncryptedFallbackLogEpisode(.episodeEnd),
                .creditProductiveSelfReconnect(at: later),
                .cancelWedgeRecoveryProbe,
                .clearDeviceDNSRecaptureRestartPending,
                .cancelFallbackRecoveryProbe,
                .signalConnectivityProjectionChanged,
                .persistHealth(.deferred),
                .evaluateProtectionNotification(at: later),
                .evaluateQAConnectivityLog(reason: "dns-smoke-probe-success", at: later),
                .deviceLog(
                    .smokeProbeSucceeded(
                        reason: "periodic-health-check",
                        transport: .dnsOverHTTPS,
                        resolverAddress: "https://primary.example/dns-query",
                        dohHTTPVersion: "h3",
                        occurredAt: later
                    )
                ),
            ]
        )
        XCTAssertEqual(
            gatewayTransition.effects,
            [
                .endEncryptedFallbackLogEpisode(.episodeEnd),
                .creditProductiveSelfReconnect(at: later),
                .cancelWedgeRecoveryProbe,
                .clearDeviceDNSRecaptureRestartPending,
                .cancelFallbackRecoveryProbe,
                .signalConnectivityProjectionChanged,
                .persistHealth(.deferred),
                .evaluateProtectionNotification(at: later),
                .evaluateQAConnectivityLog(reason: "dns-smoke-probe-success", at: later),
                .deviceLog(
                    .smokeProbeSucceeded(
                        reason: "periodic-health-check",
                        transport: .dnsOverHTTPS,
                        resolverAddress: "https://primary.example/dns-query",
                        dohHTTPVersion: "h3",
                        occurredAt: later
                    )
                ),
            ]
        )
    }

    func testStateGatewayConvertsEverySmokeOnlyEffectFamily() throws {
        var recovering = smokeState()
        recovering.reconnectEpisode = ResolverReconnectEpisodeEvidence(
            startedAt: start,
            reason: "timeout",
            peakUpstreamFailureCount: 7
        )
        let recovered = gatewayReduce(
            state: recovering,
            completion: ResolverHealthSmokeProbeCompletion(
                occurredAt: later,
                reason: "resolver-wedge-recovery",
                primaryResult: result(
                    response: Data([1]),
                    address: "192.0.2.1",
                    outcome: .success,
                    transport: .plainDNS
                ),
                primaryAccepted: true,
                fallbackResult: nil,
                fallbackAccepted: false,
                modeInsensitivePrimaryIdentifier: "primary-a",
                configuredResolverDisplayName: "Primary Resolver"
            )
        )
        let recovery = try XCTUnwrap(
            recovered.transition.effects.compactMap { effect -> ResolverHealthGatewayRecovery? in
                guard case .reportConnectivityRecovery(let recovery) = effect else {
                    return nil
                }
                return recovery
            }.first
        )
        XCTAssertEqual(recovery.reason, "timeout")
        XCTAssertEqual(recovery.peakUpstreamFailureCount, 7)
        XCTAssertEqual(recovery.transport, .plainDNS)
        XCTAssertEqual(recovery.verifiedBy, "smoke-probe")
        XCTAssertNil(recovered.state.reconnectEpisode)

        var fallbackCandidate = smokeState()
        fallbackCandidate.episode.deviceDNSFallbackEvidenceCount = 2
        let fallback = gatewayReduce(
            state: fallbackCandidate,
            completion: ResolverHealthSmokeProbeCompletion(
                occurredAt: later,
                reason: "fallback-check",
                primaryResult: result(
                    response: nil,
                    address: "https://primary.example/dns-query",
                    outcome: .timeout,
                    transport: .dnsOverHTTPS
                ),
                primaryAccepted: false,
                fallbackResult: result(
                    response: Data([1]),
                    address: "192.0.2.53",
                    outcome: .success,
                    transport: .deviceDNS
                ),
                fallbackAccepted: true,
                modeInsensitivePrimaryIdentifier: "primary-a",
                configuredResolverDisplayName: "Primary Resolver"
            )
        )
        XCTAssertTrue(fallback.transition.effects.contains(.scheduleFallbackRecoveryProbe))
        XCTAssertEqual(fallback.state.episode.deviceDNSFallbackEvidenceCount, 3)
        XCTAssertTrue(fallback.state.episode.deviceDNSFallbackModeActive)
        XCTAssertTrue(
            fallback.transition.effects.contains { effect in
                if case .deviceLog(.smokeProbeDeviceFallback) = effect {
                    return true
                }
                return false
            }
        )

        var rejectedAtThreshold = smokeState()
        rejectedAtThreshold.identity.rejectedResponseCount = 2
        rejectedAtThreshold.identity.rejectedResponseResolverIdentifier = "primary-a"
        let rejected = gatewayReduce(
            state: rejectedAtThreshold,
            completion: ResolverHealthSmokeProbeCompletion(
                occurredAt: later,
                reason: "resolver-wedge-recovery",
                primaryResult: result(
                    response: Data([1]),
                    address: "192.0.2.1",
                    outcome: .success,
                    transport: .plainDNS
                ),
                primaryAccepted: false,
                fallbackResult: nil,
                fallbackAccepted: false,
                modeInsensitivePrimaryIdentifier: "primary-a",
                configuredResolverDisplayName: "Primary Resolver"
            )
        )
        XCTAssertTrue(
            rejected.transition.effects.contains { effect in
                if case .recordIncident(let incident) = effect,
                    incident.kind == .rejectedResponseStreak
                {
                    return true
                }
                return false
            }
        )
        XCTAssertEqual(rejected.state.identity.rejectedResponseCount, 3)
        XCTAssertNotNil(rejected.state.reconnectEpisode)
        XCTAssertTrue(rejected.transition.effects.contains(.evaluateSelfReconnect(at: later)))
        XCTAssertTrue(rejected.transition.effects.contains(.scheduleWedgeRecoveryProbe))
        XCTAssertTrue(
            rejected.transition.effects.contains { effect in
                if case .deviceLog(.smokeProbeFailed) = effect {
                    return true
                }
                return false
            }
        )
    }

    func testAcceptedPrimaryClearsScopedEvidenceAndCapturesRecoveryBeforeReset() {
        var state = smokeState()
        state.identity.rejectedResponseCount = 3
        state.identity.rejectedResponseResolverIdentifier = "primary-a"
        state.episode.consecutiveUpstreamFailureCount = 8
        state.episode.consecutiveSmokeProbeFailureCount = 6
        state.episode.deviceDNSFallbackEvidenceCount = 3
        state.episode.deviceDNSFallbackModeActive = true
        state.episode.lastDeviceDNSFallbackActivatedAt = start
        state.episode.lastEncryptedFallbackSuccessAt = start
        state.episode.consecutiveCarriedQueryFailureCount = 2
        state.episode.lastAcceptedPrimaryEvidenceAt = start
        state.session.upstreamFailureCount = 11
        state.reconnectEpisode = ResolverReconnectEpisodeEvidence(
            startedAt: start,
            reason: "timeout",
            peakUpstreamFailureCount: 11
        )
        state.effectDelivery.lastReconnectNeededActivityAt = start

        let transition = reduce(
            state: state,
            evidence: smokeEvidence(
                reason: "network-path-changed",
                primaryResult: result(
                    response: Data([1]),
                    address: "https://primary.example/dns-query",
                    outcome: .success,
                    transport: .dnsOverHTTPS,
                    negotiatedDoHProtocol: "h3"
                ),
                primaryAccepted: true
            )
        )

        XCTAssertEqual(transition.state.session.lastDNSSmokeProbeAt, later)
        XCTAssertEqual(transition.state.session.lastDNSSmokeProbeSucceeded, true)
        XCTAssertEqual(transition.state.session.dnsSmokeProbeSuccessCount, 5)
        XCTAssertEqual(transition.state.session.dnsSmokeProbeFailureCount, 9)
        XCTAssertEqual(transition.state.session.upstreamSuccessCount, 0)
        XCTAssertEqual(transition.state.session.upstreamFailureCount, 11)
        XCTAssertEqual(
            transition.state.session.lastResolverAddress,
            "https://primary.example/dns-query"
        )
        XCTAssertEqual(transition.state.session.lastResolverTransport, .dnsOverHTTPS)
        XCTAssertEqual(transition.state.session.lastDoHHTTPVersion, "h3")
        XCTAssertEqual(transition.state.episode.consecutiveUpstreamFailureCount, 0)
        XCTAssertEqual(transition.state.episode.consecutiveSmokeProbeFailureCount, 0)
        XCTAssertEqual(transition.state.episode.deviceDNSFallbackEvidenceCount, 0)
        XCTAssertFalse(transition.state.episode.deviceDNSFallbackModeActive)
        XCTAssertNil(transition.state.episode.lastDeviceDNSFallbackActivatedAt)
        XCTAssertNil(transition.state.episode.lastEncryptedFallbackSuccessAt)
        XCTAssertEqual(transition.state.episode.consecutiveCarriedQueryFailureCount, 2)
        XCTAssertEqual(transition.state.episode.lastAcceptedPrimaryEvidenceAt, later)
        XCTAssertNil(transition.state.episode.lastFailureReason)
        XCTAssertEqual(transition.state.identity.rejectedResponseCount, 0)
        XCTAssertNil(transition.state.identity.rejectedResponseResolverIdentifier)
        XCTAssertNil(transition.state.reconnectEpisode)
        XCTAssertNil(transition.state.effectDelivery.lastReconnectNeededActivityAt)
        XCTAssertEqual(
            transition.effects,
            [
                .endEncryptedFallbackLogEpisode(.episodeEnd),
                .reportConnectivityRecovery(
                    ResolverHealthRecovery(
                        startedAt: start,
                        recoveredAt: later,
                        durationMilliseconds: 1_000_000,
                        reason: "timeout",
                        peakUpstreamFailureCount: 11,
                        transport: .dnsOverHTTPS,
                        verifiedBy: "smoke-probe",
                        activityContext: ResolverHealthActivityContext(
                            connectivitySeverity: .healthy,
                            networkKind: .wifi,
                            networkPathIsSatisfied: true,
                            resolverTransport: .dnsOverHTTPS,
                            deviceDNSFallbackActive: false
                        )
                    )
                ),
                .creditProductiveSelfReconnect(at: later),
                .cancelWedgeRecoveryProbe,
                .clearDeviceDNSRecaptureRestartPending,
                .cancelFallbackRecoveryProbe,
                .requestResolverRuntimeReset(
                    .full(reason: "device-dns-fallback-recovered", force: true)
                ),
                .signalConnectivityProjectionChanged,
                .persistHealth(.deferred),
                .appendNetworkActivity(.deviceDNSFallbackRecovered, at: later),
                .evaluateProtectionNotification(at: later),
                .deliverPendingResolverFailures(reason: "device-dns-fallback-recovered"),
                .evaluateQAConnectivityLog(reason: "dns-smoke-probe-success", at: later),
                .deviceLog(
                    .smokeProbeSucceeded(
                        reason: "network-path-changed",
                        transport: .dnsOverHTTPS,
                        resolverAddress: "https://primary.example/dns-query",
                        dohHTTPVersion: "h3",
                        occurredAt: later
                    )
                ),
            ]
        )

        let reset = ResolverHealthReducer.reduce(
            state: transition.state,
            event: .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: .fullRuntime(
                        currentPrimaryIdentifier: "primary-a",
                        recordsObservableReset: true
                    ),
                    reason: "device-dns-fallback-recovered",
                    occurredAt: later
                )
            ),
            projectingOnto: providerBase()
        )
        XCTAssertNil(reset.state.episode.lastAcceptedPrimaryEvidenceAt)
        XCTAssertNil(reset.state.session.lastDoHHTTPVersion)
    }

    func testPeriodicAndStartSuccessPreserveAcceptedEvidenceAndPriorDoHObservation() {
        for reason in ["periodic-health-check", "startTunnel"] {
            var state = smokeState()
            state.episode.lastAcceptedPrimaryEvidenceAt = start
            state.session.lastDoHHTTPVersion = "h2"
            state.session.lastDNSSmokeProbeSucceeded = true

            let transition = reduce(
                state: state,
                evidence: smokeEvidence(
                    reason: reason,
                    primaryResult: result(
                        response: Data([1]),
                        address: "192.0.2.53",
                        outcome: .success,
                        transport: .plainDNS
                    ),
                    primaryAccepted: true
                )
            )

            XCTAssertEqual(transition.state.episode.lastAcceptedPrimaryEvidenceAt, start)
            XCTAssertEqual(transition.state.session.lastDoHHTTPVersion, "h2")
            XCTAssertFalse(
                transition.effects.contains { effect in
                    if case .appendNetworkActivity = effect {
                        return true
                    }
                    return false
                }
            )
        }
    }

    func testAcceptedFallbackBuildsCandidateOneTwoThreeAndActivatesExactlyOnce() {
        var state = smokeState()
        state.identity.rejectedResponseCount = 2
        state.identity.rejectedResponseResolverIdentifier = "primary-a"
        state.episode.consecutiveUpstreamFailureCount = 8
        state.episode.consecutiveSmokeProbeFailureCount = 6
        state.episode.lastAcceptedPrimaryEvidenceAt = start
        state.episode.lastEncryptedFallbackSuccessAt = start
        state.episode.consecutiveCarriedQueryFailureCount = 2
        state.session.lastDoHHTTPVersion = "h3"

        for expectedCount in 1...3 {
            let transition = reduce(
                state: state,
                evidence: acceptedFallbackEvidence(reason: "fallback-check")
            )
            state = transition.state

            XCTAssertEqual(state.episode.deviceDNSFallbackEvidenceCount, expectedCount)
            XCTAssertEqual(state.identity.rejectedResponseCount, 2)
            XCTAssertEqual(state.identity.rejectedResponseResolverIdentifier, "primary-a")
            XCTAssertEqual(state.episode.lastAcceptedPrimaryEvidenceAt, start)
            XCTAssertEqual(state.episode.lastEncryptedFallbackSuccessAt, start)
            XCTAssertEqual(state.episode.consecutiveCarriedQueryFailureCount, 2)
            XCTAssertEqual(state.session.lastDoHHTTPVersion, "h3")
            XCTAssertEqual(state.session.lastDNSSmokeProbeAt, later)
            XCTAssertEqual(state.session.lastDNSSmokeProbeSucceeded, true)
            XCTAssertEqual(state.session.dnsSmokeProbeSuccessCount, 4 + expectedCount)
            XCTAssertEqual(state.session.dnsSmokeProbeFailureCount, 9)
            XCTAssertEqual(state.session.upstreamFailureCount, 11)
            XCTAssertEqual(state.episode.consecutiveSmokeProbeFailureCount, 0)
            XCTAssertEqual(state.episode.consecutiveUpstreamFailureCount, 0)
            XCTAssertNil(state.episode.lastFailureReason)
            XCTAssertEqual(state.session.lastResolverAddress, "192.0.2.53")
            XCTAssertEqual(state.session.lastResolverTransport, .deviceDNS)

            if expectedCount < 3 {
                XCTAssertFalse(state.episode.deviceDNSFallbackModeActive)
                XCTAssertNil(state.episode.lastDeviceDNSFallbackActivatedAt)
                XCTAssertEqual(state.session.deviceDNSFallbackActivationCount, 4)
                XCTAssertEqual(
                    transition.effects,
                    [
                        .creditProductiveSelfReconnect(at: later),
                        .cancelWedgeRecoveryProbe,
                        .clearDeviceDNSRecaptureRestartPending,
                        .signalConnectivityProjectionChanged,
                        .scheduleFallbackRecoveryProbe,
                        .persistHealth(.immediate),
                        .evaluateQAConnectivityLog(
                            reason: "device-dns-fallback-candidate",
                            at: later
                        ),
                        .deviceLog(
                            .smokeProbeDeviceFallback(
                                reason: "fallback-check",
                                evidenceCount: expectedCount,
                                fallbackModeActive: false,
                                resolverAddress: "192.0.2.53",
                                occurredAt: later
                            )
                        ),
                    ]
                )
            } else {
                XCTAssertTrue(state.episode.deviceDNSFallbackModeActive)
                XCTAssertEqual(state.episode.lastDeviceDNSFallbackActivatedAt, later)
                XCTAssertEqual(state.session.deviceDNSFallbackActivationCount, 5)
                XCTAssertEqual(
                    transition.effects,
                    [
                        .creditProductiveSelfReconnect(at: later),
                        .cancelWedgeRecoveryProbe,
                        .clearDeviceDNSRecaptureRestartPending,
                        .requestResolverRuntimeReset(
                            .full(reason: "device-dns-fallback-activated", force: true)
                        ),
                        .signalConnectivityProjectionChanged,
                        .appendNetworkActivity(
                            .deviceDNSFallbackActivated(reason: "fallback-check"),
                            at: later
                        ),
                        .scheduleFallbackRecoveryProbe,
                        .evaluateProtectionNotification(at: later),
                        .persistHealth(.immediate),
                        .deliverPendingResolverFailures(
                            reason: "device-dns-fallback-activated"
                        ),
                        .evaluateQAConnectivityLog(
                            reason: "device-dns-fallback-activated",
                            at: later
                        ),
                        .deviceLog(
                            .smokeProbeDeviceFallback(
                                reason: "fallback-check",
                                evidenceCount: 3,
                                fallbackModeActive: true,
                                resolverAddress: "192.0.2.53",
                                occurredAt: later
                            )
                        ),
                    ]
                )

                let reset = ResolverHealthReducer.reduce(
                    state: state,
                    event: .resolverRuntimeResetOccurred(
                        ResolverRuntimeResetObservation(
                            kind: .fullRuntime(
                                currentPrimaryIdentifier: "primary-a",
                                recordsObservableReset: true
                            ),
                            reason: "device-dns-fallback-activated",
                            occurredAt: later
                        )
                    ),
                    projectingOnto: providerBase()
                )
                XCTAssertNil(reset.state.episode.lastAcceptedPrimaryEvidenceAt)
                XCTAssertNil(reset.state.session.lastDoHHTTPVersion)
                XCTAssertNil(reset.state.episode.lastEncryptedFallbackSuccessAt)
                XCTAssertEqual(reset.state.episode.consecutiveCarriedQueryFailureCount, 0)
                XCTAssertEqual(reset.state.episode.deviceDNSFallbackEvidenceCount, 3)
                XCTAssertTrue(reset.state.episode.deviceDNSFallbackModeActive)
            }
        }
    }

    func testBackedOffPrimaryDoesNotEarnCandidateAndActiveFallbackStillForcesReset() {
        var inactive = smokeState()
        inactive.episode.deviceDNSFallbackEvidenceCount = 1
        let noCredit = reduce(
            state: inactive,
            evidence: acceptedFallbackEvidence(
                reason: "fallback-check",
                primaryOutcome: .backedOff
            )
        )
        XCTAssertEqual(noCredit.state.episode.deviceDNSFallbackEvidenceCount, 1)
        XCTAssertFalse(noCredit.state.episode.deviceDNSFallbackModeActive)

        var active = smokeState()
        active.episode.deviceDNSFallbackEvidenceCount = 3
        active.episode.deviceDNSFallbackModeActive = true
        active.episode.lastDeviceDNSFallbackActivatedAt = nil
        let alreadyActive = reduce(
            state: active,
            evidence: acceptedFallbackEvidence(reason: "fallback-check")
        )

        XCTAssertEqual(alreadyActive.state.episode.deviceDNSFallbackEvidenceCount, 3)
        XCTAssertTrue(alreadyActive.state.episode.deviceDNSFallbackModeActive)
        XCTAssertEqual(alreadyActive.state.episode.lastDeviceDNSFallbackActivatedAt, later)
        XCTAssertEqual(alreadyActive.state.session.deviceDNSFallbackActivationCount, 4)
        XCTAssertEqual(
            alreadyActive.effects,
            [
                .creditProductiveSelfReconnect(at: later),
                .cancelWedgeRecoveryProbe,
                .clearDeviceDNSRecaptureRestartPending,
                .requestResolverRuntimeReset(
                    .full(reason: "device-dns-fallback-activated", force: true)
                ),
                .signalConnectivityProjectionChanged,
                .scheduleFallbackRecoveryProbe,
                .evaluateProtectionNotification(at: later),
                .persistHealth(.immediate),
                .deliverPendingResolverFailures(reason: "device-dns-fallback-activated"),
                .evaluateQAConnectivityLog(
                    reason: "device-dns-fallback-activated",
                    at: later
                ),
                .deviceLog(
                    .smokeProbeDeviceFallback(
                        reason: "fallback-check",
                        evidenceCount: 3,
                        fallbackModeActive: true,
                        resolverAddress: "192.0.2.53",
                        occurredAt: later
                    )
                ),
            ]
        )
    }

    func testActiveFallbackModeRemainsStickyAfterOrganicFailureClearsCandidateCount() {
        let cases: [(ResolverAttemptOutcome, Int)] = [(.timeout, 1), (.backedOff, 0)]

        for (primaryOutcome, expectedEvidenceCount) in cases {
            var state = smokeState()
            state.episode.deviceDNSFallbackEvidenceCount = 0
            state.episode.deviceDNSFallbackModeActive = true
            state.episode.lastDeviceDNSFallbackActivatedAt = start

            let transition = reduce(
                state: state,
                evidence: acceptedFallbackEvidence(
                    reason: "fallback-check",
                    primaryOutcome: primaryOutcome
                )
            )

            XCTAssertEqual(
                transition.state.episode.deviceDNSFallbackEvidenceCount,
                expectedEvidenceCount
            )
            XCTAssertTrue(transition.state.episode.deviceDNSFallbackModeActive)
            XCTAssertEqual(transition.state.episode.lastDeviceDNSFallbackActivatedAt, start)
            XCTAssertEqual(transition.state.session.deviceDNSFallbackActivationCount, 4)
            XCTAssertEqual(
                transition.effects,
                [
                    .creditProductiveSelfReconnect(at: later),
                    .cancelWedgeRecoveryProbe,
                    .clearDeviceDNSRecaptureRestartPending,
                    .requestResolverRuntimeReset(
                        .full(reason: "device-dns-fallback-activated", force: true)
                    ),
                    .signalConnectivityProjectionChanged,
                    .scheduleFallbackRecoveryProbe,
                    .evaluateProtectionNotification(at: later),
                    .persistHealth(.immediate),
                    .deliverPendingResolverFailures(reason: "device-dns-fallback-activated"),
                    .evaluateQAConnectivityLog(
                        reason: "device-dns-fallback-activated",
                        at: later
                    ),
                    .deviceLog(
                        .smokeProbeDeviceFallback(
                            reason: "fallback-check",
                            evidenceCount: expectedEvidenceCount,
                            fallbackModeActive: true,
                            resolverAddress: "192.0.2.53",
                            occurredAt: later
                        )
                    ),
                ]
            )
        }
    }

    func testPrimarySuccessAfterPreviousFailureEmitsRecoveryActivity() {
        var previousFailure = smokeState()
        previousFailure.session.lastDNSSmokeProbeSucceeded = false
        let recoveryActivity = reduce(
            state: previousFailure,
            evidence: smokeEvidence(
                reason: "periodic-health-check",
                primaryResult: result(
                    response: Data([1]),
                    address: "192.0.2.53",
                    outcome: .success,
                    transport: .plainDNS
                ),
                primaryAccepted: true
            )
        )
        XCTAssertTrue(
            recoveryActivity.effects.contains(
                .appendNetworkActivity(
                    .dnsSmokeProbeSucceeded(
                        resolver: "Primary Resolver",
                        transport: .plainDNS,
                        dohHTTPVersion: nil
                    ),
                    at: later
                )
            )
        )
    }

    func testInactiveFailurePreservesCandidateAndNonSmokeSessionFailureTotal() {
        var state = smokeState()
        state.episode.deviceDNSFallbackEvidenceCount = 2
        state.episode.lastAcceptedPrimaryEvidenceAt = start
        state.episode.lastEncryptedFallbackSuccessAt = start
        state.episode.consecutiveCarriedQueryFailureCount = 2
        state.session.lastDoHHTTPVersion = "h3"
        state.session.upstreamFailureCount = 41
        var base = providerBase()
        base.upstreamFailureCount = 41

        let transition = ResolverHealthReducer.reduce(
            state: state,
            event: .smokeProbeCompleted(
                smokeEvidence(
                    reason: "periodic-health-check",
                    primaryResult: result(
                        response: nil,
                        address: "192.0.2.1",
                        outcome: .timeout,
                        transport: .plainDNS
                    ),
                    primaryAccepted: false
                )
            ),
            projectingOnto: base
        )
        var projected = base
        transition.projection.apply(to: &projected)

        XCTAssertEqual(transition.state.episode.deviceDNSFallbackEvidenceCount, 2)
        XCTAssertFalse(transition.state.episode.deviceDNSFallbackModeActive)
        XCTAssertEqual(transition.state.episode.lastAcceptedPrimaryEvidenceAt, start)
        XCTAssertEqual(transition.state.episode.lastEncryptedFallbackSuccessAt, start)
        XCTAssertEqual(transition.state.episode.consecutiveCarriedQueryFailureCount, 2)
        XCTAssertEqual(transition.state.session.lastDoHHTTPVersion, "h3")
        XCTAssertEqual(transition.state.episode.consecutiveSmokeProbeFailureCount, 1)
        XCTAssertEqual(transition.state.episode.consecutiveUpstreamFailureCount, 1)
        XCTAssertEqual(transition.state.episode.lastFailureReason, "timeout")
        XCTAssertEqual(transition.state.session.dnsSmokeProbeFailureCount, 10)
        XCTAssertEqual(transition.state.session.lastUpstreamFailureAt, later)
        XCTAssertEqual(transition.state.session.lastResolverAddress, "192.0.2.1")
        XCTAssertEqual(transition.state.session.lastResolverTransport, .plainDNS)
        XCTAssertEqual(projected.upstreamFailureCount, 41)
        XCTAssertNotEqual(
            ProtectionConnectivityPolicy.assessment(
                isConnected: true,
                health: projected,
                now: later
            ).primaryAction,
            .reconnect
        )
        XCTAssertEqual(
            transition.effects,
            [
                .signalConnectivityProjectionChanged,
                .persistHealth(.deferred),
                .appendNetworkActivity(.dnsSmokeProbeFailed(reason: "timeout"), at: later),
                .scheduleWedgeRecoveryProbe,
                .evaluateProtectionNotification(at: later),
                .evaluateQAConnectivityLog(reason: "dns-smoke-probe-failed", at: later),
                .deviceLog(
                    .smokeProbeFailed(
                        reason: "periodic-health-check",
                        failure: "timeout",
                        consecutiveSmokeFailures: 1,
                        consecutiveRejectedResponses: 0,
                        occurredAt: later
                    )
                ),
            ]
        )

        var saturated = state
        saturated.episode.consecutiveSmokeProbeFailureCount =
            DeviceDNSFallbackPolicy.maxTrackedConsecutiveSmokeProbeFailures
        let saturatedTransition = reduce(
            state: saturated,
            evidence: smokeEvidence(
                reason: "periodic-health-check",
                primaryResult: result(
                    response: nil,
                    address: "192.0.2.1",
                    outcome: .timeout,
                    transport: .plainDNS
                ),
                primaryAccepted: false
            )
        )
        XCTAssertEqual(
            saturatedTransition.state.episode.consecutiveSmokeProbeFailureCount,
            DeviceDNSFallbackPolicy.maxTrackedConsecutiveSmokeProbeFailures
        )
    }

    func testFailedSmokeRearmsHeldReconnectEpisodeBelowFreshReconnectThreshold() {
        var state = smokeState()
        state.episode.consecutiveUpstreamFailureCount = 0
        state.reconnectEpisode = ResolverReconnectEpisodeEvidence(
            startedAt: start,
            reason: "timeout",
            peakUpstreamFailureCount: 7
        )

        let transition = reduce(
            state: state,
            evidence: smokeEvidence(
                reason: "resolver-wedge-recovery",
                primaryResult: result(
                    response: nil,
                    address: "192.0.2.1",
                    outcome: .timeout,
                    transport: .plainDNS
                ),
                primaryAccepted: false
            )
        )
        var projected = providerBase()
        transition.projection.apply(to: &projected)

        XCTAssertNotEqual(
            ProtectionConnectivityPolicy.assessment(
                isConnected: true,
                health: projected,
                now: later
            ).primaryAction,
            .reconnect
        )
        XCTAssertEqual(transition.state.reconnectEpisode?.startedAt, start)
        XCTAssertEqual(transition.state.reconnectEpisode?.peakUpstreamFailureCount, 7)
        XCTAssertTrue(transition.effects.contains(.scheduleWedgeRecoveryProbe))
        XCTAssertFalse(
            transition.effects.contains { effect in
                if case .evaluateSelfReconnect = effect {
                    return true
                }
                return false
            }
        )
    }

    func testActiveFallbackFailureDeactivatesWithoutImmediateRuntimeReset() {
        var state = smokeState()
        state.episode.deviceDNSFallbackEvidenceCount = 3
        state.episode.deviceDNSFallbackModeActive = true
        state.episode.lastDeviceDNSFallbackActivatedAt = start

        let transition = reduce(
            state: state,
            evidence: smokeEvidence(
                reason: "device-dns-fallback-recovery",
                primaryResult: result(
                    response: nil,
                    address: "192.0.2.1",
                    outcome: .timeout,
                    transport: .plainDNS
                ),
                primaryAccepted: false
            )
        )

        XCTAssertEqual(transition.state.episode.deviceDNSFallbackEvidenceCount, 0)
        XCTAssertFalse(transition.state.episode.deviceDNSFallbackModeActive)
        XCTAssertNil(transition.state.episode.lastDeviceDNSFallbackActivatedAt)
        XCTAssertEqual(
            transition.effects,
            [
                .cancelFallbackRecoveryProbe,
                .signalConnectivityProjectionChanged,
                .persistHealth(.deferred),
                .appendNetworkActivity(.dnsSmokeProbeFailed(reason: "timeout"), at: later),
                .evaluateProtectionNotification(at: later),
                .evaluateQAConnectivityLog(reason: "dns-smoke-probe-failed", at: later),
                .deviceLog(
                    .smokeProbeFailed(
                        reason: "device-dns-fallback-recovery",
                        failure: "timeout",
                        consecutiveSmokeFailures: 1,
                        consecutiveRejectedResponses: 0,
                        occurredAt: later
                    )
                ),
            ]
        )
        XCTAssertFalse(
            transition.effects.contains { effect in
                if case .requestResolverRuntimeReset = effect {
                    return true
                }
                return false
            }
        )
    }

    func testInactiveCandidateSurvivesFailureAndNextQualifyingSuccessActivates() {
        var state = smokeState()
        state.episode.deviceDNSFallbackEvidenceCount = 2
        let failed = reduce(
            state: state,
            evidence: smokeEvidence(
                reason: "periodic-health-check",
                primaryResult: result(
                    response: nil,
                    address: "192.0.2.1",
                    outcome: .timeout,
                    transport: .plainDNS
                ),
                primaryAccepted: false
            )
        )
        let recovered = reduce(
            state: failed.state,
            evidence: acceptedFallbackEvidence(reason: "fallback-check")
        )

        XCTAssertEqual(failed.state.episode.deviceDNSFallbackEvidenceCount, 2)
        XCTAssertEqual(recovered.state.episode.deviceDNSFallbackEvidenceCount, 3)
        XCTAssertTrue(recovered.state.episode.deviceDNSFallbackModeActive)
        XCTAssertEqual(recovered.state.session.deviceDNSFallbackActivationCount, 5)
    }

    func testRejectedEscalationSurvivesHandoffsAndEmitsThresholdIncidentOnce() throws {
        var state = smokeState()
        state.identity.rejectedResponseCount = 0
        state.identity.rejectedResponseResolverIdentifier = nil
        state.session.rejectedResponseRescopeCount = 0
        var finalTransition: ResolverHealthTransition?

        for index in 0..<3 {
            let eventAt = later.addingTimeInterval(TimeInterval(index))
            let rejected = ResolverHealthReducer.reduce(
                state: state,
                event: .smokeProbeCompleted(
                    smokeEvidence(
                        occurredAt: eventAt,
                        reason: "resolver-wedge-recovery",
                        primaryResult: result(
                            response: Data([1]),
                            address: "192.0.2.1",
                            outcome: .success,
                            transport: .plainDNS
                        ),
                        primaryAccepted: false
                    )
                ),
                projectingOnto: providerBase()
            )
            state = rejected.state
            finalTransition = rejected

            guard index < 2 else {
                continue
            }
            let handoffAt = eventAt.addingTimeInterval(0.25)
            state =
                ResolverHealthReducer.reduce(
                    state: state,
                    event: .networkPathObserved(
                        ResolverNetworkPathObservation(
                            previousKind: index == 0 ? .wifi : .cellular,
                            previousIsSatisfied: true,
                            kind: index == 0 ? .cellular : .wifi,
                            isSatisfied: true,
                            observedAt: handoffAt
                        )
                    ),
                    projectingOnto: providerBase()
                ).state
            state =
                ResolverHealthReducer.reduce(
                    state: state,
                    event: .resolverRuntimeResetOccurred(
                        ResolverRuntimeResetObservation(
                            kind: .fullRuntime(
                                currentPrimaryIdentifier: "primary-a",
                                recordsObservableReset: true
                            ),
                            reason: "network-path-changed",
                            occurredAt: handoffAt
                        )
                    ),
                    projectingOnto: providerBase()
                ).state
        }

        let transition = try XCTUnwrap(finalTransition)
        XCTAssertEqual(transition.state.identity.rejectedResponseCount, 3)
        XCTAssertEqual(
            transition.state.identity.rejectedResponseResolverIdentifier,
            "primary-a"
        )
        XCTAssertEqual(transition.state.session.rejectedResponseRescopeCount, 1)
        XCTAssertEqual(transition.state.session.dnsSmokeProbeFailureCount, 12)
        XCTAssertEqual(transition.state.episode.consecutiveSmokeProbeFailureCount, 1)
        XCTAssertEqual(transition.state.reconnectEpisode?.reason, "rejected-response")
        XCTAssertNotEqual(
            ProtectionConnectivityPolicy.assessment(
                isConnected: true,
                health: providerBase(),
                now: later.addingTimeInterval(2)
            ).primaryAction,
            .reconnect
        )
        var projectedAtThreshold = providerBase()
        transition.projection.apply(to: &projectedAtThreshold)
        XCTAssertEqual(
            ProtectionConnectivityPolicy.assessment(
                isConnected: true,
                health: projectedAtThreshold,
                now: later.addingTimeInterval(2)
            ).primaryAction,
            .reconnect
        )
        XCTAssertEqual(
            transition.effects.filter { effect in
                if case .recordIncident(let incident) = effect,
                    incident.kind == .rejectedResponseStreak
                {
                    return true
                }
                return false
            }.count,
            1
        )
        XCTAssertTrue(
            transition.effects.contains(
                .recordIncident(
                    ResolverHealthIncident(
                        kind: .wedgeDetected,
                        occurredAt: later.addingTimeInterval(2),
                        reason: "rejected-response",
                        durationMilliseconds: nil,
                        verifiedBy: nil
                    )
                )
            )
        )
        let thresholdAt = later.addingTimeInterval(2)
        XCTAssertEqual(
            transition.effects,
            [
                .recordIncident(
                    ResolverHealthIncident(
                        kind: .rejectedResponseStreak,
                        occurredAt: thresholdAt,
                        reason: "rejected-response",
                        durationMilliseconds: nil,
                        verifiedBy: nil
                    )
                ),
                .signalConnectivityProjectionChanged,
                .persistHealth(.deferred),
                .appendNetworkActivity(
                    .dnsSmokeProbeFailed(reason: "rejected-response"),
                    at: thresholdAt
                ),
                .recordIncident(
                    ResolverHealthIncident(
                        kind: .wedgeDetected,
                        occurredAt: thresholdAt,
                        reason: "rejected-response",
                        durationMilliseconds: nil,
                        verifiedBy: nil
                    )
                ),
                .appendNetworkActivity(
                    .reconnectNeeded(reason: "rejected-response"),
                    at: thresholdAt
                ),
                .evaluateSelfReconnect(at: thresholdAt),
                .scheduleWedgeRecoveryProbe,
                .evaluateProtectionNotification(at: thresholdAt),
                .evaluateQAConnectivityLog(
                    reason: "dns-smoke-probe-failed",
                    at: thresholdAt
                ),
                .deviceLog(
                    .smokeProbeFailed(
                        reason: "resolver-wedge-recovery",
                        failure: "rejected-response",
                        consecutiveSmokeFailures: 1,
                        consecutiveRejectedResponses: 3,
                        occurredAt: thresholdAt
                    )
                ),
            ]
        )

        let fourthAt = later.addingTimeInterval(3)
        let fourth = ResolverHealthReducer.reduce(
            state: transition.state,
            event: .smokeProbeCompleted(
                smokeEvidence(
                    occurredAt: fourthAt,
                    reason: "resolver-wedge-recovery",
                    primaryResult: result(
                        response: Data([1]),
                        address: "192.0.2.1",
                        outcome: .success,
                        transport: .plainDNS
                    ),
                    primaryAccepted: false
                )
            ),
            projectingOnto: providerBase()
        )
        XCTAssertEqual(fourth.state.identity.rejectedResponseCount, 4)
        XCTAssertFalse(
            fourth.effects.contains { effect in
                if case .recordIncident(let incident) = effect,
                    incident.kind == .rejectedResponseStreak
                {
                    return true
                }
                return false
            }
        )
    }

    func testFallbackRecoveryReportsWedgeBeforeEndingFallbackLogEpisode() {
        var state = smokeState()
        state.reconnectEpisode = ResolverReconnectEpisodeEvidence(
            startedAt: start,
            reason: "rejected-response",
            peakUpstreamFailureCount: 7
        )

        let transition = reduce(
            state: state,
            evidence: acceptedFallbackEvidence(reason: "resolver-wedge-recovery")
        )

        XCTAssertNil(transition.state.reconnectEpisode)
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
                        transport: .deviceDNS,
                        verifiedBy: "smoke-probe",
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
                .creditProductiveSelfReconnect(at: later),
                .cancelWedgeRecoveryProbe,
                .clearDeviceDNSRecaptureRestartPending,
                .signalConnectivityProjectionChanged,
                .scheduleFallbackRecoveryProbe,
                .persistHealth(.immediate),
                .evaluateQAConnectivityLog(
                    reason: "device-dns-fallback-candidate",
                    at: later
                ),
                .deviceLog(
                    .smokeProbeDeviceFallback(
                        reason: "resolver-wedge-recovery",
                        evidenceCount: 1,
                        fallbackModeActive: false,
                        resolverAddress: "192.0.2.53",
                        occurredAt: later
                    )
                ),
            ]
        )
        XCTAssertFalse(
            transition.effects.contains { effect in
                if case .recordIncident(let incident) = effect,
                    incident.kind == .wedgeRecovered
                {
                    return true
                }
                return false
            }
        )
        XCTAssertFalse(
            transition.effects.contains { effect in
                if case .appendNetworkActivity(.connectivityRecovered, at: _) = effect {
                    return true
                }
                return false
            }
        )
    }

    func testRecoveryDurationFloorsAtZeroWhenWallClockMovesBackward() {
        var state = smokeState()
        state.reconnectEpisode = ResolverReconnectEpisodeEvidence(
            startedAt: later,
            reason: "timeout",
            peakUpstreamFailureCount: 4
        )
        let recoveredAt = start
        let transition = ResolverHealthReducer.reduce(
            state: state,
            event: .smokeProbeCompleted(
                smokeEvidence(
                    occurredAt: recoveredAt,
                    reason: "resolver-wedge-recovery",
                    primaryResult: result(
                        response: Data([1]),
                        address: "192.0.2.1",
                        outcome: .success,
                        transport: .plainDNS
                    ),
                    primaryAccepted: true
                )
            ),
            projectingOnto: providerBase()
        )

        XCTAssertTrue(
            transition.effects.contains(
                .reportConnectivityRecovery(
                    ResolverHealthRecovery(
                        startedAt: later,
                        recoveredAt: recoveredAt,
                        durationMilliseconds: 0,
                        reason: "timeout",
                        peakUpstreamFailureCount: 4,
                        transport: .plainDNS,
                        verifiedBy: "smoke-probe",
                        activityContext: ResolverHealthActivityContext(
                            connectivitySeverity: .healthy,
                            networkKind: .wifi,
                            networkPathIsSatisfied: true,
                            resolverTransport: .plainDNS,
                            deviceDNSFallbackActive: false
                        )
                    )
                )
            )
        )
    }

    func testReconnectActivityReminderUsesInclusiveThreeHundredSecondBoundary() {
        var state = smokeState()
        state.identity.rejectedResponseCount = 2
        state.identity.rejectedResponseResolverIdentifier = "primary-a"
        state.reconnectEpisode = ResolverReconnectEpisodeEvidence(
            startedAt: start,
            reason: "rejected-response",
            peakUpstreamFailureCount: 2
        )
        state.episode.consecutiveUpstreamFailureCount = 8
        state.effectDelivery.lastReconnectNeededActivityAt = start

        let beforeBoundary = reduceRejected(state: state, occurredAt: start.addingTimeInterval(299))
        let atBoundary = reduceRejected(state: state, occurredAt: start.addingTimeInterval(300))
        let aboveBoundary = reduceRejected(state: state, occurredAt: start.addingTimeInterval(301))

        XCTAssertFalse(hasReconnectNeededActivity(beforeBoundary.effects))
        XCTAssertTrue(hasReconnectNeededActivity(atBoundary.effects))
        XCTAssertTrue(hasReconnectNeededActivity(aboveBoundary.effects))
        XCTAssertEqual(beforeBoundary.state.reconnectEpisode?.reason, "rejected-response")
        XCTAssertEqual(beforeBoundary.state.reconnectEpisode?.peakUpstreamFailureCount, 9)
        XCTAssertEqual(
            beforeBoundary.state.effectDelivery.lastReconnectNeededActivityAt,
            start
        )
        XCTAssertEqual(
            atBoundary.state.effectDelivery.lastReconnectNeededActivityAt,
            start.addingTimeInterval(300)
        )
    }

    func testEverySmokeProjectionPreservesProviderOwnedEnvelopeAndTallies() {
        var base = providerBase()
        base.cacheHitCount = 31
        base.cacheMissCount = 32
        base.coalescedQueryCount = 33
        base.upstreamFailureCount = 34
        base.lastNetworkSettingsReapplyFailureAt = start
        base.lastNetworkSettingsReapplyFailureReason = "provider-owned"
        base.networkSettingsReapplyFailureCount = 35
        base.failClosedServedQueryCount = 36
        base.lastFailClosedAt = start
        base.lastFailClosedReason = "snapshot-unavailable"

        let events: [ResolverSmokeProbeEvidence] = [
            smokeEvidence(
                reason: "network-path-changed",
                primaryResult: result(
                    response: Data([1]),
                    address: "192.0.2.1",
                    outcome: .success,
                    transport: .plainDNS
                ),
                primaryAccepted: true
            ),
            acceptedFallbackEvidence(reason: "fallback-check"),
            smokeEvidence(
                reason: "periodic-health-check",
                primaryResult: result(
                    response: nil,
                    address: "192.0.2.1",
                    outcome: .timeout,
                    transport: .plainDNS
                ),
                primaryAccepted: false
            ),
        ]

        for event in events {
            var state = smokeState()
            state.session.upstreamFailureCount = base.upstreamFailureCount
            let transition = ResolverHealthReducer.reduce(
                state: state,
                event: .smokeProbeCompleted(event),
                projectingOnto: base
            )
            var projected = base
            transition.projection.apply(to: &projected)
            XCTAssertResolverHealthProviderFieldsEqual(projected, base)
            XCTAssertEqual(projected.upstreamFailureCount, base.upstreamFailureCount)
        }
    }

    private func reduce(
        state: ResolverHealthEvidenceState,
        evidence: ResolverSmokeProbeEvidence
    ) -> ResolverHealthTransition {
        ResolverHealthReducer.reduce(
            state: state,
            event: .smokeProbeCompleted(evidence),
            projectingOnto: providerBase()
        )
    }

    private func gatewayReduce(
        state: ResolverHealthEvidenceState,
        completion: ResolverHealthSmokeProbeCompletion
    ) -> (state: ResolverHealthEvidenceState, transition: ResolverHealthGatewayTransition) {
        var snapshot = providerBase()
        ResolverHealthSnapshotProjection(state: state).apply(to: &snapshot)
        return ResolverHealthGateway.reduce(
            state: state,
            event: .smokeProbeCompleted(completion),
            projectingOnto: snapshot
        )
    }

    private func reduceRejected(
        state: ResolverHealthEvidenceState,
        occurredAt: Date
    ) -> ResolverHealthTransition {
        ResolverHealthReducer.reduce(
            state: state,
            event: .smokeProbeCompleted(
                smokeEvidence(
                    occurredAt: occurredAt,
                    reason: "resolver-wedge-recovery",
                    primaryResult: result(
                        response: Data([1]),
                        address: "192.0.2.1",
                        outcome: .success,
                        transport: .plainDNS
                    ),
                    primaryAccepted: false
                )
            ),
            projectingOnto: providerBase()
        )
    }

    private func hasReconnectNeededActivity(_ effects: [ResolverHealthEffect]) -> Bool {
        effects.contains { effect in
            if case .appendNetworkActivity(.reconnectNeeded, at: _) = effect {
                return true
            }
            return false
        }
    }

    private func smokeState() -> ResolverHealthEvidenceState {
        var state = ResolverHealthEvidenceState()
        state.identity.primaryIdentifier = "primary-a"
        state.episode.lastFailureReason = "timeout"
        state.session.networkPathIsSatisfied = true
        state.session.dnsSmokeProbeSuccessCount = 4
        state.session.dnsSmokeProbeFailureCount = 9
        state.session.deviceDNSFallbackActivationCount = 4
        state.session.lastResolverTransport = .plainDNS
        state.session.upstreamFailureCount = 11
        return state
    }

    private func smokeEvidence(
        occurredAt: Date? = nil,
        reason: String,
        primaryResult: DNSResolutionResult,
        primaryAccepted: Bool,
        fallbackResult: DNSResolutionResult? = nil,
        fallbackAccepted: Bool = false
    ) -> ResolverSmokeProbeEvidence {
        return ResolverSmokeProbeEvidence(
            occurredAt: occurredAt ?? later,
            reason: reason,
            primaryResult: primaryResult,
            primaryAccepted: primaryAccepted,
            fallbackResult: fallbackResult,
            fallbackAccepted: fallbackAccepted,
            modeInsensitivePrimaryIdentifier: "primary-a",
            configuredResolverDisplayName: "Primary Resolver"
        )
    }

    private func acceptedFallbackEvidence(
        reason: String,
        primaryOutcome: ResolverAttemptOutcome = .timeout
    ) -> ResolverSmokeProbeEvidence {
        smokeEvidence(
            reason: reason,
            primaryResult: result(
                response: nil,
                address: "https://primary.example/dns-query",
                outcome: primaryOutcome,
                transport: .dnsOverHTTPS
            ),
            primaryAccepted: false,
            fallbackResult: result(
                response: Data([1]),
                address: "192.0.2.53",
                outcome: .success,
                transport: .deviceDNS
            ),
            fallbackAccepted: true
        )
    }

    private func result(
        response: Data?,
        address: String,
        outcome: ResolverAttemptOutcome,
        transport: DNSResolverTransport,
        negotiatedDoHProtocol: String? = nil
    ) -> DNSResolutionResult {
        DNSResolutionResult(
            response: response,
            successfulResolverAddress: response == nil ? nil : address,
            attempts: [
                ResolverAttempt(
                    address: address,
                    outcome: outcome,
                    transport: transport,
                    negotiatedDoHProtocol: negotiatedDoHProtocol
                )
            ],
            transport: transport,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false
        )
    }

    private func providerBase() -> TunnelHealthSnapshot {
        resolverHealthProviderSnapshot()
    }

}
