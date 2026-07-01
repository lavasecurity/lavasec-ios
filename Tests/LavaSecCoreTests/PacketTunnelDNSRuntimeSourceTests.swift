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

    func testDeviceDNSCaptureExhaustionDropsStaleResolverOnlyWhenEncryptedFallbackCatchesIt() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let retryBlock = try sourceBlock(
            in: source,
            startingAt: "private func runDeviceDNSCaptureRetry",
            endingBefore: "private func cancelDeviceDNSCaptureRetry"
        )

        // On capture-retry EXHAUSTION (a genuine resolver-changing handoff, not a
        // transient mask) the tunnel stops serving the previous network's now-
        // unreachable resolvers — but ONLY when a per-query encrypted fallback will
        // catch the queries. Phase 0 hygiene (lavasec-infra#57).
        XCTAssertTrue(
            retryBlock.contains("event: \"device-dns-capture-retry-exhausted\""),
            "Exhaustion must still be observable in the device log."
        )

        // The drop is gated on the encrypted fallback actually being the catcher. With
        // NO fallback (Device-DNS-only), `device-dns-unavailable` is not restart-worthy
        // (cold-start state), so dropping would strand the no-fallback handoff WITHOUT
        // escalation (Codex P1 on #110) — preserve the stale resolver there and let the
        // existing restart-worthy recovery fire (Track 4 is the prompt fix, separate).
        XCTAssertTrue(
            retryBlock.contains("currentResolverRuntimeConfiguration().encryptedFallback != nil"),
            "The exhaustion drop must be gated on whether an encrypted fallback will catch the queries."
        )
        XCTAssertTrue(
            retryBlock.contains("preserveOnEmptyCapture: !routesToEncryptedFallback"),
            "Drop the stale resolver only when the encrypted fallback catches it; otherwise preserve it (no-fallback keeps its restart-worthy recovery)."
        )

        // The drop must be gated behind the retry-exhaustion check (only when truly
        // exhausted, never on a routine empty read mid-retry).
        let gateRange = try XCTUnwrap(
            retryBlock.range(of: "DeviceDNSFallbackPolicy.shouldRetryDeviceDNSCapture"),
            "Expected the shouldRetryDeviceDNSCapture gate in runDeviceDNSCaptureRetry."
        )
        let dropRange = try XCTUnwrap(
            retryBlock.range(of: "preserveOnEmptyCapture: !routesToEncryptedFallback"),
            "Expected the fallback-gated stale-drop in the exhaustion branch."
        )
        XCTAssertTrue(
            gateRange.lowerBound < dropRange.lowerBound,
            "The stale-drop must come after (inside) the retry-exhaustion gate."
        )

        // When a drop does happen, it must take effect on the live runtime and nudge a
        // confirming probe so queries route to the fallback at once, mirroring recapture.
        XCTAssertTrue(
            retryBlock.contains("reason: \"device-dns-stale-dropped-on-exhaustion\""),
            "The drop+reset must be tagged distinctly for field logs."
        )
        XCTAssertTrue(
            retryBlock.contains("collectPendingResponsesAndResetResolverRuntime("),
            "Dropping the stale resolver must reset the runtime so live queries fail fast."
        )
        XCTAssertTrue(
            retryBlock.contains("scheduleResolverSmokeProbeIfNeeded(reason: \"device-dns-stale-dropped-on-exhaustion\")"),
            "A confirming probe must run so the policy sees the unavailable primary now."
        )
    }

    func testDeviceDNSRecaptureRestartIsGatedAndProductiveCreditIsPersisted() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")

        // Track 4: the no-fallback exhaustion path escalates to the gated cold-restart;
        // the fallback case must NOT (Option-A keeps serving over the encrypted path).
        let retryBlock = try sourceBlock(
            in: source,
            startingAt: "private func runDeviceDNSCaptureRetry",
            endingBefore: "private func cancelDeviceDNSCaptureRetry"
        )
        let gateRange = try XCTUnwrap(
            retryBlock.range(of: "if !routesToEncryptedFallback {"),
            "The recapture restart must be gated on there being no encrypted fallback."
        )
        let callRange = try XCTUnwrap(
            retryBlock.range(of: "promptDeviceDNSRecaptureRestartIfPolicyAllows(now:"),
            "The exhaustion branch must escalate to the gated recapture restart."
        )
        XCTAssertTrue(gateRange.lowerBound < callRange.lowerBound)

        // The recapture entry uses its OWN cap reason (higher ceiling) and shares the
        // guarded teardown (Track-1 path guard + on-demand + atomic cancel, no main hop).
        let promptBlock = try sourceBlock(
            in: source,
            startingAt: "private func promptDeviceDNSRecaptureRestartIfPolicyAllows",
            endingBefore: "private func performGuardedSelfReconnectTeardown"
        )
        XCTAssertTrue(promptBlock.contains("reason: .deviceDNSRecapture"))
        XCTAssertTrue(promptBlock.contains("performGuardedSelfReconnectTeardown(reason: .deviceDNSRecapture"))
        // A throttled/declined recapture still arms the in-place wedge probe (always-eventually-retry).
        XCTAssertTrue(promptBlock.contains("scheduleResolverWedgeRecoveryProbeIfNeeded()"))

        // The shared teardown persists the restart-survivable credit marker BEFORE the
        // cancel — the cancel kills the process, so an in-memory marker would not survive.
        let teardownBlock = try sourceBlock(
            in: source,
            startingAt: "private func performGuardedSelfReconnectTeardown",
            endingBefore: "private static func isOnDemandConfirmedEnabled"
        )
        let saveMarkerRange = try XCTUnwrap(
            teardownBlock.range(of: "Self.saveLastSelfReconnectAt(now)"),
            "The teardown must persist the credit marker."
        )
        let cancelRange = try XCTUnwrap(teardownBlock.range(of: "cancelTunnelWithError(nil)"))
        XCTAssertTrue(
            saveMarkerRange.lowerBound < cancelRange.lowerBound,
            "The credit marker must be persisted before the cancel that kills the process."
        )

        // THE LOAD-BEARING CORRECTION: the productive-recovery credit reads the PERSISTED
        // lastSelfReconnectAt (which survives the restart's process kill) and prunes the
        // persisted attempt store — it does NOT rely on the in-memory wedge marker, which
        // the cancel wipes (crediting through that would be a silent no-op for the cold
        // restart this exists to credit).
        let creditBlock = try sourceBlock(
            in: source,
            startingAt: "private func creditProductiveSelfReconnectIfPending",
            endingBefore: "// Pairs a logged"
        )
        XCTAssertTrue(
            creditBlock.contains("Self.loadLastSelfReconnectAt()"),
            "The credit must read the persisted (restart-survivable) marker."
        )
        XCTAssertTrue(
            creditBlock.contains("Self.saveSelfReconnectAttemptTimes("),
            "The credit must prune the persisted attempt store."
        )
        XCTAssertFalse(
            creditBlock.contains("reconnectNeededSince"),
            "The credit must not depend on the in-memory wedge marker (wiped by the restart)."
        )
        // Credit removes ONLY the recovered restart's own attempt (the marker), not every
        // attempt at-or-before it — earlier unproductive restarts stay counted so an
        // intermittent loop still hits the per-window cap after one success (Codex P2).
        XCTAssertTrue(
            creditBlock.contains("firstIndex(of: lastSelfReconnectAt)"),
            "The credit must remove a single matching attempt, not a range."
        )
        XCTAssertFalse(
            creditBlock.contains("filter { $0 > lastSelfReconnectAt }"),
            "The credit must not erase every attempt at-or-before the marker (Codex P2)."
        )

        // The credit is invoked from a confirmed-recovery site (smoke-probe success), NOT
        // from inside logConnectivityRecoveredIfWedged (whose wedge-marker guard the restart wipes).
        XCTAssertTrue(source.contains("creditProductiveSelfReconnectIfPending(now: now)"))
    }

    func testRecaptureIntentIsCarriedIntoTheWedgeRetry() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")

        // Codex P1/P2: when a no-fallback recapture restart cannot fire now (throttled by
        // cooldown, OR `.noAction` because idle/low traffic keeps severity below
        // `.needsReconnect`), the recovery retry re-enters the WEDGE path
        // (selfReconnectIfPolicyAllows). Without carrying the recapture intent it applies the
        // lower `.wedge` cap (2) and discards the recapture cap (3), suppressing the intended
        // third recapture restart. Fix: a sticky `deviceDNSRecaptureRestartPending` flag set
        // on ANY decline (recapture is owed once recapture exhausted), read by the wedge path
        // to pick the ceiling, cleared on confirmed recovery.

        // 1) The recapture decline branch marks the pending flag — on ANY decline, NOT only
        //    `.throttled` (`.noAction` also covers the idle/low-traffic case — Codex P2).
        let promptBlock = try sourceBlock(
            in: source,
            startingAt: "private func promptDeviceDNSRecaptureRestartIfPolicyAllows",
            endingBefore: "private func performGuardedSelfReconnectTeardown"
        )
        XCTAssertFalse(
            promptBlock.contains("if decision == .throttled"),
            "The recapture-pending flag must not be gated on .throttled only (Codex P2)."
        )
        let declineGuardRange = try XCTUnwrap(
            promptBlock.range(of: "guard decision == .reconnect else {"),
            "The recapture restart must decline when the policy does not say reconnect."
        )
        let setPendingRange = try XCTUnwrap(
            promptBlock.range(of: "deviceDNSRecaptureRestartPending = true"),
            "A declined recapture restart must mark the recapture restart as pending."
        )
        let probeRange = try XCTUnwrap(promptBlock.range(of: "scheduleResolverWedgeRecoveryProbeIfNeeded()"))
        // Set inside the decline branch, before the always-eventually-retry backstop probe.
        XCTAssertTrue(declineGuardRange.lowerBound < setPendingRange.lowerBound)
        XCTAssertTrue(setPendingRange.lowerBound < probeRange.lowerBound)

        // 2) The wedge path picks its restart reason from the flag and threads it into BOTH
        //    the policy decision (so the ceiling matches) and the shared teardown.
        let wedgeBlock = try sourceBlock(
            in: source,
            startingAt: "private func selfReconnectIfPolicyAllows",
            endingBefore: "// Track 4 — the gated cold-restart"
        )
        XCTAssertTrue(wedgeBlock.contains("deviceDNSRecaptureRestartPending ? .deviceDNSRecapture : .wedge"))
        XCTAssertTrue(wedgeBlock.contains("reason: restartReason,"))
        XCTAssertTrue(wedgeBlock.contains("performGuardedSelfReconnectTeardown(reason: restartReason"))
        // The wedge path must no longer hard-code `.wedge` for the teardown.
        XCTAssertFalse(wedgeBlock.contains("performGuardedSelfReconnectTeardown(reason: .wedge"))

        // 3) The flag is cleared on recovery so a later unrelated wedge uses the wedge cap.
        let clearBlock = try sourceBlock(
            in: source,
            startingAt: "private func clearReconnectNeededActivitySuppression",
            endingBefore: "#if LAVA_QA_TOOLS"
        )
        XCTAssertTrue(clearBlock.contains("deviceDNSRecaptureRestartPending = false"))

        // 4) ...and on a fresh tunnel lifecycle (resetHealth), so a reused provider instance
        //    (manual stop/start without a process kill) can't carry recapture intent into an
        //    unrelated wedge with the higher ceiling (Codex P2).
        let resetBlock = try sourceBlock(
            in: source,
            startingAt: "private func resetHealth",
            endingBefore: "private func startPathMonitor"
        )
        XCTAssertTrue(resetBlock.contains("deviceDNSRecaptureRestartPending = false"))
    }

    func testWakeProactivelyReHandshakesResolverAfterSuspend() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let wakeBlock = try sourceBlock(
            in: source,
            startingAt: "override func wake()",
            endingBefore: "#if DEBUG || LAVA_QA_TOOLS"
        )

        // On wake the upstream connections are stale, so wake() drops them and
        // re-probes: refresh device DNS, force-drop cached responses + tear down
        // stale sockets/connections, invalidate the bootstrap cache, then
        // re-handshake on settle. The forced reset closes the pre-settle-probe
        // window where a query could otherwise reuse a pre-sleep connection.
        XCTAssertTrue(wakeBlock.contains("dnsStateQueue.async"))
        // In-flight smoke probes are invalidated so a pre-sleep result can't apply
        // after resume and flip fallback on stale conditions.
        XCTAssertTrue(wakeBlock.contains("invalidateInFlightSmokeProbes()"))
        XCTAssertTrue(wakeBlock.contains("refreshDeviceDNSResolverAddressesOnDNSQueue(reason: \"wake\")"))
        XCTAssertTrue(wakeBlock.contains("collectPendingResponsesAndResetResolverRuntime("))
        XCTAssertTrue(wakeBlock.contains("reason: \"wake\""))
        XCTAssertTrue(wakeBlock.contains("force: true"))
        XCTAssertTrue(wakeBlock.contains("writeServerFailures(for: pendingResponses)"))
        XCTAssertTrue(wakeBlock.contains("resolverBootstrapService.invalidateAll()"))
        XCTAssertTrue(wakeBlock.contains("resolverProbeCoalescer.noteUnsettled()"))
        // wake() must NOT clear the device-DNS fallback decision: it also fires on
        // ordinary sleep, and dropping a working fallback would force a
        // failing-primary retry and a fresh DNS stall every wake. Real network
        // changes clear fallback in handleNetworkPathUpdate instead.
        XCTAssertFalse(
            wakeBlock.contains("resetFailureAndFallbackStateForRecovery()"),
            "wake() should preserve fallback mode; only a real network change clears it."
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

    func testSelfReconnectEscalatesWedgedDNSWithBackoffGuards() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")

        // The reconnect-needed path escalates into the self-reconnect policy.
        let reconnectBlock = try sourceBlock(
            in: source,
            startingAt: "private func appendReconnectNeededIfPolicyRequiresReconnect",
            endingBefore: "private func selfReconnectIfPolicyAllows"
        )
        XCTAssertTrue(reconnectBlock.contains("selfReconnectIfPolicyAllows(assessment: assessment, now: now)"))

        let helperBlock = try sourceBlock(
            in: source,
            startingAt: "private func selfReconnectIfPolicyAllows",
            endingBefore: "private static func loadSelfReconnectAttemptTimes"
        )
        // Decision delegates to the pure, tested policy, gated by protectionEnabled
        // AND a confirmed Connect-On-Demand signal (protectionEnabled alone can be
        // persisted even when arming on-demand failed, so a self-cancel without
        // on-demand would strand the user offline).
        XCTAssertTrue(helperBlock.contains("TunnelSelfReconnectPolicy.decision("))
        XCTAssertTrue(helperBlock.contains("protectionEnabled: currentAppConfiguration().protectionEnabled"))
        XCTAssertTrue(helperBlock.contains("onDemandEnabled: Self.isOnDemandConfirmedEnabled()"))
        XCTAssertTrue(helperBlock.contains("guard decision == .reconnect else"))
        // Latched so the cancel is issued once; attempts persisted for the
        // cross-restart backoff (the cancel kills the process).
        XCTAssertTrue(helperBlock.contains("guard !hasRequestedSelfReconnect else"))
        XCTAssertTrue(helperBlock.contains("hasRequestedSelfReconnect = true"))
        XCTAssertTrue(helperBlock.contains("saveSelfReconnectAttemptTimes"))
        XCTAssertTrue(helperBlock.contains("cancelTunnelWithError(nil)"))
    }

    func testSelfReconnectReValidatesNetworkPathBeforeCancel() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let helperBlock = try sourceBlock(
            in: source,
            startingAt: "private func selfReconnectIfPolicyAllows",
            endingBefore: "private static func loadSelfReconnectAttemptTimes"
        )

        // The .reconnect decision is computed on dnsStateQueue but the network path can
        // flip before the teardown lands. The cancel must be re-validated on a fresh
        // dnsStateQueue turn and gated on the path still being satisfied — tearing down
        // into a dead path hands Connect-On-Demand nothing to recover into and lengthens
        // the OFF window (field-confirmed).
        XCTAssertTrue(
            helperBlock.contains("dnsStateQueue.async"),
            "The cancel must be deferred to a fresh dnsStateQueue turn so an enqueued path update settles first."
        )
        // Must gate on the handler-stamped freshest path state, NOT only
        // health.networkPathIsSatisfied (which lands via a second deferred hop and can be
        // stale-satisfied when a delivered path update hasn't been applied yet).
        XCTAssertTrue(
            helperBlock.contains("self.latestMonitoredPathIsSatisfied"),
            "The teardown must re-check the handler-stamped latestMonitoredPathIsSatisfied, not just the deferred health flag."
        )

        // The path guard must PRECEDE the cancel: the cancel cannot fire on an
        // unsatisfied path.
        let guardRange = try XCTUnwrap(
            helperBlock.range(of: "guard self.latestMonitoredPathIsSatisfied"),
            "Expected a latestMonitoredPathIsSatisfied guard in selfReconnectIfPolicyAllows."
        )
        let cancelRange = try XCTUnwrap(
            helperBlock.range(of: "cancelTunnelWithError(nil)"),
            "Expected a cancelTunnelWithError(nil) call in selfReconnectIfPolicyAllows."
        )
        XCTAssertTrue(
            guardRange.lowerBound < cancelRange.lowerBound,
            "The networkPathIsSatisfied guard must come before cancelTunnelWithError."
        )

        // The persisted attempt (which counts against the per-window cap) must also be
        // committed only on the satisfied path, after the guard — a skipped teardown
        // must not burn a cap slot.
        // Target the COMMIT save (updatedAttempts), not the earlier normalization
        // self-heal save (attempts) that runs before the decision.
        let saveRange = try XCTUnwrap(
            helperBlock.range(of: "saveSelfReconnectAttemptTimes(updatedAttempts)"),
            "Expected the committed-attempt saveSelfReconnectAttemptTimes(updatedAttempts) in selfReconnectIfPolicyAllows."
        )
        XCTAssertTrue(
            guardRange.lowerBound < saveRange.lowerBound,
            "The self-reconnect attempt must be persisted only after the path guard passes."
        )

        // On an unsatisfied path: release the latch so a later satisfied settle can
        // retry, re-arm the lighter wedge-recovery probe, and record why it was skipped.
        XCTAssertTrue(
            helperBlock.contains("self.hasRequestedSelfReconnect = false"),
            "A skipped teardown must release the self-reconnect latch so recovery isn't permanently suppressed."
        )
        XCTAssertTrue(
            helperBlock.contains("scheduleResolverWedgeRecoveryProbeIfNeeded()"),
            "A skipped teardown must re-arm the wedge-recovery probe instead of cancelling blind."
        )
        XCTAssertTrue(
            helperBlock.contains("event: \"self-reconnect-skipped-path-unsatisfied\""),
            "A skipped teardown must be observable in the device log."
        )
    }

    func testSelfReconnectReValidatesWedgeBeforeCancel() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let helperBlock = try sourceBlock(
            in: source,
            startingAt: "private func selfReconnectIfPolicyAllows",
            endingBefore: "private static func loadSelfReconnectAttemptTimes"
        )

        // A queued smoke-probe / organic-query success can run on dnsStateQueue between the
        // .reconnect decision and the deferred cancel turn, clearing the wedge without
        // clearing hasRequestedSelfReconnect. The deferred turn must RE-RUN THE FULL
        // self-reconnect policy against fresh health and bail unless it still says reconnect
        // — re-deriving only the assessment and checking primaryAction == .reconnect is too
        // loose, because a wedge that cleared to .dnsSlow can still report .reconnect while
        // the policy is .noAction (Codex P2). Otherwise it tears down a now-healthy / covered
        // / merely-slow tunnel.
        let revalidateRange = try XCTUnwrap(
            helperBlock.range(of: "let revalidatedAssessment = ProtectionConnectivityPolicy.assessment"),
            "The deferred cancel turn must re-derive the connectivity assessment."
        )
        let decisionRange = try XCTUnwrap(
            helperBlock.range(of: "let revalidatedDecision = TunnelSelfReconnectPolicy.decision"),
            "The deferred cancel turn must re-run the full self-reconnect policy, not just the assessment."
        )
        let wedgeGuardRange = try XCTUnwrap(
            helperBlock.range(of: "guard revalidatedDecision == .reconnect else"),
            "The deferred cancel must be gated on the FULL policy still returning .reconnect."
        )
        // The wedge re-check must precede both the committed attempt and the cancel.
        let saveRange = try XCTUnwrap(
            helperBlock.range(of: "saveSelfReconnectAttemptTimes(updatedAttempts)"),
            "Expected the committed-attempt save in selfReconnectIfPolicyAllows."
        )
        let cancelRange = try XCTUnwrap(
            helperBlock.range(of: "cancelTunnelWithError(nil)"),
            "Expected a cancelTunnelWithError(nil) call in selfReconnectIfPolicyAllows."
        )
        XCTAssertTrue(revalidateRange.lowerBound < decisionRange.lowerBound)
        XCTAssertTrue(decisionRange.lowerBound < wedgeGuardRange.lowerBound)
        XCTAssertTrue(
            wedgeGuardRange.lowerBound < saveRange.lowerBound,
            "The wedge re-check must come before the persisted attempt."
        )
        XCTAssertTrue(
            wedgeGuardRange.lowerBound < cancelRange.lowerBound,
            "The wedge re-check must come before cancelTunnelWithError."
        )
        // On a cleared wedge, release the latch (so a later real wedge can retry) and bail.
        let latchReleaseRange = try XCTUnwrap(
            helperBlock.range(of: "self.hasRequestedSelfReconnect = false"),
            "A bailed cancel must release the self-reconnect latch."
        )
        XCTAssertTrue(wedgeGuardRange.lowerBound < latchReleaseRange.upperBound)

        // The teardown must be issued on the SAME dnsStateQueue turn the path was validated —
        // no DispatchQueue.main.async hop, which would reopen a path-flip window AFTER the
        // attempt was already burned (Codex P2). cancelTunnelWithError is async to iOS, and
        // setTunnelNetworkSettings is already called off-main here, so an off-main cancel is safe.
        XCTAssertFalse(
            helperBlock.contains("DispatchQueue.main.async"),
            "The cancel must not hop to the main queue — it reopens a cancel-into-dead-network window after the path guard."
        )
    }

    func testPathMonitorStampsFreshSatisfiedStateBeforeDeferringHandling() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let monitorBlock = try sourceBlock(
            in: source,
            startingAt: "private func startPathMonitor",
            endingBefore: "private func handleNetworkPathUpdate"
        )

        // The handler runs on dnsStateQueue but defers the heavy handleNetworkPathUpdate
        // (which applies health.networkPathIsSatisfied) to a SECOND dnsStateQueue.async.
        // The freshest-state stamp must happen SYNCHRONOUSLY in the handler, BEFORE that
        // deferral, so the self-reconnect guard can observe a delivered-but-not-yet-applied
        // path change one hop earlier (the cancel-into-dead-network race).
        let stampRange = try XCTUnwrap(
            monitorBlock.range(of: "self.latestMonitoredPathIsSatisfied = update.isSatisfied"),
            "The pathUpdateHandler must stamp latestMonitoredPathIsSatisfied synchronously."
        )
        let deferRange = try XCTUnwrap(
            monitorBlock.range(of: "self.dnsStateQueue.async"),
            "The pathUpdateHandler defers handleNetworkPathUpdate to a second turn."
        )
        XCTAssertTrue(
            stampRange.lowerBound < deferRange.lowerBound,
            "The synchronous stamp must precede the deferred handleNetworkPathUpdate hop."
        )
    }

    func testRecoveryFromAReconnectNeededWedgeIsLogged() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")

        // Both recovery paths route through the shared helper so a self-heal that
        // never reaches an organic query is still recorded: the organic-query path
        // (recordUpstreamResult) and the in-place smoke-probe path (primary +
        // device-DNS-fallback success in applyResolverSmokeProbeResult).
        let recordBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordUpstreamResult",
            endingBefore: "private func updateResolverBackoff"
        )
        // Organic-query recovery is recorded as proven by real forwarding; the
        // smoke-probe paths record an upstream-only verification, so the two are
        // distinguishable in field logs.
        XCTAssertTrue(recordBlock.contains("logConnectivityRecoveredIfWedged(transport: result.transport, verifiedBy: \"forwarding\", now: now)"))

        let smokeProbeBlock = try sourceBlock(
            in: source,
            startingAt: "private func applyResolverSmokeProbeResult",
            endingBefore: "private func resetHealth"
        )
        XCTAssertTrue(smokeProbeBlock.contains("logConnectivityRecoveredIfWedged(transport: primaryResult.transport, verifiedBy: \"smoke-probe\", now: now)"))
        XCTAssertTrue(smokeProbeBlock.contains("logConnectivityRecoveredIfWedged(transport: .deviceDNS, verifiedBy: \"smoke-probe\", now: now)"))

        // The helper emits both the activity-log row and the firm device-log line,
        // and measures duration from the wedge START (reconnectNeededSince), not the
        // last failed lookup — so a multi-minute outage isn't underreported.
        let helperBlock = try sourceBlock(
            in: source,
            startingAt: "private func logConnectivityRecoveredIfWedged",
            endingBefore: "private func clearReconnectNeededActivitySuppression"
        )
        XCTAssertTrue(helperBlock.contains("guard let wedgeStart = reconnectNeededSince else"))
        XCTAssertTrue(helperBlock.contains("now.timeIntervalSince(wedgeStart)"))
        // The activity row carries the wedge's failure reason + transport so
        // distinct-cause recoveries within the 30s coalescing window aren't merged.
        XCTAssertTrue(helperBlock.contains(".connectivityRecovered(reason: \"\\(failureReason) via \\(transport.rawValue)\")"))
        XCTAssertTrue(helperBlock.contains("event: \"dns-recovered\""))
        // ...and records whether the recovery was proven by real forwarding vs the
        // upstream-only smoke probe, so a false-positive recovery is diagnosable.
        XCTAssertTrue(helperBlock.contains("\"verifiedBy\": verifiedBy"))
        // The marker is cleared by the recovery (here), so a handoff recovery that
        // passes through the suppression clear on the network change is still caught.
        XCTAssertTrue(helperBlock.contains("reconnectNeededSince = nil"))
        // The failure depth is read from the marker (callers reset the live counter
        // before recovery), so the recovery log still records how deep the wedge got.
        XCTAssertTrue(helperBlock.contains("\"consecutiveUpstreamFailureCount\": \"\\(reconnectNeededPeakFailureCount)\""))

        // Wedge start is stamped once on entry; the peak failure depth is tracked
        // there too (where the live counter is still at its wedge value).
        let reconnectBlock = try sourceBlock(
            in: source,
            startingAt: "private func appendReconnectNeededIfPolicyRequiresReconnect",
            endingBefore: "private func selfReconnectIfPolicyAllows"
        )
        XCTAssertTrue(reconnectBlock.contains("if reconnectNeededSince == nil {"))
        XCTAssertTrue(reconnectBlock.contains("reconnectNeededPeakFailureCount = max(reconnectNeededPeakFailureCount, health.consecutiveUpstreamFailureCount)"))

        // The suppression clear must NOT drop the wedge marker (it runs on the
        // network-change/wake reset before the settle probe recovers). The marker is
        // owned by the recovery log + the lifecycle reset only.
        let clearBlock = try sourceBlock(
            in: source,
            startingAt: "private func clearReconnectNeededActivitySuppression",
            endingBefore: "#if LAVA_QA_TOOLS"
        )
        XCTAssertFalse(clearBlock.contains("reconnectNeededSince = nil"))
        let resetHealthBlock = try sourceBlock(
            in: source,
            startingAt: "private func resetHealth()",
            endingBefore: "private func startPathMonitor()"
        )
        XCTAssertTrue(resetHealthBlock.contains("reconnectNeededSince = nil"))
    }

    func testEncryptedFallbackSuccessRecordsServingSignalButNeverStampsTheWedgeMarker() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let recordBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordUpstreamResult",
            endingBefore: "private func updateResolverBackoff"
        )
        let fallbackBranch = try sourceBlock(
            in: recordBlock,
            startingAt: "if result.usedEncryptedFallback {",
            endingBefore: "} else {"
        )

        // The branch records the serving-fallback signal the policy reads for coverage...
        XCTAssertTrue(
            fallbackBranch.contains("health.lastEncryptedFallbackSuccessAt = now"),
            "The fallback branch must record the serving-fallback signal."
        )
        // ...but must NEVER stamp the wedge marker. The marker is overloaded (it flips
        // treatsResolverRejectionAsFallbackTrigger and survives path changes), so stamping it
        // for the covered state would bypass authoritative SERVFAIL/REFUSED. Coverage works via
        // the per-query fallback + the policy suppression; in-place recovery for the covered
        // state is a deferred follow-up that must not reuse this marker.
        XCTAssertFalse(
            fallbackBranch.contains("reconnectNeededSince = now"),
            "The encrypted-fallback branch must NOT stamp the wedge marker (it flips the rejection-as-fallback trigger)."
        )
    }

    func testPrimaryRecoveryClearsTheEncryptedFallbackServingTimestamp() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")

        // The serving signal must be cleared on a forwarding primary recovery so a stale
        // success can't cover a later outage's probe (the policy keys coverage on an absolute
        // freshness window, relying on this clear to scope it to the current outage).
        let recordBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordUpstreamResult",
            endingBefore: "private func updateResolverBackoff"
        )
        XCTAssertTrue(
            recordBlock.contains("health.lastPrimaryUpstreamSuccessAt = now")
                && recordBlock.contains("health.lastEncryptedFallbackSuccessAt = nil"),
            "A forwarding primary recovery must clear the encrypted-fallback serving timestamp."
        )

        // ...and on an accepted primary SMOKE-probe recovery (which never sets
        // lastPrimaryUpstreamSuccessAt), otherwise a smoke-only recovery would leave the stale
        // timestamp covering a new outage.
        let smokeBlock = try sourceBlock(
            in: source,
            startingAt: "private func applyResolverSmokeProbeResult",
            endingBefore: "private func invalidateInFlightSmokeProbes"
        )
        XCTAssertTrue(
            smokeBlock.contains("health.lastEncryptedFallbackSuccessAt = nil"),
            "An accepted primary smoke-probe recovery must clear the encrypted-fallback serving timestamp."
        )
    }

    func testWedgedResolverSelfRecoversWithoutAManualToggle() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")

        // The reconnect-needed path arms the in-place wedge recovery in addition
        // to the (rate-limited, on-demand-gated) self-reconnect, so a same-network
        // wedge recovers even when self-reconnect is suppressed.
        let reconnectBlock = try sourceBlock(
            in: source,
            startingAt: "private func appendReconnectNeededIfPolicyRequiresReconnect",
            endingBefore: "private func selfReconnectIfPolicyAllows"
        )
        XCTAssertTrue(reconnectBlock.contains("scheduleResolverWedgeRecoveryProbeIfNeeded()"))

        // The recovery clears the backoff penalty box + stale connections (the
        // clean slate a fresh process gets on a manual toggle) and re-probes; the
        // failed re-probe re-arms it, so it self-sustains at the wedge cadence.
        let recoveryBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverWedgeRecoveryProbeIfNeeded()",
            endingBefore: "private func cancelResolverWedgeRecoveryProbe()"
        )
        XCTAssertTrue(recoveryBlock.contains("resolverBackoffPolicy.reset()"))
        XCTAssertTrue(recoveryBlock.contains("resetResolverTransientState()"))
        // A wedge is often stale resolvers from a prior network — re-capture
        // device DNS before re-probing so the device-DNS user gets fresh addresses.
        XCTAssertTrue(recoveryBlock.contains("refreshDeviceDNSResolverAddressesOnDNSQueue(reason: \"resolver-wedge-recovery\")"))
        XCTAssertTrue(recoveryBlock.contains("scheduleResolverSmokeProbeIfNeeded(reason: isCoveredWedge ? \"covered-primary-recapture\" : \"resolver-wedge-recovery\")"))
        XCTAssertTrue(recoveryBlock.contains("assessment.primaryAction == .reconnect"))
        // The recovery loop re-arms on an escalating cadence (LAV-92 fast guide), not a flat
        // 30s interval, so a brief blip recovers in seconds while a sustained wedge backs off to
        // the legacy 30s ceiling. The flat constant must be gone.
        XCTAssertFalse(source.contains("resolverWedgeRecoveryProbeInterval"))
        XCTAssertTrue(source.contains("private let resolverWedgeRecoveryCadence = ResolverWedgeRecoveryCadence()"))
        XCTAssertTrue(recoveryBlock.contains("resolverWedgeRecoveryCadence.delay(forAttempt: resolverWedgeRecoveryAttempt)"))
        XCTAssertTrue(recoveryBlock.contains("resolverWedgeRecoveryAttempt += 1"))
        // The fast ramp is confined to the UNCOVERED down-wedge (user offline). A COVERED wedge
        // (online via encrypted fallback) keeps the gentle ceiling cadence and zeroes the ramp so
        // a later real down-wedge still starts fast.
        XCTAssertTrue(recoveryBlock.contains("ProtectionConnectivityPolicy.isEncryptedFallbackCoveringWedge(health: health, now: now)"))
        XCTAssertTrue(recoveryBlock.contains("resolverWedgeRecoveryCadence.maxInterval"))
        // A pending probe must be preempted whenever a SOONER one is now warranted (coverage lapsed,
        // or a down probe already backed off to the cap) — a deadline comparison that subsumes every
        // covered<->uncovered transition, so the offline user never waits out a stale timer
        // (Codex P2 ×2). The fire path and cancel/resetHealth clear the armed deadline.
        // Preempt a pending probe when the cadence MODE changed (covered<->uncovered) OR a sooner
        // probe is warranted within the same mode. The mode check stops a covered/online wedge from
        // being fast-probed (which could tear down a working fallback) AND speeds an offline user up
        // when coverage lapses (Codex P2 r1/r2/r5).
        XCTAssertTrue(recoveryBlock.contains("let modeChanged = resolverWedgeRecoveryArmedCovered != coveredNow"))
        XCTAssertTrue(recoveryBlock.contains("guard modeChanged || deadline < armedDeadline else {"))
        XCTAssertTrue(recoveryBlock.contains("resolverWedgeRecoveryArmedDeadline = deadline"))
        XCTAssertTrue(recoveryBlock.contains("resolverWedgeRecoveryArmedCovered = coveredNow"))
        // The fast ramp is floored at the recovery probe's ACTUAL smoke-probe timeout (computed the
        // same way the probe computes it — transport + device-DNS-fallback availability), so a
        // sooner re-arm can't fire a new probe while the previous one is still in flight and discard
        // it / churn the session. Covers encrypted AND fallback-capable plain primaries (Codex P2
        // r3/r4).
        XCTAssertTrue(recoveryBlock.contains("Self.smokeProbeTimeoutSeconds("))
        XCTAssertTrue(recoveryBlock.contains("reason: \"resolver-wedge-recovery\""))
        XCTAssertTrue(recoveryBlock.contains("delay = max(rampDelay, probeTimeout)"))
        // The fired probe finding the wedge already gone must end the episode (reset the ramp),
        // not strand the counter at a backed-off value for the next wedge (adversarial P2).
        XCTAssertGreaterThanOrEqual(
            recoveryBlock.components(separatedBy: "resolverWedgeRecoveryAttempt = 0").count - 1, 2,
            "the no-longer-wedged early return and the covered branch must both zero the ramp counter"
        )

        // Every recovery/success path funnels through the suppression clear, which
        // is the single cancel point that keeps the recovery loop bounded to the
        // actual wedge (no resetting a now-healthy resolver).
        let suppressionBlock = try sourceBlock(
            in: source,
            startingAt: "private func clearReconnectNeededActivitySuppression()",
            endingBefore: "#if LAVA_QA_TOOLS"
        )
        XCTAssertTrue(suppressionBlock.contains("cancelResolverWedgeRecoveryProbe()"))
        // Cancelling the probe (recovery / lifecycle reset) resets the episode counter so the
        // next wedge restarts the fast escalation ramp rather than inheriting a backed-off delay.
        XCTAssertTrue(source.contains("resolverWedgeRecoveryAttempt = 0"))
        // The lifecycle reset must also own wedge-probe teardown, so a reused provider instance
        // (manual stop/start without a process kill) can't inherit a stranded probe/counter
        // (adversarial P3 — resetHealth previously relied on stop always preceding start).
        let resetHealthBlock = try sourceBlock(
            in: source,
            startingAt: "private func resetHealth()",
            endingBefore: "private func startPathMonitor()"
        )
        XCTAssertTrue(resetHealthBlock.contains("cancelResolverWedgeRecoveryProbe()"))

        // A suppressed self-reconnect must be diagnosable from the Release log so a
        // "said reconnect needed but never recovered" report carries the reason.
        let selfReconnectBlock = try sourceBlock(
            in: source,
            startingAt: "private func selfReconnectIfPolicyAllows",
            endingBefore: "private static func loadSelfReconnectAttemptTimes"
        )
        XCTAssertTrue(selfReconnectBlock.contains("event: \"self-reconnect-suppressed\""))
        // ...but a persistent wedge must not flood the capped log: the line is gated
        // on a changed suppression signature or an elapsed cooldown, not emitted per tick.
        XCTAssertTrue(selfReconnectBlock.contains("lastSelfReconnectSuppressionSignature"))
        XCTAssertTrue(selfReconnectBlock.contains("if changed || cooldownElapsed {"))
    }

    func testRecordDeliveryOnlyAdvancesThrottleForProblems() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let recordBlock = try sourceBlock(
            in: source,
            startingAt: "private static func recordProtectionNotificationDelivery",
            endingBefore: "private static func removeSupersededProtectionNotifications"
        )

        // The 600s minimum-problem-delivery throttle keys off the delivered-at
        // timestamp; only a problem delivery may advance it. (Only actionable problem
        // banners are delivered now — no recovery acknowledgement.)
        let prefix = try sourceBlock(
            in: recordBlock,
            startingAt: "let defaults",
            endingBefore: "if notification.kind.isProblem {"
        )
        XCTAssertFalse(prefix.contains("protectionLastDeliveredNotificationAtDefaultsKey"))
        let problemBranch = try sourceBlock(
            in: source,
            startingAt: "if notification.kind.isProblem {",
            endingBefore: "private static func removeSupersededProtectionNotifications"
        )
        XCTAssertTrue(problemBranch.contains("protectionLastDeliveredNotificationAtDefaultsKey"))
        // No recovery-acknowledgement delivery path remains in recordDelivery.
        XCTAssertFalse(recordBlock.contains(".reconnected"))
    }

    func testEncryptedFallbackSilentClearAlsoLiftsTheDuplicateGuardID() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        // Back-dating `lastDeliveredAt` alone is not enough: the silent supersede removed
        // the reconnect banner, so the persisted last-delivered *id* must also be cleared.
        // Otherwise a lapse back to `.needsReconnect` with the same event id is suppressed by
        // notification(for:)'s exact-id duplicate guard until a later probe shifts the id,
        // defeating the back-dated cooldown. The clear must live in the cooldown branch so a
        // real `.healthy` recovery (cooldownAnchor == nil) keeps its duplicate guard intact.
        let cooldownBranch = try sourceBlock(
            in: source,
            startingAt: "if let cooldownAnchor {",
            endingBefore: "let requestIdentifiers = identifiers.map {"
        )
        XCTAssertTrue(
            cooldownBranch.contains("removeObject(forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey)"),
            "The encrypted-fallback silent clear must also clear the duplicate-guard id so a lapsed wedge re-posts."
        )
    }

    func testEncryptedFallbackCoverageClearsOnSustainedCarriedFailureNotASingleTransient() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        // In the covered state the primary is wedged, so the policy is re-assessed inside
        // the SAME recordUpstreamResult call (appendReconnectNeededIfPolicyRequiresReconnect)
        // with the smoke-failure count already at the reconnect threshold. So a lone
        // forwarding transient that cleared coverage would synchronously self-reconnect — the
        // LAV-80-class restart this path suppresses. The clear MUST be gated on a sustained
        // carried-query streak, never the first failure.
        let failureBranch = try sourceBlock(
            in: source,
            startingAt: "health.lastFailureReason = result.failureSummary",
            endingBefore: "health.upstreamSuccessCount += 1"
        )
        XCTAssertTrue(
            failureBranch.contains("consecutiveCarriedQueryFailureCount += 1"),
            "A real-forwarding total failure must advance the carried-query streak."
        )
        XCTAssertTrue(
            failureBranch.contains("if consecutiveCarriedQueryFailureCount >= encryptedFallbackCoverageClearFailureThreshold {"),
            "The encrypted-fallback coverage teardown must be GATED on a sustained streak, not the first failure."
        )
        XCTAssertTrue(
            failureBranch.contains("health.lastEncryptedFallbackSuccessAt = nil"),
            "A sustained carried-query outage must drop the fallback serving timestamp so the restart can surface."
        )
        // The gate must use the forwarding-only counter — NOT health.consecutiveUpstreamFailureCount,
        // which a failed PRIMARY smoke probe also bumps; that pollution is the over-escalation trap
        // (a lone transient layered on a smoke-inflated count).
        XCTAssertFalse(
            failureBranch.contains("consecutiveUpstreamFailureCount >="),
            "The coverage-clear gate must use the forwarding-only streak, not the smoke-polluted counter."
        )

        // A carried success resets the streak so a fresh outage re-accumulates from zero.
        let successBranch = try sourceBlock(
            in: source,
            startingAt: "health.upstreamSuccessCount += 1",
            endingBefore: "if result.usedEncryptedFallback {"
        )
        XCTAssertTrue(
            successBranch.contains("consecutiveCarriedQueryFailureCount = 0"),
            "Any carried success must reset the carried-query streak."
        )
    }

    func testEncryptedFallbackCoverageBackstopIsAFixedCarriedFailureCountByDesign() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        // LAV-96 removed the wall-clock freshness ceiling; the ONLY backstop that tears down
        // encrypted-fallback coverage on a still-wedged primary is now the carried-query FAILURE
        // STREAK. This pins that threshold so it can't silently drift, and records the deliberate
        // tradeoff Codex flagged on #104: with the ceiling gone, the first
        // (encryptedFallbackCoverageClearFailureThreshold - 1) real carried failures after an idle
        // window still read as covered and suppress the reconnect. That is INTENTIONAL — clearing
        // on a lone transient would synchronously fire the LAV-80-class restart this path exists to
        // prevent (locked by testEncryptedFallbackCoverageClearsOnSustainedCarriedFailureNotASingleTransient).
        // A genuine page load bursts many DNS queries, so the streak trips near-instantly under
        // real use; only a near-idle device waits, where the user is not actively resolving. Tuning
        // the count down — faster escalation in the dead-everything-after-idle case — is LAV-93's
        // within-identity escalation scope, deliberately deferred from LAV-96.
        XCTAssertTrue(
            source.contains("private let encryptedFallbackCoverageClearFailureThreshold = 3"),
            "The encrypted-fallback coverage backstop is a fixed 3-carried-failure streak (LAV-96 design; tuning is LAV-93)."
        )
    }

    func testCoveredWedgeRecaptureRunsWithoutTheMarkerAndDoesNotChurnTheFallback() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let scheduleBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverWedgeRecoveryProbeIfNeeded()",
            endingBefore: "private func cancelResolverWedgeRecoveryProbe()"
        )

        // The covered wedge (encrypted fallback carrying a transition-stale primary) holds
        // no marker, so the accelerated recovery probe must re-confirm on the policy's coverage
        // predicate — the explicit named helper, derived purely from health — alongside the
        // down-wedge signals, or it would abort and strand the primary on the fallback.
        XCTAssertTrue(scheduleBlock.contains("let isCoveredWedge = ProtectionConnectivityPolicy.isEncryptedFallbackCoveringWedge(health: self.health, now: now)"))
        // The loop stays ALIVE on the broader carrying signal (survives a rejected recapture probe,
        // which flips the gated covered predicate false while the marker is unstamped); isCoveredWedge
        // still drives the recapture reason + churn-skip.
        XCTAssertTrue(scheduleBlock.contains("let isCarryingFallback = ProtectionConnectivityPolicy.isEncryptedFallbackCarryingWedge(health: self.health, now: now)"))
        XCTAssertTrue(scheduleBlock.contains("isDownWedge || isCarryingFallback"))
        XCTAssertTrue(scheduleBlock.contains("\"covered-primary-recapture\""))

        // HARD CONSTRAINT — the reason recovery-in-place was deferred: the covered recapture
        // must NEVER stamp `reconnectNeededSince`. Stamping it feeds currentDeviceResolverWedged
        // into DNSResolverRuntimePlan, flipping treatsResolverRejectionAsFallbackTrigger and
        // bypassing authoritative SERVFAIL/REFUSED on a freshly handed-off network.
        XCTAssertFalse(
            scheduleBlock.contains("reconnectNeededSince ="),
            "Covered-state recapture must not stamp the overloaded wedge marker."
        )

        // The DoH/DoT session churn must be gated to a DOWN wedge that the fallback is NOT
        // carrying. In the covered state — INCLUDING the overlap where a stale down-wedge
        // marker is also held — those sessions are ACTIVELY carrying the fallback, so resetting
        // them would disrupt the very path keeping the user online. The `!isCoveredWedge`
        // conjunct is what suppresses the churn when the marker is held but coverage is live.
        let gatedResetRegion = try sourceBlock(
            in: scheduleBlock,
            startingAt: "self.resolverBackoffPolicy.reset()",
            endingBefore: "self.scheduleResolverSmokeProbeIfNeeded("
        )
        XCTAssertTrue(
            gatedResetRegion.contains("if isDownWedge, !isCoveredWedge {"),
            "resetResolverTransientState must skip the churn whenever coverage is live, even if the wedge marker is also held."
        )
        XCTAssertTrue(gatedResetRegion.contains("resetResolverTransientState()"))
    }

    func testCoveredWedgeRecaptureLoopReArmsWithoutTheMarker() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        // The smoke-probe-failure path re-arms the recovery loop on the marker for the down
        // wedge; the covered wedge holds none, so it must ALSO re-arm on the carrying signal
        // (isEncryptedFallbackCarryingWedge = covering MINUS the rejected==0 gate, still requiring a
        // failed smoke-probe context — survives a rejected recapture probe, unlike the gated
        // covering predicate), else the covered recapture loop stalls after its own rejected
        // re-probe until the 300s routine probe.
        XCTAssertTrue(
            source.contains("if currentDeviceResolverWedged() || ProtectionConnectivityPolicy.isEncryptedFallbackCarryingWedge(health: health, now: now) {"),
            "The covered recapture loop must re-arm on the fallback-carrying signal in the smoke-failure path."
        )
    }

    func testDeviceResolverWedgedStaysPurelyTheDownWedgeMarker() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        // HARD CONSTRAINT (the reason the covered recapture got its own read, not the marker):
        // currentDeviceResolverWedged() — which feeds DNSResolverRuntimePlan.make's
        // deviceResolverWedged and thus treatsResolverRejectionAsFallbackTrigger (the
        // authoritative-SERVFAIL/REFUSED bypass) — must read ONLY reconnectNeededSince, never the
        // encrypted-fallback coverage signal. If a future edit routes coverage through here, a
        // transition blip would start bypassing authoritative rejections.
        let wedgedBlock = try sourceBlock(
            in: source,
            startingAt: "private func currentDeviceResolverWedged() -> Bool {",
            endingBefore: "private func orderedResolverAddressesForCurrentNetwork"
        )
        XCTAssertTrue(wedgedBlock.contains("reconnectNeededSince != nil"))
        XCTAssertFalse(
            wedgedBlock.contains("EncryptedFallback") || wedgedBlock.contains("isEncryptedFallbackCoveringWedge"),
            "currentDeviceResolverWedged() must stay purely the down-wedge marker — no coverage signal."
        )
        // And the rejection-trigger feed stays the marker only.
        XCTAssertTrue(source.contains("deviceResolverWedged: currentDeviceResolverWedged()"))
    }

    func testCarriedQueryFailureStreakResetsOnContextResets() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        // The episode-scoped carried-query failure streak must be cleared by the context-reset
        // paths (a network change / recovery and a fresh tunnel session), not only by a later
        // forwarding success — otherwise a 1–2 count from a prior episode carries over and the
        // first carried failure in the next one tears down a freshly-serving fallback.
        let recoveryReset = try sourceBlock(
            in: source,
            startingAt: "private func resetFailureAndFallbackStateForRecovery()",
            endingBefore: "private func invalidateInFlightSmokeProbes("
        )
        XCTAssertTrue(
            recoveryReset.contains("consecutiveCarriedQueryFailureCount = 0"),
            "A network-change / recovery reset must clear the carried-query failure streak."
        )
        let healthReset = try sourceBlock(
            in: source,
            startingAt: "private func resetHealth()",
            endingBefore: "private func startPathMonitor("
        )
        XCTAssertTrue(
            healthReset.contains("consecutiveCarriedQueryFailureCount = 0"),
            "A fresh tunnel session (resetHealth) must clear the carried-query failure streak."
        )
        // A resolver-runtime reset (config / preset change) also opens a fresh fallback episode.
        let runtimeReset = try sourceBlock(
            in: source,
            startingAt: "private func collectPendingResponsesAndResetResolverRuntime(",
            endingBefore: "private func writeServerFailures("
        )
        XCTAssertTrue(
            runtimeReset.contains("consecutiveCarriedQueryFailureCount = 0"),
            "A resolver-runtime reset must clear the carried-query failure streak for the new resolver context."
        )
        // The DNS-health-context baseline keys on lastResolverIdentityChangeAt, which must be bumped
        // ONLY on an actual PRIMARY-resolver switch — never a forced same-resolver runtime reset, and
        // never a fallback-only change (the full identifier moves, but the primary identity does not) —
        // so a benign reload / fallback swap can't advance the baseline and hide a still-wedged primary.
        XCTAssertTrue(
            runtimeReset.contains("if let previousPrimaryIdentifier, previousPrimaryIdentifier != currentPrimaryIdentifier {")
                && runtimeReset.contains("health.lastResolverIdentityChangeAt = Date()"),
            "lastResolverIdentityChangeAt must be gated on an actual PRIMARY-resolver-identity change."
        )

        // The identity-scoped rejected streak must be cleared ONLY on a genuine identity change
        // (stale evidence about the old resolver would otherwise block the new resolver's coverage
        // via the round-19 nonzero-count gate) — and NEVER on a same-resolver reset, so it survives
        // the network-flap churn LAV-87 relies on.
        let identityChangeBranch = try sourceBlock(
            in: runtimeReset,
            startingAt: "if let previousPrimaryIdentifier, previousPrimaryIdentifier != currentPrimaryIdentifier {",
            endingBefore: "return pendingResponses"
        )
        XCTAssertTrue(
            identityChangeBranch.contains("health.consecutiveRejectedSmokeResponseCount = 0")
                && identityChangeBranch.contains("health.rejectedSmokeResponseResolverIdentity = nil"),
            "A genuine resolver-identity change must clear the stale identity-scoped rejected streak."
        )
        let beforeIdentityBranch = try sourceBlock(
            in: runtimeReset,
            startingAt: "consecutiveCarriedQueryFailureCount = 0",
            endingBefore: "if let previousPrimaryIdentifier, previousPrimaryIdentifier != currentPrimaryIdentifier {"
        )
        XCTAssertFalse(
            beforeIdentityBranch.contains("consecutiveRejectedSmokeResponseCount"),
            "The rejected streak must NOT be cleared on a same-resolver reset (LAV-87 churn survival)."
        )
        // The encrypted-fallback COVERAGE timestamp must be invalidated on ANY runtime reset (it
        // is fallback-side state — a fallback-only change leaves the primary baseline untouched, so
        // a just-disabled / swapped fallback would otherwise keep suppressing reconnect via its
        // stale success). It is in the always-runs reset block, NOT the primary-identity branch.
        XCTAssertTrue(
            beforeIdentityBranch.contains("health.lastEncryptedFallbackSuccessAt = nil"),
            "A runtime reset must invalidate the encrypted-fallback coverage timestamp (fallback-side state)."
        )
    }

    // (LAV-96) The former `testEncryptedFallbackCoverageWindowExceedsRecoveryProbeCadence`
    // invariant was removed with the `encryptedFallbackCoverageWindow` constant: coverage no
    // longer lapses on a wall-clock timer, so there is no window-vs-cadence knife-edge to lock.
    // The new behaviour (idle does not lapse coverage; a sustained carried-query failure does)
    // is locked behaviourally in ProtectionConnectivityPolicyTests.

    func testEncryptedFallbackCoverageLiftsDuplicateGuardWithNoOutstandingBanner() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        // Tunnel-side mirror of the app: coverage with no outstanding banner must still lift the
        // exact-id duplicate guard so a later lapse to a same-second reconnect id isn't suppressed.
        let coverageBranch = try sourceBlock(
            in: source,
            startingAt: "} else if assessment.severity == .usingEncryptedFallback {",
            endingBefore: "// Use the pre-clear"
        )
        XCTAssertTrue(
            coverageBranch.contains("removeObject(forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey)"),
            "Coverage with no outstanding banner must lift the duplicate-guard id (tunnel consumer)."
        )
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

        // Once the new network settles, re-capture device DNS — the capture at the
        // instant of a handoff can preserve the previous network's (now
        // unreachable) resolvers, which wedge a device-DNS user until the next
        // change. Reset the runtime only when the addresses actually changed.
        XCTAssertTrue(settleProbeBlock.contains("refreshDeviceDNSResolverAddressesOnDNSQueue(reason: \"network-settled\")"))
        XCTAssertTrue(settleProbeBlock.contains("deviceDNSResolverAddresses != previousDeviceDNSResolverAddresses"))

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
            endingBefore: "private func reusableCompactSnapshot("
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

    func testTunnelArtifactReadsResolveThroughThePointer() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")

        // The tunnel must read artifacts through the published pointer (versioned dir,
        // root fallback), not by hardcoding the root container artifact paths.
        XCTAssertTrue(
            source.contains("FilterArtifactStore(directoryURL: containerURL).readableStore()"),
            "Tunnel artifact reads must resolve through readableStore() (pointer -> versioned, root fallback)."
        )

        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadCompiledSnapshot(",
            endingBefore: "private func reusableCompactSnapshot("
        )
        XCTAssertTrue(
            loadBlock.contains("readableArtifactStore()"),
            "loadCompiledSnapshot must resolve the pointer store."
        )
        XCTAssertTrue(
            loadBlock.contains("FilterArtifactStore(directoryURL: containerURL)"),
            "A resolved-store miss must fall back to the fresh root store before recompiling."
        )
        XCTAssertTrue(
            loadBlock.contains("reusableCompactSnapshot(") && loadBlock.contains("reusablePreparedSnapshot("),
            "Both reads must go through the reuse+budget gated helpers (no decode before the gate)."
        )
    }

    func testTunnelKeepsLastKnownGoodOnFailedReloadAndDoesNotFlicker() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")

        // A reload must only DISCARD the resident snapshot pre-decode when a reusable,
        // in-budget artifact is present (the decode is then all-but-certain). Otherwise
        // the resident is kept so a build failure (e.g. a stale-pinned-hash refresh)
        // degrades to "keep last-known-good", never to fail-closed.
        XCTAssertTrue(
            source.contains("let hasReusableArtifact = self.readCompactSnapshotSummary(configuration: configuration) != nil"),
            "Pre-decode discard must be gated on a reusable artifact being present."
        )
        // Keep-last-known-good must require the resident to be a genuine FILTERING
        // snapshot. A non-nil identity also covers the permissive pass-through built for
        // an empty config; keeping that when the new config wants filtering would fail
        // OPEN (protection connected, nothing filtered). So the keep guard must also test
        // currentResidentSnapshotHasEnabledFilters(); otherwise it falls through to
        // fail-closed.
        XCTAssertTrue(
            source.contains("if hasResidentSnapshot && !freedResidentBeforeDecode && self.currentResidentSnapshotHasEnabledFilters() {"),
            "A failed reload may only keep last-known-good when the resident is a genuine filtering snapshot."
        )
        XCTAssertTrue(
            source.contains("residentHasEnabledFilters: !configuration.enabledBlocklistIDs.isEmpty"),
            "The resident's filtering status must be committed atomically with the loaded snapshot."
        )
        XCTAssertTrue(
            source.contains("event: \"loadSnapshot-reload-failed-keeping-resident\""),
            "Keeping last-known-good on a failed reload must be observable."
        )

        // Clearing the snapshot-unavailable marker from a detached reload branch (no-op,
        // keep-resident, filters-disabled) must be generation-gated, so a stale reload
        // can't erase a newer reload's fail-closed marker and re-arm the self-reconnect
        // loop. The ungated setter must not exist for the clear path.
        XCTAssertTrue(
            source.contains("private func clearResidentFailClosedDueToUnavailableSnapshot(ifCurrentGeneration generation: UInt64)"),
            "Marker clears from detached reload branches must be generation-gated."
        )
        XCTAssertFalse(
            source.contains("setResidentFailClosedDueToUnavailableSnapshot(false)"),
            "Marker must never be cleared ungated (use the generation-gated clear)."
        )

        // A snapshot-unavailable fail-closed must NOT escalate to a self-reconnect
        // restart loop (the wedge that bricked Guard). The suppression guard must run
        // BEFORE the reconnect policy decision.
        let reconnectBlock = try sourceBlock(
            in: source,
            startingAt: "private func selfReconnectIfPolicyAllows(",
            endingBefore: "private static func isOnDemandConfirmedEnabled("
        )
        let guardRange = try XCTUnwrap(reconnectBlock.range(of: "guard !isResidentFailClosedDueToUnavailableSnapshot() else {"))
        let decisionRange = try XCTUnwrap(reconnectBlock.range(of: "TunnelSelfReconnectPolicy.decision("))
        XCTAssertTrue(
            guardRange.lowerBound < decisionRange.lowerBound,
            "Self-reconnect must be suppressed for a snapshot-unavailable fail-closed before the policy decision."
        )
        XCTAssertTrue(
            reconnectBlock.contains("event: \"self-reconnect-suppressed-snapshot-unavailable\""),
            "Suppressing self-reconnect for an unavailable snapshot must be observable."
        )
    }

    func testTunnelServesLastKnownGoodOnColdStartBuildFailure() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")

        // The live-reload keep-resident path only protects reloads that have an in-memory
        // resident. On a COLD start (forced by a DNS-handoff self-reconnect) there is no
        // resident, so a failed fresh (re)compile — the rotating-upstream / stale-pinned-
        // hash wedge — would fail CLOSED and clear protection to zero. loadCompiledSnapshot
        // must instead serve a config-matched last-known-good artifact from disk.
        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadCompiledSnapshot(",
            endingBefore: "private func reusableCompactSnapshot("
        )

        // The compile-error catch must fall back, not return nil/fail-closed directly.
        let compileErrorRange = try XCTUnwrap(
            loadBlock.range(of: "event: \"loadSnapshot-cache-compile-error\"")
        )
        let fallbackCallRange = try XCTUnwrap(
            loadBlock.range(
                of: "return serveLastKnownGoodOrFailClosed()",
                range: compileErrorRange.upperBound ..< loadBlock.endIndex
            )
        )
        XCTAssertTrue(
            compileErrorRange.upperBound <= fallbackCallRange.lowerBound,
            "A failed in-extension recompile must attempt the last-known-good fallback, not fail closed directly."
        )

        // An over-budget FRESH compile (a same-config rotation can grow a source past the
        // budget while an older in-budget artifact for the same config still exists) must
        // also route through the fallback, not return nil and clear protection. The fallback
        // is itself budget-gated, so it can only ever serve an in-budget last-known-good.
        let overBudgetRange = try XCTUnwrap(
            loadBlock.range(of: "event: \"loadSnapshot-compiled-over-budget\"")
        )
        let overBudgetFallbackRange = try XCTUnwrap(
            loadBlock.range(
                of: "return serveLastKnownGoodOrFailClosed()",
                range: overBudgetRange.upperBound ..< loadBlock.endIndex
            )
        )
        XCTAssertTrue(
            overBudgetRange.upperBound <= overBudgetFallbackRange.lowerBound,
            "An over-budget fresh compile must attempt the last-known-good fallback before failing closed."
        )

        // The fallback is gated on the user wanting filtering (non-empty config) AND on
        // there being no keepable resident, so an empty config still returns the permissive
        // pass-through and a live reload keeps its in-memory snapshot.
        XCTAssertTrue(
            loadBlock.contains("if !hasKeepableFilteringResident, !configuration.enabledBlocklistIDs.isEmpty {"),
            "The last-known-good fallback must only serve for a filtering config with no keepable resident."
        )
        XCTAssertTrue(
            loadBlock.contains("event: \"loadSnapshot-last-known-good\""),
            "Serving a last-known-good artifact on a failed cold-start build must be observable."
        )

        // The disk decode is COLD-START ONLY: it must be gated on there being no keepable
        // filtering resident, so a live reload that still holds a healthy resident keeps it
        // in memory (the caller's existing keep-resident branch) instead of decoding a
        // multi-MB artifact and risking the 2x-resident jetsam peak.
        let keepableGateRange = try XCTUnwrap(
            loadBlock.range(of: "let hasKeepableFilteringResident = self.currentResidentSnapshotIdentity() != nil")
        )
        XCTAssertTrue(
            loadBlock.contains("&& self.currentResidentSnapshotHasEnabledFilters()"),
            "The keepable-resident gate must require the resident to be a genuine filtering snapshot."
        )
        let lastKnownGoodEventRange = try XCTUnwrap(
            loadBlock.range(of: "event: \"loadSnapshot-last-known-good\"")
        )
        XCTAssertTrue(
            keepableGateRange.upperBound <= lastKnownGoodEventRange.lowerBound,
            "The disk last-known-good decode must be gated on no keepable filtering resident (cold-start only)."
        )

        // The fallback reader must use the config-only gate (canServeAsLastKnownGood),
        // NOT the strict catalog-hash gate — otherwise it would reject the very artifact
        // the rotated catalog invalidated and we would still fail closed.
        let fallbackBlock = try sourceBlock(
            in: source,
            startingAt: "private func lastKnownGoodCompactSnapshot(",
            endingBefore: "private func reusablePreparedSnapshot("
        )
        XCTAssertTrue(
            fallbackBlock.contains("summary.canServeAsLastKnownGood(for: configuration)"),
            "The last-known-good reader must gate on the config-only predicate, not the strict catalog-hash gate."
        )
        XCTAssertTrue(
            fallbackBlock.contains("FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: ruleCount)"),
            "The last-known-good reader must still enforce the compact memory budget before decoding."
        )
    }

    func testReusablePreparedSnapshotRebindsToManifestAndRebudgetsAfterDecode() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let preparedBlock = try sourceBlock(
            in: source,
            startingAt: "private func reusablePreparedSnapshot(",
            endingBefore: "private func loadPreparedSnapshot("
        )

        // The manifest and prepared file are read separately, so a concurrent root
        // republish can pair an in-budget manifest with over-budget prepared bytes.
        // The decoded prepared must be re-bound to the manifest it was budget-gated on
        // (identity + generatedAt + summary, mirroring FilterArtifactStore.preparedSelection)
        // and re-budgeted against its OWN summary before it can become resident — never
        // weaker than the baseline it replaced.
        XCTAssertTrue(
            preparedBlock.contains("prepared.identity == manifest.snapshotIdentity"),
            "Prepared decode must re-bind to the manifest identity (no manifest<->prepared skew)."
        )
        XCTAssertTrue(
            preparedBlock.contains("prepared.snapshot.generatedAt == manifest.generatedAt"),
            "Prepared decode must re-bind to the manifest generation."
        )
        XCTAssertTrue(
            preparedBlock.contains("prepared.summary == manifest.summary"),
            "Prepared decode must re-bind to the manifest summary (the budget-gated counts)."
        )
        // Authority budget gate is the DECODED prepared's own counts, not the manifest's.
        XCTAssertTrue(
            preparedBlock.contains("let ruleCount = prepared.summary.blockRuleCount + prepared.summary.allowRuleCount + prepared.summary.guardrailRuleCount"),
            "Budget must be re-checked against the decoded prepared's own summary post-decode."
        )
        XCTAssertTrue(
            preparedBlock.contains("FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: ruleCount)"),
            "An over-budget decoded prepared must be refused before becoming resident."
        )
    }

    func testTunnelDoesNotFallBackToUnboundLegacySnapshots() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadCompiledSnapshot(",
            endingBefore: "private func reusableCompactSnapshot("
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
        // The in-extension compile streams sources into a memory-mapped CompactFilterSnapshot
        // (never a dirty union), so the resident snapshot is the 9 B/rule mapped-compact form
        // and the last-line resident gate is the compact device budget (`exceedsBudget` /
        // `maxFilterRuleCount`) — the same ceiling the app's mapped artifact uses. The
        // streaming compiler enforces its own (lower) transient ceiling and fails closed
        // before this point. A post-upgrade re-parse that overshoots fails closed instead of
        // jetsamming the extension.
        XCTAssertTrue(loadBlock.contains("FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: compiledRuleCount)"))
        XCTAssertTrue(loadBlock.contains("configuration.enabledBlocklistIDs.isEmpty ? (baseSnapshot, expectedIdentity) : nil"))
        XCTAssertTrue(loadBlock.contains("CachedFilterSnapshotCompiler(\n                cacheDirectoryURL: catalogCacheURL\n            )"))
        // Scratch from a jetsam-killed compile is reclaimed ONCE at startTunnel, before any
        // reload spawns a compile — NOT per-compile, which would race a concurrent reload's
        // in-flight scratch dir. So the sweep must be absent from the compile path and sit
        // immediately before the startTunnel snapshot load.
        XCTAssertFalse(loadBlock.contains("sweepStaleScratch"))
        XCTAssertTrue(source.contains(
            "CachedFilterSnapshotCompiler.sweepStaleScratch(cacheDirectoryURL: catalogCacheURL)\n            }\n            self.loadSnapshotInBackground(reason: \"startTunnel\""
        ))
        XCTAssertTrue(initialStateBlock.contains("FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)"))
        XCTAssertTrue(loadSnapshotBlock.contains("FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)"))
        XCTAssertTrue(loadSnapshotBlock.contains("\"resolver\": configuration.resolverDiagnosticDisplayName"))
        XCTAssertFalse(loadSnapshotBlock.contains("\"resolver\": runtimeSnapshot.resolver.displayName"))
    }

    func testLoadInitialSharedStatePersistsAPruneThatHappenedDuringLoad() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let initialStateBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadInitialSharedState()",
            endingBefore: "private func refreshConfigurationIfNeeded"
        )

        // A prune performed inside DiagnosticsPersistence.load (the fine-grained retention
        // window elapsed at an idle start) sets the store's pending-prune flag, NOT the
        // persistence controller's dirty flag — so loadInitialSharedState must consume that
        // flag and force a persist, or the stale on-disk events linger until the next DNS
        // event dirties diagnostics, breaking the on-disk retention guarantee.
        XCTAssertTrue(initialStateBlock.contains("consumePendingFineGrainedPrunePersist()"))
        XCTAssertTrue(initialStateBlock.contains("prunedDuringLoad || diagnosticsPersistence.isDirty"))
        XCTAssertTrue(initialStateBlock.contains("persistDiagnosticsIfNeeded(force: true)"))
    }

    func testLoadInitialSharedStateWarmResumesFromDiskBeforeFailingClosed() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let initialStateBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadInitialSharedState()",
            endingBefore: "private func refreshConfigurationIfNeeded"
        )
        let bootstrapBlock = try sourceBlock(
            in: source,
            startingAt: "private func bootstrapResidentSnapshotFromDisk(",
            endingBefore: "private func reusablePreparedSnapshot("
        )

        // A non-empty config attempts a synchronous on-disk fast-resume BEFORE installing the
        // block-all FailClosedRuntimeSnapshot — eliminating the cold-start (post-self-reconnect)
        // false-positive window whenever a serviceable in-budget artifact exists.
        XCTAssertTrue(initialStateBlock.contains("bootstrapResidentSnapshotFromDisk(configuration: configuration)"))
        // Resume installs a real resident: wrapped like the async commit, identity set so the
        // immediately-following async load hits the no-op reload gate, and marked filtering.
        XCTAssertTrue(initialStateBlock.contains("base: resumed.snapshot"))
        XCTAssertTrue(initialStateBlock.contains("bootstrapIdentity = resumed.identity"))
        XCTAssertTrue(initialStateBlock.contains("bootstrapHasEnabledFilters = true"))
        // NEVER fail open: no serviceable / over-cap artifact still installs fail-closed.
        XCTAssertTrue(initialStateBlock.contains("FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)"))
        // The bootstrap FULLY OWNS the resident markers in EVERY branch (unconditional reset),
        // so a same-instance startTunnel retry after a setTunnelNetworkSettings failure cannot
        // carry a stale "healthy filtering resident" marker into a later fail-closed bootstrap
        // (Codex P2 — would make the async loader keep the block-all snapshot unmarked).
        XCTAssertTrue(initialStateBlock.contains("residentSnapshotIdentity = bootstrapIdentity"))
        XCTAssertTrue(initialStateBlock.contains("residentSnapshotHasEnabledFilters = bootstrapHasEnabledFilters"))
        XCTAssertTrue(initialStateBlock.contains("residentFailClosedDueToUnavailableSnapshot = false"))
        // The resident-state install is confined to snapshotQueue: a detached snapshot load from
        // a prior provider lifecycle (not cancelled on stop/restart) may read these queue-guarded
        // markers concurrently with this new start. Two critical sections: release-before-decode
        // then install — the release frees a same-instance restart's prior resident so the
        // bootstrap decode doesn't stack into a 2x-resident jetsam peak.
        XCTAssertEqual(initialStateBlock.components(separatedBy: "snapshotQueue.sync {").count - 1, 2)
        XCTAssertTrue(initialStateBlock.contains("snapshot = FilterSnapshot(blockRules: DomainRuleSet())"))

        // The bootstrap reuses the SAME budget/header-gated strict-reuse helper as the async path
        // — and deliberately does NOT serve last-known-good (that would risk under-blocking with
        // stale rules when the current artifact is reusable-but-over-cap).
        XCTAssertTrue(bootstrapBlock.contains("reusableCompactSnapshot("))
        XCTAssertFalse(bootstrapBlock.contains("lastKnownGoodCompactSnapshot("))
        XCTAssertTrue(bootstrapBlock.contains("Self.maxSynchronousBootstrapRuleCount"))
        XCTAssertTrue(source.contains("maxSynchronousBootstrapRuleCount = 1_000_000"))
        // The gate MUST run via the skip-only readSyncBootstrapInfo BEFORE any reuse/LKG read
        // (which call readSummary): it both caps the size AND excludes legacy (pre-summary-schema)
        // artifacts, which readSummary would full-decode — and reusableCompactSnapshot would then
        // decode again — doubling the synchronous decode on cold start.
        XCTAssertTrue(bootstrapBlock.contains("CompactFilterSnapshot.readSyncBootstrapInfo(from: data)"))
        XCTAssertTrue(bootstrapBlock.contains("info.hasStoredSummary"))
        XCTAssertTrue(bootstrapBlock.contains("info.totalRuleCount > cap"))
        // The pre-gate is best-effort; the cap is RE-ENFORCED authoritatively inside
        // reusableCompactSnapshot on the same mmapped bytes it decodes, so an atomic republish
        // between the two reads can't slip an over-cap artifact into a synchronous decode.
        XCTAssertTrue(bootstrapBlock.contains("syncDecodeRuleCap: cap"))
        XCTAssertTrue(source.contains("syncDecodeRuleCap: Int? = nil"))
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
        XCTAssertTrue(loadBlock.contains("compactSnapshotRuleCountExceedingBudget(configuration: configuration)"))
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

    func testDeviceDebugLogShipsInReleaseForFeedbackReport() throws {
        let appGroup = try readSource("Shared/AppGroup.swift")
        // The device debug log is compiled in all configurations (including
        // Release/TestFlight) so the optional Feedback report can carry on-device
        // VPN diagnostics. A privacy audit confirmed no event records a queried
        // domain. Guard against accidental re-gating behind #if DEBUG.
        let enumIndex = try XCTUnwrap(appGroup.range(of: "enum LavaSecDeviceDebugLog {")?.lowerBound)
        let prefix = String(appGroup[..<enumIndex])
        XCTAssertFalse(
            prefix.hasSuffix("#if DEBUG || LAVA_QA_TOOLS\n"),
            "LavaSecDeviceDebugLog must stay un-gated so Release builds emit the device log."
        )
        XCTAssertFalse(
            prefix.hasSuffix("#if DEBUG\n"),
            "LavaSecDeviceDebugLog must stay un-gated so Release builds emit the device log."
        )

        // The core network-change DNS-recovery events must fire in Release: no bare
        // `#if DEBUG` may remain wrapping a device-log append in the tunnel.
        let tunnel = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        XCTAssertFalse(
            tunnel.contains("#if DEBUG\n            LavaSecDeviceDebugLog.append")
                || tunnel.contains("#if DEBUG\n        LavaSecDeviceDebugLog.append"),
            "Tunnel device-log appends must not be re-gated behind #if DEBUG."
        )
    }

    func testEncryptedTransportsEmitHandshakeObservations() throws {
        let dotSource = try readSource("Sources/LavaSecCore/DoTTransport.swift")
        let doqSource = try readSource("Sources/LavaSecCore/DoQTransport.swift")
        let dohSource = try readSource("Sources/LavaSecCore/DoHTransport.swift")

        // Handshake cost is the per-connection sub-phase under an endpoint
        // attempt; it is reported when a debug logger is injected (the tunnel now
        // injects one in all configurations), measured connect -> ready / connect
        // timings.
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

        // The tunnel injects the device-debug-log sink into every transport
        // unconditionally (including Release) so the optional Feedback report can
        // carry resolver handshake/health observations. The injected details are
        // audited to never include a queried domain — only endpoints and timings.
        let tunnelSource = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        XCTAssertTrue(tunnelSource.contains("private let dohResolver = DoHTransport(timeoutSeconds: PacketTunnelProvider.dohTimeoutSeconds) { event, details in"))
        XCTAssertTrue(tunnelSource.contains("private let dotResolver = DoTTransport(timeoutSeconds: PacketTunnelProvider.dotTimeoutSeconds) { event, details in"))
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
        let prewarmBlock = try sourceBlock(
            in: source,
            startingAt: "private func prewarmResolverBootstrapIfNeeded",
            endingBefore: "private func resolveDoQBootstrapAddresses"
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
        // A custom doq:// encrypted fallback keeps its hostname in the nested plan, so
        // the bootstrap (and the prewarm) must consider the fallback's DoQ endpoints
        // too — otherwise its lookup recurses through the wedged Device DNS.
        XCTAssertTrue(doqBootstrapResponseBlock.contains("resolverConfiguration.encryptedFallbackDoQEndpoints"))
        XCTAssertTrue(prewarmBlock.contains("resolverConfiguration.encryptedFallbackDoQEndpoints"))
        XCTAssertTrue(doqBootstrapResponseBlock.contains("DomainName.normalize(question.domain)"))
        XCTAssertTrue(doqBootstrapResponseBlock.contains("DomainName.normalize(endpoint.hostname)"))
        XCTAssertTrue(doqBootstrapResponseBlock.contains("doqEndpointResolvingBootstrapIfNeeded(endpoint)"))
        XCTAssertTrue(doqBootstrapResponseBlock.contains("DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: bootstrappedEndpoint)"))
        XCTAssertTrue(doqTransportSource.contains("NWConnection(host: NWEndpoint.Host(endpoint.hostname), port: port, using: parameters)"))
        XCTAssertFalse(doqTransportSource.contains("NWEndpoint.Host(connectionHost)"))
        XCTAssertFalse(doqTransportSource.contains("sec_protocol_options_set_verify_block"))
    }

    func testDoTBootstrapsCustomHostnamesBeforeForwarding() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let packetHandlerBlock = try sourceBlock(
            in: source,
            startingAt: "private func handle(packet: Data, protocolNumber: NSNumber)",
            endingBefore: "private func forward("
        )
        let dotBootstrapResponseBlock = try sourceBlock(
            in: source,
            startingAt: "private func dotBootstrapResponse",
            endingBefore: "private func startPeriodicResolverSmokeProbe"
        )
        let resolveBlock = try sourceBlock(
            in: source,
            startingAt: "private func dotEndpointResolvingBootstrapIfNeeded",
            endingBefore: "private func doqEndpointResolvingBootstrapIfNeeded"
        )
        let prewarmBlock = try sourceBlock(
            in: source,
            startingAt: "private func prewarmResolverBootstrapIfNeeded",
            endingBefore: "private func resolveDoQBootstrapAddresses"
        )

        // The packet path must intercept DoT hostnames too (a custom `tls://` fallback
        // or primary connects by hostname when it has no bootstrap IPs), so the lookup
        // is answered from cached bootstrap IPs rather than recursing through a wedged
        // Device DNS — mirroring DoH/DoQ.
        XCTAssertTrue(packetHandlerBlock.contains("dotBootstrapResponse("))
        XCTAssertTrue(dotBootstrapResponseBlock.contains("resolverConfiguration.encryptedFallbackDoTEndpoints"))
        XCTAssertTrue(dotBootstrapResponseBlock.contains("resolverConfiguration.transport == .dnsOverTLS"))
        XCTAssertTrue(dotBootstrapResponseBlock.contains("dotEndpointResolvingBootstrapIfNeeded(endpoint)"))
        XCTAssertTrue(dotBootstrapResponseBlock.contains("guard !bootstrappedEndpoint.allBootstrapServers.isEmpty else {"))
        XCTAssertTrue(dotBootstrapResponseBlock.contains("DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: bootstrappedEndpoint)"))

        // The cache resolver only consults the cache on the packet path and warms it
        // asynchronously — never blocking the packet path on a lookup.
        XCTAssertTrue(resolveBlock.contains("resolverBootstrapService.cachedAddresses(forHostname: endpoint.hostname)"))
        XCTAssertTrue(resolveBlock.contains("resolverBootstrapService.prewarm(hostname: endpoint.hostname)"))

        // Prewarm must cover empty-bootstrap DoT endpoints (primary + fallback).
        XCTAssertTrue(prewarmBlock.contains("resolverConfiguration.encryptedFallbackDoTEndpoints"))
        XCTAssertTrue(prewarmBlock.contains("resolverConfiguration.dotEndpoints"))
    }

    func testResolverNetworkIdentityIncludesEncryptedFallbackFields() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let identityBlock = try sourceBlock(
            in: source,
            startingAt: "private static func resolverNetworkIdentity",
            endingBefore: "private func recordCacheHit"
        )

        // Changing the encrypted Device-DNS fallback resolver (e.g. saving a
        // hostname-based Custom DoH/DoT/DoQ alternative while the VPN is running) must
        // register as a resolver change so the reload re-warms its bootstrap hostname.
        // If the identity omitted these, resolverChanged would be false and the new
        // fallback host would stay un-warmed until a later packet reset.
        XCTAssertTrue(identityBlock.contains("configuration.usesEncryptedDeviceDNSFallback"))
        XCTAssertTrue(identityBlock.contains("configuration.fallbackResolverPresetID"))
        XCTAssertTrue(identityBlock.contains("configuration.fallbackCustomResolverAddress"))
        XCTAssertTrue(identityBlock.contains("configuration.fallbackCustomResolverSecondaryAddress"))
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
        // The probe timeout is reason-derived: recovery-context probes use the
        // shorter recovery timeout so a wedge is detected (and self-reconnect fired)
        // faster; routine/startup probes keep the generous timeout.
        XCTAssertTrue(probeBlock.contains("timeoutSeconds: Self.smokeProbeTimeoutSeconds("))
        XCTAssertTrue(probeBlock.contains("transport: resolverConfiguration.transport"))
        XCTAssertTrue(probeBlock.contains("canUseDeviceDNSFallback: canUseDeviceDNSFallback"))
        XCTAssertTrue(probeBlock.contains("timeout.cancel()"))
        XCTAssertTrue(probeBlock.contains("completeResolverSmokeProbeResult("))
        XCTAssertTrue(completionBlock.contains("resolverSmokeProbeGeneration += 1"))
        XCTAssertTrue(timeoutResultBlock.contains("outcome: .timeout"))
        XCTAssertTrue(timeoutResultBlock.contains("address: resolverConfiguration.cacheIdentifier"))
    }

    func testEncryptedFallbackEngagementIsLogged() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let recordBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordUpstreamResult",
            endingBefore: "private func updateResolverBackoff"
        )

        // When the Device-DNS primary is wedged and the Mullvad DoH fallback carried
        // the query, log it (privacy-safe) so field exports show the safety net.
        XCTAssertTrue(recordBlock.contains("if result.usedEncryptedFallback {"))
        XCTAssertTrue(recordBlock.contains("event: \"dns-encrypted-fallback\""))
    }

    func testEncryptedFallbackSuccessDoesNotClearTheWedgeMarker() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let recordBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordUpstreamResult",
            endingBefore: "private func updateResolverBackoff"
        )

        // A success carried by the encrypted fallback must NOT be recorded as a
        // primary recovery: that would clear `reconnectNeededSince` (the wedge marker
        // gating the refusal→fallback decision) and flap the next REFUSED into being
        // treated as authoritative. The recovery-clearing call must sit in the
        // non-fallback branch, with the fallback branch only re-arming the recovery probe.
        let successBranch = try sourceBlock(
            in: recordBlock,
            startingAt: "if result.usedEncryptedFallback {",
            endingBefore: "if result.udpTruncated {"
        )
        XCTAssertTrue(successBranch.contains("scheduleResolverWedgeRecoveryProbeIfNeeded()"))
        XCTAssertTrue(successBranch.contains("} else {"))
        // The wedge clear is in the else (primary-success) branch, after the fallback guard.
        let fallbackGuardIndex = try XCTUnwrap(successBranch.range(of: "if result.usedEncryptedFallback {")).lowerBound
        let recoveredIndex = try XCTUnwrap(successBranch.range(of: "logConnectivityRecoveredIfWedged")).lowerBound
        let elseIndex = try XCTUnwrap(successBranch.range(of: "} else {")).lowerBound
        XCTAssertLessThan(fallbackGuardIndex, elseIndex, "fallback branch comes first")
        XCTAssertLessThan(elseIndex, recoveredIndex, "wedge clear must be inside the non-fallback else branch")
    }

    func testWedgeRecoveryProbeGateHonoursHeldWedgeMarkerNotJustHealth() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let scheduleBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverWedgeRecoveryProbeIfNeeded",
            endingBefore: "private func cancelResolverWedgeRecoveryProbe"
        )

        // The wedge marker the encrypted-fallback success path deliberately holds
        // (testEncryptedFallbackSuccessDoesNotClearTheWedgeMarker) is only useful if the
        // recovery probe actually re-probes the primary while it's held. A fallback-
        // carried success clears health's failure counters, so the assessment reads
        // healthy — gating the re-probe on the assessment ALONE would strand the primary
        // on the fallback until a routine probe / manual toggle. The fire condition must
        // also honour the wedge marker.
        XCTAssertTrue(
            scheduleBlock.contains("self.currentDeviceResolverWedged()"),
            "The wedge-recovery probe must fire while the wedge marker is held, even when a fallback-carried success has made the health-derived assessment look healthy."
        )
        // Must be OR'd with the assessment (either signal fires the probe), not AND'd
        // (which would re-introduce the masked-healthy bail this guards against).
        XCTAssertTrue(
            scheduleBlock.contains("assessment.primaryAction == .reconnect || self.currentDeviceResolverWedged()"),
            "The gate must fire on EITHER the assessment or the held wedge marker."
        )
    }

    func testFailedRecoveryProbeReArmsFromHeldWedgeMarker() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let applyBlock = try sourceBlock(
            in: source,
            startingAt: "private func applyResolverSmokeProbeResult",
            endingBefore: "private func invalidateInFlightSmokeProbes"
        )

        // The recovery loop must self-sustain at the wedge cadence: a failed re-probe
        // should schedule the next one. The threshold-gated
        // appendReconnectNeededIfPolicyRequiresReconnect won't re-arm when an encrypted-
        // fallback success has reset consecutiveUpstreamFailureCount below the reconnect
        // threshold, so the smoke-probe failure path must ALSO re-arm directly while the
        // wedge marker is held (or, for the markerless covered wedge, while coverage is
        // live) — otherwise a recovery probe runs once and stalls.
        XCTAssertTrue(
            applyBlock.contains("if currentDeviceResolverWedged() || ProtectionConnectivityPolicy.isEncryptedFallbackCarryingWedge(health: health, now: now) {"),
            "A failed smoke probe must re-arm the wedge-recovery loop while the wedge marker is held (or the encrypted fallback is carrying a failed probe — even across a rejected recapture probe)."
        )
        XCTAssertTrue(
            applyBlock.contains("scheduleResolverWedgeRecoveryProbeIfNeeded()"),
            "The marker-held re-arm must reschedule the wedge-recovery probe."
        )
    }

    func testPrimaryUpstreamSuccessTimestampExcludesBothFallbacks() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let recordBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordUpstreamResult",
            endingBefore: "private func updateResolverBackoff"
        )

        // `lastPrimaryUpstreamSuccessAt` is the recovery-acknowledgement signal, so it
        // must reflect ONLY a genuine answer from the configured primary. Three fallback
        // shapes are excluded:
        //   * encrypted fallback — structurally (the assignment lives in the non-encrypted
        //     else branch),
        //   * per-query Device-DNS fallback — `withDeviceDNSFallback` keeps
        //     `usedEncryptedFallback` false but sets `deviceDNSFallbackSucceeded`,
        //   * Device-DNS fallback *mode* — a non-device configured resolver resolves via
        //     `.deviceDNS` without setting `deviceDNSFallbackSucceeded`.
        // Without these guards a fallback-carried query would falsely clear the reconnect
        // banner while DNS still depends on the fallback.
        let successBranch = try sourceBlock(
            in: recordBlock,
            startingAt: "if result.usedEncryptedFallback {",
            endingBefore: "if result.udpTruncated {"
        )
        let elseIndex = try XCTUnwrap(successBranch.range(of: "} else {")).lowerBound
        let fallbackModeTermIndex = try XCTUnwrap(
            successBranch.range(of: "result.transport == .deviceDNS && wasDeviceDNSFallbackModeActive")
        ).lowerBound
        let guardIndex = try XCTUnwrap(
            successBranch.range(of: "if !result.deviceDNSFallbackSucceeded, !resolvedThroughFallbackMode {")
        ).lowerBound
        let primaryTimestampIndex = try XCTUnwrap(
            successBranch.range(of: "health.lastPrimaryUpstreamSuccessAt = now")
        ).lowerBound
        XCTAssertLessThan(
            elseIndex,
            fallbackModeTermIndex,
            "the primary-success timestamp must sit in the non-encrypted-fallback else branch"
        )
        XCTAssertLessThan(
            guardIndex,
            primaryTimestampIndex,
            "the primary-success timestamp must be gated on neither Device-DNS fallback nor fallback mode having carried the query"
        )
    }

    func testEncryptedFallbackHostnameIsBootstrapped() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let bootstrapBlock = try sourceBlock(
            in: source,
            startingAt: "private func dohBootstrapResponse",
            endingBefore: "private func doqBootstrapResponse"
        )

        // The encrypted fallback host (Mullvad) must be bootstrapped from its bundled
        // IPs even under a Device-DNS plan — otherwise the fallback's own
        // `dns.mullvad.net` lookup is forwarded to the (possibly wedged) Device DNS
        // and the safety net can never recover a cold/cache-miss device.
        XCTAssertTrue(
            bootstrapBlock.contains("resolverConfiguration.encryptedFallbackEndpoints"),
            "DoH bootstrap must also answer the encrypted fallback hostname so the wedge safety net can resolve its own endpoint."
        )
        // A custom `https://host` resolver (primary or fallback) carries no bootstrap
        // IPs, so the DoH bootstrap must resolve them from the warmed hostname cache
        // (mirroring DoQ) and, when none are cached yet, forward the lookup rather than
        // answer from empty arrays — an empty record set would guarantee a failed connect.
        XCTAssertTrue(
            bootstrapBlock.contains("dohEndpointResolvingBootstrapIfNeeded(endpoint)"),
            "DoH bootstrap must resolve missing bootstrap IPs from the cache for custom https resolvers."
        )
        XCTAssertTrue(
            bootstrapBlock.contains("guard !bootstrappedEndpoint.allBootstrapServers.isEmpty else {"),
            "DoH bootstrap must forward (not answer empty) when a custom endpoint has no bootstrap IPs yet."
        )

        // The cache resolver only consults the cache on the packet path and warms it
        // asynchronously — it must never block the packet path on a lookup.
        let resolveBlock = try sourceBlock(
            in: source,
            startingAt: "private func dohEndpointResolvingBootstrapIfNeeded",
            endingBefore: "private func doqEndpointResolvingBootstrapIfNeeded"
        )
        XCTAssertTrue(resolveBlock.contains("resolverBootstrapService.cachedAddresses(forHostname: host)"))
        XCTAssertTrue(resolveBlock.contains("resolverBootstrapService.prewarm(hostname: host)"))

        // Prewarm must also cover empty-bootstrap DoH endpoints (primary + fallback).
        let prewarmBlock = try sourceBlock(
            in: source,
            startingAt: "private func prewarmResolverBootstrapIfNeeded",
            endingBefore: "private func resolveDoQBootstrapAddresses"
        )
        XCTAssertTrue(prewarmBlock.contains("resolverConfiguration.encryptedFallbackEndpoints"))
        XCTAssertTrue(prewarmBlock.contains("resolverConfiguration.dohEndpoints"))
    }

    func testReachableButRejectedResolverIsClassifiedAsAFailureNotSuccess() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let smokeProbeBlock = try sourceBlock(
            in: source,
            startingAt: "private func applyResolverSmokeProbeResult",
            endingBefore: "private func resetHealth"
        )

        // A response that arrived but failed acceptance is recorded as
        // `rejected-response` (a restart-worthy reason), not the wire "success" the
        // failureSummary would otherwise yield — so recovery engages instead of the
        // resolver being mis-read as healthy.
        XCTAssertTrue(smokeProbeBlock.contains("if primaryResult.response != nil {"))
        XCTAssertTrue(smokeProbeBlock.contains("primaryReason = \"rejected-response\""))
        XCTAssertTrue(smokeProbeBlock.contains("health.lastFailureReason = primaryReason"))

        // The health probe rotates its canary domain per generation so a single
        // blocked/hijacked domain can't sustain a false unhealthy verdict.
        let probeBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverSmokeProbeIfNeeded",
            endingBefore: "private func applyResolverSmokeProbeResult"
        )
        XCTAssertTrue(probeBlock.contains("DNSResolverSmokeProbe.probeDomain(forSequence: generation)"))
        XCTAssertTrue(probeBlock.contains("domain: probeDomain"))
    }

    func testConsecutiveSmokeFailureCounterResetsOnlyOnPrimaryProvenHealth() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let smokeProbeBlock = try sourceBlock(
            in: source,
            startingAt: "private func applyResolverSmokeProbeResult",
            endingBefore: "private func resetHealth"
        )

        // The consecutive smoke-failure counter (what the connectivity policy escalates
        // on) is incremented on a failed probe and reset by smoke-probe success.
        XCTAssertEqual(
            smokeProbeBlock.components(separatedBy: "health.consecutiveDNSSmokeProbeFailureCount = 0").count - 1,
            2,
            "Counter must reset in exactly the two smoke-success branches (primary + device-fallback)."
        )
        XCTAssertTrue(smokeProbeBlock.contains("health.consecutiveDNSSmokeProbeFailureCount += 1"))

        // A genuine PRIMARY forwarding success also clears the streak, but ONLY under the
        // same primary-only guard that sets lastPrimaryUpstreamSuccessAt — so a
        // fallback-carried success never resets it (streak survives a wedged primary).
        let recordBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordUpstreamResult",
            endingBefore: "private func updateResolverBackoff"
        )
        let primaryTimestampIndex = try XCTUnwrap(
            recordBlock.range(of: "health.lastPrimaryUpstreamSuccessAt = now")
        ).lowerBound
        let streakResetIndex = try XCTUnwrap(
            recordBlock.range(of: "health.consecutiveDNSSmokeProbeFailureCount = 0")
        ).lowerBound
        XCTAssertLessThan(
            primaryTimestampIndex,
            streakResetIndex,
            "The streak reset must sit alongside the primary-only success timestamp."
        )
        // The encrypted-fallback branch must NOT reset the streak (it may READ it — e.g. to
        // gate stamping the wedge marker on a current-context failure — but never zero it,
        // which would let a fallback-carried success mask a wedged primary).
        let encryptedFallbackBranch = try sourceBlock(
            in: recordBlock,
            startingAt: "if result.usedEncryptedFallback {",
            endingBefore: "} else {"
        )
        XCTAssertFalse(encryptedFallbackBranch.contains("consecutiveDNSSmokeProbeFailureCount = 0"))

        // A network/path change is a fresh primary-health context, so the recovery reset
        // (shared by the network-change + wake paths) must also clear the streak —
        // otherwise failures from the previous network carry into the next one.
        let recoveryResetBlock = try sourceBlock(
            in: source,
            startingAt: "private func resetFailureAndFallbackStateForRecovery",
            endingBefore: "private func invalidateInFlightSmokeProbes"
        )
        XCTAssertTrue(recoveryResetBlock.contains("health.consecutiveDNSSmokeProbeFailureCount = 0"))
    }

    func testRecoveryContextProbesUseAShorterTimeoutForFasterDetection() throws {
        let source = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")

        // Recovery-context probes (post-handoff / wedge / fallback-recovery) get a
        // tight timeout so an unreachable resolver is detected quickly and
        // self-reconnect fires sooner — the lever that halves the handoff blip per
        // the 1758 device log. Routine/startup probes keep the generous timeout.
        XCTAssertTrue(source.contains("private static let resolverRecoveryProbeTimeoutSeconds = 4"))
        XCTAssertTrue(source.contains("private static let resolverSmokeProbeTimeoutSeconds = 8"))

        let selectorBlock = try sourceBlock(
            in: source,
            startingAt: "private static func smokeProbeTimeoutSeconds(",
            endingBefore: "private static let slowUpstreamResponseThresholdMilliseconds"
        )
        // The short timeout is gated to the fast device/plain primary path with no
        // fallback branch — an encrypted primary (5s transport) or a fallback-capable
        // probe keeps the routine timeout, so a 3s cut can't deactivate a working
        // device-DNS fallback while the primary is still down (P1).
        XCTAssertTrue(selectorBlock.contains("recoveryContextProbeReasons.contains(reason)"))
        XCTAssertTrue(selectorBlock.contains("transport == .deviceDNS || transport == .plainDNS"))
        XCTAssertTrue(selectorBlock.contains("!canUseDeviceDNSFallback"))
        XCTAssertTrue(selectorBlock.contains("return resolverRecoveryProbeTimeoutSeconds"))
        XCTAssertTrue(selectorBlock.contains("return resolverSmokeProbeTimeoutSeconds"))

        let reasonsBlock = try sourceBlock(
            in: source,
            startingAt: "private static let recoveryContextProbeReasons",
            endingBefore: "private static func smokeProbeTimeoutSeconds"
        )
        for reason in ["network-settled", "resolver-wedge-recovery", "device-dns-fallback-recovery"] {
            XCTAssertTrue(reasonsBlock.contains("\"\(reason)\""), "recovery-context reasons should include \(reason)")
        }
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

    /// The app reads the self-reconnect timeline for a bug report's incident summary (LAV-94 B)
    /// from `LavaSecAppGroup.selfReconnectAttemptTimesDefaultsKey`, while the tunnel WRITES it under
    /// its own private `selfReconnectAttemptsDefaultsKey`. Both are the same magic string — lock the
    /// two literals together (cross-file) so a future rename on one side can't silently strand the
    /// app's read of a key the tunnel no longer writes.
    func testSelfReconnectAttemptTimesDefaultsKeyMatchesSharedConstant() throws {
        let key = "tunnel.selfReconnectAttemptTimes"
        let tunnelSource = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")
        let sharedSource = try readSource("Shared/AppGroup.swift")
        XCTAssertTrue(
            tunnelSource.contains("selfReconnectAttemptsDefaultsKey = \"\(key)\""),
            "Tunnel must persist the self-reconnect timeline under the shared key literal."
        )
        XCTAssertTrue(
            sharedSource.contains("selfReconnectAttemptTimesDefaultsKey = \"\(key)\""),
            "The shared app-group constant the app reads must equal the tunnel's persisted key."
        )
    }

    private func readSource(_ relativePath: String) throws -> String {
        let sourceURL = packageRootURL.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    /// Extracts the literal value of a `<name>: TimeInterval = <number>` declaration from source.
    private func timeIntervalConstant(_ name: String, in source: String) throws -> Double {
        let start = try XCTUnwrap(source.range(of: "\(name): TimeInterval = ")?.upperBound)
        let digits = source[start...].prefix { $0.isNumber || $0 == "." || $0 == "_" }
        return try XCTUnwrap(Double(String(digits).replacingOccurrences(of: "_", with: "")))
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
