import Foundation
import XCTest
import LavaSecDNS
import LavaSecKit

final class ResolverTierEvidenceTests: XCTestCase {
    // Oct 2 Wi-Fi capture: one three-second timeout repeatedly restarted a tier
    // that had just replied. A first failure must collect confirmation, not cancel.
    func testFirstDeviceFailureWaitsForAnIndependentConfirmation() {
        var health = ResolverTierHealth()
        XCTAssertEqual(health.apply(evidence(tier: .tierTwo), observationSequence: 11), .none)
        XCTAssertEqual(health.state(for: .tierTwo).failureCount, 1)
        XCTAssertEqual(health.state(for: .tierTwo).recoveryStatus, .waiting)
        XCTAssertEqual(health.state(for: .tierTwo).recoveryKind, .recaptureDeviceDNS)
        XCTAssertTrue(health.deviceDNSConfirmationNeeded(for: .tierTwo))
        XCTAssertFalse(health.deviceDNSRecaptureIsConfirmed(for: .tierTwo))
    }

    func testTwoIndependentDeviceFailuresConfirmWithoutWallClockThresholds() {
        var health = ResolverTierHealth()
        XCTAssertEqual(health.apply(evidence(sendSequence: 10), at: Date(timeIntervalSince1970: 100), observationSequence: 20), .none)
        XCTAssertEqual(health.apply(evidence(sendSequence: 21), at: Date(timeIntervalSince1970: 1), observationSequence: 22), .recaptureDeviceDNS)
        XCTAssertFalse(health.deviceDNSConfirmationNeeded(for: .tierOne))
        XCTAssertEqual(health.deviceDNSRecaptureObservationSequence(for: .tierOne), 22)
        XCTAssertTrue(health.deviceDNSRecaptureIsConfirmed(for: .tierOne, sendSequence: 21, observationSequence: 22))
        XCTAssertFalse(health.deviceDNSRecaptureIsConfirmed(for: .tierOne, sendSequence: 10, observationSequence: 22))
        XCTAssertFalse(health.deviceDNSRecaptureIsConfirmed(for: .tierOne, sendSequence: 21, observationSequence: 20))
    }

    // Oct 2 capture: three timeouts completed together, but every leg had already
    // launched before the first timeout finished. Query volume is not confirmation.
    func testParallelFailureBurstCannotConfirmDeviceRecapture() {
        var health = ResolverTierHealth()
        for (send, completion): (UInt64, UInt64) in [(10, 20), (11, 21), (12, 22)] {
            XCTAssertEqual(health.apply(evidence(tier: .tierTwo, sendSequence: send), observationSequence: completion), .none)
        }
        XCTAssertEqual(health.state(for: .tierTwo).failureCount, 3)
        XCTAssertTrue(health.deviceDNSConfirmationNeeded(for: .tierTwo))
        XCTAssertFalse(health.deviceDNSRecaptureIsConfirmed(for: .tierTwo))
        XCTAssertEqual(health.apply(evidence(tier: .tierTwo, sendSequence: 23), observationSequence: 24), .recaptureDeviceDNS)
    }

    // Oct 2 capture: a newer Device reply arrived while an older leg waited for
    // its timeout. Preserve the failure count without treating it as a new outage.
    func testFailureLaunchedBeforeNewerDeviceReplyCannotStartOrReplaceConfirmation() {
        var health = ResolverTierHealth()
        health.observeDeviceDNSReply(for: .tierOne, observationSequence: 11)
        XCTAssertEqual(health.apply(evidence(sendSequence: 10), observationSequence: 12), .none)
        XCTAssertEqual(health.state(for: .tierOne).failureCount, 1)
        XCTAssertFalse(health.deviceDNSConfirmationNeeded(for: .tierOne))
        XCTAssertEqual(health.apply(evidence(sendSequence: 13), observationSequence: 14), .none)
        XCTAssertEqual(health.apply(evidence(sendSequence: 10), observationSequence: 15), .none)
        XCTAssertTrue(health.deviceDNSConfirmationNeeded(for: .tierOne))
        XCTAssertEqual(health.apply(evidence(sendSequence: 16), observationSequence: 17), .recaptureDeviceDNS)
    }

    func testUDPTCPRetriesUseTheEarliestSendAndDoNotBecomeIndependentLegs() {
        let value = classified([
            .init(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS,
                pathEpoch: 4, actualEgress: .physical, sendSequence: 10),
            .init(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS,
                usedTCP: true, pathEpoch: 4, actualEgress: .physical, sendSequence: 30)
        ])
        XCTAssertEqual(value.sendSequence, 10)
        var health = ResolverTierHealth()
        _ = health.apply(evidence(sendSequence: 5), observationSequence: 20)
        XCTAssertEqual(health.apply(value, observationSequence: 40), .none)
        XCTAssertEqual(health.state(for: .tierOne).attemptCount, 3)
        XCTAssertFalse(health.deviceDNSRecaptureIsConfirmed(for: .tierOne))
    }

