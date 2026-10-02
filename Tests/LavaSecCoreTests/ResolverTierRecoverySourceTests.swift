import XCTest

final class ResolverTierRecoverySourceTests: XCTestCase {
    func testAllSelfReconnectAdmissionsUseAuthoritativeIntentAndOnlyFreshLaunchCredits() throws {
        let source = try readPacketTunnelProviderSource()
        let reconnect = try sourceBlock(in: source, startingAt: "// MARK: - Self-reconnect & guarded teardown",
                                        endingBefore: "// CON-1: INCIDENT-LEDGER IO")
        let intent = try sourceBlock(in: reconnect, startingAt: "private func selfReconnectProtectionIsWanted()",
                                     endingBefore: "static func isOnDemandConfirmedEnabled()")
        XCTAssertTrue(intent.containsTierPinsInOrder([
            "guard let container = LavaSecAppGroup.containerURL else { return false }",
            "ProtectionRestoreIntentStore.read(containerURL: container)",
            ".resolvedIntent(fallingBackTo: currentAppConfiguration().protectionEnabled)"
        ]))
        XCTAssertEqual(reconnect.components(separatedBy: "protectionEnabled: protectionIsWanted").count - 1, 4,
                       "Every initial and final typed/legacy policy admission must use resolved intent")
        XCTAssertFalse(reconnect.contains("protectionEnabled: currentAppConfiguration().protectionEnabled"))
        XCTAssertFalse(reconnect.contains("protectionEnabled: self.currentAppConfiguration().protectionEnabled"))
        XCTAssertTrue(reconnect.contains("\"protectionEnabled\": \"\\(protectionIsWanted)\""),
                      "Suppression logs must report the same resolved intent used for admission")
        let credit = try sourceBlock(in: source, startingAt: "func creditProductiveSelfReconnectIfPending(",
                                     endingBefore: "#if LAVA_QA_TOOLS")
        XCTAssertTrue(credit.containsTierPinsInOrder([
            "Self.loadLastSelfReconnectAt()", "guard health.startedAt > lastSelfReconnectAt",
            "Self.clearLastSelfReconnectAt()", "remaining.remove(at: creditedIndex)"
        ]))
    }

    func testTierEvidenceIsReducedBeforeAggregateHealthCanMaskIt() throws {
        let source = try readPacketTunnelProviderSource()
        let record = try sourceBlock(in: source, startingAt: "func recordUpstreamResult(",
                                     endingBefore: "// MARK: - Canonical tier evidence")
        XCTAssertTrue(record.containsTierPinsInOrder([
            "updateResolverBackoff(from: result.attempts)",
            "recordResolverTierEvidence(tierEvidence, at: now)",
            "ResolverHealthOrganicUpstreamCompletion(",
            "applyResolverHealthEvent(.organicUpstreamCompleted(completion))"
        ]))
        XCTAssertTrue(record.contains("clientDeadlineExpired"))
        XCTAssertTrue(record.contains("recordingClientDeadlineExpired()"))
        let dispatch = try sourceBlock(in: source, startingAt: "func recordResolverTierEvidence(",
                                       endingBefore: "func resolverTierEvidenceIsCurrent(")
        for action in ["case .upstreamSession:", "case .retryFixedEndpoint:", "case .recaptureDeviceDNS:"] {
            XCTAssertTrue(dispatch.contains(action), action)
        }
        XCTAssertTrue(dispatch.contains("guard resolverTierEvidenceIsCurrent(evidence)"))
        XCTAssertTrue(dispatch.contains("resolverTierHealth.apply(evidence, at: now, observationSequence: observationSequence)"))
        XCTAssertTrue(dispatch.containsTierPinsInOrder([
            "case .recaptureDeviceDNS:", "evaluateDeviceDNSTierRecapture(",
            "evidence: evidence, observationSequence: observationSequence, now: now)"
        ]))
        XCTAssertTrue(dispatch.containsTierPinsInOrder([
            "case .none:", "if evidence.outcome == .failure, evidence.resolverKind == .device",
            "resolverTierHealth.deviceDNSConfirmationNeeded(for: evidence.tier)",
            "scheduleDeviceDNSTierConfirmation(evidence: evidence, now: now)"
        ]))
        XCTAssertTrue(dispatch.contains("health.dnsTierHealth") == false,
                      "Dispatch must publish through the single tier projection seam")
    }

