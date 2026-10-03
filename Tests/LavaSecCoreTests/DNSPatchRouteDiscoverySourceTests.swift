import XCTest

final class DNSPatchRouteDiscoverySourceTests: XCTestCase {
    func testInitialSettingsCallbackRejectsStaleErrorsBeforeRuntimeCleanup() throws {
        let source = try readSource(.packetTunnelProviderLifecycle)
        let initialCallback = try sourceBlock(in: source,
            startingAt: "setTunnelNetworkSettings(settingsBundle.settings) { [weak self] error in",
            endingBefore: "let duration = Date().timeIntervalSince(settingsStartedAt)")
        XCTAssertTrue(sourceContainsInOrder([
            "guard self.isCurrentTunnelLifecycle(lifecycleGeneration) else",
            "if let error",
            "self.cleanUpTunnelRuntimeAfterFailedStart(reason: \"setTunnelNetworkSettings-error\")",
        ], in: initialCallback), "An old initial-settings error must complete cancelled without invalidating a newer provider lifecycle.")
    }

    func testOrdinarySettingsReapplyCannotBypassTheStartupInstallDrain() throws {
        let source = try readSource(.packetTunnelProviderNetworkPath)
        let reapply = try sourceBlock(in: source, startingAt: "func reapplyTunnelNetworkSettings(",
            endingBefore: "private func recordNetworkSettingsReapplyFailure(")
        XCTAssertTrue(sourceContainsInOrder([
            "guard tunnelLifecycleIsActive else",
            "dnsPatchStartupInstallPolicy?.requestSettingsReapply(",
            "action != .reapply",
            "return",
            "lastNetworkSettingsReapplyUptime = now",
            "chainedClaimedResolverDestinations?.update(",
            "let settingsBundle = makeTunnelNetworkSettingsForLatchedDataPath()",
            "setTunnelNetworkSettings(settingsBundle.settings)",
        ], in: reapply), "A path/configuration/filter nudge must join the startup drain before changing its classifier or posting competing settings.")
    }

    func testInitialSettingsWaitForPhysicalDiscoveryBeforeCapturingRoutes() throws {
        let source = try readSource(.packetTunnelProviderLifecycle)
        let start = try sourceBlock(in: source, startingAt: "override func startTunnel(",
            endingBefore: "override func stopTunnel(")
        XCTAssertTrue(sourceContainsInOrder([
            "startDNSPatchDiscovery(lifecycleGeneration:",
            "startPathMonitor(lifecycleGeneration:",
            "prepareDNSPatchInitialSettings(lifecycleGeneration:",
            "if let discoveryError",
            "let makeInitialSettings:",
            "let settingsBundle = self.makeTunnelNetworkSettingsForLatchedDataPath()",
            "self.dnsPatchStartupInstallPolicy?.beginInitialInstall(",
            "setTunnelNetworkSettings(settingsBundle.settings)",
        ], in: start), "Both actual physical endpoints must settle before the first settings bundle is captured and posted.")
        let discovery = try readSource(.dnsPatchRouteDiscovery)
        XCTAssertTrue(discovery.contains("parameters.requiredInterface = interface"))
        XCTAssertFalse(discovery.contains(".send("), "Discovery must stay independent of installed tunnel routes and packet traffic.")
    }

    func testInitialPreparationWaitUsesTheOwnedCompletionAndRevalidatesLifecycle() throws {
        let source = try readSource(.packetTunnelProviderLifecycle)
        let prepare = try sourceBlock(in: source, startingAt: "private func prepareDNSPatchInitialSettings(",
            endingBefore: "private func finishDNSPatchStartupSettings(")
        XCTAssertTrue(prepare.contains("self.tunnelLifecycleIsActive"))
        XCTAssertTrue(prepare.contains("self.isCurrentTunnelLifecycle(lifecycleGeneration)"))
        XCTAssertTrue(prepare.contains("initialSettingsAction("))
        XCTAssertTrue(prepare.contains("self.dnsPatchStartupInstallCompletion = completion"))
        XCTAssertTrue(prepare.contains("DispatchQueue.global(qos: .utility).async { completion(failure) }"))
        XCTAssertTrue(prepare.contains("DispatchQueue.global(qos: .utility).async { completion(nil) }"))
        let settle = try sourceBlock(in: source, startingAt: "private func completeDNSPatchInitialDiscovery(",
            endingBefore: "private func cancelDNSPatchStartupInstallCompletion()")
        XCTAssertTrue(sourceContainsInOrder([
            "guard let completion = self.dnsPatchStartupInstallCompletion",
            "self.dnsPatchStartupInstallCompletion = nil",
            "self.prepareDNSPatchInitialSettings(",
        ], in: settle), "Settlement consumes the same cancellable completion before resuming initial preparation.")
        let initial = try sourceBlock(in: source, startingAt: "let makeInitialSettings:",
            endingBefore: "guard let settingsBundle = DispatchQueue.getSpecific(")
        XCTAssertTrue(initial.contains("self.tunnelLifecycleIsActive"))
        XCTAssertTrue(initial.contains("self.isCurrentTunnelLifecycle(lifecycleGeneration)"))
        XCTAssertTrue(initial.contains("beginInitialInstall(lifecycleGeneration: lifecycleGeneration) == true else { return nil }"),
            "A stop or superseded policy between discovery and capture cannot admit the first settings post.")
    }