    func testEveryWireAttemptNeedsANonzeroSendSequence() {
        for missing in [nil, UInt64(0)] {
            let value = classified([
                .init(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS,
                    pathEpoch: 4, actualEgress: .physical, sendSequence: 10),
                .init(address: "192.168.1.2", outcome: .timeout, transport: .deviceDNS,
                    pathEpoch: 4, actualEgress: .physical, sendSequence: missing)
            ])
            XCTAssertNil(value.sendSequence)
            var health = ResolverTierHealth()
            XCTAssertEqual(health.apply(value, observationSequence: 20), .none)
            XCTAssertFalse(health.deviceDNSConfirmationNeeded(for: .tierOne))
        }
        let localRefusal = classified([
            .init(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS,
                pathEpoch: 4, actualEgress: .physical, sendSequence: 10),
            .init(address: "192.168.1.2", outcome: .backedOff, transport: .deviceDNS)
        ])
        XCTAssertEqual(localRefusal.sendSequence, 10)
    }

    func testMissingOrNonmonotonicCompletionCannotAuthorizeConfirmation() {
        for (send, completion): (UInt64?, UInt64?) in [(nil, 20), (0, 20), (10, nil), (10, 0), (10, 10), (10, 9)] {
            var health = ResolverTierHealth()
            XCTAssertEqual(health.apply(evidence(sendSequence: send), observationSequence: completion), .none)
            XCTAssertFalse(health.deviceDNSConfirmationNeeded(for: .tierOne))
            XCTAssertFalse(health.deviceDNSRecaptureIsConfirmed(for: .tierOne))
        }
    }

    func testLocalRefusalsNeitherConfirmNorEraseAPendingWireFailure() {
        var health = ResolverTierHealth()
        _ = health.apply(evidence(), observationSequence: 11)
        for outcome in ResolverAttemptOutcome.allCases where !outcome.reachedTheWire {
            let refused = classified([
                .init(address: "192.168.1.1", outcome: outcome, transport: .deviceDNS,
                    pathEpoch: 4, actualEgress: .physical, sendSequence: 12)
            ])
            XCTAssertEqual(health.apply(refused, observationSequence: 13), .none, outcome.rawValue)
            XCTAssertTrue(health.deviceDNSConfirmationNeeded(for: .tierOne), outcome.rawValue)
        }
        XCTAssertFalse(health.deviceDNSRecaptureIsConfirmed(for: .tierOne))
        XCTAssertEqual(health.apply(evidence(sendSequence: 14), observationSequence: 15), .recaptureDeviceDNS)
    }

    func testOtherTierRepliesCannotClearPendingDeviceConfirmation() {
        var health = ResolverTierHealth()
        _ = health.apply(evidence(tier: .tierTwo), observationSequence: 11)
        _ = health.apply(evidence(tier: .tierZero, kind: .upstream, outcome: .served), observationSequence: 12)
        _ = health.apply(evidence(tier: .tierOne, kind: .fixed, outcome: .answered, rejection: true), observationSequence: 13)
        XCTAssertTrue(health.deviceDNSConfirmationNeeded(for: .tierTwo))
        XCTAssertEqual(health.apply(evidence(tier: .tierTwo, sendSequence: 14), observationSequence: 15), .recaptureDeviceDNS)
    }

    func testSameTierLateOrErrorReplyRetiresPendingAndConfirmedFailures() {
        for confirmed in [false, true] {
            for reply in [evidence(outcome: .served), evidence(outcome: .answered, rejection: true),
                          evidence(outcome: .served).recordingClientDeadlineExpired()] {
                var health = ResolverTierHealth()
                _ = health.apply(evidence(), observationSequence: 11)
                if confirmed { _ = health.apply(evidence(sendSequence: 12), observationSequence: 13) }
                _ = health.apply(reply.recordingReply(observationSequence: 15), observationSequence: 20)
                XCTAssertFalse(health.deviceDNSConfirmationNeeded(for: .tierOne))
                XCTAssertFalse(health.deviceDNSRecaptureIsConfirmed(for: .tierOne))
                XCTAssertEqual(health.apply(evidence(sendSequence: 12), observationSequence: 21), .none)
                XCTAssertFalse(health.deviceDNSConfirmationNeeded(for: .tierOne))
            }
        }
    }

    func testDelayedMergedReplyDoesNotEraseAFailureAfterTheRawReply() {
        for confirmed in [false, true] {
            var health = ResolverTierHealth()
            let rawReply = evidence(outcome: .answered, rejection: true).recordingReply(observationSequence: 10)
            health.observeDeviceDNSReply(for: .tierOne, observationSequence: 10)
            _ = health.apply(evidence(sendSequence: 11), at: Date(timeIntervalSince1970: 12), observationSequence: 12)
            if confirmed {
                _ = health.apply(evidence(sendSequence: 13), at: Date(timeIntervalSince1970: 14), observationSequence: 14)
            }
            let previous = health.state(for: .tierOne)
            XCTAssertEqual(health.apply(rawReply, at: Date(timeIntervalSince1970: 30), observationSequence: 30), .none)
            XCTAssertEqual(health.deviceDNSRecaptureIsConfirmed(for: .tierOne), confirmed)
            XCTAssertEqual(health.deviceDNSConfirmationNeeded(for: .tierOne), !confirmed)
            XCTAssertEqual(health.state(for: .tierOne).recoveryKind, .recaptureDeviceDNS)
            XCTAssertEqual(health.state(for: .tierOne).recoveryStatus, confirmed ? .eligible : .waiting)
            var expected = previous
            expected.answeredCount += 1
            expected.attemptCount += 1
            XCTAssertEqual(health.state(for: .tierOne), expected)
        }
    }