    func testRecaptureUsesTierEvidenceAndTheSharedBudget() throws {
        let source = try readPacketTunnelProviderSource()
        let admission = try sourceBlock(in: source, startingAt: "func deviceDNSTierRecaptureIsEligible(",
                                        endingBefore: "func scheduleResolverTierRecaptureRetry(")
        for pin in ["ResolverTierEvidence.DeviceDNSRecaptureContext(",
                    "tunnelLifecycleIsActive ? tunnelLifecycleGeneration : 0",
                    "!upstream.containsFullTunnel", "!protocolConfiguration.includeAllNetworks",
                    "latestMonitoredPathIsSatisfied", "currentResolverHealthSchedulingView().networkPathIsSatisfied",
                    "!isResidentFailClosedDueToUnavailableSnapshot()", "deviceDNSResolverAddresses",
                    "latchedChainedAllowedIPsCover($0)", "evidence.permitsDeviceDNSRecapture(in: context)"] {
            XCTAssertTrue(admission.contains(pin), pin)
        }
        let entry = try sourceBlock(in: source, startingAt: "func evaluateDeviceDNSTierRecapture(",
                                    endingBefore: "func deviceDNSTierRecaptureIsEligible(")
        XCTAssertTrue(entry.containsTierPinsInOrder([
            "let sendSequence = evidence.sendSequence", "resolverTierHealth.deviceDNSRecaptureIsConfirmed(",
            "observationSequence: observationSequence)", "deviceDNSTierRecaptureIsEligible(evidence)",
            "requirement: .deviceDNSRecapture"
        ]))
        XCTAssertTrue(entry.contains("requirement: .deviceDNSRecapture"))
        XCTAssertFalse(entry.contains("ProtectionConnectivityPolicy.assessment"))
        XCTAssertTrue(entry.contains("Self.isOnDemandConfirmedEnabled()"))
        XCTAssertTrue(entry.contains("Self.loadLastCommittedSelfReconnectAt(now: now)"))
        XCTAssertTrue(entry.contains("tierGrant: grant"))
    }

    func testConfirmationUsesTheExistingBoundedDeviceExecutor() throws {
        let source = try readPacketTunnelProviderSource()
        let confirmation = try sourceBlock(in: source, startingAt: "func scheduleDeviceDNSTierConfirmation(",
                                          endingBefore: "private func reconsiderDeviceDNSTierRecoveryAfterConfirmation(")
        XCTAssertTrue(confirmation.containsTierPinsInOrder([
            "resolverTierConfirmation == nil", "resolverTierHealth.deviceDNSConfirmationNeeded(for: evidence.tier)",
            "deviceDNSTierRecaptureIsEligible(evidence)", "selfReconnectProtectionIsWanted()",
            "refreshDeviceDNSResolverAddressesOnDNSQueue(reason: \"tier-device-dns-failure\")",
            "resolverTierHealth.setRecoveryStatus(.waiting, for: evidence.tier)",
            "runBoundedResolverWork(", "self.resolveDeviceDNS("
        ]))
        for pin in ["DNSResolutionLifetime(deadline: MonotonicDeadline(after: Self.resolverQueryLifetimeSeconds))",
                    "self.resolverTierConfirmation?.id == token", "self.resolverTierContextIdentity == context",
                    "self.currentResolverTierContextIdentity() == context",
                    "self.resolverRuntimeGeneration == generation",
                    "self.resolverTierHealth.deviceDNSConfirmationNeeded(for: evidence.tier)",
                    "self.deviceDNSTierRecaptureIsEligible(evidence)", "self.selfReconnectProtectionIsWanted()",
                    "deviceDNSResolverAddresses.filter { !latchedChainedAllowedIPsCover($0) }",
                    "egressInterface: .physical", "lifetime: lifetime, tier: evidence.tier",
                    "replyContextIdentity: context, replyRuntimeGeneration: generation, livenessOnly: true",
                    "defer { finish() }", ".recordingClientDeadlineExpired()"] {
            XCTAssertTrue(confirmation.contains(pin), pin)
        }
        XCTAssertTrue(confirmation.containsTierPinsInOrder([
            "self.recordResolverTierReply(", "rawObservation, contextIdentity: context, runtimeGeneration: generation)",
            "self.dnsStateQueue.async",
            "self.resolverTierEvidenceIsCurrent(observation)", "self.recordResolverTierEvidence([observation], at: Date())"
        ]))
        XCTAssertTrue(confirmation.contains("decision: \"checking\", sequence: sequence"))
        XCTAssertTrue(confirmation.contains("decision: \"completed\", sequence: sequence"),
                      "Checking and completion must retain the same privacy-safe incident sequence")
        XCTAssertTrue(source.contains("private func resolveUpstream("))
        XCTAssertTrue(source.contains("orchestrator.resolveUpstream("))
        XCTAssertFalse(confirmation.contains("resolveUpstream("),
                       "Confirmation must exercise this Device tier without a working higher tier short-circuiting it")
        XCTAssertFalse(confirmation.contains("creditProductiveSelfReconnectIfPending"),
                       "A confirmation canary must not credit delivered client service")
        let reset = try sourceBlock(in: source, startingAt: "func resetResolverTierEvidence()",
                                    endingBefore: "func currentResolverTierContextIdentity()")
        XCTAssertFalse(reset.contains("resolverTierConfirmation = nil"),
                       "A context reset must not release a slot whose bounded worker is still alive")
    }

