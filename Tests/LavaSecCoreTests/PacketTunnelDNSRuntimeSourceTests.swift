import LavaSecCore
import XCTest

final class PacketTunnelDNSRuntimeSourceTests: XCTestCase {
    func testHealthAndDiagnosticsWritesAreCoalescedNotPerEvent() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")

        // The dirty + interval-throttle + debounced-flush machinery (the disk-churn
        // guard against the heat-regression class, P0) is now the extracted, unit-
        // tested DebouncedPersistenceController (see DebouncedPersistenceControllerTests
        // for the cadence behavior). Both health and diagnostics must route through it
        // rather than writing per event; this pins the wiring so the coalescing path
        // can't silently regress back to inline per-event writes.
        XCTAssertTrue(source.contains("healthPersistence = DebouncedPersistenceController("))
        XCTAssertTrue(source.contains("diagnosticsPersistence = DebouncedPersistenceController("))
        XCTAssertTrue(source.contains("writeInterval: healthWriteInterval"))
        XCTAssertTrue(source.contains("writeInterval: diagnosticsWriteInterval"))
        XCTAssertTrue(source.contains("private let healthWriteInterval: TimeInterval = 30"))
        XCTAssertTrue(source.contains("private let diagnosticsWriteInterval: TimeInterval = 30"))