    func testLateReplyTransformPreservesItsRawSequence() {
        let value = evidence(outcome: .served).recordingReply(observationSequence: 20)
        XCTAssertEqual(value.recordingClientDeadlineExpired().replySequence, 20)
        XCTAssertEqual(value.recordingClientDeadlineExpired().sendSequence, value.sendSequence)
        XCTAssertNil(evidence().recordingReply(observationSequence: 20).replySequence)
    }

    func testCooldownWakeRequiresAnAttemptSentAfterTheWakeFence() {
        var health = ResolverTierHealth()
        _ = health.apply(evidence(), observationSequence: 11)
        _ = health.apply(evidence(sendSequence: 12), observationSequence: 13)
        let oldCounters = health.state(for: .tierOne)
        health.invalidateDeviceDNSConfirmation(for: .tierOne, observationSequence: 20)
        XCTAssertTrue(health.deviceDNSConfirmationNeeded(for: .tierOne))
        XCTAssertFalse(health.deviceDNSRecaptureIsConfirmed(for: .tierOne))
        XCTAssertEqual(health.state(for: .tierOne).failureCount, oldCounters.failureCount)
        XCTAssertEqual(health.state(for: .tierOne).attemptCount, oldCounters.attemptCount)
        XCTAssertEqual(health.apply(evidence(sendSequence: 14), observationSequence: 21), .none)
        XCTAssertEqual(health.apply(evidence(sendSequence: 22), observationSequence: 23), .recaptureDeviceDNS)
        XCTAssertTrue(health.deviceDNSRecaptureIsConfirmed(for: .tierOne, sendSequence: 22, observationSequence: 23))
    }

    func testContextResetRetiresAllConfirmationAndReplyFences() {
        var health = ResolverTierHealth()
        _ = health.apply(evidence(), observationSequence: 11)
        _ = health.apply(evidence(sendSequence: 12), observationSequence: 13)
        health = ResolverTierHealth()
        XCTAssertFalse(health.deviceDNSRecaptureIsConfirmed(for: .tierOne))
        XCTAssertFalse(health.deviceDNSConfirmationNeeded(for: .tierOne))
        XCTAssertEqual(health.apply(evidence(sendSequence: 14), observationSequence: 15), .none)
        XCTAssertTrue(health.deviceDNSConfirmationNeeded(for: .tierOne))
    }

    func testAnUnorderedReplyFailsClosedUntilAnOrderedReplyIsObserved() {
        var health = ResolverTierHealth()
        _ = health.apply(evidence(), observationSequence: 11)
        health.observeDeviceDNSReply(for: .tierOne, observationSequence: nil)
        XCTAssertFalse(health.deviceDNSConfirmationNeeded(for: .tierOne))
        XCTAssertEqual(health.apply(evidence(sendSequence: 12), observationSequence: 13), .none)
        XCTAssertFalse(health.deviceDNSConfirmationNeeded(for: .tierOne))
        health.observeDeviceDNSReply(for: .tierOne, observationSequence: 14)
        XCTAssertEqual(health.apply(evidence(sendSequence: 15), observationSequence: 16), .none)
        XCTAssertTrue(health.deviceDNSConfirmationNeeded(for: .tierOne))
    }

    func testRawDeviceRejectionIsObservedBeforeItsEncryptedFallbackCompletes() throws {
        let recorder = TierReplyRecorder()
        let refused = Data([0x12, 0x34, 0x81, 0x85, 0, 0, 0, 0, 0, 0, 0, 0])
        let orchestrator = replyHookOrchestrator(recorder: recorder, deviceResponse: refused, dohFails: false)
        let plan = DNSResolverRuntimePlan.make(
            resolver: .device, fallbackToDeviceDNS: false, usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"], networkKind: .wifi,
            deviceDNSFallbackModeActive: false)
            .recomputingResolverRejectionFallbackTrigger(deviceResolverWedged: true)
        orchestrator.resolveUpstream(Data(), plan: plan) { recorder.recordResult($0) }
        let result = try XCTUnwrap(recorder.result)
        XCTAssertTrue(recorder.replyObservedBeforeFallback)
        XCTAssertEqual(recorder.replies.map(\.tier), [.tierOne])
        XCTAssertEqual(recorder.deviceTiers, [.tierOne])
        XCTAssertEqual(result.tierEvidence.first?.outcome, .answered)
        XCTAssertEqual(result.tierEvidence.first?.replySequence, 50)
        XCTAssertEqual(result.tierEvidence.count, 2)
    }

    func testRawDeviceFallbackReplyIsStampedOnceWithItsSavedTier() throws {
        let recorder = TierReplyRecorder()
        let answer = Data([0x12, 0x34, 0x81, 0x80, 0, 0, 0, 0, 0, 0, 0, 0])
        let orchestrator = replyHookOrchestrator(recorder: recorder, deviceResponse: answer, dohFails: true)
        let plan = DNSResolverRuntimePlan.make(
            resolver: .quad9UnfilteredDoH, fallbackToDeviceDNS: true,
            deviceDNSAddresses: ["192.168.1.1"], networkKind: .wifi,
            deviceDNSFallbackModeActive: false)
        orchestrator.resolveUpstream(Data(), plan: plan) { recorder.recordResult($0) }
        let result = try XCTUnwrap(recorder.result)
        XCTAssertEqual(recorder.replies.map(\.tier), [.tierTwo])
        XCTAssertEqual(recorder.deviceTiers, [.tierTwo])
        XCTAssertEqual(result.tierEvidence.map(\.replySequence), [nil, 50])
        XCTAssertEqual(result.tierEvidence.last?.outcome, .served)
    }

