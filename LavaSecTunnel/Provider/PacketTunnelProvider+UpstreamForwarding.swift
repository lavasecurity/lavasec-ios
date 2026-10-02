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
    // MARK: - Upstream forwarding & resolution pipeline

    // `resolverConfiguration` is taken from the caller (`handle`) rather than
    // recomputed here: `currentResolverRuntimeConfiguration()` performs several
    // blocking `dnsStateQueue.sync` reads, and `handle` already computed the SAME
    // value to drive the bootstrap/pause/filter decision. Reusing it keeps the
    // decision and the forward on one consistent runtime and removes a second
    // batch of queue hops from the per-query hot path. Staleness is still guarded
    // by `resetResolverRuntimeStateIfNeeded` (+ResidentSnapshot.swift) and the
    // `isActiveResolverRuntime`
    // generation check before any response is written.
    //
    // Adoption timing: a resolver-config change (A→B) that commits AFTER `handle`
    // captured A at its entry — via the queued `refreshConfigurationIfNeeded` in
    // `recordDiagnostic`, or a concurrent snapshot reload — is adopted by the NEXT
    // query, not this one. This in-flight query is served under A, the runtime it
    // was classified on (previously `forward` re-read the config here and could
    // adopt B one query sooner). The lag is one query and self-correcting: the next
    // `handle` reads `appConfiguration == B` and its `forward` resets the runtime to
    // B. Because the reset is keyed on the captured identifier (not a live re-read),
    // `setAppConfiguration` alone never advances `activeResolverRuntimeIdentifier`,
    // so reset(A) hits the identity guard and no-ops rather than flipping a runtime
    // that is still A. The authoritative apply path
    // (`refreshDNSRuntimeAfterSnapshotOrConfigurationChange`, invoked from a snapshot
    // reload) is unaffected — it resets the runtime to the new identifier directly.

    func forward(
        _ request: any DNSDatagramRequest,
        question: DNSQuestion,
        protocolNumber: NSNumber,
        resolverConfiguration: ResolverRuntimeConfiguration,
        admittedAtEpoch: UInt64,
        maximumAnswerTTL: UInt32? = nil,
        temporaryPauseNormalizedDomain: String? = nil,
        isReplayOfARecordedDecision: Bool = false
    ) {
        let pending = PendingDNSResponse(
            request: request,
            protocolNumber: protocolNumber.intValue,
            maximumAnswerTTL: maximumAnswerTTL,
            temporaryPauseNormalizedDomain: temporaryPauseNormalizedDomain,
            isReplayOfARecordedDecision: isReplayOfARecordedDecision
        )
        // A chained data path DROPS every outbound IPv6 packet
        // (`ChainedOutboundPacketClassifier`, INV-CHAIN-1) — both shapes since 2026-09-19, when
        // split also claimed `::/0` to close the v6-DNS escape. If we still forwarded AAAA and
        // returned a v6 address, the client would try the dropped v6 path first and stall until
        // Happy-Eyeballs fell back to v4 — device log chimmy 2026-08-15: dual-stack sites dead
        // ~15-30 s while a v4-only site loaded. Answer AAAA with NODATA so the client uses A
        // directly. Gated on `dropsOutboundIPv6`, NOT `isChainedUpstream`: DNS-only claims no
        // IPv6 and must not suppress AAAA — the gate is the `::/0` claim (Codex, PR #559). The
        // record-type guard runs first so the mode read stays off the non-AAAA hot path.
        // Filtering already ran at the call site (this is an allow / paused forward), so
        // declining the record here never admits a blocked domain — INV-DNS-1 holds.
        // pinned: ChainedIPv6DNSPolicyTests.testAAAAIsSuppressedOnlyWhenTheDataPathDropsIPv6
        // pinned: PacketTunnelDNSRuntimeSourceTests.testForwardAnswersAAAAWithNoDataWhileChainedBeforeAnyUpstreamWork
        if ChainedIPv6DNSPolicy.isIPv6AddressQuery(question),
            ChainedIPv6DNSPolicy.answersWithNoData(
                dropsOutboundIPv6: currentTunnelDataPathMode().dropsOutboundIPv6,
                question: question
            ),
            let noData = try? DNSMessage.emptyResponse(for: request.dnsPayload, question: question) {
            recordChainedAAAANoDataIfQA(domain: question.domain)
            if let response = responseForPendingForward(noData, pending: pending).response {
                writeDNSResponse(response, for: request, protocolNumber: protocolNumber.intValue)
            }
            return
        }
        // The chained drop of outbound IPv6 also strands a client that follows the `ipv6hint`
        // SvcParam in an HTTPS/SVCB answer (RFC 9460): it races a v6 connection the data path
        // silently drops and stalls ~15-30 s until Happy-Eyeballs falls back to v4 — the same failure
        // AAAA→NODATA fixed, seeded by a different record type. Strip just that hint from the upstream
        // RESPONSE (a surgical rewrite that keeps ALPN/ipv4hint/ECH, so a v4-only site's HTTP/3 + ECH
        // still work), applied below once the upstream answers. The record-type guard runs FIRST so
        // the `currentTunnelDataPathMode()` queue read stays off the non-service-binding hot path,
        // exactly as the AAAA gate above. Gated on `dropsOutboundIPv6` — the `::/0` claim — not
        // `isChainedUpstream`, so DNS-only (no v6 claim) is unaffected (PR #559).
        // pinned: ChainedIPv6DNSPolicyTests.testStripsIPv6HintOnlyForServiceBindingQueriesWhileDroppingIPv6
        // pinned: PacketTunnelDNSRuntimeSourceTests.testForwardStripsIPv6HintFromServiceBindingAnswersWhileChained
        let stripsIPv6Hint = ChainedIPv6DNSPolicy.isServiceBindingQuery(question)
            && currentTunnelDataPathMode().dropsOutboundIPv6
        resetResolverRuntimeStateIfNeeded(identifier: resolverConfiguration.cacheIdentifier)
        // The encrypted-fallback rejection trigger (`treatsResolverRejectionAsFallbackTrigger`)
        // derives from `currentDeviceResolverWedged()`, which is deliberately NOT part of
        // `cacheIdentifier` and does not advance the resolver-runtime generation — so a wedge flip
        // between `handle`'s capture of this plan and the resolution below is invisible to BOTH the
        // reset guard above and the `isActiveResolverRuntime` generation check. Re-read just that
        // volatile bit and recompute the trigger onto the captured plan, so a query straddling a
        // Device-DNS wedge onset is carried by the encrypted fallback instead of returning the
        // wedged resolver's error response authoritatively (the exact transition the fallback
        // exists to cover). Gated on `shouldFallbackToEncrypted` — a captured field, no queue hop —
        // so encrypted-primary resolvers (no encrypted fallback) skip the read and keep the full
        // per-query savings; everything folded into `cacheIdentifier` is still reused from capture.
        let resolverConfiguration = resolverConfiguration.shouldFallbackToEncrypted
            ? resolverConfiguration.recomputingResolverRejectionFallbackTrigger(
                deviceResolverWedged: currentDeviceResolverWedged()
            )
            : resolverConfiguration
        let resolverGeneration = currentResolverRuntimeGeneration()
        let dnsPayload = request.dnsPayload
        let protocolValue = protocolNumber.intValue

        // A key fails only for a truncated DNS header, which cannot form a valid request
        // or a SERVFAIL template. Reject it before I/O; every valid lookup uses one pipeline.
        guard let cacheKey = DNSCacheKey(resolverIdentifier: resolverConfiguration.cacheIdentifier, dnsPayload: dnsPayload) else {
            recordUnansweredDNSQuery(reason: "truncated-dns-header", query: dnsPayload)
            return
        }
        let lifetime = DNSResolutionLifetime(deadline: MonotonicDeadline(after: Self.resolverQueryLifetimeSeconds)) { [weak self] in
            guard let self else { return false }
            return self.resolverWorkIsCurrent(
                admittedAtEpoch: admittedAtEpoch, generation: resolverGeneration,
                identifier: resolverConfiguration.cacheIdentifier)
        }

        let admit = { [self] in
            guard ResolverOrchestrator.workIsAdmitted(
                snapshot: admittedAtEpoch, live: self.currentResolverAdmissionEpoch()) else {
                self.recordUnansweredDNSQuery(reason: "stale-admission-epoch-before-forward", query: dnsPayload)
                return
            }

            guard self.isActiveResolverRuntime(
                identifier: resolverConfiguration.cacheIdentifier,
                generation: resolverGeneration
            ) else {
                self.writeServerFailures(for: [pending], reason: "runtime-reset-before-forward")
                return
            }

            let now = Date()
            if let cachedResponse = self.dnsResponseCache.cachedResponse(for: cacheKey, query: dnsPayload, now: now) {
                self.recordCacheHit()
                // A cached answer is evidence about DNS, not permission under today's filter.
                // pinned: PacketTunnelDNSRuntimeSourceTests.testAliasesAreCheckedForCachedAndFreshAnswers
                guard let targets = try? DNSResponseAliases.targets(in: cachedResponse, for: question) else {
                    self.writeServerFailures(for: [pending], reason: "cached-alias-response-invalid")
                    return
                }
                let answer = self.responseForPendingForward(cachedResponse, pending: pending,
                                                            reachableAliasDomains: targets)
                if let response = answer.response {
                    self.writeDNSResponse(response, for: request, protocolNumber: protocolValue)
                }
                return
            }

            self.recordCacheMiss()

            let resolutionID: UInt64
            switch self.inFlightQueryCoalescer.enqueue(
                pending, for: cacheKey,
                retainedBytes: 2 * dnsPayload.count + (temporaryPauseNormalizedDomain?.utf8.count ?? 0) + 128) {
            case .startedResolution(let id):
                resolutionID = id
            case .joinedExistingResolution:
                self.recordCoalescedQuery()
                return
            case .rejected:
                self.writeServerFailures(for: [pending], reason: "resolver-waiter-overload")
                return
            }

            self.dispatchForwardResolution(
                cacheKey: cacheKey, resolutionID: resolutionID, lifetime: lifetime,
                query: dnsPayload,
                resolverConfiguration: resolverConfiguration,
                resolverGeneration: resolverGeneration,
                admittedAtEpoch: admittedAtEpoch,
                maximumAnswerTTL: maximumAnswerTTL,
                stripsIPv6Hint: stripsIPv6Hint
            )
        }
        // Bound retained intake before dispatching resolver work; this block performs no I/O.
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true { admit() }
        else { dnsStateQueue.sync(execute: admit) }
    }

    private func dispatchForwardResolution(
        cacheKey: DNSCacheKey, resolutionID: UInt64, lifetime: DNSResolutionLifetime,
        query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration,
        resolverGeneration: Int,
        admittedAtEpoch: UInt64,
        maximumAnswerTTL: UInt32?,
        stripsIPv6Hint: Bool
    ) {
        runBoundedResolverWork(
            retainedBytes: query.count + 256, deadline: lifetime.deadline,
            discard: { [weak self] in
                self?.dnsStateQueue.async { [weak self] in
                    guard let self else { return }
                    guard lifetime.runtimeIsCurrent else { return }
                    let pending = self.inFlightQueryCoalescer.drain(cacheKey, resolutionID: resolutionID)
                    self.writeServerFailures(for: pending, reason: "resolver-work-expired-or-overloaded")
                }
            }
        ) { [weak self] finish in
            guard let self else {
                finish()
                return
            }

            // RETRY BEFORE ANSWERING, when the refusal was ours. A resolution that never reached
            // the wire has learned nothing about the name, and the caller is still waiting on the
            // one lookup it asked for — so re-asking is invisible to it, while answering SERVFAIL
            // asserts something no datagram ever tested (`isWorthRetryingBeforeTheWire`).
            //
            // Field 2026-08-29: local refusals were costing ~23 of every 148 tunnelled
            // resolutions on a healthy device, each one a fail-closed SERVFAIL that a browser
            // treats as final for a sub-resource — pages loaded with their images and video
            // missing. The refusals are BRIEF and independent, so a second attempt usually
            // succeeds. The port-registry fix removed the bulk of them; what remains is genuine
            // transient send failure, which is exactly what a retry is for (8 in 1843 resolutions
            // over four hours, device 2026-08-29T11:11-15:14Z).
            //
            // A METHOD, not a local recursive func: Swift 6 refuses to capture one in the
            // `@Sendable` resolver completion, and `swift test` does not compile this target so
            // only the app build catches it.
            self.attemptForwardResolution(
                remaining: Self.resolverRefusalRetryLimit,
                cacheKey: cacheKey, resolutionID: resolutionID, lifetime: lifetime,
                query: query,
                resolverConfiguration: resolverConfiguration,
                resolverGeneration: resolverGeneration,
                admittedAtEpoch: admittedAtEpoch,
                maximumAnswerTTL: maximumAnswerTTL,
                stripsIPv6Hint: stripsIPv6Hint,
                startedAt: Date(),
                finish: finish)
        }
    }

    /// One attempt of a forwarded resolution, re-entering itself while the refusal was ours.
    ///
    /// `remaining` counts EXTRA attempts, so the first call does the work and the recursion only
    /// happens on a pre-wire refusal. The resolver-work token is passed down and released on the
    /// terminal path ONLY — the work genuinely is not finished while a retry is pending, and
    /// releasing it early would let a bounded pool start unbounded retry chains.
    ///
    /// `startedAt` is threaded from the first attempt so the reported duration covers what the
    /// CLIENT waited, retries included, rather than resetting to flatter the last one.
    ///
    /// `isWorthRetryingBeforeTheWire` is an ALLOWLIST of transient local failures, not "anything
    /// that did not end the ladder": a latched egress-policy refusal and a lifecycle that ended
    /// both reproduce themselves exactly, so retrying either only spends the budget and delays a
    /// fail-closed answer by ~80 ms while holding a resolver slot. They fall through to the
    /// SERVFAIL below, which #620's `upstream-produced-no-response` traces.
    /// pinned: PacketTunnelDNSRuntimeSourceTests.testThePreWireRetryIsBoundedAndDelayed
    private func attemptForwardResolution(
        remaining: Int,
        cacheKey: DNSCacheKey, resolutionID: UInt64, lifetime: DNSResolutionLifetime,
        query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration,
        resolverGeneration: Int,
        admittedAtEpoch: UInt64,
        maximumAnswerTTL: UInt32?,
        stripsIPv6Hint: Bool,
        startedAt: Date,
        finish: @escaping @Sendable () -> Void
    ) {
        let completionClaim = CompletionClaim()
        resolveUpstream(
            query,
            resolverConfiguration: resolverConfiguration,
            admittedAtEpoch: admittedAtEpoch,
            lifetime: lifetime,
            // THE FORWARDING PATH hands this to `completeForward`, which decides delivery behind
            // its own runtime guard. The rung's credit is taken there, not here.
            rungCreditTiming: .deferredToDelivery
        ) { [weak self] result in
            // A duplicate transport callback must not repeat retries, evidence, or delivery.
            // pinned: PacketTunnelDNSRuntimeSourceTests.testExpiredCompletionPreservesEvidenceBeforeClientSettlement
            guard completionClaim.claim() else { return }
            guard let self else {
                finish()
                return
            }
            // NO T1 RUNG CAN BE DOUBLE-COUNTED HERE, and it is worth saying because
            // `resolveUpstream`'s wrapper records rung evidence on EVERY attempt while
            // `completeForward` records the merged result once — so a retried resolution carrying
            // a rung would report it two or three times under a per-resolution denominator.
            // It cannot: `upstreamDeclinedToServe` opens the rung only when some attempt
            // `reachedTheWire`, and `isWorthRetryingBeforeTheWire` requires that none did. The two
            // are mutually exclusive by construction, so a retried attempt has no rung to record
            // (Kilo, PR #623 — raised as a defect, refuted here). A change to either predicate
            // that broke the exclusion would create the skew silently, which is why this is
            // written down rather than left to be re-derived.
            if remaining > 0, result.isWorthRetryingBeforeTheWire {
                #if DEBUG || LAVA_QA_TOOLS
                EnergyCounters.shared.recordChainedDNSPreWireRetry()
                #endif
                // 🔴 INV-QUEUE-1: THE RETRY MUST NOT LAND ON `dnsStateQueue`. `attemptForwardResolution`
                // re-enters `resolveUpstream`, which bottoms out in `resolveUDP`'s blocking
                // `recvfrom` (up to `udpDNSTimeoutSeconds`) — and `dnsStateQueue` is SERIAL, so a
                // retry scheduled there stalls query intake, every pool worker parked in
                // `resolverSocketBinding`'s `dnsStateQueue.sync`, `completeForward`, and the
                // coalescer drain, for the whole timeout. The provider states this prohibition in
                // red at the leak-canary send and again at the bootstrap broker, and rejects a
                // stronger safety fix elsewhere on exactly these grounds.
                //
                // Worst on the HAPPY path, which is what makes it insidious: the retry exists
                // because the second attempt usually reaches the wire, so the successful case is
                // the one that blocks longest. Caught by the pre-push panel, not by the suite —
                // no test exercises queue occupancy.
                // pinned: PacketTunnelDNSRuntimeSourceTests.testThePreWireRetryIsBoundedAndDelayed
                self.resolverQueue.asyncAfter(
                    deadline: .now() + Self.resolverRefusalRetryDelay
                ) { [weak self] in
                    guard let self else {
                        finish()
                        return
                    }
                    self.attemptForwardResolution(
                        remaining: remaining - 1,
                        cacheKey: cacheKey, resolutionID: resolutionID, lifetime: lifetime,
                        query: query,
                        resolverConfiguration: resolverConfiguration,
                        resolverGeneration: resolverGeneration,
                        admittedAtEpoch: admittedAtEpoch,
                        maximumAnswerTTL: maximumAnswerTTL,
                        stripsIPv6Hint: stripsIPv6Hint,
                        startedAt: startedAt,
                        finish: finish)
                }
                return
            }
            defer {
                finish()
            }
            let result = result.recordingDuration(since: startedAt)

            self.dnsStateQueue.async { [weak self] in
                self?.completeForward(
                    cacheKey: cacheKey, resolutionID: resolutionID, lifetime: lifetime,
                    query: query,
                    resolverIdentifier: resolverConfiguration.cacheIdentifier,
                    resolverGeneration: resolverGeneration,
                    maximumAnswerTTL: maximumAnswerTTL,
                    stripsIPv6Hint: stripsIPv6Hint,
                    result: result
                )
            }
        }
    }

    /// Extra attempts for a resolution refused before the wire, beyond the first.
    ///
    /// Two, not more: the observed refusals are brief and independent, so the second attempt
    /// carries most of the rescue and a third is nearly free insurance. Beyond that the added
    /// latency on a genuinely refusing path stops buying anything, and this runs inside a bounded
    /// resolver pool whose slots a long chain would hold.
    private static let resolverRefusalRetryLimit = 2

    /// Spacing between those attempts.
    ///
    /// Short enough to stay inside one lookup the client is already waiting on — three attempts
    /// cost ~80 ms of added latency in the worst case, against a stub timeout measured in seconds.
    /// Non-zero on purpose: a zero-delay loop against a resource condition (a descriptor the
    /// kernel has not released, an interface mid-rebind) just spends the budget before the
    /// condition can clear.
    private static let resolverRefusalRetryDelay: DispatchTimeInterval = .milliseconds(40)

    func runBoundedResolverWork(
        retainedBytes: Int, deadline: MonotonicDeadline,
        discard: @escaping @Sendable () -> Void,
        _ work: @escaping @Sendable (_ finish: @escaping @Sendable () -> Void) -> Void
    ) {
        resolverAdmissionQueue.async { [weak self] in
            guard let self else { return }
            for expired in self.resolverConcurrencyAdmission.expire() { expired.discard() }
            let submission = self.resolverConcurrencyAdmission.submit(
                ResolverQueuedWork(start: work, discard: discard),
                retainedBytes: retainedBytes, deadline: deadline)
            if !submission.accepted { discard() }
            if let lease = submission.started { self.startResolverLease(lease) }
            self.scheduleResolverAdmissionExpiry()
        }
    }

    private func startResolverLease(_ lease: BoundedWorkAdmission<ResolverQueuedWork>.Lease) {
        resolverQueue.async { [weak self] in
            guard let self else { return }
            let completion = ResolverWorkCompletion { [weak self] in
                self?.releaseResolverAdmissionSlot(lease.id)
            }
            lease.work.start { completion.complete() }
        }
    }

    private func releaseResolverAdmissionSlot(_ id: UInt64) {
        resolverAdmissionQueue.async { [weak self] in
            guard let self else { return }
            let result = self.resolverConcurrencyAdmission.complete(id)
            for expired in result.expired { expired.discard() }
            if let lease = result.started { self.startResolverLease(lease) }
            self.scheduleResolverAdmissionExpiry()
        }
    }

    // One continuous-clock timer per owner. Client expiry never releases active I/O slots.
    private func scheduleResolverAdmissionExpiry() {
        let next = resolverConcurrencyAdmission.nextDeadline
        guard next != resolverAdmissionExpiryDeadline else { return }
        resolverAdmissionExpiryTask?.cancel()
        resolverAdmissionExpiryDeadline = next
        guard let next else { resolverAdmissionExpiryTask = nil; return }
        resolverAdmissionExpiryTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: next.instant) }
            catch { return }
            self?.resolverAdmissionQueue.async { [weak self] in
                guard let self, self.resolverAdmissionExpiryDeadline == next else { return }
                for expired in self.resolverConcurrencyAdmission.expire() { expired.discard() }
                self.scheduleResolverAdmissionExpiry()
            }
        }
    }

    // dnsStateQueue owns every reset; retiring waiters also purges inert admission work.
    // pinned: PacketTunnelDNSRuntimeSourceTests.testEveryResolverResetPurgesPendingAdmissionWork
    func drainPendingDNSResponses() -> [PendingDNSResponse] {
        let pending = inFlightQueryCoalescer.drainAll()
        discardPendingResolverWork()
        return pending
    }

    private func discardPendingResolverWork() {
        resolverAdmissionQueue.async { [weak self] in
            guard let self else { return }
            for work in self.resolverConcurrencyAdmission.discardPending() { work.discard() }
            self.scheduleResolverAdmissionExpiry()
        }
    }

    func runResolverSmokeProbeWork(
        _ work: @escaping @Sendable (_ finish: @escaping @Sendable () -> Void) -> Void
    ) {
        resolverSmokeProbeQueue.async {
            let completion = ResolverWorkCompletion {}
            work {
                completion.complete()
            }
        }
    }

    /// The single funnel every answer leaves through — the bootstrap answer, the blocked answer,
    /// the AAAA NODATA, a cache hit, the synthesized SERVFAIL and every forwarded reply.
    ///
    /// Its one failure is silent by construction: it returns `Void`, so a caller cannot tell a
    /// written answer from a discarded one, and every one of them proceeds as though the client
    /// was served. That makes it the last place a query can disappear, under all the seams the
    /// rest of this trace covers.
    ///
    /// - Parameter tracesDiscardedAnswer: pass `false` when the caller has ALREADY recorded this
    ///   client as unanswered, or the same loss is exported twice under two independently
    ///   suppressed reasons — so even a first occurrence reads as two (Codex P2, PR #620).
    ///   Three callers do: `writeServerFailures` (the whole batch, via
    ///   `recordUnansweredDNSBatch`), `writeParseFailureResponse` (its caller traces
    ///   `unparseable-question` immediately before), and `completeForward` — but only for the
    ///   waiters its failure count actually covers, which excludes one served a replacement
    ///   block answer. Defaults to `true`: every other write site is the only record its client
    ///   has, so a new caller must opt out rather than forget to opt in.
    /// pinned: PacketTunnelDNSRuntimeSourceTests.testTheWriteFunnelTracesADiscardedAnswer
    func writeDNSResponse(
        _ dnsPayload: Data,
        for request: any DNSDatagramRequest,
        protocolNumber: Int,
        tracesDiscardedAnswer: Bool = true
    ) {
        guard let packet = request.response(dnsPayload: dnsPayload) else {
            // The family's `response` refuses exactly one thing: a datagram that will not fit
            // its 16-bit length field — a DNS message over 65507 bytes over IPv4 (total length)
            // or over 65527 over IPv6 (payload length). Nothing upstream
            // bounds that — the length-framed transports (DoT, DoQ, TCP) read a 2-byte length
            // with no ceiling and DoH checks only a 12-byte floor, so a reply in the top bytes
            // of the representable range reaches here and is thrown away. Extreme, and it is not
            // the 2026-08-29 field case, but it is STICKY where the others are not: the forward
            // path stores the answer in the response cache BEFORE this write, so every later hit
            // on that key repeats the drop for the entry's whole TTL. Absent a trace, that reads
            // as one domain that simply never resolves while every counter stays clean.
            //
            // Keyed on the CLIENT'S query, not on `dnsPayload`: the shape must describe what was
            // asked. A response carries the question too, but it is the oversized thing here and
            // a truncated or damaged one would classify as "unparsed" — losing the A/AAAA split
            // precisely for the seam that produced it.
            if tracesDiscardedAnswer {
                recordUnansweredDNSQuery(
                    reason: "response-datagram-not-representable", query: request.dnsPayload)
            }
            return
        }

        // THE WRITE CAN BE REFUSED, and the result is `@discardableResult` so ignoring it looks
        // like ordinary code. `NEPacketTunnelFlow` returns false when the flow is closed — which
        // happens during lifecycle teardown, exactly when a batch of answers is most likely to be
        // in flight. Without this the trace reports those replies as delivered, which is the
        // reassuring direction and the one that sends the next capture the wrong way (Codex P2,
        // PR #620). Same `tracesDiscardedAnswer` gate as the framing failure above, so a batch
        // `completeForward` already classified is not counted twice.
        let didWrite = packetFlow.writePackets(
            [packet], withProtocols: [NSNumber(value: protocolNumber)])
        if !didWrite, tracesDiscardedAnswer {
            recordUnansweredDNSQuery(
                reason: "packet-flow-refused-the-write", query: request.dnsPayload)
        }
    }

    /// - Parameter admittedAtEpoch: the session that ACCEPTED this work. Required, not
    ///   defaulted: resolver work is admitted through a bounded FIFO that retains over-bound
    ///   requests, so a query accepted in one session can reach the orchestrator only after
    ///   the next has begun — and an epoch snapshotted down there would name the WRONG
    ///   session and admit everything (Codex P1, PR #524). Every caller therefore states the
    ///   epoch it was accepted under, captured before it could queue.
    /// - Parameter rungCreditTiming: how this caller justifies the T1 rung's outage credit — see
    ///   ``TierOneRungCreditTiming``. Stated by every caller rather than defaulted, because the
    ///   forwarding and probe evidence have different delivery gates.
    private func resolveUpstream(
        _ query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration,
        purpose: ResolverQueryPurpose = .forwarding,
        admittedAtEpoch: UInt64,
        lifetime: DNSResolutionLifetime? = nil,
        rungCreditTiming: TierOneRungCreditTiming,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        let orchestrator = lifetime.map {
            resolverOrchestrator.scoped(to: $0, executors: makeResolverExecutors(lifetime: $0))
        } ?? resolverOrchestrator
        orchestrator.resolveUpstream(
            query,
            plan: resolverConfiguration,
            usesIsolatedEncryptedConnections: purpose.usesIsolatedEncryptedConnection,
            admittedAtEpoch: admittedAtEpoch,
            completion: { [weak self] result in
                if lifetime?.isAdmitted ?? true {
                    self?.recordTierOneRungIfPresent(result, creditTiming: rungCreditTiming)
                }
                completion(result)
            }
        )
    }

    /// Records the chained T1 rung's outcome, if this resolution had one.
    ///
    /// BOTH orchestrator entry points funnel here, because both can produce a rung and each
    /// returns its own merged result — the forwarding path and the smoke probe alike. Counting
    /// the probe's rungs matches how T0 is already counted: `resolveTunnelledPlainDNS` records
    /// its verdict whoever asked for the resolution, so excluding the probe here would make the
    /// two tiers' numbers describe different populations.
    ///
    /// Nil for every resolution that had no rung, which is nearly all of them, so the latch read
    /// inside the recorder is not on the common path.
    /// pinned: ChainedDNSEvidenceCounterSourceTests.testBothOrchestratorEntryPointsRecordTheRung
    private func recordTierOneRungIfPresent(
        _ result: DNSResolutionResult, creditTiming: TierOneRungCreditTiming
    ) {
        guard let evidence = result.tierOneRung else { return }
        // THE COUNTERS ARE QA-ONLY, exactly like T0's own recording. `recordChainedDNSEvidence`
        // and the `health.chainedFallback*` counters it moves live inside
        // `#if DEBUG || LAVA_QA_TOOLS` because the chained settings panel that reads them is a QA
        // surface. The rung's evidence must be scoped identically or the two tiers would be
        // counted in different builds — and in a Release build this would not even compile, since
        // the recorder is behind the same flag.
        #if DEBUG || LAVA_QA_TOOLS
        recordChainedTierOneRungEvidence(evidence)
        #endif
        // THE OUTAGE CREDIT IS NOT, and the gate above is why the rung fetch moved out of it.
        // This arm changes what the driver does — whether a healthy session surrenders — so
        // scoping it to QA builds would ship the defect to every user and fix it only for us.
        // A served rung is the tunnel-DNS cause's disarming evidence in the one case T0 can never
        // supply it: a split-tunnel upstream whose `DNS =` answers its own namespace and drops
        // the rest, where every public name is a tunnelled non-answer the rung then rescues
        // (field 2026-09-01 — see `reportTierOneRungRescue`).
        //
        // `ladderServed`, NOT `outcome == .served`, and the difference is the user's own T2.
        // `outcome` is the SELECTION's verdict — the right question for the counters above and
        // the wrong one here: a user whose T1 is dark and whose configured T2 answered received
        // a real answer and was not blackholed, so surrendering chaining on their behalf honours
        // no intent they expressed. The tiers beneath T1 exist to answer; when they do, this
        // credit says so. See `ResolverOrchestrator.TierOneRungEvidence.ladderServed`.
        //
        // Forwarding credits only inside completeForward's runtime, waiter and lifetime gates.
        // Probes have no client; their credit is fenced by the runtime that scheduled them.
        // pinned: ChainedDNSEvidenceCounterSourceTests.testAServedRungCreditsTheOutageDriverInEveryBuild
        guard evidence.ladderServed else { return }
        switch creditTiming {
        case .deferredToDelivery:
            return
        case .noClient(let admittedAtRuntimeGeneration):
            guard currentResolverRuntimeGeneration() == admittedAtRuntimeGeneration else { return }
        }
        reportTierOneRungRescue(
            forLifecycle: evidence.originatingLifecycle,
            latchEpoch: evidence.originatingLatchEpoch)
    }

    /// Credits a served physical T1 rung only in the lifecycle and latch that admitted it.
    /// The validation and report share one DNS-state critical section; forwarded responses
    /// additionally pass completeForward's runtime and client-lifetime gates.
    func reportTierOneRungRescue(forLifecycle generation: UInt64, latchEpoch: UInt64) {
        let submit = {
            guard self.tunnelLifecycleIsActive,
                generation == self.tunnelLifecycleGeneration,
                latchEpoch == self.tunnelDataPathLatchEpoch,
                let driver = self.chainedRuntime?.driver
            else { return }
            driver.reportTierOneRungRescue()
        }
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            submit()
            return
        }
        dnsStateQueue.sync(execute: submit)
    }

    /// - Parameter admittedAtEpoch: see `resolveUpstream`. The smoke probe hops to its own
    ///   queue before resolving, which is the same "accepted here, runs later" shape.
    /// - Parameter rungCreditTiming: see `resolveUpstream`. The SMOKE PROBE is `.noClient`, which
    ///   is a fence rather than an exemption: it must still credit — probe queries produce T0
    ///   `.unanswered` observations like any other resolution, so withholding their rescues would
    ///   let an idle device declare against a ladder that was serving — but with no client to
    ///   appeal to, a probe that outlived its resolver runtime is describing something else.
    func resolvePrimaryUpstream(
        _ query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration,
        purpose: ResolverQueryPurpose = .forwarding,
        admittedAtEpoch: UInt64,
        rungCreditTiming: TierOneRungCreditTiming,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        resolverOrchestrator.resolvePrimaryUpstream(
            query,
            plan: resolverConfiguration,
            usesIsolatedEncryptedConnections: purpose.usesIsolatedEncryptedConnection,
            admittedAtEpoch: admittedAtEpoch,
            completion: { [weak self] result in
                self?.recordTierOneRungIfPresent(result, creditTiming: rungCreditTiming)
                completion(result)
            }
        )
    }

    /// Whether the DATA PATH a T1 rung was admitted under is still installed.
    ///
    /// `nil` means the work carries no latch token — every `.planned` resolution — and passes
    /// without reading anything. Only the chained T1 rung supplies one.
    ///
    /// SEPARATE FROM ``currentResolverAdmissionEpoch``, which answers a different question: that
    /// one is the tunnel LIFECYCLE, and a relatch does not move it. Replacing the latched resolver
    /// or fallback policy leaves every admission guard passing while the rung's plan is already
    /// stale — so without this the rung kept sending to the resolver the user had just switched
    /// OFF, one wire attempt per remaining address (Codex P2, PR #608 → PR #610).
    ///
    /// Read on `dnsStateQueue` with the same specific-key re-entrancy pattern the rest of the
    /// provider's state uses (`INV-QUEUE-1`).
    /// pinned: TunnelDataPathLatchSourceTests.testThePlainLadderRefusesEveryAddressAfterARelatch
    func resolverLatchIsCurrent(_ admittedAtLatchEpoch: UInt64?) -> Bool {
        guard let admittedAtLatchEpoch else { return true }
        let read: () -> Bool = { admittedAtLatchEpoch == self.tunnelDataPathLatchEpoch }
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return read()
        }

        return dnsStateQueue.sync(execute: read)
    }

    /// Checks lifecycle and resolver identity together on their owning queue.
    /// pinned: PacketTunnelDNSRuntimeSourceTests.testResolverLifetimeReadsOneCoherentRuntimeIdentity
    func resolverWorkIsCurrent(admittedAtEpoch: UInt64, generation: Int, identifier: String? = nil) -> Bool {
        let read: () -> Bool = {
            ResolverOrchestrator.workIsAdmitted(
                snapshot: admittedAtEpoch,
                live: self.tunnelLifecycleIsActive ? self.tunnelLifecycleGeneration : 0)
                && self.resolverRuntimeGeneration == generation
                && (identifier == nil || self.activeResolverRuntimeIdentifier == identifier)
        }
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return read()
        }
        return dnsStateQueue.sync(execute: read)
    }

    /// The lifecycle generation resolution may run under, or zero when none may.
    ///
    /// Read on `dnsStateQueue` like every other lifecycle read (`INV-QUEUE-1`), through the
    /// same dual-entry pattern, because the orchestrator consults it from the resolver queues
    /// AND from paths already on `dnsStateQueue`. One `sync` per resolution and per endpoint
    /// rung — the same cost profile as `egressAllowance`, which is consulted on the same
    /// path, and never per packet.
    func currentResolverAdmissionEpoch() -> UInt64 {
        let read: () -> UInt64 = {
            self.tunnelLifecycleIsActive ? self.tunnelLifecycleGeneration : 0
        }
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return read()
        }

        return dnsStateQueue.sync(execute: read)
    }

    /// Publishes raw T1 selection, admitted physical endpoints, and each endpoint's outcome.
    /// Raw identity detects settings changes; admitted endpoints name the counters' evidence.
    /// Publish at runtime start for idle-session visibility, then only when the latch changes.
    /// Confined to dnsStateQueue.
    /// pinned: ChainedFallbackPublicationSourceTests.testTheLatchIsPublishedWhenTheRuntimeStarts
    func publishChainedFallbackOutcomesOnQueue(
        configuration: ChainedUpstreamConfiguration
    ) {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        // ONE LATCH, read once, for both the enumeration and the identity. Publishing the
        // endpoints from one read and the identity from another would let a latch install between
        // them and put two selections in one snapshot.
        let latch = latchedChainedTierOneResolverConfiguration
        // THE SAME LIST THE OUTCOMES ARE DERIVED FROM, via the one shared helper — see
        // ``tierOneEndpoints``. A device-DNS selection's addresses are the tunnel's live capture,
        // so reading `chainedTierOneResolverEndpoints` here would publish an empty "latched" set
        // beside outcomes that enumerate real resolvers.
        let deviceResolvers = currentDeviceDNSResolverAddresses()
        let latched = latch.map {
            Self.tierOneEndpoints(latched: $0, deviceResolvers: deviceResolvers)
        } ?? []
        // Derived by the type that owns the gate, because only it can tell WHICH rule refused an
        // address — this was open-coded against route coverage, which reported every unusable AND
        // unrouted address (a multicast literal on a split tunnel) as a routing miss, and had no
        // executable coverage because it lived in the provider (Kilo, PR #575).
        let outcomes = Self.tierOneOutcomes(
            latched: latch, deviceResolvers: deviceResolvers, upstream: configuration)
        // THE ADMITTED OUTCOMES, not the tunnel's append list. The tunnelled route carries no
        // T1 at all since PR #590. The snapshot field's contract is "the endpoints the
        // fallback counters aggregate", and those counters move for exactly the admitted ones;
        // publishing empty against moving counters breaks the settings panel's attribution and
        // the bug report's diagnostics (Codex, PR #590).
        let effective = outcomes.filter { $0.disposition == .admitted }.map(\.address)
        // THE IDENTITY, not the endpoint list, is what the freshness check compares.
        //
        // Endpoints alone cannot tell one transport of a provider from another whenever both
        // reach the same host — Cloudflare DoT and DoH differ in scheme and port, not in name —
        // and the panel would report "current" for a session running the other one. The identity
        // carries the preset ID, the transport and every endpoint, so it separates every pair
        // that is genuinely a different resolver (the plan's S4 obligation).
        // pinned: ChainedFallbackPublicationSourceTests.testTheLatchedIdentityIsPublishedForTheFreshnessCheck
        let identity = latch?.chainedTierOneResolverIdentity ?? ""
        // THE COUNTER KEYS, which are not the endpoints above. An encrypted attempt is recorded
        // under the endpoint's `cacheIdentifier` (`doh:<absolute URL>`), and that is what the bug
        // report's redaction folds on — a host-only map matched nothing (Codex P1, PR #591).
        // pinned: ChainedFallbackPublicationSourceTests.testTheAttemptKeysArePublishedForTheRedaction
        let attemptKeys = latch?.chainedTierOneResolverAttemptKeys ?? []
        // The CONFIGURATION's selection inputs, not just the chosen addresses: admission also
        // depends on `AllowedIPs`, the conf's own `DNS =` and the client address, so a
        // full-tunnel-to-split replacement reverses the verdict while the addresses stay put
        // (Codex, PR #575). A fingerprint, never the fields — they name the operator's
        // infrastructure and this snapshot travels in bug reports.
        let configurationFingerprint = configuration.resolverSelectionFingerprint
        // EVIDENCE IS SCOPED TO THE ADDRESSES IT WAS COLLECTED FROM, and until PR #592 that was
        // free: every selection's endpoints were fixed at latch, so the effective set could not
        // move under a running session and the counters could only ever describe one resolver.
        //
        // A DEVICE-DNS SELECTION BREAKS THAT, and it is the only one that can. Its addresses are
        // the tunnel's live capture, so a roam from wifi to cellular hands the rung a different
        // resolver mid-session while every term below keeps accumulating. The panel would then
        // report the new network's resolver as "Working" on the strength of rescues the previous
        // network's resolver produced, and stay wrong until enough fresh failures outvoted them
        // (Codex P2, PR #592).
        //
        // BOTH FALLING TERMS, not just one, and the second is the sharper of the two. There are
        // two recency streaks and they ask different questions: `chainedFallbackUnansweredStreak`
        // is "did anything come back", `chainedFallbackUnhelpfulReplyStreak` is "did what came
        // back help". `ChainedFallbackStatus.status` reads the latter FIRST — at or above
        // `consecutiveUnansweredFailureThreshold` it returns `.answeringWithoutResolving` and no
        // later branch runs — so a stale unhelpful streak does not merely tint the reading, it
        // decides it. Clearing four of the five would have let a previous network's soft-failing
        // resolver condemn the new one outright (Kilo, PR #592).
        //
        // THE IDENTITY IS THE SECOND WAY THE EVIDENCE GOES STALE, and PR #599 is what made it
        // reachable. Until the reload handler could relatch the rung in place, the latch was
        // installed once per session and the identity could not move under running counters, so
        // the effective set was the only term that could. It is not a superset of the identity:
        // two selections can publish the SAME admitted addresses and still be different
        // resolvers — a DoH and a DoT preset on one hostname, or two custom DoH URLs on one
        // host — and the panel would then read the previous resolver's attempts, rescues and
        // streaks as the new one's, labelling it working or broken on evidence it never
        // produced (Codex P2, PR #599).
        //
        // GATED ON `chainedFallbackEvaluated` so the FIRST publish of a session — where the
        // previous value is the empty default — is not read as a change and does not clear
        // counters that belong to this session. Transient captures do not churn this either: the
        // capture itself already preserves the last usable set when iOS briefly reports only
        // Lava's own tunnel DNS (``setDeviceDNSResolverAddresses(_:preserveOnEmptyCapture:)``).
        // Nor does the identity churn: it is derived from the latch, so it moves only when a
        // latch is installed or replaced, never per query.
        // pinned: ChainedFallbackPublicationSourceTests.testAChangedEffectiveSetResetsTheFallbackEvidence
        //
        // THE POLICY IDENTITY, NOT THE PUBLISHED RESOLVER IDENTITY, and the difference is the same
        // one the relatch above turns on. `identity` names the resolver the rung asks FIRST, which
        // is what the panel's freshness check needs; the counters describe the whole LADDER and go
        // stale for strictly more reasons. A change to `fallbackToDeviceDNS`,
        // `usesEncryptedDeviceDNSFallback` or the encrypted fallback preset relatches the rung and
        // changes whether a T1 attempt ends up answering, while leaving both the resolver
        // identity and the effective address set byte-identical — so the panel labelled the new
        // policy working or broken on the old policy's evidence (Codex P2, PR #599). The policy
        // identity is a superset of the resolver identity, so it replaces that term rather than
        // joining it.
        let policyIdentity = latch?.chainedTierOneRungPolicyIdentity ?? ""
        // HOISTED, because the stamp below makes the comparison equal again — and the change gate
        // needs the same answer AFTER that.
        let policyChangedUnderIt = publishedFallbackEvidencePolicyIdentity != policyIdentity
        if health.chainedFallbackEvaluated,
            health.chainedFallbackEffectiveAddresses != effective || policyChangedUnderIt {
            health.chainedFallbackAttemptCount = 0
            health.chainedFallbackAnswerCount = 0
            health.chainedFallbackRescueCount = 0
            health.chainedFallbackUnansweredStreak = 0
            health.chainedFallbackUnhelpfulReplyStreak = 0
        }
        // STAMPED UNCONDITIONALLY, not inside the reset. The evidence from here on was gathered
        // under the CURRENT policy whether or not anything was cleared, so leaving this behind on
        // a publish that did not reset would make the next publish reset for a change already
        // accounted for.
        publishedFallbackEvidencePolicyIdentity = policyIdentity
        // RETIRED, NOT FORGOTTEN — and deliberately NOT nested in the reset above.
        //
        // The PER-ADDRESS maps (`resolverAttemptCounts` and siblings) are session-wide and keyed
        // by whichever address was tried, so an address this publish drops from the lists stays in
        // them. `redactedFallbackIdentities()` folds using the CURRENT lists, so a dropped address
        // reaches a bug report as a verbatim key — a LAN or ISP resolver naming the user's network
        // (Codex P1, PR #592).
        //
        // THE TWO QUESTIONS HAVE DIFFERENT ANSWERS, which is why this is its own block. Resetting
        // the counters asks "does the evidence still describe what we are asking", and only the
        // EFFECTIVE set can answer that — those counters move for admitted addresses. Retiring
        // asks "is an address leaving the snapshot while still keying the maps", and the LATCHED
        // list answers that independently: a roam can replace an `.alreadyPrimary` address —
        // latched, never effective, and keyed in the maps because T0 asks it — while the
        // admitted set does not move at all. Nested under the reset, that address was dropped
        // unretired and unfolded (Codex P1, second round).
        //
        // The maps cannot be folded here instead: they are owned by `ResolverHealthEvidence` and
        // projected into this snapshot, so a write would be overwritten by the next projection.
        //
        // THE ATTEMPT KEYS RETIRE TOO, and they are a THIRD list, not a spelling of the other two.
        // An encrypted attempt is recorded under the endpoint's `cacheIdentifier`
        // (`doh:https://host/path`) while the latched list carries only the host, so a Custom DoH
        // URL that changes its path or query keeps the same host on both sides of a relatch — the
        // address lists do not move at all — while the old full URL is dropped from
        // `chainedFallbackAttemptKeys` and left keying the session-wide counter maps. It then
        // reached a bug report verbatim, which is the same disclosure this block exists to stop,
        // through the one list it did not read (Codex P1, PR #592, on a retro review of the
        // merged code).
        //
        // ONE RETIRED LIST FOR BOTH because both are KEYS OF THE SAME MAPS and both fold to the
        // same T1 placeholder in `redactedFallbackIdentities()`. Splitting them would buy a
        // more precise field name and a second thing to forget.
        //
        // ONLY WHAT IS ACTUALLY LEAVING. A key still named by any new list is still folded by it
        // and does not belong here. Unique, order preserved, append-only: anything this session
        // has asked stays foldable for the rest of it.
        // pinned: ChainedFallbackPublicationSourceTests.testRetiredAddressesStayFoldableForRedaction
        if health.chainedFallbackEvaluated {
            var retired = health.chainedFallbackRetiredAddresses
            for key in health.chainedFallbackEffectiveAddresses
                + health.chainedFallbackLatchedAddresses
                + health.chainedFallbackAttemptKeys
            where !key.isEmpty && !effective.contains(key) && !latched.contains(key)
                && !attemptKeys.contains(key) && !retired.contains(key) {
                retired.append(key)
            }
            health.chainedFallbackRetiredAddresses = retired
        }
        // THE POLICY TERM JOINS THE GATE TOO, or the reset above only clears the copy nobody
        // reads. A ladder-policy change moves neither the addresses nor the published resolver
        // identity — that is the whole reason the reset needed its own scope — so every other term
        // here is false and this returns BEFORE `markHealthCountersUpdated()`, leaving the
        // persisted counters the settings surface and bug reports read describing the old policy
        // (the same defect Codex found on PR #601's capture term, which this one mirrors).
        guard !health.chainedFallbackEvaluated
            || policyChangedUnderIt
            || health.chainedFallbackLatchedAddresses != latched
            || health.chainedFallbackLatchedIdentity != identity
            || health.chainedFallbackAttemptKeys != attemptKeys
            || health.chainedFallbackLatchedConfigurationFingerprint != configurationFingerprint
            || health.chainedFallbackEffectiveAddresses != effective
            || health.chainedFallbackOutcomes != outcomes
        else { return }
        health.chainedFallbackEvaluated = true
        health.chainedFallbackLatchedAddresses = latched
        health.chainedFallbackLatchedIdentity = identity
        health.chainedFallbackAttemptKeys = attemptKeys
        health.chainedFallbackLatchedConfigurationFingerprint = configurationFingerprint
        health.chainedFallbackEffectiveAddresses = effective
        health.chainedFallbackOutcomes = outcomes
        markHealthCountersUpdated()
    }

    /// Derives the admitted T0 route and both lifecycle/latch tokens in one critical section.
    /// Per-attempt validation must compare the tokens from the same latch as the addresses;
    /// a separately read token could make a stale route appear current during replacement.
    /// A construction downgrade yields no route; physical T1 endpoints never enter this selection.
    func currentTunnelledPlainDNSRoute() -> ResolverOrchestrator.TunnelledPlainDNSRoute? {
        let derive: () -> ResolverOrchestrator.TunnelledPlainDNSRoute? = {
            // No route for an invalidated lifecycle: `invalidateTunnelLifecycle` marks
            // inactive and bumps the generation, but the latch and runtime stay
            // installed until the ASYNC cleanup — so a generation stamped in that
            // interval is post-invalidation yet validates as current. The activity bit
            // is what distinguishes "between stop and cleanup" from "running"
            // (Codex, PR #518 round 4).
            guard self.tunnelLifecycleIsActive,
                case .chainedUpstream(let configuration) = self.latchedDataPathMode
            else {
                return nil
            }
            // T0 owns this tunnel-pinned route. T1 uses the physical interface, subject to its
            // own egress gate; adding it here would misrepresent AllowedIPs coverage (PR #590).
            let selection = ChainedTunnelResolverSelection.selection(from: configuration)
            // THE ADMISSION VERDICT, recorded where it is actually made. The settings panel
            // cannot re-derive it: `ChainedTunnelResolverSelection` lives in the chained module,
            // which the app deliberately does not link (the packet tunnel is its one approved
            // consumer, `docs/architecture/module-boundaries.md`), and a second copy of the
            // AllowedIPs-coverage rule in the app is exactly the drift this selection's own doc
            // refuses. So the tunnel states what it admitted and the app reports it.
            //
            // Written ONLY on a change: this derive runs per resolution, and marking health
            // dirty on every query would churn the debounced snapshot write for a value that
            // moves once per latch.
            // TWO SETS, answering two different questions. The RAW latch is what the settings
            // surface compares against the user's current selection to detect a mid-session
            // change; the EFFECTIVE set is what the counters aggregate, so it is what the panel
            // names. Attributing the pair's evidence to one `.first` address misreported which
            // resolver answered whenever the second of a provider's two servers served — and
            // could name a T0 address when the first is deduped out (Codex, PR #575).
            // Re-published per resolution as well as at session start, because the LATCH can be
            // rewritten within a lifecycle (a construction downgrade does exactly that) and this
            // is where the new one is first seen. Change-gated, so the repeat costs a comparison.
            self.publishChainedFallbackOutcomesOnQueue(configuration: configuration)
            // T0 ONLY ON THE WIRE. The tunnelled loop now carries the conf's own `DNS =` and
            // nothing else: the T1 rung runs on the PHYSICAL interface, in the orchestrator,
            // because routing a public resolver through the peer made it depend on the peer being
            // an exit node — configuration we neither control nor can detect, and which rc9 (build
            // 1787723354) measured as three attempts dropped with nothing coming back.
            //
            // Leaving the appended set on the route would spend a UDP receive budget per T1
            // address through a peer that will not forward it, BEFORE the rung that actually
            // works — seconds of latency on exactly the lookups that are already failing.
            // pinned: TunnelDataPathLatchSourceTests.testTheTunnelledRouteCarriesTierZeroOnly
            return ResolverOrchestrator.TunnelledPlainDNSRoute(
                resolverAddresses: selection.resolvers,
                originatingLifecycle: self.tunnelLifecycleGeneration,
                originatingLatchEpoch: self.tunnelDataPathLatchEpoch)
        }
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return derive()
        }

        return dnsStateQueue.sync(execute: derive)
    }

    /// Whether a physical path change leaves the chained tunnelled plain-DNS carry unchanged — i.e. the
    /// chain is latched and `currentTunnelledPlainDNSRoute()` is non-nil, so DNS rides the tunnel to the
    /// conf's resolver on a route sealed to the current latch epoch, unmoved by a wifi↔cellular roam.
    /// When true, `handleNetworkPathUpdate` tells the resolver-health reducer to SKIP the destructive
    /// runtime reset + pending-SERVFAIL for a SATISFIED roam (task #56): the route/socket/binding all
    /// survive, so the reset only tears down physical-interface runtime the carry never uses and
    /// SERVFAILs in-flight carried queries that would have resolved. A nil route — dns-only,
    /// device-DNS-direct, or split with an off-tunnel resolver — yields false → today's full reset.
    /// `currentTunnelledPlainDNSRoute()` confines its own `dnsStateQueue` reads (getSpecific fast-path
    /// or `dnsStateQueue.sync`), so this is safe from `handleNetworkPathUpdate`'s queue (INV-QUEUE-1).
    func chainedTunnelledDNSSurvivesPhysicalPathChange() -> Bool {
        currentTunnelledPlainDNSRoute() != nil
    }
}