    func testDiscoveryStartsBeforeTheAtomicInitialSettingsCapture() throws {
        let source = try readSource(.packetTunnelProviderLifecycle)
        let start = try sourceBlock(in: source, startingAt: "override func startTunnel(",
            endingBefore: "override func stopTunnel(")
        XCTAssertEqual(start.components(separatedBy: "startDNSPatchDiscovery(lifecycleGeneration:").count - 1, 1)
        let discovery = try XCTUnwrap(start.range(of: "startDNSPatchDiscovery(lifecycleGeneration:"))
        let capture = try XCTUnwrap(start.range(of: "let makeInitialSettings:"))
        XCTAssertLessThan(discovery.lowerBound, capture.lowerBound,
            "Translated destinations must be discovered during initial installation, not only after startup readiness.")
        let settings = try XCTUnwrap(start.range(of: "let settingsBundle = self.makeTunnelNetworkSettingsForLatchedDataPath()"))
        let baseline = try XCTUnwrap(start.range(of: "self.dnsPatchStartupInstallPolicy?.beginInitialInstall("))
        let sync = try XCTUnwrap(start.range(of: "dnsStateQueue.sync(execute: makeInitialSettings)"))
        XCTAssertLessThan(settings.lowerBound, baseline.lowerBound)
        XCTAssertLessThan(baseline.lowerBound, sync.lowerBound,
            "The initial route bundle and policy baseline must be captured in the same queue-owned operation.")
        let discoveryStart = try sourceBlock(in: source, startingAt: "func startDNSPatchDiscovery(",
            endingBefore: "private func finishDNSPatchStartupSettings(")
        XCTAssertTrue(sourceContainsInOrder([
            "DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true",
            "start()",
            "dnsStateQueue.async(execute: start)",
        ], in: discoveryStart), "An on-queue start must initialize discovery before capturing its initial install baseline.")
    }

    func testDiscoveryPreservesObservationsButPostsOnlyForChangedCaptureDestinations() throws {
        let source = try readSource(.packetTunnelProviderLifecycle)
        let discovery = try sourceBlock(in: source, startingAt: "func startDNSPatchDiscovery(",
            endingBefore: "/// A recoverable outage under a strict profile")
        XCTAssertTrue(discovery.contains("self.isCurrentTunnelLifecycle(lifecycleGeneration)"))
        let comparison = try XCTUnwrap(discovery.range(of: "self.dnsPatchStartupInstallPolicy?.observeEndpoints("))
        let state = try XCTUnwrap(discovery.range(of: "self.dnsPatchObservedEndpoints = addresses"))
        let log = try XCTUnwrap(discovery.range(of: "event: \"dns-patch-route-observation\""))
        let gate = try XCTUnwrap(discovery.range(of: "guard action == .reapply else { return }"))
        let post = try XCTUnwrap(discovery.range(of: "self.reapplyTunnelNetworkSettings("))
        XCTAssertLessThan(comparison.lowerBound, state.lowerBound)
        XCTAssertLessThan(state.lowerBound, gate.lowerBound)
        XCTAssertLessThan(log.lowerBound, gate.lowerBound)
        XCTAssertLessThan(gate.lowerBound, post.lowerBound)
        XCTAssertTrue(discovery.contains("enforceThrottle: false"),
            "A real NAT64 route change must still post without being dropped by the network-flap throttle.")
        XCTAssertTrue(source.contains("self.dnsPatchDiscovery?.cancel()"))
        XCTAssertTrue(source.contains("self.dnsPatchDiscovery = nil"))
    }