    func testDeviceExecutorReceivesTheSoleEnabledSavedTierTwo() throws {
        let recorder = TierReplyRecorder()
        let answer = Data([0x12, 0x34, 0x81, 0x80, 0, 0, 0, 0, 0, 0, 0, 0])
        let orchestrator = replyHookOrchestrator(recorder: recorder, deviceResponse: answer, dohFails: false)
        var configuration = AppConfiguration()
        try configuration.applyDNSResolutionSelections([
            .init(id: DNSResolverPreset.quad9UnfilteredDoH.id, isEnabled: false),
            .init(id: DNSResolverPreset.device.id, isEnabled: true)
        ], allowsCustom: false)
        let plan = DNSResolverRuntimePlan.make(
            configuration: configuration, deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi, deviceDNSFallbackModeActive: false)
        orchestrator.resolveUpstream(Data(), plan: plan) { recorder.recordResult($0) }
        XCTAssertNotNil(recorder.result)
        XCTAssertEqual(recorder.deviceTiers, [.tierTwo])
        XCTAssertEqual(recorder.replies.map(\.tier), [.tierTwo])
    }

    func testWholeLegSealingRetainsItsEarlierUDPReplyStamp() throws {
        let recorder = TierReplyRecorder()
        let answer = Data([0x12, 0x34, 0x81, 0x80, 0, 0, 0, 0, 0, 0, 0, 0])
        let orchestrator = replyHookOrchestrator(
            recorder: recorder, deviceResponse: answer, dohFails: false, deviceReplySequence: 20)
        let plan = DNSResolverRuntimePlan.make(
            resolver: .device, fallbackToDeviceDNS: false,
            deviceDNSAddresses: ["192.168.1.1"], networkKind: .wifi,
            deviceDNSFallbackModeActive: false)
        orchestrator.resolveUpstream(Data(), plan: plan) { recorder.recordResult($0) }
        let result = try XCTUnwrap(recorder.result)
        XCTAssertEqual(recorder.replies.first?.replySequence, 20)
        XCTAssertEqual(result.tierEvidence.first?.replySequence, 20, "Whole-leg hook must not re-stamp raw UDP reply as 50")
    }

    func testTruncatedUDPReplyRetiresConfirmedGrantBeforeTCPFinishes() {
        var health = ResolverTierHealth()
        _ = health.apply(evidence(), observationSequence: 11)
        _ = health.apply(evidence(sendSequence: 12), observationSequence: 13)
        XCTAssertTrue(health.deviceDNSRecaptureIsConfirmed(for: .tierOne, sendSequence: 12, observationSequence: 13))

        let udp = ResolverAttempt(
            address: "192.168.1.1", outcome: .truncatedAnswer, transport: .deviceDNS,
            pathEpoch: 4, actualEgress: .physical, sendSequence: 14)
            .recordingReply(observationSequence: 15)
        // The transport observes this source-matched UDP reply before beginning TCP.
        health.observeDeviceDNSReply(for: .tierOne, observationSequence: udp.replySequence)
        XCTAssertFalse(health.deviceDNSRecaptureIsConfirmed(for: .tierOne))
        XCTAssertEqual(health.state(for: .tierOne).recoveryKind, .none)
        XCTAssertEqual(health.state(for: .tierOne).recoveryStatus, .notNeeded)

        // A new leg fails while the old TCP fallback is still outstanding.
        _ = health.apply(evidence(sendSequence: 16), at: Date(timeIntervalSince1970: 17), observationSequence: 17)
        let previous = health.state(for: .tierOne)
        let delayed = classified([
            udp,
            .init(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS,
                usedTCP: true, pathEpoch: 4, actualEgress: .physical, sendSequence: 18)
        ])
        XCTAssertEqual(delayed.outcome, .answered)
        XCTAssertEqual(delayed.replySequence, 15)
        XCTAssertEqual(delayed.sendSequence, 14)
        XCTAssertEqual(health.apply(delayed, at: Date(timeIntervalSince1970: 20), observationSequence: 20), .none)
        XCTAssertTrue(health.deviceDNSConfirmationNeeded(for: .tierOne))
        var expected = previous
        expected.answeredCount += 1
        expected.attemptCount += 2
        XCTAssertEqual(health.state(for: .tierOne), expected)
    }

    func testEvidenceRetainsLatestWireReplyAndIgnoresNoWireReplyStamps() {
        let first = ResolverAttempt(
            address: "192.168.1.1", outcome: .truncatedAnswer, transport: .deviceDNS,
            pathEpoch: 4, sendSequence: 10, replySequence: 11)
        XCTAssertEqual(first.recordingReply(observationSequence: nil).replySequence, 11)
        let value = classified([
            first,
            .init(address: "192.168.1.2", outcome: .truncatedAnswer, transport: .deviceDNS,
                pathEpoch: 4, sendSequence: 12, replySequence: 13),
            .init(address: "192.168.1.3", outcome: .sendFailed, transport: .deviceDNS,
                pathEpoch: 4, sendSequence: 14, replySequence: 99)
        ])
        XCTAssertEqual(value.replySequence, 13)
        XCTAssertEqual(value.sendSequence, 10)
    }

