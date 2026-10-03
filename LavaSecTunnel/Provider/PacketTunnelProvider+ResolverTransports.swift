@preconcurrency import ActivityKit
import Foundation
import Darwin
import Network
@preconcurrency import NetworkExtension
import Security
@preconcurrency import UserNotifications
import LavaSecChainedUpstream
import LavaSecDNS
import LavaSecFilterPipeline
import LavaSecKit

// One concern of `PacketTunnelProvider`, split out of the former single-file provider.
// Stored state lives in LavaSecTunnel/PacketTunnelProvider.swift (extensions cannot declare
// stored properties, so a property declared beside its concern moved there); the other
// `PacketTunnelProvider+*.swift` files each hold one `// MARK:` section of the class, and the
// remaining files under Provider/ hold the types the single file declared outside it.

extension PacketTunnelProvider {
    // MARK: - Resolver runtime & transports (device / plain / DoH / DoT / DoQ)

    // Wire-level executors for the core orchestrator: transports, the
    // synchronous plain/device resolvers, and the backoff gate. Per-endpoint
    // debug logging and idle-reset-on-failure live here so the orchestrator
    // stays policy-pure.

    func makeResolverExecutors(lifetime: DNSResolutionLifetime? = nil) -> ResolverOrchestrator.Executors {
        let dohResolver = dohResolver
        let dotResolver = dotResolver
        let doqResolver = doqResolver
        #if DEBUG || LAVA_QA_TOOLS
        // One wire attempt per span. "Endpoint fallback" is the multi-attempt
        // subset (an attempt whose outcome != success followed by another), so
        // the per-attempt distribution and the failover cost both fall out of
        // aggregating resolver.endpointAttempt by name. The handshake sub-cost
        // is layered underneath via the transports' dns-<t>-connection-ready
        // debug events.
        let resolverLatencyOperationID = self.resolverLatencyOperationID
        let beginResolverSpan: @Sendable (String, [String: String]) -> LatencySpan = { name, details in
            Self.makeLatencyTrace(operationID: resolverLatencyOperationID, operationKind: "resolver")
                .beginSpan(name, details: details)
        }
        let endAttemptSpan: @Sendable (LatencySpan, DNSTransportResponse) -> Void = { span, upstreamResponse in
            span.end(details: [
                "outcome": upstreamResponse.outcome.rawValue,
                "succeeded": "\(upstreamResponse.response != nil)"
            ])
        }
        #endif
        return ResolverOrchestrator.Executors(
            isEndpointBackedOff: { [weak self] address in
                self?.isResolverBackedOff(address) ?? false
            },
            claimEncryptedRecovery: { [weak self] addresses in
                guard let self else { return nil }
                return self.resolverBackoffStateQueue.sync {
                    self.resolverBackoffPolicy.claimEncryptedRecovery(from: addresses)
                }
            },
            resolveDoH: { [weak self] query, endpoint, admittedAtLatchEpoch, completion in
                // THE RUNG'S DATA PATH, asked again at the transport's own send seam. The
                // orchestrator's per-endpoint check has already passed by the time the transport
                // is handed the query, and the transports queue behind other queries and behind a
                // handshake — so this predicate is what a relatch landing in that window catches
                // (PR #611). Nil for every `.planned` resolution, where it answers true without
                // reading state.
                let isStillAdmitted: @Sendable () -> Bool = { [weak self] in
                    (lifetime?.isAdmitted ?? true) && (self?.resolverLatchIsCurrent(admittedAtLatchEpoch) ?? false)
                }
                #if DEBUG || LAVA_QA_TOOLS
                let attemptSpan = beginResolverSpan("resolver.endpointAttempt", ["transport": "DoH"])
                #endif
                dohResolver.resolve(
                    query, endpoint: endpoint.url, isStillAdmitted: isStillAdmitted, deadline: lifetime?.deadline
                ) { upstreamResponse in
                    // NOT EVERY EMPTY ANSWER IS A SICK CONNECTION. A latch refusal is the device
                    // declining to send, so tearing the session down for it would discard healthy
                    // lanes — including lanes for the resolver the user just switched TO — at
                    // exactly the moment they changed setting (Codex P2, PR #611).
                    if upstreamResponse.response == nil,
                        upstreamResponse.outcome.isTransportFailureEvidence {
                        dohResolver.resetSessionWhenIdle()
                    }
                    #if DEBUG || LAVA_QA_TOOLS
                    endAttemptSpan(attemptSpan, upstreamResponse)
                    #endif
                    completion(upstreamResponse)
                }
            },
            resolveDoT: { [weak self] query, endpoint, usesIsolatedConnection, admittedAtLatchEpoch, completion in
                // See `resolveDoH` above for why the predicate exists and why it is asked at the
                // transport rather than here.
                let isStillAdmitted: @Sendable () -> Bool = { [weak self] in
                    (lifetime?.isAdmitted ?? true) && (self?.resolverLatchIsCurrent(admittedAtLatchEpoch) ?? false)
                }
                #if DEBUG || LAVA_QA_TOOLS
                // Per-query "begin" trace is verbose Debug/QA instrumentation; it is
                // kept off the Release DNS hot path (no diagnostic value without the
                // matching result, which Release logs only on failure below).
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-dot-query-begin", details: [
                    "endpoint": endpoint.displayAddress,
                    "bootstrapCount": "\(endpoint.allBootstrapServers.count)"
                ])
                let attemptSpan = beginResolverSpan("resolver.endpointAttempt", ["transport": "DoT"])
                #endif

                let finish: @Sendable (DNSTransportResponse) -> Void = { upstreamResponse in
                    // See the DoH executor above: a refusal is not transport-failure evidence.
                    if upstreamResponse.response == nil, !usesIsolatedConnection,
                        upstreamResponse.outcome.isTransportFailureEvidence {
                        dotResolver.resetConnectionsWhenIdle()
                    }

                    let succeeded = upstreamResponse.response != nil
                    #if DEBUG || LAVA_QA_TOOLS
                    let shouldLogResult = true
                    #else
                    // Release: keep per-query logging off the DNS success hot path
                    // (appendLine open/write/close per query adds resolution
                    // latency). Failures are rare and are exactly the signal needed
                    // to diagnose a Wi-Fi/cellular handoff, so log only those.
                    let shouldLogResult = !succeeded
                    #endif
                    if shouldLogResult {
                        LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-dot-query-result", details: [
                            "endpoint": endpoint.displayAddress,
                            "outcome": upstreamResponse.outcome.rawValue,
                            "succeeded": "\(succeeded)"
                        ])
                    }
                    #if DEBUG || LAVA_QA_TOOLS
                    endAttemptSpan(attemptSpan, upstreamResponse)
                    #endif