    func testStartupDrainsKnownRoutesBeforeReadinessAndCancelsOnInvalidation() throws {
        let source = try readSource(.packetTunnelProviderLifecycle)
        let start = try sourceBlock(in: source, startingAt: "override func startTunnel(",
            endingBefore: "override func stopTunnel(")
        let drain = try XCTUnwrap(start.range(of: "self.finishDNSPatchStartupSettings("))
        let ready = try XCTUnwrap(start.range(of: "self.tunnelStartupDidComplete = true"))
        let completion = try XCTUnwrap(start.range(of: "completion(nil)"))
        XCTAssertLessThan(drain.lowerBound, ready.lowerBound)
        XCTAssertLessThan(ready.lowerBound, completion.lowerBound)
        let finish = try sourceBlock(in: source, startingAt: "private func finishDNSPatchStartupSettings(",
            endingBefore: "/// A recoverable outage under a strict profile")
        XCTAssertTrue(finish.contains("self.tunnelLifecycleIsActive"))
        XCTAssertTrue(finish.contains("self.isCurrentTunnelLifecycle(lifecycleGeneration)"))
        XCTAssertTrue(finish.contains("settingsInstallDidComplete("))
        XCTAssertTrue(finish.contains("case .installLatest:"))
        XCTAssertTrue(finish.contains("self.setTunnelNetworkSettings(settingsBundle.settings)"))
        XCTAssertTrue(finish.contains("self.finishDNSPatchStartupSettings("))
        XCTAssertTrue(finish.contains("case .ready: completion(nil)"),
            "Readiness must linearize on the policy queue, with no delivery hop before startup completion.")
        let invalidate = try sourceBlock(in: source, startingAt: "private func invalidateTunnelLifecycle(",
            endingBefore: "/// Whether a tunnel session")
        XCTAssertTrue(invalidate.contains("self.dnsPatchStartupInstallPolicy?.cancel()"))
        XCTAssertTrue(source.contains("self.dnsPatchStartupInstallPolicy = nil"))
        let cancel = try XCTUnwrap(finish.range(of: "self.dnsPatchStartupInstallPolicy?.cancel()"))
        let errorDelivery = try XCTUnwrap(finish.range(of: "DispatchQueue.global(qos: .utility).async { completion(error) }"))
        XCTAssertLessThan(cancel.lowerBound, errorDelivery.lowerBound,
            "A failed install must discard pending route work before startup failure is delivered.")
    }

    func testStartupSettingsKeepClassifierAndRouteClaimsTogether() throws {
        let source = try readSource(.packetTunnelProviderLifecycle)
        let initial = try sourceBlock(in: source, startingAt: "let makeInitialSettings:",
            endingBefore: "guard let settingsBundle = DispatchQueue.getSpecific(")
        let finish = try sourceBlock(in: source, startingAt: "private func finishDNSPatchStartupSettings(",
            endingBefore: "/// A recoverable outage under a strict profile")
        for block in [initial, finish] {
            XCTAssertTrue(sourceContainsInOrder([
                "self.chainedClaimedResolverDestinations?.update(",
                "self.makeClaimedResolverDestinations(for: self.currentTunnelDataPathMode())",
                "let settingsBundle = self.makeTunnelNetworkSettingsForLatchedDataPath()",
            ], in: block), "Classifier destinations must be refreshed alongside each startup route snapshot.")
        }
    }

    func testFreshLifecycleDiscardsThePriorStartupPolicy() throws {
        let source = try readSource(.packetTunnelProviderLifecycle)
        let begin = try sourceBlock(in: source, startingAt: "private func beginTunnelLifecycle(",
            endingBefore: "private func invalidateTunnelLifecycle(")
        XCTAssertTrue(sourceContainsInOrder([
            "self.dnsPatchStartupInstallPolicy?.cancel()",
            "self.dnsPatchStartupInstallPolicy = nil",
            "self.tunnelLifecycleGeneration += 1",
            "self.tunnelLifecycleIsActive = true",
        ], in: begin), "A patch-disabled fresh profile must not inherit a prior lifecycle's startup policy.")
    }