    func testReplyStampSurvivesCancellationOfTheFollowingTCPAttempt() {
        let value = classified([
            .init(address: "192.168.1.1", outcome: .truncatedAnswer, transport: .deviceDNS,
                pathEpoch: 4, actualEgress: .physical, sendSequence: 10, replySequence: 11),
            .init(address: "192.168.1.1", outcome: .refusedAfterLifecycleEnded, transport: .deviceDNS,
                usedTCP: true, pathEpoch: 4, actualEgress: .physical)
        ])
        XCTAssertEqual(value.outcome, .notAttempted, "Ended work remains neutral for current health")
        XCTAssertEqual(value.replySequence, 11)
        XCTAssertEqual(value.sendSequence, 10)
        XCTAssertEqual(value.recordingClientDeadlineExpired().replySequence, 11)
        XCTAssertFalse(value.permitsDeviceDNSRecapture(in: recaptureContext()))
    }

    private func replyHookOrchestrator(
        recorder: TierReplyRecorder, deviceResponse: Data, dohFails: Bool,
        deviceReplySequence: UInt64? = nil
    ) -> ResolverOrchestrator {
        let unused = DNSResolutionResult(
            response: nil, successfulResolverAddress: nil, attempts: [], transport: .plainDNS,
            udpTruncated: false, tcpFallbackAttempted: false, tcpFallbackSucceeded: false)
        return ResolverOrchestrator(executors: .init(
            isEndpointBackedOff: { _ in false },
            resolveDoH: { _, _, _, completion in
                recorder.recordFallbackStart()
                completion(.init(response: dohFails ? nil : deviceResponse, outcome: dohFails ? .timeout : .success))
            },
            resolveDoT: { _, _, _, _, completion in completion(.init(response: nil, outcome: .timeout)) },
            resolveDoQ: { _, _, _, _, completion in completion(.init(response: nil, outcome: .timeout)) },
            resolvePlain: { _, _, _, _, _, _ in unused },
            resolveTunnelledPlain: { _, _ in unused },
            resolveDevice: { _, _, _, _, _, tier in
                recorder.recordDeviceTier(tier)
                return DNSResolutionResult(
                    response: deviceResponse, successfulResolverAddress: "192.168.1.1",
                    attempts: [.init(address: "192.168.1.1", outcome: .success, transport: .deviceDNS,
                        pathEpoch: 4, actualEgress: .physical, sendSequence: 10,
                        replySequence: deviceReplySequence)],
                    transport: .deviceDNS, udpTruncated: false,
                    tcpFallbackAttempted: false, tcpFallbackSucceeded: false)
            },
            observeTierReply: { evidence in
                recorder.recordReply(evidence)
                return evidence.recordingReply(observationSequence: 50)
            }),
            egressAllowance: { .dnsOnlyMode }, tunnelledPlainDNSRoute: { nil },
            admissionEpoch: { 7 }, currentPathEpoch: { 4 }, tierOneFallbackPlan: { nil })
    }

    func testRepairOpportunityFollowsResolverKindRatherThanTierNumber() {
        for tier in [DNSResolverTier.tierOne, .tierTwo] {
            var health = ResolverTierHealth()
            XCTAssertEqual(health.apply(evidence(tier: tier, kind: .device), observationSequence: 11), .none)
            XCTAssertEqual(health.apply(evidence(tier: tier, kind: .device, sendSequence: 12), observationSequence: 13), .recaptureDeviceDNS)
            XCTAssertEqual(health.state(for: tier).consecutiveFailureCount, 2)
            XCTAssertEqual(health.apply(evidence(tier: tier, kind: .fixed)), .retryFixedEndpoint)
        }
        var health = ResolverTierHealth()
        XCTAssertEqual(health.apply(evidence(tier: .tierZero, kind: .upstream, egress: .tunnel)), .upstreamSession)
        XCTAssertEqual(health.apply(evidence(tier: .tierTwo, kind: .device, egress: .tunnel)), .none)
    }

    func testSuccessAtAnotherTierDoesNotEraseDeviceFailure() {
        var health = ResolverTierHealth()
        _ = health.apply(evidence(tier: .tierTwo, kind: .device), observationSequence: 11)
        _ = health.apply(evidence(tier: .tierTwo, kind: .device, sendSequence: 12), observationSequence: 13)
        for tier in [DNSResolverTier.tierZero, .tierOne] {
            _ = health.apply(evidence(tier: tier, kind: .fixed, outcome: .served))
        }
        XCTAssertEqual(health.state(for: .tierTwo).consecutiveFailureCount, 2)
        XCTAssertEqual(health.state(for: .tierTwo).recoveryKind, .recaptureDeviceDNS)
        _ = health.apply(evidence(tier: .tierTwo, kind: .device, outcome: .served), observationSequence: 15)
        XCTAssertEqual(health.state(for: .tierTwo).consecutiveFailureCount, 0)
        XCTAssertEqual(health.state(for: .tierTwo).recoveryKind, .none)
    }

