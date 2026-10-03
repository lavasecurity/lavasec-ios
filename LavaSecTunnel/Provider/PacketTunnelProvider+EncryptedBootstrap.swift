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
    // MARK: - Encrypted-resolver bootstrap (endpoint hostname resolution)

    private func dohEndpointResolvingBootstrapIfNeeded(
        _ endpoint: DNSOverHTTPSEndpoint, admittedAtEpoch: UInt64
    ) -> DNSOverHTTPSEndpoint {
        // A built-in DoH endpoint ships with bootstrap IPs; a user-typed custom
        // `https://host` resolver does not. Resolve the missing bootstrap from the
        // hostname cache (warmed while Device DNS was reachable) so the DoH client
        // can connect even when the device resolver is wedged — mirroring the DoQ
        // path. Literal-IP hosts and already-bootstrapped endpoints pass through.
        guard endpoint.allBootstrapServers.isEmpty,
              let host = endpoint.url.host,
              ResolverEndpoint(address: host) == nil
        else {
            return endpoint
        }

        guard let cached = resolverBootstrapService.cachedAddresses(forHostname: host) else {
            // Never block the packet path on a bootstrap lookup: warm the cache
            // asynchronously (pre-warms at tunnel start, resolver switches, and
            // network changes make this miss rare).
            resolverBootstrapService.prewarm(hostname: host, admittedAtEpoch: admittedAtEpoch)
            return endpoint
        }

        return DNSOverHTTPSEndpoint(
            url: endpoint.url,
            bootstrapIPv4Servers: cached.ipv4,
            bootstrapIPv6Servers: cached.ipv6
        )
    }

    private func dotEndpointResolvingBootstrapIfNeeded(
        _ endpoint: DNSOverTLSEndpoint, admittedAtEpoch: UInt64
    ) -> DNSOverTLSEndpoint {
        // As with DoH/DoQ: a built-in DoT endpoint ships bootstrap IPs, a user-typed
        // custom `tls://host` resolver does not. Fill the missing IPs from the warmed
        // hostname cache so the DoT connection doesn't have to resolve its own hostname
        // through a wedged Device DNS. Literal-IP hosts and already-bootstrapped
        // endpoints pass through.
        guard endpoint.allBootstrapServers.isEmpty,
              ResolverEndpoint(address: endpoint.hostname) == nil
        else {
            return endpoint
        }

        guard let cached = resolverBootstrapService.cachedAddresses(forHostname: endpoint.hostname) else {
            resolverBootstrapService.prewarm(hostname: endpoint.hostname, admittedAtEpoch: admittedAtEpoch)
            return endpoint
        }

        return DNSOverTLSEndpoint(
            hostname: endpoint.hostname,
            port: endpoint.port,
            bootstrapIPv4Servers: cached.ipv4,
            bootstrapIPv6Servers: cached.ipv6
        )
    }

    private func doqEndpointResolvingBootstrapIfNeeded(
        _ endpoint: DNSOverQUICEndpoint, admittedAtEpoch: UInt64
    ) -> DNSOverQUICEndpoint {
        guard endpoint.allBootstrapServers.isEmpty,
              ResolverEndpoint(address: endpoint.hostname) == nil
        else {
            return endpoint
        }

        guard let cached = resolverBootstrapService.cachedAddresses(forHostname: endpoint.hostname) else {
            // Never block the packet path on a bootstrap lookup: warm the
            // cache asynchronously and let the stub resolver's retry find the
            // addresses (pre-warms at tunnel start, resolver switches, and
            // network changes make this miss rare).
            resolverBootstrapService.prewarm(hostname: endpoint.hostname, admittedAtEpoch: admittedAtEpoch)
            return endpoint
        }

        return DNSOverQUICEndpoint(
            hostname: endpoint.hostname,
            port: endpoint.port,
            bootstrapIPv4Servers: cached.ipv4,
            bootstrapIPv6Servers: cached.ipv6
        )
    }

    func prewarmResolverBootstrapIfNeeded(admittedAtEpoch: UInt64) {
        let resolverConfiguration = currentResolverRuntimeConfiguration()
        // Prewarm the primary's DoQ endpoints (when DoQ is the active transport) AND
        // any encrypted-fallback DoQ endpoints (a custom `doq://` fallback a wedged
        // Device-DNS primary keeps). The fallback host must be bootstrapped even
        // though the primary transport is Device DNS, mirroring the DoH fallback.
        var doqEndpoints = resolverConfiguration.encryptedFallbackDoQEndpoints
        if resolverConfiguration.transport == .dnsOverQUIC {
            doqEndpoints = resolverConfiguration.doqEndpoints + doqEndpoints
        }

        for endpoint in doqEndpoints
        where endpoint.allBootstrapServers.isEmpty && ResolverEndpoint(address: endpoint.hostname) == nil {
            resolverBootstrapService.prewarm(hostname: endpoint.hostname, admittedAtEpoch: admittedAtEpoch)
        }

        // Same for DoH: a user-typed custom `https://host` resolver (primary or the
        // encrypted fallback) ships no bootstrap IPs, so warm its hostname while the
        // device resolver is reachable. Built-in endpoints carry their own IPs and
        // are skipped (allBootstrapServers non-empty).
        var dohEndpoints = resolverConfiguration.encryptedFallbackEndpoints
        if resolverConfiguration.transport == .dnsOverHTTPS {
            dohEndpoints = resolverConfiguration.dohEndpoints + dohEndpoints
        }

        for endpoint in dohEndpoints where endpoint.allBootstrapServers.isEmpty {
            guard let host = endpoint.url.host, ResolverEndpoint(address: host) == nil else {
                continue
            }
            resolverBootstrapService.prewarm(hostname: host, admittedAtEpoch: admittedAtEpoch)
        }

        // And DoT: a custom `tls://host` resolver (primary or encrypted fallback)
        // connects by hostname when it has no bootstrap IPs, so warm its hostname too.
        var dotEndpoints = resolverConfiguration.encryptedFallbackDoTEndpoints
        if resolverConfiguration.transport == .dnsOverTLS {
            dotEndpoints = resolverConfiguration.dotEndpoints + dotEndpoints
        }

        for endpoint in dotEndpoints
        where endpoint.allBootstrapServers.isEmpty && ResolverEndpoint(address: endpoint.hostname) == nil {
            resolverBootstrapService.prewarm(hostname: endpoint.hostname, admittedAtEpoch: admittedAtEpoch)
        }
    }

    /// Whether this session may resolve DNS on the physical interface at all.
    ///
    /// The orchestrator's `EgressAllowance` governs everything routed THROUGH it. These
    /// paths are not: the DoQ bootstrap resolves a custom resolver's hostname with
    /// `resolvePlainDNS(... .deviceDNS)` directly, a failed smoke probe calls
    /// `resolveDeviceDNS` directly, and the probe/recovery timers arm their own wakes. All
    /// of them act on the interface the chained tunnel routed everything away from, and all
    /// are invisible to the allowance and to the `refusedByEgressPolicy` diagnostics.
    ///
    /// The ANSWER is the egress policy's, not this file's (C3). This body used to be a
    /// private copy of the rule — `!currentTunnelDataPathMode().isChainedUpstream` — which
    /// is the arrangement `ChainedResolverEgressPolicy` exists to end: suspensions that CAN
    /// diverge rather than ones that cannot. The provider contributes the one input only it
    /// knows, the latched mode, and consumes the policy's decision. The DoQ bootstrap
    /// deliberately consumes the same decision as the probes: a bootstrap hostname
    /// resolution on the physical interface is the same behaviour class the suspension
    /// covers, and the transports it would bootstrap are refused anyway.
    /// pinned: TunnelDataPathLatchSourceTests.testDirectDNSPathsAreSuppressedWhileChained
    /// pinned: TunnelDataPathLatchSourceTests.testThePhysicalInterfaceDNSSeamConsumesThePolicyDecision
    // Placed BEFORE `permitsPhysicalInterfaceDNS()` so the C3 pin
    // (`testThePhysicalInterfaceDNSSeamConsumesThePolicyDecision`), which reads the block from
    // that function to `resolveDoQBootstrapAddresses`, still sees only that function's literal-
    // free body — this helper's comment mentions "false" and would otherwise trip the pin. This
    // positioning note is above the doc comment so the `///` block stays contiguous with the
    // declaration and remains its documentation.
    /// The active DNS-health owner for the current latch.
    ///
    /// The one place the reconnect actor, the organic-evidence recorder, and (through
    /// `ChainedResolverEgressPolicy`, which sources from the same type) the physical-interface
    /// suspension all read, so no seam can derive "who owns health" differently — the gap the
    /// false-reconnect loop (#548) slipped through was one seam that had no such check yet.
    /// Reads only `currentTunnelDataPathMode()`, so it inherits that method's dual-entry safety
    /// and adds no state of its own.
    func dnsHealthAuthority() -> DNSHealthAuthority {
        DNSHealthAuthority(chainedIsLatched: currentTunnelDataPathMode().isChainedUpstream)
    }

    func permitsPhysicalInterfaceDNS() -> Bool {
        ChainedResolverEgressPolicy.permitsPhysicalInterfaceHealthProbes(
            chainedIsLatched: currentTunnelDataPathMode().isChainedUpstream)
    }

    func resolveDoQBootstrapAddresses(
        for hostname: String,
        resolverAddresses: [String],
        admittedAtEpoch: UInt64,
        lifetime: DNSResolutionLifetime? = nil
    ) -> (ipv4: [String], ipv6: [String]) {
        // No addresses rather than addresses obtained by leaking. The caller treats an empty
        // result as "could not bootstrap", which while chained is the truth: the encrypted
        // transports this would bootstrap are themselves refused, so the query buys nothing
        // and costs the user's DNS going to their ISP.
        guard permitsPhysicalInterfaceDNS() else { return ([], []) }
        // The KICK's token, carried across the bootstrap service's queue hop — this body
        // runs on the service's own serial queue, an unbounded time after the pre-warm was
        // accepted, so a capture HERE would read whatever session is live by then and every
        // downstream check would pass trivially (the panel's find, PR #524). A pre-warm
        // kicked by a session that has since ended is refused per attempt at the socket
        // seam below, exactly like every other plain ladder.
        let aQuery = DNSResolverSmokeProbe.query(
            transactionID: UInt16.random(in: 0...UInt16.max),
            domain: hostname,
            recordType: DNSRecordType.a.rawValue
        )
        let aResult = resolvePlainDNS(
            aQuery, resolverAddresses: resolverAddresses, transport: .deviceDNS,
            admittedAtEpoch: admittedAtEpoch, lifetime: lifetime)
        let ipv4 = DNSBootstrapAddressExtractor.addresses(from: aResult.response, matching: aQuery, recordType: .a)

        let aaaaQuery = DNSResolverSmokeProbe.query(
            transactionID: UInt16.random(in: 0...UInt16.max),
            domain: hostname,
            recordType: DNSRecordType.aaaa.rawValue
        )
        let aaaaResult = resolvePlainDNS(
            aaaaQuery, resolverAddresses: resolverAddresses, transport: .deviceDNS,
            admittedAtEpoch: admittedAtEpoch, lifetime: lifetime)
        let ipv6 = DNSBootstrapAddressExtractor.addresses(from: aaaaResult.response, matching: aaaaQuery, recordType: .aaaa)

        return (ipv4, ipv6)
    }

    func resolveUDP(
        _ query: Data, endpoint: ResolverEndpoint, admittedAtEpoch: UInt64,
        admittedAtLatchEpoch: UInt64? = nil,
        egressInterface: ResolverOrchestrator.EgressInterface = .providerDefault,
        lifetime: DNSResolutionLifetime? = nil
    ) -> DNSUpstreamResponse {
        // ADMISSION FIRST, at the socket seam — the same placement where the tunnelled
        // executor validates its route triple (S6, PR #518): every plain/device ladder
        // rung passes through here, so one guard below every loop covers each wire
        // attempt, however long the previous rung blocked (Codex P1, PR #524). The
        // ladder in +ResolverTransports.swift stops on this outcome; `shouldAttemptTCPFallback`
        // already
        // answers false for it.
        guard lifetime?.isAdmitted ?? true, ResolverOrchestrator.workIsAdmitted(
            snapshot: admittedAtEpoch, live: currentResolverAdmissionEpoch()
        ) else {
            return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded)
        }

        // AND THE LATCH, AT THE SAME SEAM, for the reason the guard above is placed here rather
        // than at the top of the ladder: every plain and device wire attempt passes through this
        // function, so one check here covers each of them however long the previous address
        // blocked. The T1 rung is the only caller that supplies a token; a multi-address plan
        // otherwise spent its whole walk under a policy the user had already replaced, sending to
        // the device resolver they had just switched off (Codex P2, PR #608 → PR #610).
        guard resolverLatchIsCurrent(admittedAtLatchEpoch) else {
            return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLatchReplaced)
        }

        // The per-attempt binding re-read is the DNS-only ladder's shape, and re-reading
        // is the fail-SAFE direction there: across a mid-resolution relatch the binding
        // can only get MORE confined (system-chosen → tunnel-pinned), never leak. The
        // residual it accepts is a disclosure nuance, not a leak: a DNS-only resolution
        // straddling a restart INTO a chained lifecycle sends its remaining attempts —
        // queries to the user's own configured resolver — through the new tunnel. The
        // tunnelled executor must NOT use this entry point: its direction of the same
        // race is the leak, so it decides per attempt through
        // `resolverSocketBinding(forLifecycle:)` instead.
        //
        // THE T1 RUNG OVERRIDES IT, and must: `currentResolverSocketBinding()` keys only on
        // whether chained is latched, so it pins the rung to the utun — sending the query to a
        // peer that will not forward it, which is the failure the rung exists to remove (Codex,
        // PR #590). The policy owns both answers so the leak rules stay in one file.
        // pinned: TunnelDataPathLatchSourceTests.testTheTierOneRungOverridesTheChainedSocketBinding
        let binding: ChainedResolverSocketBinding
        switch egressInterface {
        case .providerDefault:
            binding = currentResolverSocketBinding(for: endpoint)
        case .physical:
            binding = ChainedResolverEgressPolicy.tierOneSocketBinding(
                destinationIsFloorClaimed: deviceResolverIsFloorClaimed(endpoint.addressLiteral),
                destinationIsProfileCovered: latchedChainedAllowedIPsCover(endpoint.addressLiteral),
                physicalInterfaceIndex: currentPhysicalInterfaceIndex())
        }
        return resolveUDP(query, endpoint: endpoint, bindingDecision: binding, lifetime: lifetime)
    }

    func resolveUDP(
        _ query: Data, endpoint: ResolverEndpoint, bindingDecision: ChainedResolverSocketBinding,
        lifetime: DNSResolutionLifetime? = nil
    ) -> DNSUpstreamResponse {
        // Strict-mode provider DNS uses the lifecycle-bound direct engine path below.
        // Never fall back to a kernel socket when that path cannot admit a query.
        guard !protocolConfiguration.includeAllNetworks else {
            return DNSUpstreamResponse(response: nil, outcome: .refusedByEgressPolicy)
        }
        // A short-lived per-query socket (like TCPResolver) so the blocking recvfrom
        // runs on the concurrent resolverQueue instead of serializing every plain/
        // device UDP query through one queue — a single slow/unreachable resolver
        // otherwise head-of-line-blocks all plain/device DNS for up to the UDP
        // timeout. Per-query sockets also mean concurrent queries never share one FD,
        // removing the cross-talk the mismatched-response budget only partly absorbs.
        // The socket's deinit closes the descriptor when this returns.
        // Split deliberately (Codex, PR #570): the binding refusal and a socket-creation failure are
        // DIFFERENT faults that used to collapse to one `.socketUnavailable`. The TWO refusals are
        // split from each other as well: a missing TUNNEL interface and a missing PHYSICAL pin are
        // opposite conditions, and reporting the second as the first (Kilo, PR #747) sent a reader
        // looking for a `virtualInterface` lag that was not happening.
        let binding: ResolverInterfaceBinding
        switch bindingDecision {
        case .permitted(let permitted):
            binding = permitted
        case .refusedNoTunnelInterface:
            // Tunnel interface not ready yet (`virtualInterface` lag) — transient, local, no wire
            // attempt. Distinct outcome so backoff does not penalise the upstream endpoint for it.
            return DNSUpstreamResponse(response: nil, outcome: .tunnelInterfaceUnavailable)
        case .refusedNoPhysicalInterface:
            // The tunnel interface IS known; F2's live physical pin for a floor-claimed,
            // profile-uncovered destination is missing. Also local, no wire attempt, also not the
            // upstream's fault — its own outcome so neither condition is reported as the other.
            return DNSUpstreamResponse(response: nil, outcome: .physicalInterfaceUnavailable)
        }
        // WHICH HALF REFUSED decides whether the upstream is throttled, so the reason is read
        // rather than discarded. `.socket` is a genuine local resource failure and keeps backing
        // off under real pressure (descriptor exhaustion, etc.); `.port` is our OWN registry
        // declining the carve-out and must not — device 2026-08-29 charged a healthy resolver for
        // our full table 7 times in one minute, and every one cost a DNS resolution.
        // pinned: PacketTunnelDNSRuntimeSourceTests.testASocketCreationFailureNamesWhichHalfRefused
        switch UDPResolverSocket.make(
            endpoint: endpoint, timeoutSeconds: Self.udpDNSTimeoutSeconds, binding: binding,
            ownResolverPorts: ownResolverPorts)
        {
        case .failure(.socket):
            return DNSUpstreamResponse(response: nil, outcome: .socketUnavailable)
        case .failure(.port):
            return DNSUpstreamResponse(response: nil, outcome: .resolverPortUnavailable)
        case .success(let socket):
            return socket.resolve(query, lifetime: lifetime)
        }
    }

    /// Why a tunnelled attempt may — or may not — egress at this instant.
    ///
    /// Replaces a bare `ChainedResolverSocketBinding?`, whose `nil` collapsed two DIFFERENT
    /// refusals into one answer the caller then reported as `.socketUnavailable`. Neither is a
    /// socket condition: the socket is never reached. The cost of the collapse was measured, not
    /// theorised — device 2026-08-29T08:11Z, 23 `backedOff` refusals behind 3 `socketUnavailable`
    /// ones — because `.socketUnavailable` DOES back off, so three token refusals at cold start
    /// benched the profile's SOLE resolver for 30 s and blackholed the next 23 lookups.
    /// `.refusedAfterLifecycleEnded` / `.refusedAfterLatchReplaced` map to the policy's
    /// no-penalty `backedOff` and end the ladder instead of walking it (`endsTheResolutionLadder`),
    /// so one latch bump can no longer stamp a penalty on every address in the route.
    ///
    /// The split mirrors `resolveUDP`'s own, one seam down (PR #608 -> #610): same two questions,
    /// same two outcomes, previously asked at one seam and not the other.
    /// pinned: TunnelDataPathLatchSourceTests.testATokenRefusalIsNotReportedAsASocketFailure
    enum TunnelledEgressConsult {
        case permitted(ChainedResolverSocketBinding)
        case direct(TunnelUDPResolver, ChainedOutageDriver)
        /// The session this work belongs to is gone, or a newer one replaced it.
        case lifecycleEnded
        /// The session is alive; the data path it was admitted under is not.
        case latchReplaced
    }

    /// The socket binding for a tunnelled attempt, pinned to the lifecycle AND the
    /// latch install the route was derived under — `nil` once either has moved on.
    ///
    /// The two guards and the binding consult are ONE on-queue critical section, and
    /// that atomicity is the point (Codex, PR #518, all three rounds). A tunnelled
    /// failover loop can straddle a stop/start: a per-attempt re-read of the binding
    /// alone hands the next attempt whatever the NEW state latched — for a DNS-only
    /// relatch that is `.systemChosen`, and the old route's upstream-resolver query
    /// egresses on the physical interface, the exact leak S6 exists to close. The
    /// generation alone was not enough either: it moves BEFORE the latch is replaced
    /// and the construction downgrade rewrites the latch without touching it, so only
    /// the latch epoch proves the route and this binding derive from the SAME latch —
    /// under which a chained-derived route yields a tunnel-pinned binding or a
    /// refusal, never `.systemChosen`.
    ///
    /// Delegates to `currentResolverSocketBinding()` — the one derivation seam — from
    /// inside the critical section; a second derivation site here is exactly what that
    /// seam's doc forbids.
    ///
    /// RESIDUAL, recorded rather than closed (Codex, PR #518 round 5): authorization
    /// ends at this read. An invalidation landing between the guard returning and the
    /// socket's `sendto` cannot revoke the escaped decision, so that one attempt still
    /// performs wire I/O — bounded by a single UDP receive timeout, and only ever into
    /// OUR OWN dying tunnel: the guard validated latch-is-chained under the same
    /// tokens, so the escaped binding is tunnel-pinned by construction and physical
    /// egress stays unrepresentable. Closing the window would mean holding
    /// `dnsStateQueue` across socket syscalls — the blocking coupling `INV-QUEUE-1`
    /// exists to forbid — to remove behaviour that is already fail-safe in every
    /// outcome (the packets land at retired read loops or the send fails; the
    /// observation side is separately closed by submitting the report through the
    /// token check in one critical section).
    /// pinned: TunnelDataPathLatchSourceTests.testTheTunnelledExecutorRunsThePackageLoopOverThePinnedSocket
    private func resolverSocketBinding(
        forLifecycle generation: UInt64, latchEpoch: UInt64
    ) -> TunnelledEgressConsult {
        let decide: () -> TunnelledEgressConsult = {
            // STILL ONE CRITICAL SECTION, and still all three terms — the guard is split in two
            // only to name which one refused. Reading them apart, or outside this closure, is the
            // race the fused consult exists to close (Codex, PR #518, three rounds).
            guard self.tunnelLifecycleIsActive,
                generation == self.tunnelLifecycleGeneration
            else { return .lifecycleEnded }
            guard latchEpoch == self.tunnelDataPathLatchEpoch else { return .latchReplaced }
            if let runtime = self.chainedRuntime, let resolver = runtime.directDNS {
                return .direct(resolver, runtime.driver)
            }
            // A strict profile may never fall back to a kernel socket, including a
            // profile edit racing a provider that was started in another mode.
            guard !self.protocolConfiguration.includeAllNetworks else { return .latchReplaced }
            return .permitted(self.currentResolverSocketBinding())
        }
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return decide()
        }

        return dnsStateQueue.sync(execute: decide)
    }

    /// The tunnelled `.plainDNS` executor's body: the package resolution loop over
    /// runtime-owned full-tunnel packets or split-tunnel pinned UDP I/O, plus observations.
    ///
    /// Thin on purpose — every decision (the EDNS0 cap, the failover, TC-is-liveness,
    /// what counts as unanswered) lives in `TunnelledPlainDNSResolution` where it has
    /// executable tests; this method contributes only the two things the package
    /// cannot: the real socket, and the driver.
    ///
    /// Full routing uses the runtime's direct WireGuard transport even when strict routing
    /// is disabled, so a live profile flag change cannot switch transport underneath it.
    /// The split socket is the SAME `resolveUDP` the DNS-only path uses: while chained,
    /// `currentResolverSocketBinding()` pins it to the tunnel interface and claims its
    /// source port in `ownResolverPorts`, so the classifier's carve-out carries the
    /// datagram out through the session (S8.7b) — there is no tunnelled-specific socket
    /// to drift from the pinned one. A TOKEN refusal answers `.refusedAfterLifecycleEnded`
    /// or `.refusedAfterLatchReplaced` fail-closed, exactly as the DNS-only path's own
    /// seam does; `.socketUnavailable` is reserved for a socket that genuinely could not
    /// be built, because that one throttles the endpoint and the token refusals must not.
    /// pinned: TunnelDataPathLatchSourceTests.testTheTunnelledExecutorRunsThePackageLoopOverThePinnedSocket
    func resolveTunnelledPlainDNS(
        _ query: Data, route: ResolverOrchestrator.TunnelledPlainDNSRoute,
        lifetime: DNSResolutionLifetime? = nil
    ) -> DNSResolutionResult {
        // THE EVIDENCE IS RECORDED AT EVERY EXIT, never at entry. Resolved decision 3
        // gates the deferred TCP retry on rates, and a rate needs a denominator nothing
        // else in this process can supply: the outage driver sees only observations,
        // which are deliberately not 1:1 with resolutions (a local refusal reports
        // nothing, an unparseable query's report is dropped, a fully backed-off route
        // never reaches the wire). So the denominator is every resolution the carry was
        // asked for — counted at each of this function's two exits rather than here: an
        // entry count is emitted in the flush window the resolution STARTED in while its
        // outcome lands in the window it FINISHED in, and a failover loop spending a UDP
        // timeout per silent resolver crosses a 60 s boundary readily, which left the
        // per-window rates uncomputable (Codex, PR #520). Both exits below record exactly
        // once; the harness compiles out of Release, and the S9 battery reads it.
        //
        // Everything this resolution uses is anchored to the ROUTE'S OWN tokens,
        // sealed in with the addresses at derivation. The observation is SUBMITTED
        // through those tokens after the wire work — validated and delivered in one
        // critical section (`reportTunnelDNSObservation(_:forLifecycle:latchEpoch:)`),
        // never via a returned driver reference: token-keyed is what makes the NEXT
        // lifecycle's driver unreachable (a fresh read would let a stale resolution's
        // timeout seed its accumulation — round 1's rule), and delivering inside the
        // check is what stops an invalidation landing mid-resolve or mid-report from
        // handing evidence to a driver whose lifecycle already ended (rounds 5-6).
        // THE BACKOFF LEDGER APPLIES HERE TOO. Tunnelled timeouts are recorded into
        // `resolverBackoffPolicy` by `recordUpstreamResult` exactly as physical ones are,
        // and without this consult they would never be read back: a persistently dead
        // resolver in the selected set costs its full UDP timeout serially on EVERY
        // resolution — head-of-line latency on the bounded resolver pool — while the
        // surviving resolver keeps health green. Same seam as `resolvePlainDNS`
        // (`orderedResolverAddressesForAttempt`). When every address is suppressed, the
        // backoff policy retries the original ordered set so suppression cannot empty T0.
        let addressesForAttempt = orderedResolverAddressesForAttempt(route.resolverAddresses)
        guard
            let attemptRoute = ResolverOrchestrator.TunnelledPlainDNSRoute(
                resolverAddresses: addressesForAttempt,
                originatingLifecycle: route.originatingLifecycle,
                originatingLatchEpoch: route.originatingLatchEpoch)
        else {
            #if DEBUG || LAVA_QA_TOOLS
            // EXIT 1 — a resolution the carry was asked for and refused before the wire.
            // It belongs in the denominator (the population is "asked for", not "sent")
            // and carries no outcome terms: nothing was transmitted, so there is no
            // truncation and no silence to attribute to a resolver. Token-validated for
            // the same reason exit 2 is — it is still this lifecycle's resolution or it is
            // no session's.
            recordChainedDNSEvidence(
                truncation: .notSeen, timeout: nil,
                forLifecycle: route.originatingLifecycle,
                latchEpoch: route.originatingLatchEpoch)
            #endif
            return DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: route.resolverAddresses.map {
                    ResolverAttempt(address: $0, outcome: .backedOff, transport: .plainDNS)
                },
                transport: .plainDNS,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false)
        }

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query,
            route: attemptRoute,
            // Each failover rung stamps the tunnelled backoff-path epoch live at its send, so a rung
            // that runs after a surviving-carry roam is scored against the NEW path even if an earlier
            // rung in this same ladder ran before the roam (task #56, Codex #565). Read BEFORE the send
            // on purpose (errs safe): a roam in the microseconds between this read and the syscall stamps
            // the rung with the old epoch, so its new-path timeout is filtered and the resolver skips
            // backoff for ONE query cycle (self-correcting) — the opposite (stamp at/after the send)
            // would let an old-path timeout re-stamp backoff on the healthy new path, the false-positive
            // blackout this fix removes. Accepted as a documented micro-residual (Codex #565).
            pathEpochAtAttempt: { self.currentResolverBackoffPathEpoch() }
        ) {
            cappedQuery, endpoint in
            // Every attempt's egress decision is pinned to the lifecycle AND latch THE
            // ROUTE WAS DERIVED UNDER, atomically with the binding consult — see
            // `resolverSocketBinding(forLifecycle:latchEpoch:)` for why anything less
            // lets a failover loop straddling a relatch send the old route's query on
            // the physical interface (Codex, PR #518). A refusal NAMES ITSELF: it is a
            // token refusal, never a socket one, and INV-DNS-1 is satisfied by the
            // fail-closed answer built from either.
            guard lifetime?.isAdmitted ?? true else {
                return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded)
            }
            switch self.resolverSocketBinding(
                forLifecycle: route.originatingLifecycle,
                latchEpoch: route.originatingLatchEpoch)
            {
            case .lifecycleEnded:
                return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded)
            case .latchReplaced:
                return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLatchReplaced)
            case .direct(let resolver, let driver):
                return resolver.resolve(
                    cappedQuery, endpoint: endpoint, timeout: TimeInterval(Self.udpDNSTimeoutSeconds), lifetime: lifetime
                ) { packet, deadline in
                    driver.sendResolverPacket(packet, deadline: deadline)
                }
            case .permitted(let bindingDecision):
                return self.resolveUDP(
                    cappedQuery, endpoint: endpoint, bindingDecision: bindingDecision, lifetime: lifetime)
            }
        }
        #if DEBUG || LAVA_QA_TOOLS
        // EXIT 2 — the resolution reached the wire, so its terms are derived from what
        // came back and recorded in ONE call, which is what keeps them in one flush
        // window (see `recordChainedDNSResolution`).
        //
        // TRUNCATION comes from the RESULT, not the observation, because the observation
        // deliberately cannot tell: a TC answer classifies `.answered` (TC is resolver
        // liveness — the trap decision 3 exists to name), so the driver's answered count
        // folds truncations in with ordinary successes. `udpTruncated` is the surviving
        // distinction — but it is `sawTruncation` across the WHOLE failover loop, which
        // stays true when a later resolver returns a complete response. That resolution
        // resolved, and a TCP retry would have added nothing to it, so the two shapes are
        // split here rather than conflated into one inflated gate (Codex, PR #520).
        let truncation: EnergyCounters.ChainedDNSTruncation
        if verdict.result.udpTruncated {
            truncation = verdict.result.response == nil ? .unresolved : .rescuedByFailover
        } else {
            truncation = .notSeen
        }
        // SILENCE, DERIVED FROM THE RESULT AND NOT FROM THE OBSERVATION — the same split the
        // truncation term makes, and for the same reason. The observation is a LIVENESS
        // verdict: a TC answer paired with another resolver's silence classifies `.answered`
        // on purpose, so the outage budget is not spent on one large-response domain. Reading
        // silence off it inherits that rule, and the TC-plus-timeout resolution — a resolver
        // demonstrably went quiet and nothing resolved — recorded no timeout at all
        // (Codex, PR #520). I had already made this argument for truncation one screen up and
        // failed to apply it here.
        //
        // The population is "did not complete AND a resolver's budget elapsed": a timeout
        // rescued by a later resolver is not a silent domain, and an all-local-failure
        // resolution never had a resolver go quiet.
        //
        // Split by whether there is a name to attribute it to. The nameless branch should
        // never fire — `serveDNS` parse-gates before dispatch — so it is a CANARY rather than
        // a rate; see `recordChainedDNSResolution` for why that is the useful reading.
        var timeout: EnergyCounters.ChainedDNSTimeout?
        if verdict.result.response == nil,
            verdict.result.attempts.contains(where: { $0.outcome == .timeout })
        {
            if let name = verdict.unresolvedQueryName {
                timeout = .named(
                    nameKey: ChainedOutageDriver.TunnelDNSObservation.nameKey(
                        forNormalizedName: name))
            } else {
                timeout = .unparseableQuery
            }
        }
        // Recorded THROUGH THE ROUTE'S TOKENS, like the report below. An earlier shape
        // recorded ahead of any lifecycle check on the reasoning that a resolution the
        // tunnel performed during teardown is still a resolution — but that reasoning
        // belonged to the version that counted the denominator at entry, where dropping
        // the outcome would have stranded a denominator with no numerator. Now that every
        // term travels together, discarding them together leaves the rate balanced, and
        // the measurement is per-SESSION: active resolver I/O can complete after stop,
        // so an unguarded record lets the old lifecycle's terms land in the window
        // `activate()` has just reset for the new one (Codex, PR #520).
        // NO T1 TERMS HERE. This call used to carry `fallbackRescue`/`fallbackAttempted`/
        // `fallbackAnswered` off the tunnelled verdict; the rung egresses on the physical
        // interface, so the tunnelled verdict never sees it and those terms were permanently
        // false. The rung's evidence travels on the RESULT instead, and is read where each
        // consumer can honestly read it: `recordTierOneRungIfPresent` moves the QA counters
        // (the plan's S3), while a served rung's outage credit is taken — in every build — past
        // whichever gate decides that path's delivery, or under a runtime fence where a path has
        // no delivery at all. See ``TierOneRungCreditTiming``.
        // REPLY SHAPE, taken from the verdict for the same reason every other term is: the
        // RFC 2308 §2.2 split needs the wire message, which the counters never see. Unbacked is a
        // strict subset of empty and the recorder bumps both, so the capture cannot be misread as
        // two populations (PR #588).
        // AND THE ADDRESS-QUERY SPLIT, which the two terms above cannot carry: they are read from
        // the header, never the question, so an AAAA NODATA for a v4-only host and an A NODATA for
        // a public name are one number in them (field 2026-08-28 — see the counter's own note).
        recordChainedDNSEvidence(
            truncation: truncation, timeout: timeout,
            emptyAnswer: verdict.sawUnbackedEmptyAnswer
                ? .unbacked : (verdict.sawEmptyAnswer ? .backed : .notSeen),
            ipv4AddressNegative: {
                switch verdict.ipv4AddressNegative {
                case .none: return .none
                case .emptyAnswer: return .emptyAnswer
                case .nameDoesNotExist: return .nameDoesNotExist
                }
            }(),
            // AND WHAT WAS IN THE ANSWER when there WAS one, which the split above cannot say:
            // it only distinguishes kinds of nothing. The chained route carries 100.64.0.0/10
            // into the tunnel and sends the rest direct, so a public name answered with a CGNAT
            // or private address resolves fine and then loads nothing (field 2026-08-29 — see
            // the counters' own note).
            // Computed HERE, not carried on the verdict, because the walk it needs exists only
            // for these counters and this block is the QA gate. `Package.swift` sets no
            // swiftSettings, so LAVA_QA_TOOLS is undefined inside the package and the same gate
            // written there would collapse to DEBUG-only — dropping the diagnostic from the QA
            // builds the field captures come from. Release never reaches this line.
            ipv4AddressClasses: {
                let classes = verdict.ipv4AnswerAddressClasses(forQuery: query)
                return EnergyCounters.ChainedDNSIPv4AddressClasses(
                    containsPublicRoutable: classes.containsPublicRoutable,
                    containsCarrierGradeNAT: classes.containsCarrierGradeNAT,
                    containsPrivateUse: classes.containsPrivateUse,
                    containsSpecialUse: classes.containsSpecialUse)
            }(),
            // The IPv6 counterpart, so an AAAA answer is counted somewhere: the IPv4 classes
            // above are silent for it, and the 2026-09-17/19 captures could not say how much of
            // the resolution volume was v6 (the observability gap in
            // `plans/2026-09-17-path-independent-dns-capture-floor.md`). Same QA gate.
            hasIPv6AnswerAddress: verdict.hasIPv6AnswerAddress(forQuery: query),
            forLifecycle: route.originatingLifecycle,
            latchEpoch: route.originatingLatchEpoch)
        #endif
        switch verdict.observation {
        case .answered:
            reportTunnelDNSObservation(
                .answered,
                forLifecycle: route.originatingLifecycle,
                latchEpoch: route.originatingLatchEpoch)
        case .unanswered(let normalizedQueryName):
            // A query that does not parse has no name to key the distinct-names floor
            // with; dropping the report is the fail-SAFE direction (nothing arms), and
            // a query the DNS path could not parse is not the evidence stream the
            // outage cause is scoped to anyway.
            if let normalizedQueryName {
                reportTunnelDNSObservation(
                    .unanswered(
                        nameKey: ChainedOutageDriver.TunnelDNSObservation.nameKey(
                            forNormalizedName: normalizedQueryName)),
                    forLifecycle: route.originatingLifecycle,
                    latchEpoch: route.originatingLatchEpoch)
            }
        case nil:
            break
        }
        return verdict.result
    }

    /// Submits a tunnel-DNS observation to the driver of the lifecycle a route was
    /// derived under — validated and DELIVERED in one critical section, so the driver
    /// never escapes the token check. A validating read that RETURNS the driver leaves
    /// a read-to-call gap: an invalidation landing inside it hands a report to a driver
    /// whose lifecycle already ended, and an unanswered observation completing an
    /// almost-armed accumulation could start the retry ladder during shutdown
    /// (Codex, PR #518 round 6). Submission-through-the-check leaves nothing to escape
    /// into: stale tokens drop the report — the lifecycle ended, so there is nothing
    /// the evidence could correctly arm — and a report submitted while the tokens are
    /// current belongs to the lifecycle that carried the query, with the driver's own
    /// retirement gate bounding whatever follows.
    ///
    /// Dual-entry like `currentTunnelDataPathMode()` and safe from the same places: the
    /// resolution paths this serves run on `resolverQueue`, the smoke-probe queue, the
    /// serving adapter's queue or the read-loop callback — never on the engine queue
    /// (`INV-QUEUE-1`: the engine→dnsState direction is one-way, and `serveDNS` hops off
    /// the engine queue before any of this machinery runs). Holding the DNS confinement
    /// across the door couples nothing: the door is a stamp and an async enqueue behind
    /// a leaf lock, non-blocking by its own pinned contract.
    /// pinned: TunnelDataPathLatchSourceTests.testTheTunnelledExecutorRunsThePackageLoopOverThePinnedSocket
    private func reportTunnelDNSObservation(
        _ observation: ChainedOutageDriver.TunnelDNSObservation,
        forLifecycle generation: UInt64, latchEpoch: UInt64
    ) {
        let submit = {
            guard self.tunnelLifecycleIsActive,
                generation == self.tunnelLifecycleGeneration,
                latchEpoch == self.tunnelDataPathLatchEpoch,
                let driver = self.chainedRuntime?.driver
            else { return }
            driver.reportTunnelDNSObservation(observation)
        }
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            submit()
            return
        }

        dnsStateQueue.sync(execute: submit)
    }

    #if DEBUG || LAVA_QA_TOOLS
    /// Records one resolution's evidence terms into the window of the lifecycle that
    /// carried the query — or into no window at all.
    ///
    /// VALIDATED AND RECORDED IN ONE CRITICAL SECTION, for the same reason
    /// `reportTunnelDNSObservation` is: a read that returns "the tokens are current" and
    /// then records outside the section can have the lifecycle end in the gap. Here the
    /// consequence is measurement rather than safety, but it is the measurement the whole
    /// PR exists for.
    ///
    /// WHY THE CHECK AT ALL, when the terms describe work the tunnel really did: stop
    /// cannot synchronously finish active resolver I/O, and `activate()` has by then reset
    /// the counters for the NEW session. An unguarded record therefore lands the old
    /// lifecycle's denominator, outcome and distinct-name key in the new session's first
    /// window — contaminating exactly what the per-session reset exists to isolate, and
    /// doing it at the moment an A/B battery cell begins (Codex, PR #520).
    ///
    /// AND DISCARDING IS BALANCED, which it was not in the earlier shape. While the
    /// denominator was counted at entry, dropping the outcome stranded a denominator with
    /// no numerator; now every term of one resolution travels together, so dropping them
    /// together leaves every rate intact. The resolution is simply part of no session's
    /// measurement — which is the truth about one whose lifecycle ended mid-flight.
    /// pinned: ChainedDNSEvidenceCounterSourceTests.testTheEvidenceRecordIsValidatedAndRecordedInOneSection
    private func recordChainedDNSEvidence(
        truncation: EnergyCounters.ChainedDNSTruncation,
        timeout: EnergyCounters.ChainedDNSTimeout?,
        emptyAnswer: EnergyCounters.ChainedDNSEmptyAnswer = .notSeen,
        ipv4AddressNegative: EnergyCounters.ChainedDNSIPv4AddressNegative = .none,
        ipv4AddressClasses: EnergyCounters.ChainedDNSIPv4AddressClasses = .none,
        hasIPv6AnswerAddress: Bool = false,
        fallbackRescue: Bool = false,
        fallbackAttempted: Bool = false,
        fallbackAnswered: Bool = false,
        forLifecycle generation: UInt64, latchEpoch: UInt64
    ) {
        let record = {
            guard self.tunnelLifecycleIsActive,
                generation == self.tunnelLifecycleGeneration,
                latchEpoch == self.tunnelDataPathLatchEpoch
            else { return }
            EnergyCounters.shared.recordChainedDNSResolution(
                truncation: truncation, timeout: timeout, emptyAnswer: emptyAnswer,
                ipv4AddressNegative: ipv4AddressNegative,
                ipv4AddressClasses: ipv4AddressClasses,
                hasIPv6AnswerAddress: hasIPv6AnswerAddress)
            // The fallback-rescue NUMERATOR moves under the SAME lifecycle guard as its
            // `chainedDNSResolution` denominator (Kilo, PR #575): an unguarded bump on the
            // resolver pool could count a torn-down lifecycle's in-flight rescue whose
            // companion denominator this guard discards — stranding the numerator above its
            // own denominator at exactly the teardown boundary the rate exists to measure.
            self.applyChainedFallbackEvidenceOnQueue(
                attempted: fallbackAttempted, answered: fallbackAnswered, rescue: fallbackRescue)
        }
        // Dual-entry like the observation report, and reached from the same places — the
        // resolution paths run on `resolverQueue`, the smoke-probe queue, the serving
        // adapter's queue or the read-loop callback, never the engine queue (`INV-QUEUE-1`).
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            record()
            return
        }
        dnsStateQueue.sync(execute: record)
    }

    /// The chained fallback counters, applied on `dnsStateQueue` with the lifecycle guard ALREADY
    /// passed by the caller.
    ///
    /// Extracted so the two evidence sources cannot drift. T0's verdict reaches it through
    /// ``recordChainedDNSEvidence``; the physical T1 rung reaches it through
    /// ``recordChainedTierOneRungEvidence``, because after PR #590 the tunnelled verdict carries
    /// no T1 terms at all and every rung — rescues included — would otherwise be invisible
    /// (Codex, PR #590). One copy of the nesting rules means the panel reads the same counters
    /// whichever tier moved them.
    /// pinned: ChainedDNSEvidenceCounterSourceTests.testBothEvidenceSourcesShareOneFallbackCounterBlock
    private func applyChainedFallbackEvidenceOnQueue(
        attempted: Bool, answered: Bool, rescue: Bool
    ) {
        if rescue {
            // KNOWN MEASUREMENT CAVEAT, and it is inherent rather than an oversight. Before the
            // physical rung, this numerator and its `chainedDNSResolution` denominator were bumped
            // in ONE dnsStateQueue critical section, so a 60 s flush boundary could never fall
            // between them. T0-sourced evidence still works that way. A RUNG-sourced rescue
            // cannot: the rung's outcome is not known until after T0 has returned and its
            // denominator has already been recorded, so a flush landing in the gap puts the two
            // in adjacent windows (adversarial review, PR #590).
            //
            // SESSION TOTALS ARE UNAFFECTED — nothing is lost or double-counted, and the totals
            // are what a field capture is read from. Only a PER-WINDOW rate can be off by one at
            // a boundary, in either direction. Deferring the denominator until the rung resolves
            // would fix the window at the cost of losing the denominator entirely whenever a
            // resolution is abandoned mid-rung, which is the worse trade for the thing these
            // counters exist to measure.
            EnergyCounters.shared.bump(.chainedDNSFallbackRescue)
        }
        // The SETTINGS-SURFACE counters. The lifecycle guard and the dnsStateQueue confinement
        // are the CALLER's — both entry points establish them before reaching here, which is why
        // this is `...OnQueue` — because a torn-down lifecycle's in-flight resolution must not
        // move a counter the panel reads as this session's.
        // A rescue is a strict subset of an attempt, so both are bumped rather than one or
        // the other: the panel's "tried and nothing came back" verdict is exactly
        // attempts-without-rescues, and crediting only the rescue would make a working
        // fallback and a dead one produce the same reading.
        if attempted {
            self.health.chainedFallbackAttemptCount += 1
            // THE STREAK, and the only fallback term that can fall. Bumped only when this
            // attempt produced no answer, so it measures the CURRENT run of silence rather
            // than the session total — a fallback that served a lookup and then went dark
            // otherwise reads healthy for the session's whole life, because every other
            // counter is cumulative (Codex, PR #575).
            if !answered {
                self.health.chainedFallbackUnansweredStreak += 1
            }
        }
        // An ANSWER — including SERVFAIL/REFUSED and a truncated reply — proves the peer
        // forwarded the query and the resolver is reachable. Counted separately from the
        // attempt so the surface can tell "couldn't resolve it either" from silence.
        if answered {
            self.health.chainedFallbackAnswerCount += 1
            // The SECOND streak, and the reason one is not enough: the unanswered streak
            // resets on ANY answer, SERVFAIL and REFUSED included, so a fallback that served
            // once and then soft-fails every retry keeps clearing it while its cumulative
            // rescue count holds `working` in place. This one asks the other question —
            // still HELPING, not merely replying (Codex, PR #575).
            //
            // Counted on REPLIES, not attempts, so the number is also the honest payload for
            // `answeringWithoutResolving`: it is exactly the run of replies that did not serve
            // the name, with no rescue folded in.
            if !rescue {
                self.health.chainedFallbackUnhelpfulReplyStreak += 1
            }
            // Reset unconditionally, NOT inside the `attempted` arm above: an answer
            // is proof the far end is forwarding right now, whatever bookkeeping the attempt
            // flag did, and a streak that survived it would keep condemning a live resolver.
            self.health.chainedFallbackUnansweredStreak = 0
        }
        if rescue {
            self.health.chainedFallbackRescueCount += 1
            // A served answer is proof the fallback is helping RIGHT NOW, so it clears the
            // unhelpful-reply run unconditionally — the same argument as the answer reset
            // above, one rung narrower.
            self.health.chainedFallbackUnhelpfulReplyStreak = 0
        }
        if attempted || answered || rescue {
            self.markHealthCountersUpdated()
        }
    }

    /// Records a physical T1 rung against the same counters T0 uses.
    ///
    /// Called only when the merged result actually carries a rung, so the extra latch read costs
    /// nothing on the overwhelming majority of resolutions — the rung exists only where T0
    /// declined to serve.
    ///
    /// THE LIFECYCLE TOKENS TRAVEL WITH THE EVIDENCE. An earlier version of this re-derived them
    /// from the current latch and called that the guard, which was wrong: the fetched tokens are
    /// the CURRENT session's, so comparing them against the current session always passed. The
    /// tokens now come from the route the rung was opened against, so a rung whose session ended
    /// mid-flight is dropped rather than credited to whichever session happens to be live.
    /// pinned: ChainedDNSEvidenceCounterSourceTests.testThePhysicalRungMovesTheFallbackCounters
    func recordChainedTierOneRungEvidence(
        _ evidence: ResolverOrchestrator.TierOneRungEvidence
    ) {
        // NIL IS A REFUSAL TO COUNT, not a missing reading. The selection never reached the
        // wire — every endpoint backed off, or a mid-ladder relatch refused the leg — so no
        // datagram left on its behalf and no counter may move. Counting local refusals as
        // attempts is what had the panel report "your VPN isn't forwarding" about queries nobody
        // sent, and send users to configure an exit node they did not need (Codex, PR #575).
        //
        // The OUTAGE credit is unaffected: it is taken in `recordTierOneRungIfPresent`, outside
        // this recorder and independent of this guard, because the rung's own T2 may well have
        // served the name while the selection sat dark — and the user is no more blackholed for
        // it (Codex P1, PR #639).
        guard let outcome = evidence.outcome else { return }
        // served ⊆ answered ⊆ attempted — the same nesting T0 supplies, so `notForwarded`
        // (attempts without answers) and `answeringWithoutResolving` (answers without rescues)
        // keep meaning what they mean.
        let answered = outcome == .answered || outcome == .served
        let record = {
            // THE CARRIED TOKENS, not a fresh read. This guard previously fetched the CURRENT
            // route and compared its tokens against the current lifecycle — which they equal by
            // construction, so it could never reject anything. A rung admitted under session A
            // and completing after session B started landed A's rescue in B's counters and B's
            // energy numerator: exactly the cross-lifecycle contamination the per-session reset
            // exists to prevent, and which T0's own guard does prevent (Codex, PR #590).
            guard self.tunnelLifecycleIsActive,
                evidence.originatingLifecycle == self.tunnelLifecycleGeneration,
                evidence.originatingLatchEpoch == self.tunnelDataPathLatchEpoch
            else { return }
            // The energy rescue bump lives INSIDE the shared block — doing it here as well would
            // double-count every rescue against its `chainedDNSResolution` denominator.
            self.applyChainedFallbackEvidenceOnQueue(
                attempted: true, answered: answered, rescue: outcome == .served)
        }
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            record()
            return
        }
        dnsStateQueue.sync(execute: record)
    }
    #endif

    func orderedResolverAddressesForAttempt(_ addresses: [String], now: Date = Date()) -> [String] {
        resolverBackoffStateQueue.sync {
            resolverBackoffPolicy.availableAddresses(from: addresses, now: now)
        }
    }

    func isResolverBackedOff(_ address: String, now: Date = Date()) -> Bool {
        resolverBackoffStateQueue.sync {
            resolverBackoffPolicy.isBackedOff(address, now: now)
        }
    }

    func completeForward(
        cacheKey: DNSCacheKey, resolutionID: UInt64, lifetime: DNSResolutionLifetime,
        query: Data,
        resolverIdentifier: String,
        resolverGeneration: Int,
        maximumAnswerTTL: UInt32?,
        stripsIPv6Hint: Bool,
        result: DNSResolutionResult
    ) {
        guard isActiveResolverRuntime(identifier: resolverIdentifier, generation: resolverGeneration) else {
            // DELIBERATELY UNTRACED, and the reasoning here was wrong once. The waiters are not
            // drained here on purpose — the reset that advanced the runtime owns them
            // (`collectPendingResponsesAndResetResolverRuntime` drains and settles the whole
            // coalescer), and draining them again would answer one batch twice.
            //
            // It is tempting to trace the DISCARDED ANSWER as a lost query. It is not one. Since
            // PR #617 a wake reset REPLAYS what it drains, so the client on the other side of
            // this discarded result is very likely answered a moment later by
            // `replayPendingDNSRequestsAfterWake` — and this device wakes hundreds of times per
            // session, so tracing here would bury the capture in failures that did not happen
            // (Codex P2, PR #620). A trace that fires on a routine wake is worse than silence:
            // it is the diagnostic manufacturing the outage it was added to find.
            // pinned: PacketTunnelDNSRuntimeSourceTests.testTheDiscardedPostResetAnswerIsNotTracedAsAFailure
            return
        }

        guard lifetime.runtimeIsCurrent else { return }
        let clientDeadlineExpired = !lifetime.isAdmitted
        // Attempt completion remains evidence after client expiry; it cannot claim late service.
        // pinned: PacketTunnelDNSRuntimeSourceTests.testExpiredCompletionPreservesEvidenceBeforeClientSettlement
        recordUpstreamResult(result, clientDeadlineExpired: clientDeadlineExpired)

        let pendingResponses = inFlightQueryCoalescer.drain(cacheKey, resolutionID: resolutionID)
        guard !pendingResponses.isEmpty else { return }
        guard !clientDeadlineExpired else {
            writeServerFailures(for: pendingResponses, reason: "resolver-work-expired")
            return
        }

        // THE RUNG'S OUTAGE CREDIT, taken HERE and nowhere earlier on this path.
        //
        // The guard above is the only place that knows this answer will be delivered rather than
        // discarded, and the credit's whole claim is that the USER got an answer. Two earlier
        // shapes were wrong: crediting in `recordTierOneRungIfPresent` unconditionally credited
        // results this guard then threw away, and re-checking `isActiveResolverRuntime` there
        // still left a gap — that check runs a `dnsStateQueue.sync` while this function is
        // enqueued onto the same queue afterwards, so a reset landing between them passes there
        // and fails here (Codex P2, PR #639, twice). Past this line the claim is structural.
        //
        // Deliberately BEFORE the disposition and well-formedness work below, because those
        // decide what the client is SENT, not whether the ladder served: `ladderServed` already
        // carries both bars, computed on the rung's own reply at the merge where the rung's
        // answer is still distinguishable from T0's.
        // pinned: ChainedDNSEvidenceCounterSourceTests.testTheForwardingCreditWaitsForTheDeliveryGate
        if let rung = result.tierOneRung, rung.ladderServed {
            reportTierOneRungRescue(
                forLifecycle: rung.originatingLifecycle, latchEpoch: rung.originatingLatchEpoch)
        }

        let upstreamResponse = result.response ?? DNSResponseFactory.serverFailure(for: query)

        guard let upstreamResponse else {
            // Not even a SERVFAIL could be synthesized — the query itself is unusable as a
            // template. The client gets nothing at all, which is the quietest failure here.
            recordUnansweredDNSQuery(
                reason: "no-response-and-no-servfail-template", query: query,
                clientQueries: pendingResponses.count)
            return
        }
        // Validate before classification; malformed replies and unchecked aliases become SERVFAIL.
        let isWellFormed = DNSWireMessage.hasWellFormedResourceRecords(upstreamResponse)
        // Full-RCODE validation also rejects protocol-invalid EDNS.
        let disposition = DNSAnswerDisposition.disposition(ofResponse: upstreamResponse)
        let reachableAliasDomains = (try? DNSMessage.parseQuestion(from: query)).flatMap { question in
            try? DNSResponseAliases.targets(in: upstreamResponse, for: question)
        }
        let failureReason: String?
        if result.response == nil {
            // A synthesized SERVFAIL: the resolver ladder produced no answer. The client is told
            // "failed" rather than left waiting, but from the user's side the name did not resolve.
            failureReason = "upstream-produced-no-response"
        } else if !isWellFormed || disposition == nil {
            failureReason = "upstream-response-malformed"
        } else if reachableAliasDomains == nil {
            failureReason = "upstream-alias-response-invalid"
        } else if disposition == .resolverFailure {
            // A REAL failure packet from a reachable resolver — SERVFAIL or REFUSED — which this
            // pipeline deliberately preserves rather than synthesizing over. `result.response` is
            // non-nil, so the first arm never sees it, and without this the commonest way a name
            // fails to resolve would be the one shape the trace stayed silent about (Codex P2,
            // PR #620). NXDOMAIN is excluded on purpose: a name that does not exist is a correct
            // answer, and filing it here would make ordinary browsing look broken.
            failureReason = "upstream-refused-or-failed"
        } else {
            failureReason = nil
        }
        let validatedResponse = isWellFormed && disposition != nil && reachableAliasDomains != nil
            ? upstreamResponse
            : DNSResponseFactory.serverFailure(for: query)
        guard let validatedResponse else {
            recordUnansweredDNSQuery(
                reason: "malformed-response-and-no-servfail-template", query: query,
                clientQueries: pendingResponses.count)
            return
        }
        // Strip the `ipv6hint` from HTTPS/SVCB answers BEFORE the response is cached or written, so
        // the cache holds the stripped bytes and every coalesced client sees the same answer. A
        // strip that is not provably compression-safe returns the response unchanged (INV-DNS-1).
        let responseToWrite: Data
        if stripsIPv6Hint {
            let stripped = DNSServiceBinding.strippingIPv6Hints(from: validatedResponse)
            #if DEBUG || LAVA_QA_TOOLS
            if stripped.count != validatedResponse.count {
                recordChainedIPv6HintStrippedIfQA(
                    domain: (try? DNSMessage.parseQuestion(from: query))?.domain ?? ""
                )
            }
            #endif
            responseToWrite = stripped
        } else {
            responseToWrite = validatedResponse
        }

        let cacheMaximumAnswerTTL = pendingResponses
            .compactMap(\.maximumAnswerTTL)
            .min()
            ?? maximumAnswerTTL
        let responseToCache = responseByApplyingMaximumAnswerTTL(
            responseToWrite,
            maximumAnswerTTL: cacheMaximumAnswerTTL
        )

        if let responseToCache {
            dnsResponseCache.store(responseToCache, for: cacheKey)
        }

        // Policy and pause are re-read per waiter. A replacement block is a usable answer,
        // so it must not inflate the resolver-failure count (INV-DNS-1, PR #620).
        var clientQueriesReachedByTheFailure = 0
        var clientQueriesGivenNothing = 0
        for pending in pendingResponses {
            let answer = responseForPendingForward(
                responseToWrite, pending: pending, reachableAliasDomains: reachableAliasDomains ?? [])
            let isAnsweredByBlock = answer.isAnsweredByBlock
            guard let pendingResponse = answer.response else {
                // Nothing is written for this client at all — the block answer could not be built
                // for a domain we must not relay. It counts under the failure when there is one,
                // and reports itself below when there is not.
                clientQueriesReachedByTheFailure += 1
                clientQueriesGivenNothing += 1
                continue
            }
            if !isAnsweredByBlock {
                clientQueriesReachedByTheFailure += 1
            }
            let response = DNSWireMessage.replacingTransactionID(in: pendingResponse, from: pending.request.dnsPayload)
            // Failure batches are traced below; replacement blocks retain their own write trace.
            writeDNSResponse(
                response,
                for: pending.request,
                protocolNumber: pending.protocolNumber,
                tracesDiscardedAnswer: failureReason == nil || isAnsweredByBlock
            )
        }
        // Emit once for the clients that actually received the failure.
        if let failureReason {
            if clientQueriesReachedByTheFailure > 0 {
                recordUnansweredDNSQuery(
                    reason: failureReason, query: query,
                    clientQueries: clientQueriesReachedByTheFailure)
            }
        } else if clientQueriesGivenNothing > 0 {
            // A GOOD upstream answer, and these clients still got nothing: the pause expired, the
            // domain is blocked now, and the block answer would not build. Rare, and correct to
            // drop rather than relay — but silent until here.
            recordUnansweredDNSQuery(
                reason: "block-answer-not-buildable", query: query,
                clientQueries: clientQueriesGivenNothing)
        }
    }

    func responseByApplyingMaximumAnswerTTL(
        _ response: Data,
        maximumAnswerTTL: UInt32?
    ) -> Data? {
        guard DNSWireMessage.hasWellFormedResourceRecords(response) else {
            return nil
        }
        guard let maximumAnswerTTL else {
            return response
        }

        return DNSWireMessage.cappingCacheableTTLs(in: response, to: maximumAnswerTTL)
    }

    /// Applies current filtering once per client, then records the final decision once.
    /// Parsing the alias graph is shared by a resolution batch; policy and pause are not.
    func responseForPendingForward(
        _ response: Data,
        pending: PendingDNSResponse,
        reachableAliasDomains: [String] = []
    ) -> (response: Data?, isAnsweredByBlock: Bool) {
        guard let question = try? DNSMessage.parseQuestion(from: pending.request.dnsPayload) else {
            return (nil, false)
        }
        let outcome = forwardedDecision(for: question, pending: pending,
                                        reachableAliasDomains: reachableAliasDomains)
        recordDiagnostic(domain: question.domain, decision: outcome.decision,
                         failClosedReason: outcome.failClosedReason,
                         isReplayOfARecordedDecision: pending.isReplayOfARecordedDecision)
        if outcome.decision.action == .block {
            // Failure to synthesize the block cannot fall through to the upstream answer.
            return (try? DNSMessage.blockedResponse(for: pending.request.dnsPayload,
                                                    question: question, ttl: blockedTTL,
                                                    addressMode: blockedAddressModeForQA), true)
        }
        return (responseByApplyingMaximumAnswerTTL(response, maximumAnswerTTL: outcome.maximumAnswerTTL), false)
    }

    func writeParseFailureResponse(for request: any DNSDatagramRequest, protocolNumber: Int) {
        guard let response = DNSResponseFactory.serverFailure(for: request.dnsPayload) else {
            return
        }

        // ALREADY RECORDED: the only caller traces `unparseable-question` immediately before
        // calling this, so a refused write here would export the same query twice under two
        // separately suppressed reasons (Codex P2, PR #620).
        writeDNSResponse(
            response,
            for: request,
            protocolNumber: protocolNumber,
            tracesDiscardedAnswer: false
        )
    }

    func currentResolverRuntimeGeneration() -> Int {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return resolverRuntimeGeneration
        }

        return dnsStateQueue.sync {
            resolverRuntimeGeneration
        }
    }

    private func currentResolverBackoffPathEpoch() -> Int {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return resolverBackoffPathEpoch
        }

        return dnsStateQueue.sync {
            resolverBackoffPathEpoch
        }
    }

    func isActiveResolverRuntime(identifier: String, generation: Int) -> Bool {
        activeResolverRuntimeIdentifier == identifier && resolverRuntimeGeneration == generation
    }


    func currentResolverRuntimeConfiguration(
        ignoresDeviceDNSFallbackMode: Bool = false,
        allowsQueryFallback: Bool = true
    ) -> ResolverRuntimeConfiguration {
        let configuration = currentAppConfiguration()
        let schedulingView = currentResolverHealthSchedulingView()
        return DNSResolverRuntimePlan.make(
            configuration: configuration,
            deviceDNSAddresses: currentDeviceDNSResolverAddresses(),
            networkKind: currentNetworkKind(),
            deviceDNSFallbackModeActive: schedulingView.deviceDNSFallbackModeActive,
            ignoresDeviceDNSFallbackMode: ignoresDeviceDNSFallbackMode,
            allowsQueryFallback: allowsQueryFallback,
            deviceResolverWedged: schedulingView.reconnectEpisodeIsActive
        )
    }

    // "Broadly wedged" evidence for the encrypted fallback: the connectivity policy
    // has declared a needs-reconnect wedge (driven by the smoke probe on known-good
    // domains + consecutive upstream failures) and it hasn't recovered. This is NOT
    // reset by individual SERVFAIL/REFUSED forwarding replies, so a stale off-network
    // resolver that refuses everything still trips it via the smoke probe, while a
    // healthy resolver answering one blocked domain with REFUSED does not.
    func currentDeviceResolverWedged() -> Bool {
        currentResolverHealthSchedulingView().reconnectEpisodeIsActive
    }

    func orderedResolverAddressesForCurrentNetwork(_ addresses: [String]) -> [String] {
        DNSResolverRuntimePlan.orderedResolverAddresses(addresses, networkKind: currentNetworkKind())
    }

    /// `DomainName.normalize` memoized for a resolver endpoint hostname — the bootstrap checks
    /// call this per candidate endpoint on every DNS packet, and the hostnames are stable for the
    /// resolver runtime. Returns exactly what `try? DomainName.normalize(hostname)` would (the
    /// cached success, or nil for a hostname that fails to normalize). Resolver hostnames that
    /// fail normalization are not cached (recomputed on each call, matching the prior `try?`
    /// behaviour) — in practice resolver hostnames are always valid, so this path is not hit.
    private func normalizedEndpointHostname(_ hostname: String) -> String? {
        endpointHostnameNormalizationCacheLock.lock()
        if let cached = endpointHostnameNormalizationCache[hostname] {
            endpointHostnameNormalizationCacheLock.unlock()
            return cached
        }
        endpointHostnameNormalizationCacheLock.unlock()

        guard let normalized = try? DomainName.normalize(hostname) else {
            return nil
        }

        endpointHostnameNormalizationCacheLock.lock()
        if endpointHostnameNormalizationCache.count >= Self.endpointHostnameNormalizationCacheLimit {
            endpointHostnameNormalizationCache.removeAll(keepingCapacity: true)
        }
        endpointHostnameNormalizationCache[hostname] = normalized
        endpointHostnameNormalizationCacheLock.unlock()
        return normalized
    }

    func clearEndpointHostnameNormalizationCache() {
        endpointHostnameNormalizationCacheLock.lock()
        endpointHostnameNormalizationCache.removeAll(keepingCapacity: true)
        endpointHostnameNormalizationCacheLock.unlock()
    }

    func dohBootstrapResponse(
        for question: DNSQuestion,
        query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration,
        admittedAtEpoch: UInt64
    ) -> Data? {
        // Hostnames that must be answered from bundled bootstrap IPs rather than
        // forwarded (forwarding would recurse through the very resolver we're trying
        // to reach):
        //   - the active DoH primary's endpoints, and
        //   - the encrypted fallback endpoints (Mullvad), which a Device-DNS primary
        //     keeps for the wedge safety net. Without bootstrapping the fallback host,
        //     its own `dns.mullvad.net` lookup would be forwarded to the (possibly
        //     wedged) Device DNS, so the safety net couldn't recover a cold device.
        var candidateEndpoints = resolverConfiguration.encryptedFallbackEndpoints
        if resolverConfiguration.transport == .dnsOverHTTPS {
            candidateEndpoints = resolverConfiguration.dohEndpoints + candidateEndpoints
        }

        // `question.normalizedDomain` is `DomainName.normalize(question.domain)`, already
        // computed once in `DNSMessage.parseQuestion`. Reuse it instead of re-normalizing
        // on every query: the bootstrap closure runs first on every DNS packet, and for a
        // non-resolver hostname (the common case) all three transports' checks run, so this
        // previously re-normalized the question domain up to 3× per query.
        let normalizedQuestionDomain = question.normalizedDomain
        guard !candidateEndpoints.isEmpty,
              let endpoint = candidateEndpoints.first(where: { endpoint in
                  guard let endpointHost = endpoint.url.host,
                        let normalizedEndpointHost = normalizedEndpointHostname(endpointHost)
                  else {
                      return false
                  }

                  return normalizedQuestionDomain == normalizedEndpointHost
              })
        else {
            return nil
        }

        let bootstrappedEndpoint = dohEndpointResolvingBootstrapIfNeeded(endpoint, admittedAtEpoch: admittedAtEpoch)
        guard !bootstrappedEndpoint.allBootstrapServers.isEmpty else {
            // A custom DoH endpoint with no bootstrap IPs yet (cache not warmed).
            // Answering from empty arrays would hand the client an empty record set
            // and guarantee the connection fails; forwarding the hostname normally at
            // least resolves while Device DNS is healthy, so don't intercept here.
            return nil
        }

        // Bootstrap answers for the selected DoH hostname bypass filtering and diagnostics to avoid resolver recursion.
        return DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: bootstrappedEndpoint)
    }

    func doqBootstrapResponse(
        for question: DNSQuestion,
        query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration,
        admittedAtEpoch: UInt64
    ) -> Data? {
        // Candidate DoQ hostnames to answer from bundled bootstrap IPs rather than
        // forward (forwarding would recurse through the very resolver we're reaching):
        //   - the active DoQ primary's endpoints, and
        //   - the encrypted fallback's DoQ endpoints (a custom `doq://` fallback a
        //     Device-DNS primary keeps for the wedge safety net). Without bootstrapping
        //     the fallback host, its lookup would be forwarded to the (possibly wedged)
        //     Device DNS, so the safety net couldn't recover a cold device — the same
        //     reasoning as the DoH fallback in `dohBootstrapResponse`.
        var candidateEndpoints = resolverConfiguration.encryptedFallbackDoQEndpoints
        if resolverConfiguration.transport == .dnsOverQUIC {
            candidateEndpoints = resolverConfiguration.doqEndpoints + candidateEndpoints
        }

        // Reuse question.normalizedDomain instead of re-normalizing per query (see dohBootstrapResponse).
        let normalizedQuestionDomain = question.normalizedDomain
        guard !candidateEndpoints.isEmpty,
              let endpoint = candidateEndpoints.first(where: { endpoint in
                  guard let normalizedEndpointHost = normalizedEndpointHostname(endpoint.hostname) else {
                      return false
                  }

                  return normalizedQuestionDomain == normalizedEndpointHost
              })
        else {
            return nil
        }

        let bootstrappedEndpoint = doqEndpointResolvingBootstrapIfNeeded(endpoint, admittedAtEpoch: admittedAtEpoch)
        guard !bootstrappedEndpoint.allBootstrapServers.isEmpty else {
            return nil
        }

        // Bootstrap answers for the selected DoQ hostname keep NWConnection hostname-based for SNI/cert validation while avoiding resolver recursion.
        return DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: bootstrappedEndpoint)
    }

    func dotBootstrapResponse(
        for question: DNSQuestion,
        query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration,
        admittedAtEpoch: UInt64
    ) -> Data? {
        // Candidate DoT hostnames to answer from bundled/cached bootstrap IPs rather
        // than forward (forwarding would recurse through the very resolver we're
        // reaching). `DoTTransport` connects by hostname when an endpoint has no
        // bootstrap IPs, so without this a custom `tls://` fallback (or primary) would
        // resolve its own hostname through the (possibly wedged) Device DNS — the same
        // reasoning as the DoH/DoQ bootstraps.
        var candidateEndpoints = resolverConfiguration.encryptedFallbackDoTEndpoints
        if resolverConfiguration.transport == .dnsOverTLS {
            candidateEndpoints = resolverConfiguration.dotEndpoints + candidateEndpoints
        }

        // Reuse question.normalizedDomain instead of re-normalizing per query (see dohBootstrapResponse).
        let normalizedQuestionDomain = question.normalizedDomain
        guard !candidateEndpoints.isEmpty,
              let endpoint = candidateEndpoints.first(where: { endpoint in
                  guard let normalizedEndpointHost = normalizedEndpointHostname(endpoint.hostname) else {
                      return false
                  }

                  return normalizedQuestionDomain == normalizedEndpointHost
              })
        else {
            return nil
        }

        let bootstrappedEndpoint = dotEndpointResolvingBootstrapIfNeeded(endpoint, admittedAtEpoch: admittedAtEpoch)
        guard !bootstrappedEndpoint.allBootstrapServers.isEmpty else {
            return nil
        }

        // Bootstrap answers for the selected DoT hostname keep NWConnection hostname-based for SNI/cert validation while avoiding resolver recursion.
        return DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: bootstrappedEndpoint)
    }
}