        // Mutations funnel into the controller's debounced flush; persist* delegates
        // the force/throttled write — there is no inline per-event disk write left.
        XCTAssertTrue(source.contains("healthPersistence.markDirty()"))
        XCTAssertTrue(source.contains("diagnosticsPersistence.markDirty()"))
        XCTAssertTrue(source.contains("healthPersistence.flush(force: force)"))
        XCTAssertTrue(source.contains("diagnosticsPersistence.flush(force: force)"))
    }

    func testDeviceDNSRefreshUsesFallbackPolicyInsteadOfClearingOnEmptyCapture() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let refreshBlock = try sourceBlock(
            in: source,
            startingAt: "private func refreshDeviceDNSResolverAddressesOnDNSQueue",
            endingBefore: "private static func currentSystemDNSServerAddresses()"
        )
        let setterBlock = try sourceBlock(
            in: source,
            startingAt: "private func setDeviceDNSResolverAddresses",
            endingBefore: "private func currentDeviceDNSFallbackModeActive()"
        )

        XCTAssertTrue(
            refreshBlock.contains("DeviceDNSFallbackPolicy.refreshedResolverAddresses"),
            "The tunnel should keep the last usable device DNS resolvers when iOS only reports Lava's tunnel DNS."
        )
        XCTAssertTrue(
            setterBlock.contains("DeviceDNSFallbackPolicy.refreshedResolverAddresses"),
            "The non-queue setter should use the same empty-capture policy as DNS-queue refreshes."
        )
        XCTAssertTrue(
            setterBlock.contains("preserveOnEmptyCapture"),
            "The setter should make empty-capture preservation explicit."
        )
        XCTAssertTrue(
            source.contains("refreshDeviceDNSResolverAddressesOnDNSQueue(reason: \"network-path-changed\")"),
            "Network changes should keep the last usable Device DNS capture when iOS briefly reports only Lava's tunnel DNS."
        )
        XCTAssertFalse(
            refreshBlock.contains("deviceDNSResolverAddresses = addresses"),
            "Assigning the raw capture directly can wipe fallback DNS while the tunnel is active."
        )
    }

    func testResolverFallbackRunsInlineToAvoidQueueStarvation() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let resolveBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolveUpstream",
            endingBefore: "private func resolvePrimaryUpstream"
        )
        let orchestratorSource = try readSource("Sources/LavaSecCore/ResolverOrchestrator.swift")
        let orchestratorResolveBlock = try sourceBlock(
            in: orchestratorSource,
            startingAt: "public func resolveUpstream",
            endingBefore: "public func resolvePrimaryUpstream"
        )

        XCTAssertTrue(resolveBlock.contains("resolverOrchestrator.resolveUpstream("))
        XCTAssertTrue(orchestratorResolveBlock.contains("let fallbackResult = executors.resolveDevice(query, plan.deviceDNSFallbackAddresses)"))
        XCTAssertTrue(orchestratorResolveBlock.contains("completion(primaryResult.withDeviceDNSFallback(fallbackResult))"))
        XCTAssertFalse(orchestratorResolveBlock.contains("resolverQueue.async"))
    }

    func testUDPResolverSendsToEndpointPerQueryWithoutConnectingSocketAtCreation() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let udpSocketBlock = try sourceBlock(
            in: source,
            startingAt: "private final class UDPResolverSocket",
            endingBefore: "private enum TCPResolver"
        )

        XCTAssertFalse(
            udpSocketBlock.contains("Self.connect(descriptor"),
            "UDP socket creation should not fail because a resolver route cannot be connected yet."
        )
        XCTAssertTrue(
            udpSocketBlock.contains("send(query, endpoint: endpoint, fileDescriptor: fileDescriptor)"),
            "Each UDP query should use sendto with its endpoint so route changes do not poison socket creation."
        )
    }

    func testUDPResolverValidatesReceivedPacketSourceBeforeDNSPayload() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let udpSocketBlock = try sourceBlock(
            in: source,
            startingAt: "private final class UDPResolverSocket",
            endingBefore: "private enum TCPResolver"
        )
        let sourceMatcherBlock = try sourceBlock(
            in: source,
            startingAt: "private func isExpectedSource",
            endingBefore: "private func send("
        )

        XCTAssertTrue(
            udpSocketBlock.contains("var sourceAddress = sockaddr_storage()"),
            "recvfrom should capture the UDP sender address on unconnected sockets."
        )
        XCTAssertTrue(
            udpSocketBlock.contains("isExpectedSource(sourceAddress, endpoint: endpoint)"),
            "DNS payload validation should only run for packets sent by the resolver endpoint."
        )
        XCTAssertTrue(
            sourceMatcherBlock.contains("sin_port == in_port_t(53).bigEndian"),
            "UDP source validation should require the DNS server port."
        )
        XCTAssertTrue(sourceMatcherBlock.contains("inet_pton(AF_INET, endpoint.address"))
        XCTAssertTrue(sourceMatcherBlock.contains("inet_pton(AF_INET6, endpoint.address"))
    }

    func testBlockedDNSResponsesUseShortTTLWithoutChangingUpstreamResponseCache() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let blockedBlock = try sourceBlock(
            in: source,
            startingAt: "private let blockedTTL",
            endingBefore: "private static let maxConcurrentResolverQueries"
        )
        let cacheSource = try readSource("Sources/LavaSecCore/DNSResponseCache.swift")
        let upstreamCacheBlock = try sourceBlock(
            in: cacheSource,
            startingAt: "public enum DNSResponseCachePolicy",
            endingBefore: "public final class DNSResponseCache"
        )

        XCTAssertTrue(blockedBlock.contains("private let blockedTTL: UInt32 = 1"))
        XCTAssertTrue(source.contains("ttl: blockedTTL"))
        XCTAssertTrue(upstreamCacheBlock.contains("static func cacheTTL(for response: Data) -> TimeInterval?"))
        XCTAssertTrue(upstreamCacheBlock.contains("return min(TimeInterval(minimumTTL), maximumTTL)"))
    }

    func testTemporaryPauseForwardsWouldBlockDomainsWithShortTTL() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let handleBlock = try sourceBlock(
            in: source,
            startingAt: "private func handle(packet: Data, protocolNumber: NSNumber)",
            endingBefore: "private func forward("
        )
        let pauseTTLBlock = try sourceBlock(
            in: source,
            startingAt: "private func temporaryPauseMaximumAnswerTTL",
            endingBefore: "private func currentResolverPreset()"
        )
        let completeForwardBlock = try sourceBlock(
            in: source,
            startingAt: "private func completeForward",
            endingBefore: "private func currentResolverRuntimeGeneration()"
        )

        XCTAssertTrue(source.contains("private let pausedWouldBlockForwardTTL: UInt32 = 1"))
        XCTAssertTrue(source.contains("private var protectionPolicySnapshot: any FilterRuntimeSnapshot"))
        XCTAssertTrue(handleBlock.contains("isProtectionPaused: {"))
        XCTAssertTrue(handleBlock.contains("isTemporaryProtectionPauseActive(synchronizesDefaults: false)"))
        XCTAssertTrue(handleBlock.contains("case .pausedForward:"))
        XCTAssertTrue(handleBlock.contains("temporaryPauseMaximumAnswerTTL(forNormalizedDomain: question.normalizedDomain)"))
        XCTAssertTrue(handleBlock.contains("temporaryPauseNormalizedDomain: question.normalizedDomain"))
        XCTAssertTrue(pauseTTLBlock.contains("protectionPolicyDecision(forNormalizedDomain: normalizedDomain)"))
        XCTAssertTrue(pauseTTLBlock.contains("decision.action == .block ? pausedWouldBlockForwardTTL : nil"))
        XCTAssertTrue(completeForwardBlock.contains("maximumAnswerTTL: UInt32?"))
        XCTAssertTrue(completeForwardBlock.contains("pending.maximumAnswerTTL"))
        XCTAssertTrue(source.contains("DNSWireMessage.cappingCacheableTTLs(in: response, to: maximumAnswerTTL)"))
    }

    func testDNSParseFailuresReturnServerFailureInsteadOfForwardingRawQuery() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let parseFailureBlock = try sourceBlock(
            in: source,
            startingAt: "guard let question = try? DNSMessage.parseQuestion(from: request.dnsPayload)",
            endingBefore: "let resolverConfiguration = currentResolverRuntimeConfiguration()"
        )

        XCTAssertTrue(parseFailureBlock.contains("writeParseFailureResponse"))
        XCTAssertFalse(
            parseFailureBlock.contains("forward(request"),
            "Unparseable DNS must fail closed instead of being forwarded outside the filter."
        )
    }

    func testUDPResolverSendHelperUsesSendtoForIPv4AndIPv6() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let sendBlock = try sourceBlock(
            in: source,
            startingAt: "private func send(",
            endingBefore: "private func receiveFailureOutcome()"
        )

        XCTAssertTrue(sendBlock.contains("sendto("))
        XCTAssertTrue(sendBlock.contains("inet_pton(AF_INET, endpoint.address"))
        XCTAssertTrue(sendBlock.contains("inet_pton(AF_INET6, endpoint.address"))
        XCTAssertFalse(
            sendBlock.contains("Darwin.send("),
            "Unconnected UDP sockets must use sendto, not send."
        )
    }

    func testPlainDNSAttemptsTCPFallbackAfterUDPTimeoutOnly() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let plainResolverBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolvePlainDNS(",
            endingBefore: "private func shouldAttemptTCPFallback(afterUDPOutcome"
        )
        let fallbackDecisionBlock = try sourceBlock(
            in: source,
            startingAt: "private func shouldAttemptTCPFallback(afterUDPOutcome",
            endingBefore: "private func doqEndpointResolvingBootstrapIfNeeded"
        )

        XCTAssertTrue(
            plainResolverBlock.contains("shouldAttemptTCPFallback(afterUDPOutcome: udpResult.outcome)"),
            "Plain DNS should try bounded TCP fallback after a UDP timeout instead of immediately moving on."
        )
        XCTAssertTrue(
            plainResolverBlock.contains("let tcpResult = TCPResolver.resolve(query, endpoint: endpoint, timeoutSeconds: Self.tcpDNSTimeoutSeconds)")
        )
        XCTAssertTrue(
            plainResolverBlock.contains("tcpFallbackAttempted: attemptedTCPFallback"),
            "Health should report TCP fallback attempts even when UDP was not truncated."
        )
        XCTAssertTrue(fallbackDecisionBlock.contains("case .timeout:"))
        XCTAssertTrue(fallbackDecisionBlock.contains("return true"))
        XCTAssertTrue(fallbackDecisionBlock.contains("case .sendFailed:"))
        XCTAssertTrue(fallbackDecisionBlock.contains("return false"))
    }

    func testPlainDNSBackoffDoesNotRetryEveryQueryWhenAllResolversAreBackedOff() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let plainResolverBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolvePlainDNS(",
            endingBefore: "private func shouldAttemptTCPFallback"
        )
        let addressOrderBlock = try sourceBlock(
            in: source,
            startingAt: "private func orderedResolverAddressesForAttempt",
            endingBefore: "private func isResolverBackedOff"
        )

        XCTAssertTrue(plainResolverBlock.contains("if addressesForAttempt.isEmpty, !resolverAddresses.isEmpty"))
        XCTAssertTrue(plainResolverBlock.contains("ResolverAttempt(address: $0, outcome: .backedOff, transport: transport)"))
        XCTAssertFalse(addressOrderBlock.contains("available.isEmpty ? addresses : available"))
        XCTAssertTrue(addressOrderBlock.contains("resolverBackoffPolicy.availableAddresses(from: addresses, now: now)"))
    }

    func testResolverSocketsRequireTimeoutSetup() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let udpSocketBlock = try sourceBlock(
            in: source,
            startingAt: "private final class UDPResolverSocket",
            endingBefore: "private enum TCPResolver"
        )
        let tcpResolverBlock = try sourceBlock(
            in: source,
            startingAt: "private enum TCPResolver",
            endingBefore: "private enum DNSMessageTraits"
        )

        XCTAssertTrue(
            source.contains("private func configureSocketTimeouts("),
            "Resolver sockets should share checked timeout setup instead of ignoring setsockopt failures."
        )
        XCTAssertTrue(
            udpSocketBlock.contains("guard configureSocketTimeouts(descriptor, receive: true, send: false, timeoutSeconds: timeoutSeconds) else"),
            "UDP resolver sockets must fail closed when receive timeouts cannot be installed."
        )
        XCTAssertTrue(
            tcpResolverBlock.contains("guard configureSocketTimeouts(descriptor, receive: true, send: true, timeoutSeconds: timeoutSeconds) else"),
            "TCP fallback must fail closed when receive/send timeouts cannot be installed."
        )
        XCTAssertFalse(udpSocketBlock.contains("_ = setsockopt"))
        XCTAssertFalse(tcpResolverBlock.contains("_ = setsockopt"))
    }

    func testReconnectNeededActivityIsPolicyGated() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let recordBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordUpstreamResult",
            endingBefore: "private func updateResolverBackoff"
        )
        let smokeProbeBlock = try sourceBlock(
            in: source,
            startingAt: "private func applyResolverSmokeProbeResult",
            endingBefore: "private func resetHealth"
        )
        let helperBlock = try sourceBlock(
            in: source,
            startingAt: "private func appendReconnectNeededIfPolicyRequiresReconnect",
            endingBefore: "#if LAVA_QA_TOOLS"
        )

        XCTAssertTrue(recordBlock.contains("appendReconnectNeededIfPolicyRequiresReconnect(now: now)"))
        XCTAssertTrue(smokeProbeBlock.contains("appendReconnectNeededIfPolicyRequiresReconnect(now: now)"))
        XCTAssertFalse(recordBlock.contains("appendNetworkActivity(\n                event: .reconnectNeeded"))
        XCTAssertFalse(smokeProbeBlock.contains("appendNetworkActivity(event: .reconnectNeeded"))
        XCTAssertTrue(helperBlock.contains("ProtectionConnectivityPolicy.assessment"))
        XCTAssertTrue(helperBlock.contains("assessment.primaryAction == .reconnect"))
        XCTAssertTrue(helperBlock.contains("lastReconnectNeededActivityAt"))
    }

    func testNetworkFlapCoalescesProactiveResolverRebuild() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let pathBlock = try sourceBlock(
            in: source,
            startingAt: "private func handleNetworkPathUpdate(",
            endingBefore: "private func reapplyTunnelNetworkSettings("
        )
        let settleProbeBlock = try sourceBlock(
            in: source,
            startingAt: "private func performCoalescedNetworkSettleProbe()",
            endingBefore: "private func doqEndpointResolvingBootstrapIfNeeded("
        )

        // Immediate teardown stays inline on every change (stale connections must
        // die regardless of coalescing).
        XCTAssertTrue(pathBlock.contains("collectPendingResponsesAndResetResolverRuntime("))
        XCTAssertTrue(pathBlock.contains("resolverBootstrapService.invalidateAll()"))

        // The proactive rebuild is coalesced, not run per flap: a satisfied change
        // re-arms the settle timer, an unsatisfied change cancels it, and the
        // inline per-flap prewarm + smoke probe are gone.
        XCTAssertTrue(pathBlock.contains("resolverProbeCoalescer.noteUnsettled()"))
        XCTAssertTrue(pathBlock.contains("resolverProbeCoalescer.cancel()"))
        XCTAssertFalse(
            pathBlock.contains("scheduleResolverSmokeProbeIfNeeded(reason: \"network-path-changed\")"),
            "The smoke probe must be deferred to the coalesced settle probe, not fired on every flap."
        )
        XCTAssertFalse(
            pathBlock.contains("prewarmResolverBootstrapIfNeeded()"),
            "Bootstrap pre-warm must be deferred to the coalesced settle probe, not run on every flap."
        )

        // The deferred probe does the proactive rebuild once, gated on a live path.
        XCTAssertTrue(settleProbeBlock.contains("guard health.networkPathIsSatisfied else"))
        XCTAssertTrue(settleProbeBlock.contains("prewarmResolverBootstrapIfNeeded()"))
        XCTAssertTrue(settleProbeBlock.contains("scheduleResolverSmokeProbeIfNeeded(reason: \"network-settled\")"))

        // Settle window + scheduler wiring.
        XCTAssertTrue(source.contains("private let resolverProbeSettleInterval: TimeInterval = 1.5"))
        XCTAssertTrue(source.contains("NetworkSettleCoalescer("))
        XCTAssertTrue(source.contains("DispatchSettleWorkScheduler(queue: dnsStateQueue)"))
    }

    func testHandlePacketRoutesThroughDNSQueryDispatcher() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let handleBlock = try sourceBlock(
            in: source,
            startingAt: "private func handle(packet: Data, protocolNumber: NSNumber)",
            endingBefore: "private func forward("
        )

        // The decision precedence is delegated to the pure DNSQueryDispatcher
        // (unit-tested in DNSQueryDispatcherTests); the provider supplies lazy
        // state closures and performs I/O on the returned decision.
        XCTAssertTrue(source.contains("private let dnsQueryDispatcher = DNSQueryDispatcher()"))
        XCTAssertTrue(handleBlock.contains("dnsQueryDispatcher.decide("))
        XCTAssertTrue(handleBlock.contains("bootstrapResponse: {"))
        XCTAssertTrue(handleBlock.contains("isProtectionPaused: {"))
        XCTAssertTrue(handleBlock.contains("filterDecision: {"))
        XCTAssertTrue(handleBlock.contains("case .bootstrap(let bootstrapResponse):"))
        XCTAssertTrue(handleBlock.contains("case .pausedForward:"))
        XCTAssertTrue(handleBlock.contains("case .filtered(let filterDecision):"))
        // Bootstrap still resets resolver runtime; filtered-block still builds the
        // blocked response — the per-branch I/O is unchanged.
        XCTAssertTrue(handleBlock.contains("resetResolverRuntimeStateIfNeeded(identifier: resolverConfiguration.cacheIdentifier)"))
        XCTAssertTrue(handleBlock.contains("DNSMessage.blockedResponse("))
    }

    func testSmokeProbesDoNotMutateLiveResolverBackoff() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let smokeProbeBlock = try sourceBlock(
            in: source,
            startingAt: "private func applyResolverSmokeProbeResult",
            endingBefore: "private func resetHealth"
        )
        let queryResultBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordUpstreamResult",
            endingBefore: "private func updateResolverBackoff"
        )

        XCTAssertFalse(
            smokeProbeBlock.contains("updateResolverBackoff"),
            "Smoke probes should not poison live resolver backoff or make user DNS fail."
        )
        XCTAssertTrue(
            queryResultBlock.contains("updateResolverBackoff(from: result.attempts)"),
            "Real query failures may still update resolver backoff."
        )
    }

    func testTunnelStartClearsResolverRuntimeAndRefreshesEncryptedResolverSessions() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let startBlock = try sourceBlock(
            in: source,
            startingAt: "override func startTunnel",
            endingBefore: "override func stopTunnel"
        )
        let lifecycleResetBlock = try sourceBlock(
            in: source,
            startingAt: "private func resetResolverRuntimeForTunnelLifecycle",
            endingBefore: "private func collectPendingResponsesAndResetResolverRuntime"
        )

        XCTAssertTrue(startBlock.contains("let lifecycleGeneration = beginTunnelLifecycle(reason: \"startTunnel\")"))
        XCTAssertTrue(startBlock.contains("isCurrentTunnelLifecycle(lifecycleGeneration)"))
        XCTAssertTrue(startBlock.contains("cleanUpTunnelRuntimeAfterFailedStart"))
        XCTAssertTrue(startBlock.contains("resetResolverRuntimeForTunnelLifecycle(reason: \"startTunnel\")"))
        XCTAssertTrue(lifecycleResetBlock.contains("activeResolverRuntimeIdentifier = nil"))
        XCTAssertTrue(lifecycleResetBlock.contains("dnsResponseCache.removeAll()"))
        XCTAssertTrue(lifecycleResetBlock.contains("inFlightQueryCoalescer.drainAll()"))
        XCTAssertTrue(lifecycleResetBlock.contains("resolverBackoffPolicy.reset()"))
        XCTAssertTrue(lifecycleResetBlock.contains("dohResolver.resetSession()"))
        XCTAssertTrue(lifecycleResetBlock.contains("dotResolver.resetConnections()"))
        XCTAssertTrue(lifecycleResetBlock.contains("doqResolver.resetConnections()"))
    }

    func testTemporaryPauseExpiryRefreshesLiveActivityFromTunnel() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let project = try readSource("LavaSec.xcodeproj/project.pbxproj")
        let expiryBlock = try sourceBlock(
            in: source,
            startingAt: "private func resumeExpiredTemporaryProtectionPauseIfNeeded()",
            endingBefore: "private func currentTemporaryProtectionPauseUntil("
        )

        XCTAssertTrue(project.contains("LavaActivityAttributes.swift in Sources"))
        XCTAssertTrue(source.contains("import ActivityKit"))
        XCTAssertTrue(
            expiryBlock.contains("protectionPauseStore.clearStoredPause()"),
            "Expiry must clear stored pause through the store (no revision mint, no inline key removal)."
        )
        XCTAssertTrue(expiryBlock.contains("updateLiveActivitiesAfterTemporaryProtectionPauseExpired()"))
        XCTAssertFalse(
            expiryBlock.contains("loadSnapshotInBackground"),
            "Pause expiry must not reload the snapshot; it is identity-unchanged (plan F2)."
        )
        XCTAssertFalse(
            expiryBlock.contains("resetDNSRuntimeForProtectionPolicyChange"),
            "Pause expiry must not reset the DNS runtime; pause-era cache entries expire with the pause window."
        )
        XCTAssertTrue(source.contains("private func updateLiveActivitiesAfterTemporaryProtectionPauseExpired()"))
        XCTAssertTrue(source.contains("Activity<LavaActivityAttributes>.activities"))
        XCTAssertTrue(source.contains("LavaActivityAttributes.ContentState("))
        XCTAssertTrue(source.contains("protectionState: .on"))
        XCTAssertTrue(source.contains("pause-expired-live-activity-update"))
    }

    func testTunnelLifecycleBoundsTemporaryPauseToCurrentVPNSession() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let startBlock = try sourceBlock(
            in: source,
            startingAt: "override func startTunnel",
            endingBefore: "override func stopTunnel"
        )
        let stopBlock = try sourceBlock(
            in: source,
            startingAt: "override func stopTunnel",
            endingBefore: "private static func errorDebugDetails"
        )
        let stopCleanupBlock = try sourceBlock(
            in: source,
            startingAt: "private func cleanUpTunnelRuntimeAfterStop",
            endingBefore: "private static func errorDebugDetails"
        )
        let currentPauseBlock = try sourceBlock(
            in: source,
            startingAt: "private func currentTemporaryProtectionPauseUntil(",
            endingBefore: "private var protectionPauseDefaults"
        )
        let expiryBlock = try sourceBlock(
            in: source,
            startingAt: "private func resumeExpiredTemporaryProtectionPauseIfNeeded()",
            endingBefore: "private func updateLiveActivitiesAfterTemporaryProtectionPauseExpired()"
        )

        let beginSessionIndex = try XCTUnwrap(startBlock.range(of: "beginFreshProtectionVPNSession(reason: \"startTunnel\")")?.lowerBound)
        let scheduleIndex = try XCTUnwrap(startBlock.range(of: "scheduleProtectionPauseResumeIfNeeded(reason: \"startTunnel\")")?.lowerBound)
        XCTAssertLessThan(
            beginSessionIndex,
            scheduleIndex,
            "The tunnel must clear stale pause state before scheduling pause expiry on a fresh VPN session."
        )
        XCTAssertTrue(stopBlock.contains("cleanUpTunnelRuntimeAfterStop(reason: \"stopTunnel\")"))
        XCTAssertTrue(stopCleanupBlock.contains("endProtectionVPNSession(reason: reason)"))
        XCTAssertTrue(source.contains("private func beginFreshProtectionVPNSession(reason: String)"))
        XCTAssertTrue(source.contains("private func endProtectionVPNSession(reason: String)"))
        // Session binding (pauseSessionID == activeSessionID) is enforced inside
        // ProtectionPauseStore and covered by ProtectionPauseStoreTests; the
        // tunnel must route reads and cleanup through the stores.
        XCTAssertTrue(currentPauseBlock.contains("protectionPauseStore.storedPauseState()"))
        XCTAssertTrue(currentPauseBlock.contains("protectionSessionStore.beginFreshSession()"))
        XCTAssertTrue(currentPauseBlock.contains("protectionSessionStore.clearActiveSessionID()"))
        XCTAssertTrue(expiryBlock.contains("protectionPauseStore.clearStoredPause()"))
    }

    func testTemporaryPauseKeepsFullPolicySnapshotLoaded() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadCompiledSnapshot(",
            endingBefore: "private func loadCompactPreparedSnapshot()"
        )
        let activePauseBlock = try sourceBlock(
            in: source,
            startingAt: "private func isTemporaryProtectionPauseActive",
            endingBefore: "private func currentTemporaryProtectionPauseUntil("
        )

        XCTAssertFalse(loadBlock.contains("allowsTemporaryPassThrough"))
        XCTAssertFalse(loadBlock.contains("isTemporaryProtectionPauseActive()"))
        XCTAssertFalse(source.contains("canUseTemporaryPassThroughSnapshot"))
        XCTAssertTrue(loadBlock.contains("return (compactSnapshot, compactSnapshot.identity)"))
        XCTAssertTrue(loadBlock.contains("return (preparedSnapshot.snapshot, preparedSnapshot.identity)"))
        XCTAssertTrue(activePauseBlock.contains("pauseUntil > now"))
    }

    func testTunnelDoesNotFallBackToUnboundLegacySnapshots() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadCompiledSnapshot(",
            endingBefore: "private func loadCompactPreparedSnapshot()"
        )
        let initialStateBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadInitialSharedState()",
            endingBefore: "private func refreshConfigurationIfNeeded"
        )
        let loadSnapshotBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadSnapshotInBackground(reason: String, operationID: LatencyOperationID? = nil)",
            endingBefore: "private func scheduleProtectionPauseResumeIfNeeded"
        )

        XCTAssertFalse(source.contains("loadLegacyPersistedSnapshot"))
        XCTAssertTrue(loadBlock.contains("let baseSnapshot = configuration.filterSnapshot()"))
        XCTAssertTrue(loadBlock.contains("configuration.enabledBlocklistIDs.isEmpty ? (baseSnapshot, expectedIdentity) : nil"))
        XCTAssertTrue(loadBlock.contains("CachedFilterSnapshotCompiler(\n                cacheDirectoryURL: catalogCacheURL\n            )"))
        XCTAssertTrue(initialStateBlock.contains("FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)"))
        XCTAssertTrue(loadSnapshotBlock.contains("FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)"))
        XCTAssertTrue(loadSnapshotBlock.contains("\"resolver\": configuration.resolverDiagnosticDisplayName"))
        XCTAssertFalse(loadSnapshotBlock.contains("\"resolver\": runtimeSnapshot.resolver.displayName"))
    }

    func testProtectionStateRefreshClearsInFlightQueriesEvenWhenResolverIsUnchanged() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let refreshBlock = try sourceBlock(
            in: source,
            startingAt: "private func refreshDNSRuntimeAfterSnapshotOrConfigurationChange()",
            endingBefore: "private func resetResolverRuntimeStateIfNeeded"
        )
        let resetBlock = try sourceBlock(
            in: source,
            startingAt: "private func resetDNSRuntimeForProtectionPolicyChange",
            endingBefore: "private func resetResolverRuntimeStateIfNeeded"
        )

        XCTAssertTrue(refreshBlock.contains("resetDNSRuntimeForProtectionPolicyChange"))
        XCTAssertTrue(resetBlock.contains("resolverRuntimeGeneration += 1"))
        XCTAssertTrue(resetBlock.contains("inFlightQueryCoalescer.drainAll()"))
        XCTAssertTrue(resetBlock.contains("dnsResponseCache.removeAll()"))
        XCTAssertTrue(resetBlock.contains("writeServerFailures(for: pendingResponses)"))
    }

    func testReloadSnapshotRequestsAreCoalescedAndEpochGuarded() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let appMessageBlock = try sourceBlock(
            in: source,
            startingAt: "override func handleAppMessage",
            endingBefore: "case LavaSecAppGroup.reloadConfigurationMessage"
        )
        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadSnapshotInBackground(reason: String, operationID: LatencyOperationID? = nil)",
            endingBefore: "private func scheduleProtectionPauseResumeIfNeeded"
        )

        XCTAssertTrue(source.contains("private var snapshotReloadGeneration: UInt64 = 0"))
        XCTAssertTrue(source.contains("private var lastAppliedTemporaryProtectionPauseIsActive = false"))
        XCTAssertTrue(source.contains("private func requestSnapshotReload(reason: String, force: Bool = false, operationID: LatencyOperationID? = nil)"))
        XCTAssertTrue(source.contains("private func nextSnapshotReloadGeneration() -> UInt64"))
        XCTAssertTrue(
            appMessageBlock.contains("reason: \"appMessage\","),
            "Snapshot reload app messages must force a reload and carry the caller's operation id."
        )
        XCTAssertTrue(appMessageBlock.contains("operationID: providerMessage.operationID.map(LatencyOperationID.init(rawValue:))"))
        XCTAssertTrue(appMessageBlock.contains("case LavaSecAppGroup.reloadProtectionPauseMessage:"))
        XCTAssertTrue(
            appMessageBlock.contains("refreshProtectionPauseStateOnly(reason: \"protectionPause\")"),
            "Pause messages must refresh pause state without forcing a snapshot reload (plan F2)."
        )
        XCTAssertFalse(
            appMessageBlock.contains("requestSnapshotReload(reason: \"protectionPause\")"),
            "Pause flips must not reset the DNS runtime or reload the snapshot."
        )
        // The CFNotificationCenter Darwin-notify IPC was removed: it never fired
        // reliably in the NE extension (0 callbacks across 14 device probe runs)
        // and sendProviderMessage is the sole tunnel IPC. Guard reintroduction.
        XCTAssertFalse(source.contains("CFNotificationCenterAddObserver"))
        XCTAssertFalse(source.contains("handlePauseStateChangedDarwinNotification"))
        XCTAssertFalse(source.contains("refreshProtectionPauseStateOnly(reason: \"darwin-pause\")"))

        let appGroupSource = try readSource("Shared/AppGroup.swift")
        XCTAssertFalse(
            appGroupSource.contains("DarwinNotificationName"),
            "The Darwin-notify name aliases were removed with the unreliable observer path."
        )
        XCTAssertTrue(loadBlock.contains("guard self.isCurrentSnapshotReloadGeneration(generation) else"))
        XCTAssertTrue(loadBlock.contains("self.refreshConfigurationIfNeeded(force: true)"))
        XCTAssertTrue(loadBlock.contains("protectionPolicySnapshot: runtimePolicySnapshot,"))
        XCTAssertTrue(loadBlock.contains("identity: loaded.identity"))
        // The cheap no-op gate must skip the decode when the on-disk artifact
        // matches the resident snapshot, and the genuine-change path must drop
        // the resident snapshot (fail-closed) before decoding to avoid the
        // 2x-resident memory peak that jetsams the extension.
        XCTAssertTrue(loadBlock.contains("residentSnapshotSatisfiesReload(configuration: configuration)"))
        XCTAssertTrue(loadBlock.contains("loadSnapshot-reload-noop"))
        XCTAssertTrue(loadBlock.contains("loadSnapshot-failclosed-before-decode"))
        // Tunnel backstop: an over-budget artifact must be refused (fail-closed)
        // before the decode, never jetsam.
        XCTAssertTrue(loadBlock.contains("compactSnapshotRuleCountExceedingBudget()"))
        XCTAssertTrue(loadBlock.contains("loadSnapshot-over-budget"))

        let refreshConfigIndex = try XCTUnwrap(loadBlock.range(of: "self.refreshConfigurationIfNeeded(force: true)")?.lowerBound)
        let replaceSnapshotIndex = try XCTUnwrap(loadBlock.range(of: "self.replaceSnapshot(\n                runtimeSnapshot")?.lowerBound)
        XCTAssertLessThan(
            refreshConfigIndex,
            replaceSnapshotIndex,
            "Snapshot reloads must apply config before replacing runtime snapshots so DNS transport state matches the newest config."
        )
    }

    func testProviderMessagesDecodeOperationEnvelopeAndLogReceiveReplySpans() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let appMessageCompletionBlock = try sourceBlock(
            in: source,
            startingAt: "private struct AppMessageCompletion",
            endingBefore: "private final class ResolverWorkCompletion"
        )
        let appMessageBlock = try sourceBlock(
            in: source,
            startingAt: "override func handleAppMessage",
            endingBefore: "private func readPackets()"
        )

        XCTAssertTrue(appMessageCompletionBlock.contains("let latencySpan: LatencySpan?"))
        XCTAssertTrue(appMessageCompletionBlock.contains("latencySpan?.end(details: [\"status\": response == nil ? \"nil-reply\" : \"reply\"])"))
        XCTAssertTrue(appMessageBlock.contains("guard let providerMessage = LavaSecProviderMessageCodec.decode(messageData)"))
        XCTAssertTrue(appMessageBlock.contains("let message = providerMessage.kind"))
        XCTAssertTrue(appMessageBlock.contains("operationID: LatencyOperationID(rawValue: operationID)"))
        XCTAssertTrue(appMessageBlock.contains("LatencyDebugLogEventSink(operationKind: \"providerMessage\""))
        XCTAssertTrue(appMessageBlock.contains("trace?.record(\"provider.message.received\""))
        XCTAssertTrue(appMessageBlock.contains("trace?.beginSpan(\"provider.message.reply\""))
        XCTAssertFalse(appMessageBlock.contains("String(data: messageData, encoding: .utf8)"))
    }

    func testStartTunnelRecordsOperationScopedLifecycleAndNetworkSettingsSpans() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let startTunnelBlock = try sourceBlock(
            in: source,
            startingAt: "override func startTunnel",
            endingBefore: "override func stopTunnel"
        )
        let latencyHelperBlock = try sourceBlock(
            in: source,
            startingAt: "private static func makeLatencyTrace(",
            endingBefore: "private func readPackets()"
        )

        XCTAssertTrue(source.contains("LavaSecAppGroup.latencyOperationIDOptionKey"))
        XCTAssertTrue(source.contains("private static func latencyOperationID(from options: [String: NSObject]?) -> LatencyOperationID?"))
        XCTAssertTrue(latencyHelperBlock.contains("LatencyDebugLogEventSink(operationKind: operationKind)"))
        XCTAssertTrue(latencyHelperBlock.contains("LavaSecDeviceDebugLog.append(component: \"tunnel\""))
        XCTAssertTrue(startTunnelBlock.contains("let operationID = Self.latencyOperationID(from: options)"))
        XCTAssertTrue(startTunnelBlock.contains("Self.makeLatencyTrace(operationID: operationID, operationKind: \"tunnelStart\")"))
        XCTAssertTrue(startTunnelBlock.contains("trace.beginSpan(\"tunnel.start\""))
        XCTAssertTrue(startTunnelBlock.contains("trace.beginSpan(\"tunnel.setNetworkSettings\", parent: startSpan"))
        XCTAssertTrue(startTunnelBlock.contains("networkSettingsSpan.end(details: [\"status\": \"error\""))
        XCTAssertTrue(startTunnelBlock.contains("networkSettingsSpan.end(details: [\"status\": \"stale\""))
        XCTAssertTrue(startTunnelBlock.contains("networkSettingsSpan.end(details: [\"status\": \"ok\""))
        XCTAssertTrue(startTunnelBlock.contains("startSpan.end(details: [\"status\": \"ready\""))
    }

    func testResolverTransportSeamsEmitLatencySpans() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let executorsBlock = try sourceBlock(
            in: source,
            startingAt: "private func makeResolverExecutors()",
            endingBefore: "private func resolveDeviceDNS("
        )
        let bootstrapBlock = try sourceBlock(
            in: source,
            startingAt: "private lazy var resolverBootstrapService = ResolverBootstrapService(",
            endingBefore: "private func doqEndpointResolvingBootstrapIfNeeded"
        )

        // One operation id groups the resolver-path spans for a session.
        XCTAssertTrue(source.contains("private let resolverLatencyOperationID = LatencyOperationID.make()"))
        XCTAssertTrue(executorsBlock.contains("Self.makeLatencyTrace(operationID: resolverLatencyOperationID, operationKind: \"resolver\")"))
        // Every encrypted wire attempt is spanned; "endpoint fallback" is the
        // multi-attempt subset of resolver.endpointAttempt.
        XCTAssertTrue(executorsBlock.contains("beginResolverSpan(\"resolver.endpointAttempt\", [\"transport\": \"DoH\"])"))
        XCTAssertTrue(executorsBlock.contains("beginResolverSpan(\"resolver.endpointAttempt\", [\"transport\": \"DoT\"])"))
        XCTAssertTrue(executorsBlock.contains("beginResolverSpan(\"resolver.endpointAttempt\", [\"transport\": \"DoQ\"])"))
        // Plain DNS is the dominant path for plain-IP-resolver users, so it is
        // spanned too (one span over the whole UDP/TCP/iteration resolution).
        XCTAssertTrue(executorsBlock.contains("beginResolverSpan(\"resolver.endpointAttempt\", [\"transport\": \"plain\"])"))
        XCTAssertTrue(executorsBlock.contains("beginResolverSpan(\"resolver.deviceFallback\", [:])"))
        // Spans are stripped from Release: every emission sits behind the
        // latency build gate, like the rest of the tunnel spans.
        XCTAssertTrue(executorsBlock.contains("#if DEBUG || LAVA_QA_TOOLS"))
        XCTAssertTrue(bootstrapBlock.contains(".beginSpan(\"resolver.bootstrap\")"))
        XCTAssertTrue(bootstrapBlock.contains("#if DEBUG || LAVA_QA_TOOLS"))
    }

    func testEncryptedTransportsEmitHandshakeObservations() throws {
        let dotSource = try readSource("Sources/LavaSecCore/DoTTransport.swift")
        let doqSource = try readSource("Sources/LavaSecCore/DoQTransport.swift")
        let dohSource = try readSource("Sources/LavaSecCore/DoHTransport.swift")

        // Handshake cost is the per-connection sub-phase under an endpoint
        // attempt; it is reported only when a debug logger is injected (nil in
        // Release), measured connect -> ready / connect timings.
        XCTAssertTrue(dotSource.contains("debugLogger: DNSTransportDebugLogger?"))
        XCTAssertTrue(dotSource.contains("\"dns-dot-connection-ready\""))
        XCTAssertTrue(dotSource.contains("\"handshakeMs\""))
        XCTAssertTrue(dotSource.contains("connectionStartedAtMonotonicTime"))

        XCTAssertTrue(doqSource.contains("\"dns-doq-connection-ready\""))
        XCTAssertTrue(doqSource.contains("details[\"handshakeMs\"]"))
        XCTAssertTrue(doqSource.contains("currentConnectionStartedAtMonotonicTime"))

        XCTAssertTrue(dohSource.contains("debugLogger: DNSTransportDebugLogger?"))
        XCTAssertTrue(dohSource.contains("\"dns-doh-connection-ready\""))
        XCTAssertTrue(dohSource.contains("!transaction.isReusedConnection"))
        XCTAssertTrue(dohSource.contains("\"handshakeMs\""))

        // The tunnel injects the loggers only under the latency build gate so
        // Release transports never link the debug-log backend.
        let tunnelSource = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        XCTAssertTrue(tunnelSource.contains("private let dohResolver: DoHTransport = {"))
        XCTAssertTrue(tunnelSource.contains("private let dotResolver: DoTTransport = {"))
    }

    func testMalformedUpstreamResponsesFailClosedBeforeForwardingOrCaching() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let completeForwardBlock = try sourceBlock(
            in: source,
            startingAt: "private func completeForward",
            endingBefore: "private func responseByApplyingMaximumAnswerTTL"
        )
        let ttlApplyBlock = try sourceBlock(
            in: source,
            startingAt: "private func responseByApplyingMaximumAnswerTTL",
            endingBefore: "private func writeParseFailureResponse"
        )
        let cachePolicyBlock = try sourceBlock(
            in: try readSource("Sources/LavaSecCore/DNSResponseCache.swift"),
            startingAt: "public enum DNSResponseCachePolicy",
            endingBefore: "public final class DNSResponseCache"
        )

        XCTAssertTrue(completeForwardBlock.contains("DNSWireMessage.hasWellFormedResourceRecords(upstreamResponse)"))
        XCTAssertTrue(completeForwardBlock.contains("DNSResponseFactory.serverFailure(for: query)"))
        XCTAssertTrue(ttlApplyBlock.contains("DNSWireMessage.cappingCacheableTTLs(in: response, to: maximumAnswerTTL)"))
        XCTAssertTrue(cachePolicyBlock.contains("recordType != 41"))
        XCTAssertTrue(cachePolicyBlock.contains("if recordType != 41, ttl == 0"))
        XCTAssertTrue(cachePolicyBlock.contains("isValidCompressedNameTarget"))
    }

    func testDoHFailuresRefreshURLSessionWhenIdleWithoutCancellingParallelTasks() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let executorsBlock = try sourceBlock(
            in: source,
            startingAt: "private func makeResolverExecutors",
            endingBefore: "private func resolveDeviceDNS"
        )

        XCTAssertTrue(executorsBlock.contains("if upstreamResponse.response == nil"))
        XCTAssertTrue(executorsBlock.contains("dohResolver.resetSessionWhenIdle()"))
        XCTAssertFalse(
            executorsBlock.contains("dohResolver.resetSession()"),
            "A single failed DoH request must not cancel unrelated active DoH tasks after resolver work becomes parallel."
        )
    }

    func testDoHTransportTracksActiveTasksBeforeIdleReset() throws {
        let source = try readSource("Sources/LavaSecCore/DoHTransport.swift")
        let dohTransportBlock = try sourceBlock(
            in: source,
            startingAt: "public final class DoHTransport",
            endingBefore: "private final class DoHTaskMetricsRecorder"
        )

        XCTAssertTrue(dohTransportBlock.contains("private var activeTaskCount = 0"))
        XCTAssertTrue(dohTransportBlock.contains("private var shouldResetWhenIdle = false"))
        XCTAssertTrue(dohTransportBlock.contains("func resetSessionWhenIdle()"))
        XCTAssertTrue(dohTransportBlock.contains("private func beginTaskSession() -> URLSession"))
        XCTAssertTrue(dohTransportBlock.contains("private func finishTask()"))
    }

    func testResolverWorkIsBoundedButNotSingleSerialQueue() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")

        XCTAssertTrue(
            source.contains("private let resolverQueue = DispatchQueue(label: \"com.lavasec.tunnel.resolver\", qos: .utility, attributes: .concurrent)"),
            "Resolver work should be able to make bounded progress in parallel instead of funnelling every query through one serial queue."
        )
        XCTAssertTrue(
            source.contains("private let resolverConcurrencyGate = DispatchSemaphore(value:"),
            "Concurrent resolver work must remain bounded."
        )
        XCTAssertTrue(
            source.contains("private func runBoundedResolverWork"),
            "Resolver dispatch should centralize gate handling so every path releases exactly once."
        )
    }

    func testDoHTransportUsesCompletionBasedURLSessionWithoutSemaphoreWait() throws {
        let source = try readSource("Sources/LavaSecCore/DoHTransport.swift")
        let dohTransportBlock = try sourceBlock(
            in: source,
            startingAt: "public final class DoHTransport",
            endingBefore: "private final class DoHTaskMetricsRecorder"
        )

        XCTAssertTrue(
            dohTransportBlock.contains("completion: @escaping @Sendable (DNSTransportResponse) -> Void"),
            "DoH should complete asynchronously instead of blocking a resolver worker thread."
        )
        XCTAssertTrue(dohTransportBlock.contains("dataTask(with: request)"))
        XCTAssertFalse(
            dohTransportBlock.contains("DispatchSemaphore"),
            "DoH URLSession callbacks should not be bridged by blocking on a semaphore."
        )
        XCTAssertFalse(
            dohTransportBlock.contains("semaphore.wait"),
            "DoH should preserve the URLSession timeout without occupying a worker while waiting."
        )
        XCTAssertTrue(
            dohTransportBlock.contains("task.delegate = metricsRecorder"),
            "The per-task delegate is what captures the negotiated HTTP protocol for DoH3 reporting."
        )
    }

    func testResolverRuntimeRoutesDoTThroughDedicatedTransport() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let primaryResolverBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolvePrimaryUpstream",
            endingBefore: "private func resolveDeviceDNS"
        )
        let runtimeConfigBlock = try sourceBlock(
            in: source,
            startingAt: "private func currentResolverRuntimeConfiguration",
            endingBefore: "private func orderedResolverAddressesForCurrentNetwork"
        )

        XCTAssertTrue(primaryResolverBlock.contains("resolverOrchestrator.resolvePrimaryUpstream("))
        XCTAssertTrue(primaryResolverBlock.contains("usesIsolatedEncryptedConnections: purpose.usesIsolatedEncryptedConnection"))
        XCTAssertTrue(primaryResolverBlock.contains("dotResolver.resolveIsolated(query, endpoint: endpoint, completion: finish)"))
        XCTAssertTrue(primaryResolverBlock.contains("dotResolver.resolve(query, endpoint: endpoint, completion: finish)"))
        XCTAssertTrue(runtimeConfigBlock.contains("DNSResolverRuntimePlan.make"))
        XCTAssertTrue(source.contains("private typealias ResolverRuntimeConfiguration = DNSResolverRuntimePlan"))
    }

    func testResolverRuntimeRoutesDoQThroughDedicatedTransport() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let primaryResolverBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolvePrimaryUpstream",
            endingBefore: "private func resolveDeviceDNS"
        )
        let runtimeConfigBlock = try sourceBlock(
            in: source,
            startingAt: "private func currentResolverRuntimeConfiguration",
            endingBefore: "private func orderedResolverAddressesForCurrentNetwork"
        )
        let stopBlock = try sourceBlock(
            in: source,
            startingAt: "override func stopTunnel",
            endingBefore: "private static func errorDebugDetails"
        )

        XCTAssertTrue(primaryResolverBlock.contains("resolverOrchestrator.resolvePrimaryUpstream("))
        XCTAssertTrue(primaryResolverBlock.contains("doqResolver.resolveIsolated(query, endpoint: endpoint, completion: finish)"))
        XCTAssertTrue(primaryResolverBlock.contains("doqResolver.resolve(query, endpoint: endpoint, completion: finish)"))
        XCTAssertTrue(runtimeConfigBlock.contains("DNSResolverRuntimePlan.make"))
        XCTAssertTrue(source.contains("private typealias ResolverRuntimeConfiguration = DNSResolverRuntimePlan"))
        XCTAssertTrue(stopBlock.contains("doqResolver.cancel()"))
    }

    func testDoTTransportUsesNetworkTLSAndCompletionCallbacks() throws {
        let source = try readSource("Sources/LavaSecCore/DoTTransport.swift")
        let dotTransportBlock = try sourceBlock(
            in: source,
            startingAt: "public final class DoTTransport",
            endingBefore: "final class DoTConnection"
        )
        let dotConnectionBlock = try sourceBlock(
            in: source,
            startingAt: "final class DoTConnection",
            endingBefore: "enum DNSLengthPrefixedWireMessage"
        )

        XCTAssertTrue(dotTransportBlock.contains("completion: @escaping @Sendable (DNSTransportResponse) -> Void"))
        XCTAssertTrue(dotTransportBlock.contains("resetConnections()"))
        XCTAssertTrue(dotTransportBlock.contains("resetConnectionsWhenIdle()"))
        XCTAssertTrue(dotConnectionBlock.contains("NWConnection("))
        XCTAssertTrue(dotConnectionBlock.contains("NWProtocolTLS.Options()"))
        XCTAssertTrue(dotConnectionBlock.contains("sec_protocol_options_set_tls_server_name"))
        XCTAssertTrue(dotConnectionBlock.contains("NWParameters(tls: tlsOptions, tcp: tcpOptions)"))
        XCTAssertTrue(dotConnectionBlock.contains("receiveExact"))
        XCTAssertTrue(dotConnectionBlock.contains("DNSWireMessage.isValidResponse"))
        XCTAssertFalse(source.contains("DispatchSemaphore"))
        XCTAssertFalse(source.contains("semaphore.wait"))
    }

    func testDoTConnectionFailureAdvancesBootstrapAddressOnlyOnce() throws {
        let source = try readSource("Sources/LavaSecCore/DoTTransport.swift")
        let dotConnectionBlock = try sourceBlock(
            in: source,
            startingAt: "final class DoTConnection",
            endingBefore: "enum DNSLengthPrefixedWireMessage"
        )
        let stateBlock = try sourceBlock(
            in: dotConnectionBlock,
            startingAt: "private func handleConnectionState",
            endingBefore: "private func sendCurrentQuery"
        )

        XCTAssertTrue(stateBlock.contains("let hadReadyCompletions = !readyCompletions.isEmpty"))
        XCTAssertTrue(stateBlock.contains("resetConnectionLocked(advanceBootstrapAddress: !hadReadyCompletions)"))
        XCTAssertTrue(stateBlock.contains("failOrRetryCurrentQuery(outcome: .receiveFailed, resetsConnection: false)"))
    }

    func testDoTTransportUsesPerEndpointConnectionPoolToAvoidHeadOfLineBlocking() throws {
        let source = try readSource("Sources/LavaSecCore/DoTTransport.swift")
        let dotTransportBlock = try sourceBlock(
            in: source,
            startingAt: "public final class DoTTransport",
            endingBefore: "final class DoTConnection"
        )

        XCTAssertTrue(dotTransportBlock.contains("private static let maxConnectionsPerEndpoint"))
        XCTAssertTrue(dotTransportBlock.contains("private var connections: [String: [DoTConnection]]"))
        XCTAssertTrue(dotTransportBlock.contains("private var nextConnectionIndexByKey: [String: Int]"))
        XCTAssertTrue(dotTransportBlock.contains("private func connectionPool(for endpoint: DNSOverTLSEndpoint) -> [DoTConnection]"))
        XCTAssertTrue(dotTransportBlock.contains("connections.values.flatMap"))
        XCTAssertFalse(dotTransportBlock.contains("private var connections: [String: DoTConnection]"))
    }

    func testDoQTransportUsesCompletionCallbacksWithoutBlocking() throws {
        let source = try readSource("Sources/LavaSecCore/DoQTransport.swift")
        let doqTransportBlock = try sourceBlock(
            in: source,
            startingAt: "public final class DoQTransport",
            endingBefore: "final class DoQConnection"
        )

        XCTAssertTrue(doqTransportBlock.contains("completion: @escaping @Sendable (DNSTransportResponse) -> Void"))
        XCTAssertTrue(doqTransportBlock.contains("resetConnections()"))
        XCTAssertTrue(doqTransportBlock.contains("resetConnectionsWhenIdle()"))
        XCTAssertTrue(source.contains("NWParameters.quic(alpn: [\"doq\"])"))
        XCTAssertTrue(source.contains("NWConnection(host: NWEndpoint.Host(endpoint.hostname), port: port, using: parameters)"))
        XCTAssertTrue(source.contains("contentContext: .finalMessage"))
        XCTAssertTrue(source.contains("DNSLengthPrefixedWireMessage.framedQuery"))
        XCTAssertTrue(source.contains("DNSWireMessage.clearingTransactionID"))
        XCTAssertTrue(source.contains("DNSWireMessage.replacingTransactionID"))
        XCTAssertTrue(source.contains("DNSWireMessage.isValidResponse"))
        XCTAssertFalse(source.contains("DispatchSemaphore"))
        XCTAssertFalse(source.contains("semaphore.wait"))
    }

    func testDoQTransportUsesPerEndpointConnectionPoolToAvoidHeadOfLineBlocking() throws {
        let source = try readSource("Sources/LavaSecCore/DoQTransport.swift")
        let doqTransportBlock = try sourceBlock(
            in: source,
            startingAt: "public final class DoQTransport",
            endingBefore: "final class DoQConnection"
        )

        XCTAssertTrue(doqTransportBlock.contains("private static let maxConnectionsPerEndpoint"))
        XCTAssertTrue(doqTransportBlock.contains("private var connections: [String: [DoQConnection]]"))
        XCTAssertTrue(doqTransportBlock.contains("private var nextConnectionIndexByKey: [String: Int]"))
        XCTAssertTrue(doqTransportBlock.contains("private func connectionPool(for endpoint: DNSOverQUICEndpoint) -> [DoQConnection]"))
        XCTAssertTrue(doqTransportBlock.contains("connections.values.flatMap"))
        XCTAssertFalse(doqTransportBlock.contains("private var connections: [String: DoQConnection]"))
    }

    func testDoQTransportUsesPublicQUICConnectionWithoutCustomStack() throws {
        // RATIONALE (recovered 2026-06-14): DoQ connection REUSE is impossible
        // with a single reused NWConnection — RFC 9250 maps each query to its own
        // QUIC stream (with FIN), so reuse needs NWConnectionGroup/openStream,
        // and that public multi-stream QUIC API is iOS 26.0+. The app floor is
        // iOS 17, so the custom stack would force an #available(iOS 26.0)-gated
        // dual path (+ an .unsupported fallback). This pin keeps DoQ on the
        // simple, uniform NWParameters.quic(alpn:) single-connection-per-query
        // path across the whole floor. 2026-06-14: the iOS-26-gated reuse path
        // (NetworkConnection<QUIC> + openStream) WAS built and device-tested on
        // iOS 26.5 against AdGuard DoQ — it failed on every attempt (openStream/
        // receive errored, the fallback then hit "Socket is not connected"), net
        // WORSE than this path, confirming Apple DTS's "hold off on QUIC" guidance.
        // It was reverted. Re-attempt only after a later iOS 26.x proves the QUIC
        // stream API reliable. If you do, update this pin deliberately — do not
        // delete it to make a change pass. See plan item 413.
        let source = try readSource("Sources/LavaSecCore/DoQTransport.swift")

        XCTAssertTrue(source.contains("NWParameters.quic(alpn: [\"doq\"])"))
        XCTAssertTrue(source.contains("NWConnection(host: NWEndpoint.Host(endpoint.hostname), port: port, using: parameters)"))
        XCTAssertTrue(source.contains("connection.start(queue: queue)"))
        XCTAssertTrue(source.contains("connection.send("))
        XCTAssertTrue(source.contains("connection.receive(minimumIncompleteLength: 1, maximumLength:"))
        XCTAssertTrue(source.contains("contentContext: .finalMessage"))
        XCTAssertTrue(source.contains("isComplete: true"))
        XCTAssertFalse(source.contains("NetworkConnection(to:"))
        XCTAssertFalse(source.contains("openStream(directionality: .bidirectional)"))
        XCTAssertFalse(source.contains("AsyncDoQConnection"))
        XCTAssertFalse(source.contains("NWProtocolQUIC.Options(alpn: [\"doq\"])"))
        XCTAssertFalse(source.contains("NWParameters(quic: options)"))
        XCTAssertFalse(source.contains("NWConnectionGroup"))
        XCTAssertFalse(source.contains("DispatchSemaphore"))
    }

    func testDoQConnectionUsesPublicQUICAvailableOnSupportedIOSVersions() throws {
        let source = try readSource("Sources/LavaSecCore/DoQTransport.swift")
        let resolveBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolveCurrentQuery",
            endingBefore: "private func finishCurrentQuery"
        )

        XCTAssertFalse(resolveBlock.contains("#available(iOS 26.0"))
        XCTAssertFalse(resolveBlock.contains("outcome: .unsupported"))
        XCTAssertTrue(source.contains("NWParameters.quic(alpn: [\"doq\"])"))
        XCTAssertFalse(source.contains("NWParameters(quic: options)"))
    }

    func testDoQConnectionMapsTimeoutToResolverOutcome() throws {
        let source = try readSource("Sources/LavaSecCore/DoQTransport.swift")

        XCTAssertTrue(source.contains("queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeout)"))
        XCTAssertTrue(source.contains("DNSTransportResponse(response: nil, outcome: .timeout)"))
        XCTAssertTrue(source.contains("currentTimeout?.cancel()"))
    }

    func testResolverSmokeProbeUsesDedicatedLaneAndEncryptedConnections() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let smokeProbeBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverSmokeProbeIfNeeded",
            endingBefore: "private func resolverSmokeProbeTimeoutResult"
        )
        let primaryResolverBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolvePrimaryUpstream",
            endingBefore: "private func resolveDeviceDNS"
        )
        let dotTransportSource = try readSource("Sources/LavaSecCore/DoTTransport.swift")
        let doqTransportSource = try readSource("Sources/LavaSecCore/DoQTransport.swift")

        XCTAssertTrue(source.contains("private enum ResolverQueryPurpose: Sendable"))
        XCTAssertTrue(
            source.contains("private let resolverSmokeProbeQueue = DispatchQueue(label: \"com.lavasec.tunnel.resolver.smoke-probe\""),
            "Smoke probes should not wait behind forwarded DNS work in the shared resolver gate."
        )
        XCTAssertTrue(source.contains("private func runResolverSmokeProbeWork"))
        XCTAssertTrue(smokeProbeBlock.contains("runResolverSmokeProbeWork"))
        XCTAssertFalse(smokeProbeBlock.contains("runBoundedResolverWork"))
        XCTAssertTrue(smokeProbeBlock.contains("resolvePrimaryUpstream(query, resolverConfiguration: resolverConfiguration, purpose: .smokeProbe)"))
        XCTAssertTrue(primaryResolverBlock.contains("purpose: ResolverQueryPurpose = .forwarding"))
        XCTAssertTrue(primaryResolverBlock.contains("resolverOrchestrator.resolvePrimaryUpstream("))
        XCTAssertTrue(primaryResolverBlock.contains("usesIsolatedEncryptedConnections: purpose.usesIsolatedEncryptedConnection"))
        XCTAssertTrue(dotTransportSource.contains("public func resolveIsolated("))
        XCTAssertTrue(doqTransportSource.contains("public func resolveIsolated("))
        XCTAssertTrue(source.contains("if usesIsolatedConnection"))
        XCTAssertTrue(source.contains("if upstreamResponse.response == nil, !usesIsolatedConnection"))
    }

    func testDoQBootstrapsHostnamesBeforeForwardingAndKeepsQUICHostnameBased() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let packetHandlerBlock = try sourceBlock(
            in: source,
            startingAt: "private func handle(packet: Data, protocolNumber: NSNumber)",
            endingBefore: "private func forward("
        )
        let executorsBlock = try sourceBlock(
            in: source,
            startingAt: "private func makeResolverExecutors",
            endingBefore: "private func resolveDeviceDNS"
        )
        let bootstrapEndpointBlock = try sourceBlock(
            in: source,
            startingAt: "private func doqEndpointResolvingBootstrapIfNeeded",
            endingBefore: "private func resolveDoQBootstrapAddresses"
        )
        let bootstrapAddressesBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolveDoQBootstrapAddresses",
            endingBefore: "private func startPeriodicResolverSmokeProbe"
        )
        let doqBootstrapResponseBlock = try sourceBlock(
            in: source,
            startingAt: "private func doqBootstrapResponse",
            endingBefore: "private func startPeriodicResolverSmokeProbe"
        )
        let doqTransportSource = try readSource("Sources/LavaSecCore/DoQTransport.swift")

        XCTAssertTrue(packetHandlerBlock.contains("doqBootstrapResponse("))
        XCTAssertTrue(executorsBlock.contains("doqResolver.resolve(query, endpoint: endpoint, completion: finish)"))
        XCTAssertFalse(executorsBlock.contains("doqEndpointResolvingBootstrapIfNeeded(endpoint)"))
        XCTAssertTrue(
            bootstrapEndpointBlock.contains("resolverBootstrapService.cachedAddresses(forHostname: endpoint.hostname)"),
            "The packet path may only consult the bootstrap cache."
        )
        XCTAssertTrue(bootstrapEndpointBlock.contains("resolverBootstrapService.prewarm(hostname: endpoint.hostname)"))
        XCTAssertFalse(
            bootstrapEndpointBlock.contains("resolveDoQBootstrapAddresses("),
            "Synchronous bootstrap lookups must never run on the packet path."
        )
        XCTAssertTrue(bootstrapEndpointBlock.contains("DNSOverQUICEndpoint("))
        XCTAssertTrue(bootstrapEndpointBlock.contains("bootstrapIPv4Servers: cached.ipv4"))
        XCTAssertTrue(bootstrapEndpointBlock.contains("bootstrapIPv6Servers: cached.ipv6"))
        XCTAssertTrue(source.contains("self.prewarmResolverBootstrapIfNeeded()"))
        XCTAssertTrue(source.contains("resolverBootstrapService.invalidateAll()"))
        XCTAssertTrue(bootstrapAddressesBlock.contains("DNSResolverSmokeProbe.query("))
        XCTAssertTrue(bootstrapAddressesBlock.contains("resolvePlainDNS(aQuery, resolverAddresses: resolverAddresses, transport: .deviceDNS)"))
        XCTAssertTrue(bootstrapAddressesBlock.contains("DNSBootstrapAddressExtractor.addresses"))
        XCTAssertTrue(doqBootstrapResponseBlock.contains("resolverConfiguration.transport == .dnsOverQUIC"))
        XCTAssertTrue(doqBootstrapResponseBlock.contains("DomainName.normalize(question.domain)"))
        XCTAssertTrue(doqBootstrapResponseBlock.contains("DomainName.normalize(endpoint.hostname)"))
        XCTAssertTrue(doqBootstrapResponseBlock.contains("doqEndpointResolvingBootstrapIfNeeded(endpoint)"))
        XCTAssertTrue(doqBootstrapResponseBlock.contains("DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: bootstrappedEndpoint)"))
        XCTAssertTrue(doqTransportSource.contains("NWConnection(host: NWEndpoint.Host(endpoint.hostname), port: port, using: parameters)"))
        XCTAssertFalse(doqTransportSource.contains("NWEndpoint.Host(connectionHost)"))
        XCTAssertFalse(doqTransportSource.contains("sec_protocol_options_set_verify_block"))
    }

    func testDoTConnectionReadinessCannotHangWithoutAQueryTimeout() throws {
        let source = try readSource("Sources/LavaSecCore/DoTTransport.swift")
        let dotConnectionBlock = try sourceBlock(
            in: source,
            startingAt: "final class DoTConnection",
            endingBefore: "enum DNSLengthPrefixedWireMessage"
        )
        let startConnectionBlock = try sourceBlock(
            in: dotConnectionBlock,
            startingAt: "private func startConnectionLocked()",
            endingBefore: "private func handleConnectionState"
        )
        let timeoutBlock = try sourceBlock(
            in: dotConnectionBlock,
            startingAt: "private func scheduleTimeout(generation: Int)",
            endingBefore: "private func failOrRetryCurrentQuery"
        )

        XCTAssertTrue(startConnectionBlock.contains("scheduleTimeout(generation: generation)"))
        XCTAssertTrue(timeoutBlock.contains("readyCompletions = []"))
        XCTAssertTrue(
            timeoutBlock.contains("failOrRetryCurrentQuery(outcome: .timeout, resetsConnection: false)"),
            "Timeouts route through failOrRetryCurrentQuery so a stale reused connection gets one fresh retry before failing."
        )
    }

    func testForwardResolutionRecordsResolverLatencyForHealth() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let dispatchBlock = try sourceBlock(
            in: source,
            startingAt: "private func dispatchForwardResolution",
            endingBefore: "private func runBoundedResolverWork"
        )
        let resultBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordUpstreamResult",
            endingBefore: "private func updateResolverBackoff"
        )

        XCTAssertTrue(dispatchBlock.contains("let startedAt = Date()"))
        XCTAssertTrue(dispatchBlock.contains("result.recordingDuration(since: startedAt)"))
        XCTAssertTrue(resultBlock.contains("health.lastUpstreamDurationMilliseconds = result.durationMilliseconds"))
        XCTAssertTrue(resultBlock.contains("consecutiveSlowUpstreamResponseCount"))
    }

    func testResolverSmokeProbeCannotRemainInProgressForever() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let constantsBlock = try sourceBlock(
            in: source,
            startingAt: "private static let udpDNSTimeoutSeconds",
            endingBefore: "private let resolverBackoffStateQueue"
        )
        let probeBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverSmokeProbeIfNeeded",
            endingBefore: "private func applyResolverSmokeProbeResult"
        )
        let completionBlock = try sourceBlock(
            in: source,
            startingAt: "private func completeResolverSmokeProbeResult",
            endingBefore: "private func applyResolverSmokeProbeResult"
        )
        let timeoutResultBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolverSmokeProbeTimeoutResult",
            endingBefore: "private func completeResolverSmokeProbeResult"
        )

        XCTAssertTrue(constantsBlock.contains("private static let resolverSmokeProbeTimeoutSeconds"))
        XCTAssertTrue(source.contains("private final class ResolverSmokeProbeTimeout: @unchecked Sendable"))
        XCTAssertTrue(source.contains("private let workItem: DispatchWorkItem"))
        XCTAssertTrue(probeBlock.contains("let timeout = ResolverSmokeProbeTimeout"))
        XCTAssertTrue(probeBlock.contains("timeout.schedule(on: dnsStateQueue, timeoutSeconds: Self.resolverSmokeProbeTimeoutSeconds)"))
        XCTAssertTrue(probeBlock.contains("timeout.cancel()"))
        XCTAssertTrue(probeBlock.contains("completeResolverSmokeProbeResult("))
        XCTAssertTrue(completionBlock.contains("resolverSmokeProbeGeneration += 1"))
        XCTAssertTrue(timeoutResultBlock.contains("outcome: .timeout"))
        XCTAssertTrue(timeoutResultBlock.contains("address: resolverConfiguration.cacheIdentifier"))
    }

    func testResolverSmokeProbeLogsPrimaryAndFallbackDecisionEvidence() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let probeBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverSmokeProbeIfNeeded",
            endingBefore: "private func resolverSmokeProbeTimeoutResult"
        )

        XCTAssertTrue(probeBlock.contains("dns-smoke-probe-primary-result"))
        XCTAssertTrue(probeBlock.contains("\"primaryAccepted\": \"\\(primarySucceeded)\""))
        XCTAssertTrue(probeBlock.contains("\"primaryOutcome\": primaryResult.failureSummary ??"))
        XCTAssertTrue(probeBlock.contains("dns-smoke-probe-fallback-begin"))
        XCTAssertTrue(probeBlock.contains("dns-smoke-probe-fallback-result"))
        XCTAssertTrue(probeBlock.contains("\"fallbackAccepted\": \"\\(fallbackSucceeded)\""))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let sourceURL = packageRootURL.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private var packageRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceBlock(
        in source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }
}