    func testRejectedDeviceAnswerCannotAuthorizeRecapture() {
        var health = ResolverTierHealth()
        for _ in 0..<4 {
            XCTAssertEqual(health.apply(evidence(kind: .device, outcome: .answered, rejection: true)), .none)
        }
        XCTAssertEqual(health.state(for: .tierOne).consecutiveRejectedResponseCount, 4)
        XCTAssertEqual(health.state(for: .tierOne).consecutiveFailureCount, 0)
        XCTAssertEqual(health.apply(evidence(kind: .fixed, outcome: .answered, rejection: true)), .retryFixedEndpoint)
    }

    func testSameTierReplyRetiresAnOutstandingNoResponseRepair() {
        for status in [DNSResolverTierHealthSnapshot.RecoveryStatus.eligible, .restarting, .throttled] {
            var health = ResolverTierHealth()
            _ = health.apply(evidence())
            health.setRecoveryStatus(status, for: .tierOne)
            XCTAssertEqual(health.apply(evidence(outcome: .answered, rejection: true)), .none)
            XCTAssertEqual(health.state(for: .tierOne).consecutiveFailureCount, 0)
            XCTAssertEqual(health.state(for: .tierOne).recoveryKind, .none)
            XCTAssertEqual(health.state(for: .tierOne).recoveryStatus, .waiting)
            XCTAssertEqual(health.state(for: .tierOne).consecutiveRejectedResponseCount, 1)
        }
        var health = ResolverTierHealth()
        XCTAssertEqual(health.apply(evidence(tier: .tierZero, kind: .upstream, outcome: .answered, rejection: true)), .upstreamSession)
    }

    func testNeutralBackoffPreservesTheLastActualFailureAndDeferredRepair() {
        var health = ResolverTierHealth()
        let failedAt = Date(timeIntervalSince1970: 1_000)
        _ = health.apply(evidence(), at: failedAt, observationSequence: 11)
        health.setRecoveryStatus(.throttled, for: .tierOne)
        let failed = health.state(for: .tierOne)
        let backedOff = ResolverTierEvidence(
            tier: .tierOne, resolverKind: .fixed, transport: .dnsOverHTTPS, egress: .tunnel,
            outcome: .notAttempted, originatingLifecycle: 7, originatingLatchEpoch: 3,
            pathEpoch: 4, resolverAddresses: [], attemptCount: 0)
        XCTAssertEqual(health.apply(backedOff, at: failedAt.addingTimeInterval(10)), .none)
        var expected = failed
        expected.notAttemptedCount += 1
        XCTAssertEqual(health.state(for: .tierOne), expected)

        var empty = ResolverTierHealth()
        _ = empty.apply(backedOff, at: failedAt)
        XCTAssertEqual(empty.state(for: .tierOne).lastOutcome, .notAttempted)
        XCTAssertEqual(empty.state(for: .tierOne).lastObservedAt, failedAt)
    }

    func testLateAnswerProvesAReplyWithoutClaimingDeliveredService() {
        let original = evidence(outcome: .served)
        let late = original.recordingClientDeadlineExpired()
        XCTAssertEqual(late.outcome, .answered)
        XCTAssertFalse(late.isResolverRejection)
        XCTAssertEqual(late.tier, original.tier)
        XCTAssertEqual(late.resolverKind, original.resolverKind)
        XCTAssertEqual(late.egress, original.egress)
        XCTAssertEqual(late.transport, original.transport)
        XCTAssertEqual(late.originatingLifecycle, original.originatingLifecycle)
        XCTAssertEqual(late.originatingLatchEpoch, original.originatingLatchEpoch)
        XCTAssertEqual(late.pathEpoch, original.pathEpoch)
        XCTAssertEqual(late.resolverAddresses, original.resolverAddresses)
        XCTAssertEqual(late.attemptCount, original.attemptCount)
        XCTAssertFalse(late.permitsDeviceDNSRecapture(in: recaptureContext()))
        var health = ResolverTierHealth()
        XCTAssertEqual(health.apply(late), .none)
        XCTAssertEqual(health.state(for: .tierOne).servedCount, 0)
        XCTAssertEqual(health.state(for: .tierOne).answeredCount, 1)
    }

    func testClientExpiryPreservesRealFailureAndExistingNonServingOutcomes() {
        for outcome in [ResolverTierEvidence.Outcome.failure, .answered, .notAttempted] {
            let value = evidence(outcome: outcome, rejection: outcome == .answered)
            XCTAssertEqual(value.recordingClientDeadlineExpired(), value)
        }
        let lateFailure = evidence().recordingClientDeadlineExpired()
        XCTAssertTrue(lateFailure.permitsDeviceDNSRecapture(in: recaptureContext()))
        var health = ResolverTierHealth()
        XCTAssertEqual(health.apply(lateFailure, observationSequence: 11), .none)
        XCTAssertTrue(health.deviceDNSConfirmationNeeded(for: .tierOne))
        XCTAssertEqual(health.state(for: .tierOne).failureCount, 1)
        XCTAssertEqual(health.state(for: .tierOne).servedCount, 0)
    }