    func testCooldownWakeRequestsFreshConfirmation() throws {
        let source = try readPacketTunnelProviderSource()
        let retry = try sourceBlock(in: source, startingAt: "func scheduleResolverTierRecaptureRetry(",
                                    endingBefore: "func promptDeviceDNSRecaptureRestartIfPolicyAllows(")
        XCTAssertTrue(retry.containsTierPinsInOrder([
            "self.currentResolverTierContextIdentity() == context",
            "self.resolverTierHealth.invalidateDeviceDNSConfirmation(",
            "observationSequence: self.nextResolverTierObservationSequence()",
            "self.scheduleDeviceDNSTierConfirmation(evidence: evidence, now: Date())"
        ]))
        XCTAssertFalse(retry.contains("evaluateDeviceDNSTierRecapture("),
                       "Elapsed cooldown time cannot replay a previously confirmed failure")
    }

    func testLegacyDeviceRecoveryUsesTheSameConfirmation() throws {
        let source = try readPacketTunnelProviderSource()
        let legacy = try sourceBlock(in: source, startingAt: "func selfReconnectIfPolicyAllows(",
                                     endingBefore: "// MARK: - Device DNS tier repair")
        XCTAssertTrue(legacy.containsTierPinsInOrder([
            "if hasConfiguredDeviceDNSTier", "reconsiderDeviceDNSTierRecovery(now: now)",
            "let rawAttempts = Self.loadSelfReconnectAttemptTimes()", "TunnelSelfReconnectPolicy.decision("
        ]))
        let captureExhaustion = try sourceBlock(in: source, startingAt: "func promptDeviceDNSRecaptureRestartIfPolicyAllows(",
                                                endingBefore: "private var hasConfiguredDeviceDNSTier:")
        XCTAssertTrue(captureExhaustion.contains("reconsiderDeviceDNSTierRecovery(now: now)"))
        XCTAssertFalse(captureExhaustion.contains("TunnelSelfReconnectPolicy.decision("))
        XCTAssertFalse(source.contains("deviceDNSRecaptureRestartPending"))
    }

