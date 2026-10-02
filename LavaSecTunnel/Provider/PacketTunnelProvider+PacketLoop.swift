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
    // MARK: - Packet read loop & DNS request handling

    /// Limits the response-shape experiment to QA DNS-only sessions; production is unchanged.
    var blockedAddressModeForQA: DNSBlockedAddressMode {
        #if DEBUG || LAVA_QA_TOOLS
        if !latchedDataPathMode.isChainedUpstream,
           let raw = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?["qaDNSBlockAddressMode"] as? String,
           let mode = DNSBlockedAddressMode(rawValue: raw) {
            return mode
        }
        #endif
        return .unspecified
    }

    /// The read loop, armed once per start with the lifecycle's data path CAPTURED.
    ///
    /// The driver parameter is the C2 branch, decided when the loop is armed: it is
    /// non-nil exactly when this lifecycle's latch resolved chained (construction is
    /// gated on `currentTunnelDataPathMode()`, never the build flag), and threading it
    /// through the recursion — rather than reading a property per batch — means a stale
    /// loop from a previous lifecycle can never feed a new lifecycle's driver, and the
    /// chained branch costs no queue hop on the packet path.
    ///
    /// The batch reaches the driver WHOLE: classification is the runner's, where the
    /// port-claim carve-out lives — pre-splitting with `IPv4UDPDNSPacket` here is the
    /// self-resolution defect the seam doc names. The DNS-only arm's FILTERING body is
    /// token-for-token the pre-chained loop (bootstrap > pause > filter precedence
    /// untouched); each arm carries its own retirement token, because provider instances
    /// are reused across starts and a stale loop competes with the live one for every
    /// `packetFlow` batch it can reach.
    /// pinned: ChainedProviderConstructionSourceTests.testTheReadLoopBranchesWholeBatchesAndKeepsDNSOnlyByteForByte
    func readPackets(chainedDriver: ChainedOutageDriver?, lifecycleGeneration: UInt64) {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else {
                return
            }

            if let chainedDriver {
                // A refused batch means the captured driver was RETIRED: this loop was
                // armed by a previous lifecycle, and re-arming it would steal batches
                // from the live lifecycle's loop for the rest of the process — each one
                // dropped whole. One boundary batch is lost; the stale loop dies with
                // its lifecycle. The driver IS this arm's retirement token, so the
                // chained hot path pays no per-batch queue hop.
                guard chainedDriver.handleOutboundBatch(packets, protocols: protocols) else {
                    return
                }
            } else {
                // The DNS-only arm has no driver to refuse for it, so its token is the
                // lifecycle generation: a stale DNS-only loop surviving into a CHAINED
                // lifecycle would steal batches whose non-DNS packets `handle` discards —
                // intermittent loss on the live data path (Codex, PR #508). One
                // dual-entry read per batch is fine at DNS-only rates, where the tunnel
                // only receives resolver-bound traffic.
                guard isCurrentTunnelLifecycle(lifecycleGeneration) else {
                    return
                }
                for (packet, protocolNumber) in zip(packets, protocols) {
                    handle(
                        packet: packet,
                        protocolNumber: protocolNumber,
                        lifecycleGeneration: lifecycleGeneration
                    )
                }
            }

            readPackets(chainedDriver: chainedDriver, lifecycleGeneration: lifecycleGeneration)
        }
    }

    private func handle(packet: Data, protocolNumber: NSNumber, lifecycleGeneration: UInt64) {
        // Either family feeds the one DNS decision path (F3c): a v6 query to the in-tunnel
        // resolver is parsed and filtered exactly as a v4 one is.
        guard let request = parseDNSDatagram(packet) else {
            return
        }

        // The batch's OWN generation, not a re-read. The read loop validated it one
        // dual-entry read ago, but a stop/start can land while this packet walks the
        // synchronous decision work below — and a token re-captured anywhere later would
        // name the NEW session and admit this query into it (Codex P1, PR #524). Every
        // caller of `handleDNSRequest` supplies the generation of the session that
        // ACCEPTED the work; this is the packet-borne acceptance boundary.
        handleDNSRequest(
            request,
            protocolNumber: protocolNumber.intValue,
            allowsTransientBootstrapDeferral: true,
            expectedLifecycleGeneration: lifecycleGeneration
        )
    }

    // `expectedLifecycleGeneration` is NON-OPTIONAL: every caller states which session
    // accepted the work (the read loop's armed generation, the bootstrap wait's stored
    // generation, the serve queue's lifecycle token). A `nil` escape hatch here was how
    // the packet-borne path lost its origin — the epoch was then re-captured below the
    // bounded FIFO and named whatever session existed by then (Codex P1, PR #524).
    /// - Parameter isReplayOfARecordedDecision: `true` only for a REPLAY of a request whose
    ///   decision was already recorded before it reached the coalescer (the wake reset's
    ///   drain). It suppresses just the USER-FACING half of `recordDiagnostic` — the
    ///   filtering counts, Domain History and the depth store — which would otherwise count
    ///   one client query twice and append a duplicate history entry (Codex P2, PR #617).
    ///   The observability halves still run; see `recordDiagnostic`. The bootstrap-wait
    ///   replay leaves this `false`: `enqueueTransientBootstrapDNSRequestIfNeeded` defers
    ///   BEFORE the record, so those requests have never been counted.
    func handleDNSRequest(
        _ request: any DNSDatagramRequest,
        protocolNumber: Int,
        allowsTransientBootstrapDeferral: Bool,
        expectedLifecycleGeneration: UInt64,
        isReplayOfARecordedDecision: Bool = false
    ) {
        // DROPPED, not answered, when the accepting session is gone. `writeDNSResponse`
        // has no lifecycle gate of its own, so a SERVFAIL built for a retired session
        // would be injected into whatever packet flow is live NOW — and a reused client
        // tuple and transaction ID can make that stale reply fail a live query (Codex,
        // PR #508; the serve-queue path documents the same rule). The transient-bootstrap
        // drain still answers ITS stale batches with SERVFAIL — it does so on its own
        // pre-drain check, for queries clients are actively waiting on; this fence only
        // catches staleness that lands after that.
        guard isCurrentTunnelLifecycle(expectedLifecycleGeneration) else {
            recordUnansweredDNSQuery(reason: "stale-lifecycle-at-handler", query: request.dnsPayload)
            return
        }

        let question: DNSQuestion
        do {
            question = try DNSMessage.parseQuestion(from: request.dnsPayload)
        } catch {
            recordUnansweredDNSQuery(reason: "unparseable-question", query: request.dnsPayload,
                                     parseFailureCategory: DNSMessage.questionParseFailureCategory(error))
            writeParseFailureResponse(for: request, protocolNumber: protocolNumber)
            return
        }

        let resolverConfiguration = currentResolverRuntimeConfiguration()
        let protocolNumberObject = NSNumber(value: protocolNumber)
        // Captured inside the filterDecision closure (non-escaping, called synchronously by
        // the dispatcher) so the fail-closed reason is read under the SAME snapshotQueue
        // pass as the decision — a deferred read could describe a different resident
        // snapshot than the one that actually served the query.
        var failClosedReasonAtDecision: String?
        // Precedence (bootstrap > pause > filter) lives in the pure, tested
        // DNSQueryDispatcher; the closures stay lazy so each provider-state read
        // happens only when its step is reached (preserving the per-query cost).
        let decision = dnsQueryDispatcher.decide(
            bootstrapResponse: {
                guard let response = dohBootstrapResponse(
                    for: question,
                    query: request.dnsPayload,
                    resolverConfiguration: resolverConfiguration,
                    admittedAtEpoch: expectedLifecycleGeneration
                ) ?? doqBootstrapResponse(
                    for: question,
                    query: request.dnsPayload,
                    resolverConfiguration: resolverConfiguration,
                    admittedAtEpoch: expectedLifecycleGeneration
                ) ?? dotBootstrapResponse(
                    for: question,
                    query: request.dnsPayload,
                    resolverConfiguration: resolverConfiguration,
                    admittedAtEpoch: expectedLifecycleGeneration
                ) else { return nil }
                // The bootstrap path writes its response DIRECTLY, bypassing `forward`'s AAAA→NODATA
                // suppression. While the data path drops v6, a v6 bootstrap answer for the resolver's
                // OWN hostname would send the client to reach its encrypted resolver over the dropped
                // path — the same stall, for the extension's own bootstrap. Answer AAAA with NODATA so
                // it uses the A (v4) bootstrap the full tunnel forwards (Codex, PR #559).
                // pinned: PacketTunnelDNSRuntimeSourceTests.testBootstrapAAAAIsSuppressedWhenTheDataPathDropsIPv6
                if ChainedIPv6DNSPolicy.isIPv6AddressQuery(question),
                    currentTunnelDataPathMode().dropsOutboundIPv6,
                    let noData = try? DNSMessage.emptyResponse(for: request.dnsPayload, question: question) {
                    return noData
                }
                return response
            },
            isProtectionPaused: {
                isTemporaryProtectionPauseActive(synchronizesDefaults: false)
            },
            filterDecision: {
                let (decision, failClosedReason) = filterDecisionCapturingFailClosedReason(
                    forNormalizedDomain: question.normalizedDomain
                )
                failClosedReasonAtDecision = failClosedReason
                return decision
            }
        )

        switch decision {
        case .bootstrap(let bootstrapResponse):
            resetResolverRuntimeStateIfNeeded(identifier: resolverConfiguration.cacheIdentifier)
            writeDNSResponse(bootstrapResponse, for: request, protocolNumber: protocolNumber)

        case .pausedForward:
            recordFirstDNSDecisionIfNeeded("pause-allow")
            let maximumAnswerTTL = temporaryPauseMaximumAnswerTTL(forNormalizedDomain: question.normalizedDomain)
            forward(
                request,
                question: question,
                protocolNumber: protocolNumberObject,
                resolverConfiguration: resolverConfiguration,
                admittedAtEpoch: expectedLifecycleGeneration,
                maximumAnswerTTL: maximumAnswerTTL,
                temporaryPauseNormalizedDomain: question.normalizedDomain,
                isReplayOfARecordedDecision: isReplayOfARecordedDecision
            )

        case .filtered(let filterDecision):
            if enqueueTransientBootstrapDNSRequestIfNeeded(
                request: request,
                protocolNumber: protocolNumber,
                filterDecision: filterDecision,
                failClosedReason: failClosedReasonAtDecision,
                allowsTransientBootstrapDeferral: allowsTransientBootstrapDeferral,
                expectedLifecycleGeneration: expectedLifecycleGeneration,
                isReplayOfARecordedDecision: isReplayOfARecordedDecision
            ) {
                return
            }

            recordFirstDNSDecisionIfNeeded(filterDecision.action == .block ? "block" : "allow")
            recordManualRuleDecisionIfNeeded(
                normalizedDomain: question.normalizedDomain,
                decision: filterDecision
            )
            guard filterDecision.action == .block else {
                forward(
                    request,
                    question: question,
                    protocolNumber: protocolNumberObject,
                    resolverConfiguration: resolverConfiguration,
                    admittedAtEpoch: expectedLifecycleGeneration,
                    isReplayOfARecordedDecision: isReplayOfARecordedDecision
                )
                return
            }

            recordDiagnostic(
                domain: question.domain,
                decision: filterDecision,
                failClosedReason: failClosedReasonAtDecision,
                isReplayOfARecordedDecision: isReplayOfARecordedDecision
            )

            guard let response = try? DNSMessage.blockedResponse(
                for: request.dnsPayload,
                question: question,
                ttl: blockedTTL,
                addressMode: blockedAddressModeForQA.limitedToQAProbeDomain(question.normalizedDomain)
            ) else {
                return
            }

            writeDNSResponse(response, for: request, protocolNumber: protocolNumber)
        }
    }
}