    func testLocalAndEndedAttemptsStayNeutral() {
        for outcome in ResolverAttemptOutcome.allCases where !outcome.reachedTheWire {
            let value = classified([ResolverAttempt(address: "192.168.1.1", outcome: outcome, transport: .deviceDNS)])
            XCTAssertEqual(value.outcome, .notAttempted, outcome.rawValue)
            var health = ResolverTierHealth()
            XCTAssertEqual(health.apply(value), .none, outcome.rawValue)
        }
        let ended = classified([
            .init(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS, pathEpoch: 4),
            .init(address: "192.168.1.1", outcome: .refusedAfterLatchReplaced, transport: .deviceDNS)
        ])
        XCTAssertEqual(ended.outcome, .notAttempted)
    }

    func testPathEvidenceRequiresOneSendTimeEpochForEveryWireAttempt() {
        XCTAssertEqual(classified([
            .init(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS, pathEpoch: 4),
            .init(address: "192.168.1.2", outcome: .timeout, transport: .deviceDNS, pathEpoch: 4)
        ]).pathEpoch, 4)
        XCTAssertNil(classified([
            .init(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS, pathEpoch: 4),
            .init(address: "192.168.1.2", outcome: .timeout, transport: .deviceDNS)
        ]).pathEpoch)
        XCTAssertNil(classified([
            .init(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS, pathEpoch: 4),
            .init(address: "192.168.1.2", outcome: .timeout, transport: .deviceDNS, pathEpoch: 5)
        ]).pathEpoch)
    }

    func testActualDestinationEgressOverridesTheRungsRequestedInterface() {
        for route in [ResolverTierEvidence.Egress.physical, .tunnel] {
            let value = classified([
                .init(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS,
                    pathEpoch: 4, actualEgress: route, sendSequence: 10)
            ])
            XCTAssertEqual(value.egress, route)
            var health = ResolverTierHealth()
            XCTAssertEqual(health.apply(value, observationSequence: 11), .none)
            let independent = classified([
                .init(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS,
                    pathEpoch: 4, actualEgress: route, sendSequence: 12)
            ])
            XCTAssertEqual(health.apply(independent, observationSequence: 13), route == .physical ? .recaptureDeviceDNS : .none)
        }
        for last in [ResolverTierEvidence.Egress.tunnel, nil] {
            let mixed = classified([
                .init(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS,
                    pathEpoch: 4, actualEgress: .physical),
                .init(address: "192.168.1.2", outcome: .timeout, transport: .deviceDNS,
                    pathEpoch: 4, actualEgress: last)
            ])
            XCTAssertEqual(mixed.egress, .mixed)
            var health = ResolverTierHealth()
            XCTAssertEqual(health.apply(mixed), .none)
        }
    }

    func testAuthoritativeNegativeIsServedAndTruncationOnlyProvesAnAnswer() {
        for code: UInt8 in [0, 3] {
            let response = Data([0x12, 0x34, 0x81, 0x80 | code, 0, 0, 0, 0, 0, 0, 0, 0])
            XCTAssertEqual(classified([
                .init(address: "192.168.1.1", outcome: .success, transport: .deviceDNS, pathEpoch: 4)
            ], response: response).outcome, .served)
        }
        let truncated = classified([
            .init(address: "192.168.1.1", outcome: .truncatedAnswer, transport: .deviceDNS, pathEpoch: 4)
        ])
        XCTAssertEqual(truncated.outcome, .answered)
        XCTAssertFalse(truncated.isResolverRejection)
    }

    func testCurrentContextRequiresLifecycleLatchAndPathIdentity() {
        let value = evidence()
        XCTAssertTrue(value.isCurrent(lifecycle: 7, latchEpoch: 3, pathEpoch: 4))
        XCTAssertFalse(value.isCurrent(lifecycle: 8, latchEpoch: 3, pathEpoch: 4))
        XCTAssertFalse(value.isCurrent(lifecycle: 7, latchEpoch: 4, pathEpoch: 4))
        XCTAssertFalse(value.isCurrent(lifecycle: 7, latchEpoch: nil, pathEpoch: 4))
        XCTAssertFalse(value.isCurrent(lifecycle: 7, latchEpoch: 3, pathEpoch: 5))
    }

    func testDeviceMissingSendEpochNeverUsesFixedEndpointsLaunchEpoch() {
        let result = DNSResolutionResult(
            response: nil, successfulResolverAddress: nil,
            attempts: [.init(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS)],
            transport: .deviceDNS, udpTruncated: false,
            tcpFallbackAttempted: false, tcpFallbackSucceeded: false)
        for kind in [ResolverTierEvidence.ResolverKind.device, .fixed] {
            let value = ResolverTierEvidence(
                tier: .tierOne, resolverKind: kind, egress: .physical, result: result,
                originatingLifecycle: 7, originatingLatchEpoch: 3, observationPathEpoch: 9)
            XCTAssertEqual(value.pathEpoch, kind == .device ? nil : 9)
        }
    }

    func testRecaptureAdmissionRequiresCurrentPermittedDeviceFailure() {
        let value = evidence()
        let context = recaptureContext()
        XCTAssertTrue(value.permitsDeviceDNSRecapture(in: context))
        XCTAssertTrue(evidence(tier: .tierTwo).permitsDeviceDNSRecapture(in: context))
        for value in [
            evidence(tier: .tierZero), evidence(kind: .fixed), evidence(egress: .tunnel),
            evidence(egress: .mixed), evidence(outcome: .served),
            evidence(outcome: .answered, rejection: true), evidence(outcome: .notAttempted)
        ] {
            XCTAssertFalse(value.permitsDeviceDNSRecapture(in: context))
        }
        for context in [
            recaptureContext(lifecycle: 0), recaptureContext(lifecycle: 8),
            recaptureContext(latchEpoch: nil), recaptureContext(latchEpoch: 4),
            recaptureContext(pathEpoch: 5), recaptureContext(physicalPermitted: false),
            recaptureContext(pathSatisfied: false), recaptureContext(snapshotAvailable: false),
            recaptureContext(captured: []), recaptureContext(captured: ["192.168.1.2"]),
            recaptureContext(covered: ["192.168.1.1"])
        ] {
            XCTAssertFalse(value.permitsDeviceDNSRecapture(in: context))
        }
    }