    func testRawDeviceReplyRetiresSilenceBeforeMergedCompletion() throws {
        let source = try readPacketTunnelProviderSource()
        let reply = try sourceBlock(in: source, startingAt: "func recordResolverTierReply(",
                                    endingBefore: "func recordResolverTierEvidence(")
        for pin in ["self.resolverTierEvidenceIsCurrent(evidence)", "evidence.resolverKind == .device",
                    "evidence.outcome == .served || evidence.outcome == .answered",
                    "self.resolverTierHealth.observeDeviceDNSReply(for: evidence.tier, observationSequence: sequence)",
                    "evidence.recordingReply(observationSequence: sequence)"] {
            XCTAssertTrue(reply.contains(pin), pin)
        }
        XCTAssertTrue(reply.containsTierPinsInOrder([
            "lifetime?.runtimeIsCurrent ?? true",
            "contextIdentity.map({ self.currentResolverTierContextIdentity() == $0 }) ?? true",
            "runtimeGeneration.map({ self.resolverRuntimeGeneration == $0 }) ?? true",
            "selections[selectionIndex].isEnabled",
            "selections[selectionIndex].resolver?.transport == .deviceDNS",
            "evidence.resolverAddresses.allSatisfy({ self.deviceDNSResolverAddresses.contains($0) })",
            "self.resolverTierHealth.observeDeviceDNSReply(for: evidence.tier, observationSequence: sequence)"
        ]))
        XCTAssertTrue(reply.contains("let sequence = evidence.replySequence ?? self.nextResolverTierObservationSequence()"),
                      "Whole-leg delivery must preserve the immediate transport reply order")
        XCTAssertFalse(reply.contains("resolverTierConfirmation = nil"),
                       "A reply retires this tier's grant without releasing a still-running confirmation worker")
        let executor = try sourceBlock(in: source, startingAt: "func makeResolverExecutors(",
                                       endingBefore: "func resolveDeviceDNS(")
        XCTAssertTrue(executor.containsTierPinsInOrder([
            "observeTierReply:", "self?.recordResolverTierReply(evidence, lifetime: lifetime) ?? evidence"
        ]))
    }

    func testDeviceRepliesAreObservedBeforeTCPRetry() throws {
        let source = try readPacketTunnelProviderSource()
        let device = try sourceBlock(in: source, startingAt: "func resolveDeviceDNS(",
                                     endingBefore: "func resolvePlainDNS(")
        XCTAssertTrue(device.containsTierPinsInOrder([
            "let readOrigin:", "let origin =", "let observeReply:", "guard let self,",
            "reply.outcome == .success || reply.outcome == .truncatedAnswer || reply.outcome == .mismatchedResponse",
            "attempts: [attempt]", "tier: tier, resolverKind: .device", "self.recordResolverTierReply(",
            "contextIdentity: origin.context", "runtimeGeneration: origin.generation).replySequence",
            "replyObserver: observeReply", "livenessOnly: livenessOnly"
        ]))
        XCTAssertFalse(device.contains("reply.outcome == .unexpectedSourceResponse"),
                       "An off-source datagram must not retire resolver silence")
        let executor = try sourceBlock(in: source, startingAt: "func makeResolverExecutors(",
                                       endingBefore: "func resolveDeviceDNS(")
        XCTAssertTrue(executor.contains("resolveDevice: { [weak self] query, addresses, admittedAtEpoch, admittedAtLatchEpoch, egressInterface, tier in"))
        XCTAssertTrue(executor.contains("egressInterface: egressInterface, lifetime: lifetime, tier: tier)"))
        let plain = try sourceBlock(in: source, startingAt: "func resolvePlainDNS(", endingBefore: "func resolveUDP(")
        XCTAssertTrue(plain.containsTierPinsInOrder([
            "let udpResult = resolveUDP(", "let udpAttempt = ResolverAttempt(",
            "let observedUDPAttempt = udpAttempt.recordingReply(",
            "observationSequence: replyObserver?(udpResult, udpAttempt)", "attempts.append(observedUDPAttempt)",
            "if livenessOnly, observedUDPAttempt.replySequence != nil", "return DNSResolutionResult(",
            "guard let udpResponse = udpResult.response else", "shouldAttemptTCPFallback(afterUDPOutcome:",
            "let tcpResult = resolveOverTCP(", "tcpAttempt.recordingReply(",
            "observationSequence: replyObserver?(tcpResult, tcpAttempt)", "if let tcpResponse = tcpResult.response"
        ]))
        XCTAssertEqual(plain.components(separatedBy: "observationSequence: replyObserver?(tcpResult, tcpAttempt)").count - 1, 2,
                       "Both timeout and truncation TCP branches must carry immediate reply evidence")
        XCTAssertEqual(plain.components(separatedBy: "if livenessOnly, attempts.last?.replySequence != nil, tcpResult.response == nil").count - 1, 2)
    }

