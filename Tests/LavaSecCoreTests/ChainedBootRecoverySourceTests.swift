import XCTest

final class ChainedBootRecoverySourceTests: XCTestCase {
    func testSuccessfulStartupArmsUnlockRecoveryAndTeardownCancelsIt() throws {
        let source = try readSource(.packetTunnelProviderLifecycle)
        XCTAssertTrue(source.contains("let startedWithProtectedDataUnavailable = !sharedProtectedContentIsReadable()"))
        let completion = try XCTUnwrap(source.range(of: "completion(nil)"))
        let recovery = try XCTUnwrap(source.range(of: "self.startChainedBootRecoveryIfNeeded("))
        XCTAssertLessThan(completion.lowerBound, recovery.lowerBound,
                          "First-unlock recovery must not cancel an unfinished startTunnel.")
        let invalidate = try sourceBlock(in: source,
            startingAt: "private func invalidateTunnelLifecycle(reason: String)",
            endingBefore: "/// Whether a tunnel session")
        XCTAssertTrue(invalidate.contains("cancelChainedBootRecovery()"))
    }

    func testRecoveryReadsOffQueueAndRevalidatesUnderTheUserMutationFence() throws {
        let source = try readSource(.packetTunnelProviderBootRecovery)
        XCTAssertTrue(source.contains("DispatchQueue.global(qos: .utility).async"))
        XCTAssertTrue(source.contains("chainedBootRecoveryReadSlot.admit(token)"))
        let invalidate = try sourceBlock(in: source, startingAt: "func cancelChainedBootRecovery()",
                                        endingBefore: "private func chainedBootRecoveryContext()")
        XCTAssertFalse(invalidate.contains("chainedBootRecoveryReadSlot.complete("))
        let read = try XCTUnwrap(source.range(of: "let readiness = self.chainedBootUpstreamReadiness"))
        let fence = try XCTUnwrap(source.range(of: "ProtectionLifecycleMutationFence.acquire("))
        XCTAssertLessThan(read.lowerBound, fence.lowerBound)
        let marker = try XCTUnwrap(source.range(of: "let marker = try? ChainedStartupFailureMarker.state("))
        XCTAssertLessThan(fence.lowerBound, marker.lowerBound)
        let readinessBody = try sourceBlock(in: source,
            startingAt: "private func chainedBootUpstreamReadiness(",
            endingBefore: "private func logChainedBootRecovery")
        XCTAssertTrue(readinessBody.containsInOrder(["evaluateChainedUpstreamReadiness()", "store.read()"] ))
        XCTAssertTrue(source.contains("wait: false"))
        XCTAssertTrue(source.contains("defer { fence?.release() }"))
        XCTAssertTrue(source.contains("chainedBootRecoveryReadSlot.complete(token)"))
        XCTAssertTrue(source.contains("completeReadinessCheck(context, token: token,"))
        XCTAssertTrue(source.contains("configurationStillMatches && durableRefusalMatches == true"))
        XCTAssertTrue(source.contains("ProtectionRestoreIntentStore.read(containerURL: container)"))
        XCTAssertTrue(source.contains("configuration?.hasLavaSecurityPlus == true"))
        XCTAssertTrue(source.contains("!snapshot.isSurrenderSuppressed"))
        XCTAssertFalse(source.contains("prepareForExplicitGuardStart()"))
        XCTAssertFalse(source.contains("recordChainedSurrender"))
        XCTAssertTrue(source.contains("guard !self.protocolConfiguration.includeAllNetworks"))
        XCTAssertTrue(source.contains("self.chainedBootRecoveryArmedGeneration != generation"))
        XCTAssertFalse(invalidate.contains("chainedBootRecoveryArmedGeneration = nil"))
    }
    func testDeliveredCombinedPathWakesDormantRecovery() throws {
        let path = try readSource(.packetTunnelProviderNetworkPath)
        XCTAssertTrue(path.containsInOrder([
            "chainedBootRecoveryPathGate = ChainedBootRecoveryPathGate(generation: lifecycleGeneration)",
            "monitor.pathUpdateHandler =", "isCurrentTunnelLifecycle(lifecycleGeneration)",
            "chainedBootRecoveryPathGate.observePhysical(generation: lifecycleGeneration,",
            "chainedBootRecoveryPathDidChange()", "self.dnsStateQueue.async",
            "isCurrentTunnelLifecycle(lifecycleGeneration)", "self.handleNetworkPathUpdate(update)",
            "chainedBootRecoveryPathGate.observeHealth(generation: lifecycleGeneration,",
            "currentResolverHealthSchedulingView().networkPathIsSatisfied",
            "chainedBootRecoveryPathDidChange()"
        ]))
        let recovery = try readSource(.packetTunnelProviderBootRecovery)
        XCTAssertTrue(recovery.contains("networkIsSatisfied: chainedBootRecoveryPathGate.isSatisfied"))
        XCTAssertTrue(recovery.contains("networkTransitionSerial: chainedBootRecoveryPathGate.satisfiedTransitionSerial"))
        let timer = try sourceBlock(in: recovery, startingAt: "private func updateChainedBootRecoveryTimer()",
                                   endingBefore: "/// Both path-owner turns")
        XCTAssertTrue(timer.containsInOrder(["pollingIsNeeded == true", "stopChainedBootRecoveryTimer()", "return"]))
        XCTAssertTrue(recovery.containsInOrder(["chainedBootRecoveryReadSlot.complete(token)",
            "completeReadinessCheck(context, token: token,", "self.pollChainedBootRecovery()"] ))
    }

    func testConfigurationInvalidationUsesExistingOwners() throws {
        let configuration = try readSource(.packetTunnelProviderConfiguration)
        let adoption = try sourceBlock(in: configuration,
            startingAt: "private func adoptAppConfiguration(_ configuration: AppConfiguration)",
            endingBefore: "static func tunnelNetworkKind" )
        XCTAssertTrue(adoption.contains("revalidateChainedBootRecoveryIfNeeded()"))
        let poll = try readSource(.packetTunnelProviderFocusConfigPoll)
        XCTAssertTrue(poll.contains("revalidateChainedBootRecoveryIfNeeded()"))
    }

}

private extension String {
    func containsInOrder(_ needles: [String]) -> Bool {
        var cursor = startIndex
        for needle in needles {
            guard let found = range(of: needle, range: cursor..<endIndex) else { return false }
            cursor = found.upperBound
        }
        return true
    }
}