    func testInitialDiscoveryHasOneDeadlineAndPublishesEndpointsBeforeSettlement() throws {
        let discovery = try readSource(.dnsPatchRouteDiscovery)
        let start = try sourceBlock(in: discovery, startingAt: "private func start()",
            endingBefore: "private func evaluate(")
        XCTAssertTrue(sourceContainsInOrder([
            "queue.asyncAfter(deadline: .now() + DNSPatchInitialDiscoveryPolicy.timeoutSeconds)",
            "self.initialPolicy.deadlineDidExpire()",
            "let monitor = NWPathMonitor(requiredInterfaceType: type)",
            "monitor.start(queue: queue)",
        ], in: start), "The overall deadline must include a missing first monitor callback.")
        let evaluation = try sourceBlock(in: discovery, startingAt: "private func evaluate(",
            endingBefore: "private func publishInitialAction(")
        XCTAssertTrue(evaluation.contains("self.connections[key] === connection"))
        XCTAssertTrue(evaluation.contains("pathObserved(initialInterface, isSatisfied: path.status == .satisfied)"))
        XCTAssertTrue(sourceContainsInOrder([
            "case .ready:",
            "var endpointIsAdmitted = false",
            "self.contract.admitsObservedEndpoint(address)",
            "self.update(self.observations.keys.sorted()",
            "endpointIsAdmitted = true",
            "self.initialPolicy.evaluationCompleted(",
            "endpointIsAdmitted: endpointIsAdmitted",
        ], in: evaluation), "An admitted endpoint must be delivered before success settlement; unusable readiness fails.")
        XCTAssertTrue(evaluation.contains("endpointIsAdmitted: false"))
        let cancel = try sourceBlock(in: discovery, startingAt: "public func cancel()",
            endingBefore: "private func start()")
        XCTAssertTrue(sourceContainsInOrder([
            "initialPolicy.cancel()", "stopMonitoring()", "publishInitialAction(action)",
        ], in: cancel))
    }

    func testInitialSettlementResumesOrCancelsTheRetainedCompletionExactlyOnce() throws {
        let source = try readSource(.packetTunnelProviderLifecycle)
        let settle = try sourceBlock(in: source, startingAt: "private func completeDNSPatchInitialDiscovery(",
            endingBefore: "private func cancelDNSPatchStartupInstallCompletion()")
        XCTAssertTrue(settle.contains("self.tunnelLifecycleIsActive"))
        XCTAssertTrue(settle.contains("self.isCurrentTunnelLifecycle(lifecycleGeneration)"))
        XCTAssertTrue(settle.contains("initialDiscoveryDidComplete("))
        XCTAssertFalse(settle.contains("dnsPatchObservedEndpoints !="),
            "An unchanged endpoint array still needs an independent discovery-settled signal.")
        XCTAssertTrue(sourceContainsInOrder([
            "event: \"dns-patch-initial-discovery-failed\"",
            "\"reason\": failure.rawValue",
            "guard let completion = self.dnsPatchStartupInstallCompletion",
            "self.dnsPatchStartupInstallCompletion = nil",
            "self.prepareDNSPatchInitialSettings(",
        ], in: settle))
        XCTAssertFalse(settle.contains("self.finishDNSPatchStartupSettings("),
            "Discovery settlement resumes only preparation; no settings can be in flight yet.")
        let cancel = try sourceBlock(in: source, startingAt: "private func cancelDNSPatchStartupInstallCompletion()",
            endingBefore: "private func prepareDNSPatchInitialSettings(")
        XCTAssertTrue(sourceContainsInOrder([
            "guard let completion = dnsPatchStartupInstallCompletion",
            "dnsPatchStartupInstallCompletion = nil",
            "DispatchQueue.global(qos: .utility).async { completion(CocoaError(.userCancelled)) }",
        ], in: cancel), "Consume before delivering cancellation so reentrant teardown cannot complete twice.")
        let prepare = try sourceBlock(in: source, startingAt: "private func prepareDNSPatchInitialSettings(",
            endingBefore: "private func finishDNSPatchStartupSettings(")
        let wait = try sourceBlock(in: prepare, startingAt: "case .waitForDiscovery:",
            endingBefore: "case .discoveryFailed(")
        XCTAssertTrue(wait.contains("self.dnsPatchStartupInstallCompletion = completion"))
        XCTAssertTrue(prepare.contains("case .discoveryFailed(let failure):"))
        XCTAssertTrue(prepare.contains("DispatchQueue.global(qos: .utility).async { completion(failure) }"))
        let finish = try sourceBlock(in: source, startingAt: "private func finishDNSPatchStartupSettings(",
            endingBefore: "/// A recoverable outage under a strict profile")
        XCTAssertFalse(finish.contains("dnsPatchStartupInstallCompletion = completion"),
            "An in-flight settings post owns its callback; only preinitial discovery may retain one.")
        XCTAssertFalse(finish.contains("case .waitForDiscovery:"))
        XCTAssertFalse(finish.contains("case .discoveryFailed("))
        XCTAssertFalse(finish.contains("resumeFromDiscovery"))
        let invalidate = try sourceBlock(in: source, startingAt: "private func invalidateTunnelLifecycle(",
            endingBefore: "/// Whether a tunnel session")
        XCTAssertTrue(invalidate.contains("self.cancelDNSPatchStartupInstallCompletion()"))
    }
}