                    completion(upstreamResponse)
                }

                if usesIsolatedConnection {
                    dotResolver.resolveIsolated(
                        query, endpoint: endpoint, isStillAdmitted: isStillAdmitted, deadline: lifetime?.deadline,
                        completion: finish)
                } else {
                    dotResolver.resolve(
                        query, endpoint: endpoint, isStillAdmitted: isStillAdmitted, deadline: lifetime?.deadline,
                        completion: finish)
                }
            },
            resolveDoQ: { [weak self] query, endpoint, usesIsolatedConnection, admittedAtLatchEpoch, completion in
                // See `resolveDoH` above.
                let isStillAdmitted: @Sendable () -> Bool = { [weak self] in
                    (lifetime?.isAdmitted ?? true) && (self?.resolverLatchIsCurrent(admittedAtLatchEpoch) ?? false)
                }
                #if DEBUG || LAVA_QA_TOOLS
                // Per-query "begin" trace is verbose Debug/QA instrumentation; kept
                // off the Release DNS hot path (see DoT path above).
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-doq-query-begin", details: [
                    "endpoint": endpoint.displayAddress
                ])
                let attemptSpan = beginResolverSpan("resolver.endpointAttempt", ["transport": "DoQ"])
                #endif

                let finish: @Sendable (DNSTransportResponse) -> Void = { upstreamResponse in
                    // See the DoH executor above: a refusal is not transport-failure evidence.
                    if upstreamResponse.response == nil, !usesIsolatedConnection,
                        upstreamResponse.outcome.isTransportFailureEvidence {
                        doqResolver.resetConnectionsWhenIdle()
                    }

                    let succeeded = upstreamResponse.response != nil
                    #if DEBUG || LAVA_QA_TOOLS
                    let shouldLogResult = true
                    #else
                    // Release: only log failures to keep per-query I/O off the DNS
                    // success hot path (see DoT path above).
                    let shouldLogResult = !succeeded
                    #endif
                    if shouldLogResult {
                        LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-doq-query-result", details: [
                            "endpoint": endpoint.displayAddress,
                            "outcome": upstreamResponse.outcome.rawValue,
                            "succeeded": "\(succeeded)"
                        ])
                    }
                    #if DEBUG || LAVA_QA_TOOLS
                    endAttemptSpan(attemptSpan, upstreamResponse)
                    #endif

                    completion(upstreamResponse)
                }

                if usesIsolatedConnection {
                    doqResolver.resolveIsolated(
                        query, endpoint: endpoint, isStillAdmitted: isStillAdmitted, deadline: lifetime?.deadline,
                        completion: finish)
                } else {
                    doqResolver.resolve(
                        query, endpoint: endpoint, isStillAdmitted: isStillAdmitted, deadline: lifetime?.deadline,
                        completion: finish)
                }
            },
            resolvePlain: { [weak self] query, addresses, transport, admittedAtEpoch, admittedAtLatchEpoch, egressInterface in
                guard let self else {
                    return DNSResolutionResult(
                        response: nil,
                        successfulResolverAddress: nil,
                        attempts: [],
                        transport: transport,
                        udpTruncated: false,
                        tcpFallbackAttempted: false,
                        tcpFallbackSucceeded: false
                    )
                }

                // Plain DNS iterates addresses with UDP-then-TCP and backoff
                // internally, so one span covers the whole plain resolution
                // (the dominant DNS phase for users on a plain-IP resolver).
                #if DEBUG || LAVA_QA_TOOLS
                let attemptSpan = beginResolverSpan("resolver.endpointAttempt", ["transport": "plain"])
                #endif
                let result = self.resolvePlainDNS(
                    query, resolverAddresses: addresses, transport: transport,
                    admittedAtEpoch: admittedAtEpoch, admittedAtLatchEpoch: admittedAtLatchEpoch,
                    egressInterface: egressInterface, lifetime: lifetime)
                #if DEBUG || LAVA_QA_TOOLS
                attemptSpan.end(details: [
                    "outcome": result.failureSummary ?? "success",
                    "succeeded": "\(result.response != nil)",
                    "usedTCP": "\(result.tcpFallbackAttempted)"
                ])
                #endif
                return result
            },
            resolveTunnelledPlain: { [weak self] query, route in
                // An absent provider means the tunnel is gone — which is what
                // `.refusedAfterLifecycleEnded` says, and nothing about a socket. It read
                // `.socketUnavailable` until the field capture of 2026-08-29T08:11Z showed what
                // that costs: `.socketUnavailable` backs the ENDPOINT off for 30 s, so a refusal
                // caused by our own teardown was charged to the user's resolver. The nil response
                // still synthesizes the SERVFAIL per INV-DNS-1; only the attribution changes.
                guard let self else {
                    return DNSResolutionResult(
                        response: nil,
                        successfulResolverAddress: nil,
                        attempts: [
                            ResolverAttempt(
                                address: route.resolverAddresses.first ?? "tunnel",
                                outcome: .refusedAfterLifecycleEnded,
                                transport: .plainDNS)
                        ],
                        transport: .plainDNS,
                        udpTruncated: false,
                        tcpFallbackAttempted: false,
                        tcpFallbackSucceeded: false
                    )
                }
                return self.resolveTunnelledPlainDNS(query, route: route, lifetime: lifetime)
            },
            resolveDevice: { [weak self] query, addresses, admittedAtEpoch, admittedAtLatchEpoch, egressInterface, tier in
                guard let self else {
                    return DNSResolutionResult(
                        response: nil,
                        successfulResolverAddress: nil,
                        attempts: [],
                        transport: .deviceDNS,
                        udpTruncated: false,
                        tcpFallbackAttempted: false,
                        tcpFallbackSucceeded: false,
                        deviceDNSUnavailable: true
                    )
                }

                #if DEBUG || LAVA_QA_TOOLS
                let fallbackSpan = beginResolverSpan("resolver.deviceFallback", [:])
                #endif
                let result = self.resolveDeviceDNS(
                    query, resolverAddresses: addresses, admittedAtEpoch: admittedAtEpoch,
                    admittedAtLatchEpoch: admittedAtLatchEpoch,
                    egressInterface: egressInterface, lifetime: lifetime, tier: tier)
                #if DEBUG || LAVA_QA_TOOLS
                fallbackSpan.end(details: ["succeeded": "\(result.response != nil)"])
                #endif
                return result
            },
            observeTierReply: { [weak self] evidence in
                self?.recordResolverTierReply(evidence, lifetime: lifetime) ?? evidence
            }
        )
    }

    /// `egressInterface` is the caller's, never assumed. A device resolver is a LAN address, so
    /// the T1 rung's datagram has to leave on the PHYSICAL interface — left to itself the
    /// socket layer pins to the tunnel whenever chained is latched, and a LAN address sent through
    /// the peer is a guaranteed timeout. The DNS-only device ladder passes `.providerDefault` and
    /// behaves exactly as it always has.
    /// pinned: TunnelDataPathLatchSourceTests.testTheDeviceExecutorCarriesTheRungsEgressInterface
    func resolveDeviceDNS(
        _ query: Data, resolverAddresses: [String], admittedAtEpoch: UInt64,
        admittedAtLatchEpoch: UInt64? = nil,
        egressInterface: ResolverOrchestrator.EgressInterface,
        lifetime: DNSResolutionLifetime? = nil,
        tier: DNSResolverTier,
        replyContextIdentity: String? = nil, replyRuntimeGeneration: Int? = nil,
        livenessOnly: Bool = false
    ) -> DNSResolutionResult {
        guard !resolverAddresses.isEmpty else {
            return DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: [
                    ResolverAttempt(
                        address: DNSResolverPreset.device.id,
                        outcome: .deviceDNSUnavailable,
                        transport: .deviceDNS
                    )
                ],
                transport: .deviceDNS,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false,
                deviceDNSUnavailable: true
            )
        }

        let readOrigin: () -> (context: String, generation: Int) = {
            (replyContextIdentity ?? self.currentResolverTierContextIdentity(),
             replyRuntimeGeneration ?? self.resolverRuntimeGeneration)
        }
        let origin = DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true
            ? readOrigin() : dnsStateQueue.sync(execute: readOrigin)
        let observeReply: @Sendable (DNSUpstreamResponse, ResolverAttempt) -> UInt64? = { [weak self] reply, attempt in
            guard let self,
                  reply.outcome == .success || reply.outcome == .truncatedAnswer || reply.outcome == .mismatchedResponse
            else { return nil }
            let partial = DNSResolutionResult(
                response: reply.response, successfulResolverAddress: reply.response == nil ? nil : attempt.address,
                attempts: [attempt], transport: .deviceDNS, udpTruncated: false,
                tcpFallbackAttempted: false, tcpFallbackSucceeded: false)
            let evidence = ResolverTierEvidence(
                tier: tier, resolverKind: .device, egress: .physical, result: partial,
                originatingLifecycle: admittedAtEpoch, originatingLatchEpoch: admittedAtLatchEpoch)
                .recordingClientDeadlineExpired()
            // Send admission may end when another lookup confirms silence. A reply already
            // received in this captured context must still revoke the deferred restart.
            // pinned: ResolverTierRecoverySourceTests.testDeviceRepliesCanRetireAnAlreadyConfirmedGrant
            return self.recordResolverTierReply(
                evidence, contextIdentity: origin.context,
                runtimeGeneration: origin.generation).replySequence
        }
        return resolvePlainDNS(
            query, resolverAddresses: resolverAddresses, transport: .deviceDNS,
            admittedAtEpoch: admittedAtEpoch, admittedAtLatchEpoch: admittedAtLatchEpoch,
            egressInterface: egressInterface, lifetime: lifetime, replyObserver: observeReply,
            livenessOnly: livenessOnly)
    }

    /// `egressInterface` defaults to `.providerDefault` — the RESTRICTIVE answer, the tunnel while
    /// chained — so a caller that does not think about it cannot leak. Only the chained T1
    /// rung passes `.physical`, and it does so explicitly (Codex, PR #590).
    func resolvePlainDNS(
        _ query: Data,
        resolverAddresses: [String],
        transport: DNSResolverTransport = .plainDNS,
        admittedAtEpoch: UInt64,
        admittedAtLatchEpoch: UInt64? = nil,
        egressInterface: ResolverOrchestrator.EgressInterface = .providerDefault,
        lifetime: DNSResolutionLifetime? = nil,
        replyObserver: (@Sendable (DNSUpstreamResponse, ResolverAttempt) -> UInt64?)? = nil,
        livenessOnly: Bool = false
    ) -> DNSResolutionResult {
        var attempts: [ResolverAttempt] = []
        var sawUDPTruncation = false
        var attemptedTCPFallback = false

        let addressesForAttempt = orderedResolverAddressesForAttempt(resolverAddresses)
        if addressesForAttempt.isEmpty, !resolverAddresses.isEmpty {
            return DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: resolverAddresses.map {
                    ResolverAttempt(address: $0, outcome: .backedOff, transport: transport)
                },
                transport: transport,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false
            )
        }

        for address in addressesForAttempt {
            guard let endpoint = ResolverEndpoint(address: address) else {
                attempts.append(ResolverAttempt(address: address, outcome: .invalidAddress, transport: transport))
                continue
            }

            let actualEgress: DNSResolverTierHealthSnapshot.Egress =
                egressInterface == .physical && latchedChainedAllowedIPsCover(address) ? .tunnel : .physical
            let udpPathEpoch = currentResolverTierPathEpoch()
            let udpSendSequence = transport == .deviceDNS ? nextResolverTierObservationSequence() : nil
            let udpResult = resolveUDP(
                query, endpoint: endpoint, admittedAtEpoch: admittedAtEpoch,
                admittedAtLatchEpoch: admittedAtLatchEpoch,
                egressInterface: egressInterface, lifetime: lifetime)
            let udpAttempt = ResolverAttempt(
                address: address, outcome: udpResult.outcome, transport: transport,
                pathEpoch: udpPathEpoch, actualEgress: actualEgress, sendSequence: udpSendSequence)
            // A source-matched UDP reply is liveness now, even if TCP or another address
            // subsequently stalls. Carry its observation order through that same leg.
            // pinned: ResolverTierRecoverySourceTests.testDeviceRepliesAreObservedBeforeTCPRetry
            let observedUDPAttempt = udpAttempt.recordingReply(
                observationSequence: replyObserver?(udpResult, udpAttempt))
            attempts.append(observedUDPAttempt)
            // Confirmation has no client answer to finish. Any verified reply settles its
            // reachability question immediately; organic lookups retain normal TCP service.
            if livenessOnly, observedUDPAttempt.replySequence != nil {
                return DNSResolutionResult(
                    response: udpResult.response,
                    successfulResolverAddress: udpResult.response == nil ? nil : address,
                    attempts: attempts, transport: transport,
                    udpTruncated: udpResult.response.map(DNSMessageTraits.isTruncated) ?? false,
                    tcpFallbackAttempted: false, tcpFallbackSucceeded: false)
            }

            // The ladder stops where it stands: the remaining addresses would each refuse
            // at the same socket-seam guard, and a resolution whose session ended is not
            // evidence about resolvers it never reached. The refusal stays LAST in
            // `attempts`, which is what selects the abandoned (neutral) aggregate path.
            if udpResult.outcome.endsTheResolutionLadder {
                break
            }

            guard let udpResponse = udpResult.response else {
                guard shouldAttemptTCPFallback(afterUDPOutcome: udpResult.outcome) else {
                    continue
                }

                attemptedTCPFallback = true
                let tcpPathEpoch = currentResolverTierPathEpoch()
                let tcpSendSequence = transport == .deviceDNS ? nextResolverTierObservationSequence() : nil
                let tcpResult = resolveOverTCP(
                    query, endpoint: endpoint, admittedAtEpoch: admittedAtEpoch,
                    admittedAtLatchEpoch: admittedAtLatchEpoch,
                    egressInterface: egressInterface, lifetime: lifetime)
                let tcpAttempt = ResolverAttempt(
                    address: address, outcome: tcpResult.outcome, transport: transport, usedTCP: true,
                    pathEpoch: tcpPathEpoch, actualEgress: actualEgress, sendSequence: tcpSendSequence)
                attempts.append(tcpAttempt.recordingReply(
                    observationSequence: replyObserver?(tcpResult, tcpAttempt)))
                if livenessOnly, attempts.last?.replySequence != nil, tcpResult.response == nil {
                    return DNSResolutionResult(
                        response: nil, successfulResolverAddress: nil, attempts: attempts,
                        transport: transport, udpTruncated: sawUDPTruncation,
                        tcpFallbackAttempted: true, tcpFallbackSucceeded: false)
                }

                if let tcpResponse = tcpResult.response {
                    return DNSResolutionResult(
                        response: tcpResponse,
                        successfulResolverAddress: address,
                        attempts: attempts,
                        transport: transport,
                        udpTruncated: sawUDPTruncation,
                        tcpFallbackAttempted: attemptedTCPFallback,
                        tcpFallbackSucceeded: true
                    )
                }

                // Same stop as the UDP rung: a TCP rung refused for a dead lifecycle
                // ends the ladder with the refusal last in `attempts`.
                if tcpResult.outcome.endsTheResolutionLadder {
                    break
                }

                continue
            }

            if DNSMessageTraits.isTruncated(udpResponse) {
                sawUDPTruncation = true
                attemptedTCPFallback = true
                let tcpPathEpoch = currentResolverTierPathEpoch()
                let tcpSendSequence = transport == .deviceDNS ? nextResolverTierObservationSequence() : nil
                let tcpResult = resolveOverTCP(
                    query, endpoint: endpoint, admittedAtEpoch: admittedAtEpoch,
                    admittedAtLatchEpoch: admittedAtLatchEpoch,
                    egressInterface: egressInterface, lifetime: lifetime)
                let tcpAttempt = ResolverAttempt(
                    address: address, outcome: tcpResult.outcome, transport: transport, usedTCP: true,
                    pathEpoch: tcpPathEpoch, actualEgress: actualEgress, sendSequence: tcpSendSequence)
                attempts.append(tcpAttempt.recordingReply(
                    observationSequence: replyObserver?(tcpResult, tcpAttempt)))
                if livenessOnly, attempts.last?.replySequence != nil, tcpResult.response == nil {
                    return DNSResolutionResult(
                        response: nil, successfulResolverAddress: nil, attempts: attempts,
                        transport: transport, udpTruncated: sawUDPTruncation,
                        tcpFallbackAttempted: true, tcpFallbackSucceeded: false)
                }

                if let tcpResponse = tcpResult.response {
                    return DNSResolutionResult(
                        response: tcpResponse,
                        successfulResolverAddress: address,
                        attempts: attempts,
                        transport: transport,
                        udpTruncated: true,
                        tcpFallbackAttempted: attemptedTCPFallback,
                        tcpFallbackSucceeded: true
                    )
                }

                // Same stop as the UDP rung: a TCP rung refused for a dead lifecycle
                // ends the ladder with the refusal last in `attempts`.
                if tcpResult.outcome.endsTheResolutionLadder {
                    break
                }

                continue
            }

            return DNSResolutionResult(
                response: udpResponse,
                successfulResolverAddress: address,
                attempts: attempts,
                transport: transport,
                udpTruncated: sawUDPTruncation,
                tcpFallbackAttempted: attemptedTCPFallback,
                tcpFallbackSucceeded: false
            )
        }

        return DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: attempts,
            transport: transport,
            udpTruncated: sawUDPTruncation,
            tcpFallbackAttempted: attemptedTCPFallback,
            tcpFallbackSucceeded: false
        )
    }

    private func shouldAttemptTCPFallback(afterUDPOutcome outcome: ResolverAttemptOutcome) -> Bool {
        switch outcome {
        case .timeout:
            return true
        case .sendFailed:
            return false
        case .success,
             .httpStatusFailure,
             .backedOff,
             .receiveFailed,
             .invalidAddress,
             .unsupported,
             .socketUnavailable,
             // Our own port table was full: a TCP retry would ask it for another carve-out and be
             // refused the same way. Nothing was truncated, so there is nothing to retry.
             .resolverPortUnavailable,
             // Interface not ready yet: a physical TCP retry refuses on the same binding — no
             // truncation signal, nothing to retry (Codex, PR #570).
             .tunnelInterfaceUnavailable,
             // F2's missing physical pin is the same shape: the destination is floor-claimed and
             // has no live physical index, so a TCP retry refuses on the identical binding.
             .physicalInterfaceUnavailable,
             .mismatchedResponse,
             // Off-source junk is no more a truncation signal than a source-matched mismatch is;
             // both mean this attempt got nothing usable, which is not the TC bit (PR #577).
             .unexpectedSourceResponse,
             .deviceDNSUnavailable,
             // A policy refusal is not a truncation signal, and retrying over TCP would be
             // the leak the refusal exists to prevent, on a different socket.
             .refusedByEgressPolicy,
             // Same reasoning one step further: the asker is gone, so there is no
             // truncation signal and nothing to retry for.
             .refusedAfterLifecycleEnded,
             // A replaced path or spent deadline cannot authorize a TCP retry.
             .refusedAfterLatchReplaced, .expiredBeforeSend,
             // Produced only by the tunnelled executor (S6), which never reaches this
             // DNS-only fallback ladder — and if it ever did, a physical TCP retry of a
             // tunnel-carried truncation would be the leak. Resolved decision 3: the
             // chained TC answer fails closed, with no TCP retry, until S9's field
             // evidence gates the tunnelled retry on.
             .truncatedAnswer:
            return false
        }
    }

    /// Runs the deferred proactive resolver rebuild (DoQ bootstrap pre-warm + DNS
    /// smoke probe) once the network path has settled. The connection teardown for
    /// each change already happened immediately in `handleNetworkPathUpdate`; only
    /// this proactive work is coalesced so a flap burst re-handshakes once, not per
    /// flap.
    func performCoalescedNetworkSettleProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.performCoalescedNetworkSettleProbe()
            }
            return
        }

        guard currentResolverHealthSchedulingView().networkPathIsSatisfied else {
            return
        }

        // Best-effort device-DNS re-capture once the new network has settled.
        //
        // KNOWN-INEFFECTIVE WHILE MASKED (field evidence, 1758 device log): on the
        // cellular networks observed, EVERY in-tunnel capture returns empty — iOS
        // surfaces only the tunnel's own 10.255.0.1 (which we filter out) while the
        // tunnel is active. Across that session all 98 `network-settled` and 98
        // `wake` captures were count:0; the only non-empty captures (count:2) were
        // the two cold `startTunnel`s. So preserveOnEmptyCapture keeps the PREVIOUS
        // network's resolvers, and on a resolver-CHANGING handoff those are
        // unreachable (timeout) → a wedge that only a tunnel restart (self-reconnect,
        // which re-captures at cold start) actually fixes. Do NOT rely on this
        // re-capture for handoff recovery; it is kept because it is harmless and may
        // still help on networks/iOS versions that don't mask. If they changed,
        // reset the runtime so the fresh addresses take effect (mirrors wake()).
        let previousDeviceDNSResolverAddresses = deviceDNSResolverAddresses
        refreshDeviceDNSResolverAddressesOnDNSQueue(reason: "network-settled")
        if deviceDNSResolverAddresses != previousDeviceDNSResolverAddresses {
            let resolverIdentifier = currentResolverRuntimeConfiguration().cacheIdentifier
            let pendingResponses = collectPendingResponsesAndResetResolverRuntime(
                identifier: resolverIdentifier,
                reason: "device-dns-recaptured-on-settle",
                force: true
            )
            writeServerFailures(for: pendingResponses, reason: "device-dns-recaptured-on-settle")
        }

        // This settle handler runs on dnsStateQueue and IS the acceptance boundary for
        // the pre-warms it kicks; the capture happens here, not on the far side of the
        // bootstrap service's queue hop (PR #524).
        prewarmResolverBootstrapIfNeeded(admittedAtEpoch: currentResolverAdmissionEpoch())
        scheduleResolverSmokeProbeIfNeeded(reason: "network-settled")
    }
}