    func testRecaptureAdmissionRequiresEveryActualEndpointToRemainCapturedAndPhysical() {
        for addresses in [[], ["192.168.1.1", "192.168.1.2"], ["2001:db8::1"]] {
            let value = ResolverTierEvidence(
                tier: .tierTwo, resolverKind: .device, transport: .deviceDNS, egress: .physical,
                outcome: .failure, originatingLifecycle: 7, originatingLatchEpoch: 3,
                pathEpoch: 4, resolverAddresses: addresses, attemptCount: addresses.count,
                failureReason: .timeout)
            let current = recaptureContext(captured: addresses)
            XCTAssertEqual(value.permitsDeviceDNSRecapture(in: current), !addresses.isEmpty)
            if let last = addresses.last {
                XCTAssertFalse(value.permitsDeviceDNSRecapture(in: recaptureContext(captured: addresses, covered: [last])))
                XCTAssertFalse(value.permitsDeviceDNSRecapture(in: recaptureContext(captured: Array(addresses.dropLast()))))
            }
        }
        let wrongTransport = ResolverTierEvidence(
            tier: .tierTwo, resolverKind: .device, transport: .plainDNS, egress: .physical,
            outcome: .failure, originatingLifecycle: 7, originatingLatchEpoch: 3,
            pathEpoch: 4, resolverAddresses: ["192.168.1.1"], attemptCount: 1)
        XCTAssertFalse(wrongTransport.permitsDeviceDNSRecapture(in: recaptureContext()))
    }

    private func recaptureContext(
        lifecycle: UInt64 = 7, latchEpoch: UInt64? = 3, pathEpoch: Int = 4,
        physicalPermitted: Bool = true, pathSatisfied: Bool = true,
        snapshotAvailable: Bool = true, captured: [String] = ["192.168.1.1"], covered: [String] = []
    ) -> ResolverTierEvidence.DeviceDNSRecaptureContext {
        .init(lifecycle: lifecycle, latchEpoch: latchEpoch, pathEpoch: pathEpoch,
            physicalRungPermitted: physicalPermitted, networkPathSatisfied: pathSatisfied,
            snapshotAvailable: snapshotAvailable, currentDeviceDNSAddresses: captured,
            profileCoveredAddresses: covered)
    }

    private func evidence(
        tier: DNSResolverTier = .tierOne,
        kind: ResolverTierEvidence.ResolverKind = .device,
        egress: ResolverTierEvidence.Egress = .physical,
        outcome: ResolverTierEvidence.Outcome = .failure,
        rejection: Bool = false, sendSequence: UInt64? = 10
    ) -> ResolverTierEvidence {
        ResolverTierEvidence(
            tier: tier, resolverKind: kind, transport: .deviceDNS, egress: egress,
            outcome: outcome, originatingLifecycle: 7, originatingLatchEpoch: 3,
            pathEpoch: 4, resolverAddresses: ["192.168.1.1"], attemptCount: 1,
            failureReason: outcome == .failure ? .timeout : nil,
            isResolverRejection: rejection, sendSequence: sendSequence)
    }

    private func classified(_ attempts: [ResolverAttempt], response: Data? = nil) -> ResolverTierEvidence {
        ResolverTierEvidence(
            tier: .tierOne, resolverKind: .device, egress: .physical,
            result: DNSResolutionResult(
                response: response, successfulResolverAddress: response == nil ? nil : "192.168.1.1",
                attempts: attempts, transport: .deviceDNS, udpTruncated: false,
                tcpFallbackAttempted: false, tcpFallbackSucceeded: false),
            originatingLifecycle: 7, originatingLatchEpoch: 3)
    }
}

private final class TierReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReplies: [ResolverTierEvidence] = []
    private var storedResult: DNSResolutionResult?
    private var storedReplyObservedBeforeFallback = false
    private var storedDeviceTiers: [DNSResolverTier] = []

    var replies: [ResolverTierEvidence] { lock.withLock { storedReplies } }
    var result: DNSResolutionResult? { lock.withLock { storedResult } }
    var replyObservedBeforeFallback: Bool { lock.withLock { storedReplyObservedBeforeFallback } }
    var deviceTiers: [DNSResolverTier] { lock.withLock { storedDeviceTiers } }

    func recordReply(_ value: ResolverTierEvidence) { lock.withLock { storedReplies.append(value) } }
    func recordResult(_ value: DNSResolutionResult) { lock.withLock { storedResult = value } }
    func recordFallbackStart() { lock.withLock { storedReplyObservedBeforeFallback = !storedReplies.isEmpty } }
    func recordDeviceTier(_ tier: DNSResolverTier) { lock.withLock { storedDeviceTiers.append(tier) } }
}