    func testDeviceRepliesCanRetireAnAlreadyConfirmedGrant() throws {
        let source = try readPacketTunnelProviderSource()
        let device = try sourceBlock(in: source, startingAt: "func resolveDeviceDNS(",
                                     endingBefore: "func resolvePlainDNS(")
        XCTAssertTrue(device.contains("tier: DNSResolverTier,"))
        XCTAssertFalse(device.contains("tier: DNSResolverTier?"),
                       "Every Device attempt must identify the configured tier whose grant a reply can retire")
        let observer = try sourceBlock(in: device, startingAt: "let observeReply:",
                                       endingBefore: "return resolvePlainDNS(")
        XCTAssertTrue(observer.containsTierPinsInOrder([
            "originatingLifecycle: admittedAtEpoch, originatingLatchEpoch: admittedAtLatchEpoch",
            "self.recordResolverTierReply(", "evidence, contextIdentity: origin.context",
            "runtimeGeneration: origin.generation).replySequence"
        ]))
        for mutableAdmission in ["lifetime:", ".isAdmitted", ".runtimeIsCurrent",
                                 "deviceDNSConfirmationNeeded", "deviceDNSRecaptureIsConfirmed"] {
            XCTAssertFalse(observer.contains(mutableAdmission),
                           "A received reply must not depend on future-send admission: \(mutableAdmission)")
        }
        let reply = try sourceBlock(in: source, startingAt: "func recordResolverTierReply(",
                                    endingBefore: "func recordResolverTierEvidence(")
        XCTAssertTrue(reply.containsTierPinsInOrder([
            "self.tunnelLifecycleIsActive", "self.resolverTierEvidenceIsCurrent(evidence)",
            "contextIdentity.map({ self.currentResolverTierContextIdentity() == $0 }) ?? true",
            "runtimeGeneration.map({ self.resolverRuntimeGeneration == $0 }) ?? true",
            "evidence.resolverAddresses.allSatisfy({ self.deviceDNSResolverAddresses.contains($0) })",
            "self.resolverTierHealth.observeDeviceDNSReply(for: evidence.tier, observationSequence: sequence)"
        ]))
        let confirmation = try sourceBlock(in: source, startingAt: "func scheduleDeviceDNSTierConfirmation(",
                                          endingBefore: "private func reconsiderDeviceDNSTierRecoveryAfterConfirmation(")
        XCTAssertTrue(confirmation.containsTierPinsInOrder([
            "let lifetime = DNSResolutionLifetime(", "self.resolverTierHealth.deviceDNSConfirmationNeeded(for: evidence.tier)",
            "guard lifetime.isAdmitted else", "self.resolveDeviceDNS(", "lifetime: lifetime, tier: evidence.tier"
        ]))
    }

    func testFinalTeardownRevalidatesTheTierAndKeepsDurableCooldown() throws {
        let source = try readPacketTunnelProviderSource()
        let teardown = try sourceBlock(in: source, startingAt: "private func performGuardedSelfReconnectTeardown(",
                                       endingBefore: "static func isOnDemandConfirmedEnabled()")
        for pin in ["self.tunnelLifecycleIsActive", "self.currentResolverTierContextIdentity() == tierGrant.contextIdentity",
                    "self.resolverRuntimeGeneration == tierGrant.runtimeGeneration",
                    "self.latestResolverTierEvidence[tierGrant.evidence.tier]?.outcome == .failure",
                    "let sendSequence = tierGrant.evidence.sendSequence",
                    "self.resolverTierHealth.deviceDNSRecaptureIsConfirmed(",
                    "observationSequence: tierGrant.observationSequence)",
                    "self.deviceDNSTierRecaptureIsEligible(tierGrant.evidence)",
                    "Self.loadSelfReconnectAttemptTimes()", "Self.isOnDemandConfirmedEnabled()"] {
            XCTAssertTrue(teardown.contains(pin), pin)
        }
        XCTAssertTrue(teardown.containsTierPinsInOrder([
            "Self.saveSelfReconnectAttemptTimes(updatedAttempts)",
            "tunnel.lastCommittedSelfReconnectAt", "Self.saveLastSelfReconnectAt(revalidatedNow)",
            "tunnel.selfReconnectRequiresDeviceDNSCredit", "self.cancelTunnelWithError(nil)"
        ]))
        XCTAssertTrue(teardown.contains("reason == .deviceDNSRecapture, forKey: \"tunnel.selfReconnectRequiresDeviceDNSCredit\""),
                      "Every Device recapture restart, including legacy admission, requires Device service credit")
        let credit = try sourceBlock(in: source, startingAt: "func creditProductiveSelfReconnectIfPending(",
                                     endingBefore: "#if LAVA_QA_TOOLS")
        XCTAssertTrue(credit.containsTierPinsInOrder([
            "tunnel.selfReconnectRequiresDeviceDNSCredit", "!recoveredDeviceDNS", "Self.clearLastSelfReconnectAt()"
        ]))
        XCTAssertFalse(credit.contains("tunnel.lastCommittedSelfReconnectAt"),
                       "Recovery credit must preserve the cooldown marker")
    }

    func testTypedRepairStatusIsPersistedBeforeTheAppSignalAndSavedOriginReloads() throws {
        let source = try readPacketTunnelProviderSource()
        let projection = try sourceBlock(in: source, startingAt: "func projectResolverTierHealth()",
                                         endingBefore: "private func resolverTierRepairSignalKey()")
        XCTAssertTrue(projection.containsTierPinsInOrder([
            "markHealthCountersUpdated()", "persistHealthIfNeeded(force: true)",
            "signalAppIfConnectivityStateChanged()"
        ]))
        XCTAssertTrue(projection.contains("previousRepairKey != resolverTierRepairSignalKey()"))
        let identity = try sourceBlock(in: source, startingAt: "static func resolverNetworkIdentity(",
                                      endingBefore: "func recordUpstreamResult(")
        XCTAssertTrue(identity.contains("configuration.configuredPrimaryDNSResolverTier.rawValue"))
    }

    func testPathAndLifecycleReplaceTheTierContextAndFenceEveryPlainSend() throws {
        let source = try readPacketTunnelProviderSource()
        XCTAssertTrue(source.contains("currentPathEpoch: { [weak self] in\n            self?.currentResolverTierPathEpoch()"))
        XCTAssertTrue(source.contains("resolverBackoffPathEpoch += 1\n                resetResolverTierEvidence()"))
        let delivery = try sourceBlock(in: source, startingAt: "monitor.pathUpdateHandler =",
                                      endingBefore: "monitor.start(queue:")
        XCTAssertTrue(delivery.containsTierPinsInOrder([
            "self.resolverBackoffPathEpoch += 1", "self.resetResolverTierEvidence()",
            "self.latestMonitoredPathIsSatisfied = update.isSatisfied", "self.handleNetworkPathUpdate(update)"
        ]))
        XCTAssertTrue(source.contains("self.tunnelLifecycleIsActive = false\n            self.resetResolverTierEvidence()"))
        XCTAssertTrue(source.contains("self.tunnelLifecycleIsActive = true\n            self.resetResolverTierEvidence()"))
        let plain = try sourceBlock(in: source, startingAt: "func resolvePlainDNS(", endingBefore: "func resolveUDP(")
        XCTAssertTrue(plain.containsTierPinsInOrder(["let udpPathEpoch = currentResolverTierPathEpoch()",
                                            "let udpResult = resolveUDP(", "pathEpoch: udpPathEpoch, actualEgress: actualEgress"]))
        XCTAssertEqual(plain.components(separatedBy: "let tcpPathEpoch = currentResolverTierPathEpoch()").count - 1, 2)
        XCTAssertEqual(plain.components(separatedBy: "pathEpoch: tcpPathEpoch").count - 1, 2)
        XCTAssertTrue(plain.contains("latchedChainedAllowedIPsCover(address) ? .tunnel : .physical"))
        XCTAssertTrue(plain.contains("let udpSendSequence = transport == .deviceDNS ? nextResolverTierObservationSequence() : nil"))
        XCTAssertTrue(plain.contains("sendSequence: udpSendSequence"))
        XCTAssertEqual(plain.components(separatedBy: "let tcpSendSequence = transport == .deviceDNS ? nextResolverTierObservationSequence() : nil").count - 1, 2)
        XCTAssertEqual(plain.components(separatedBy: "sendSequence: tcpSendSequence").count - 1, 2)
    }
}

private extension String {
    func containsTierPinsInOrder(_ pins: [String]) -> Bool {
        var cursor = startIndex
        for pin in pins {
            guard let range = range(of: pin, range: cursor..<endIndex) else { return false }
            cursor = range.upperBound
        }
        return true
    }
}
