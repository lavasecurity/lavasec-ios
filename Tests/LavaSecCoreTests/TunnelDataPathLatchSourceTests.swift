import Foundation
import XCTest

@testable import LavaSecCore

/// Pins the provider wiring for the data-path latch (plan D1) — the half the compiler
/// cannot see.
///
/// The decision itself is executable-tested in `TunnelDataPathLatchTests`. What is pinned
/// here is *where* the decision is made and *who* is allowed to read it: the latch is only
/// worth anything if it is resolved before settings exist and if no settings call site ever
/// goes back to the live configuration. Both properties are ordinary-looking code that a
/// later change could undo without any test failing.
final class TunnelDataPathLatchSourceTests: XCTestCase {
    /// The orchestrator's construction together with the derivation helpers its closures call
    /// (`currentTunnelledPlainDNSRoute`, the admission epoch, the latch check). These were one
    /// contiguous block before the provider split; the initializer is a stored property and so
    /// lives in the core file, while the helpers stayed beside the forwarding pipeline. Joining
    /// the two keeps every assertion below reading the same 21 declarations it read before —
    /// verified by diffing the joined block against the pre-split contiguous span, which differs
    /// only by the `private` widenings the split required.
    ///
    /// The second segment starts at the DOC COMMENT, not the signature. Anchoring on the bare
    /// declaration left the prose — and its own `pinned:` breadcrumb — outside every pinned span,
    /// so a later edit could contradict the contract this file exists to hold without failing
    /// anything (Kilo, PR #651).
    private static func orchestratorConstructionBlock(in provider: String) throws -> String {
        let initializer = try sourceBlock(
            in: provider,
            startingAt: "lazy var resolverOrchestrator = ResolverOrchestrator(",
            endingBefore: "lazy var resolverBootstrapService = ResolverBootstrapService("
        )
        let derivations = try sourceBlock(
            in: provider,
            startingAt: "/// Whether the DATA PATH a T1 rung was admitted under is still installed.",
            endingBefore: "// Wire-level executors for the core orchestrator"
        )
        return initializer + "\n" + derivations
    }

    func testTheBuildFlagIsFlippedAndStillConsulted() throws {
        let provider = try readPacketTunnelProviderSource()

        // The single line that turned the phase on — flipped LAST, alone, once C1-C7 all
        // held on main (the plan's S8 merge order) and the S8.8b construction slices
        // landed. Pinned TRUE so an un-flip is a deliberate decision that rewrites this
        // test, never a stray revert: the flag's comment, INV-CHAIN-1's tense, and the
        // placeholder test's branch all changed with it and would silently rot beneath a
        // quiet `false`.
        XCTAssertTrue(
            provider.contains("static let buildSupportsChainedDataPath = true"),
            "The build wires the data path since S8.8b; un-flipping is a decision that "
                + "rewrites this test and INV-CHAIN-1 together, not a one-character edit."
        )
        XCTAssertTrue(
            provider.contains("buildSupportsChainedDataPath: Self.buildSupportsChainedDataPath"),
            "The latch must consult the build-capability flag, not assume it."
        )
    }

    /// The resolver socket binding must follow the LATCHED mode and the REAL interface.
    ///
    /// Same class of pin as the egress allowance below, and it exists because a mutation proved
    /// it was needed: hardcoding `chainedIsLatched: false` in the seam left the entire suite
    /// green. Every behavioural test of `socketBinding` calls the policy directly, so none of
    /// them can see a provider that stops asking it the truth — and the failure is silent, since
    /// a DNS-only-looking binding is exactly what a working DNS-only build produces.
    ///
    /// What the compiler cannot see, and this pins: the two inputs are derived, not constant.
    func testTheProbesOwnFallbackIsGatedOnTheAdmittingLifecycle() throws {
        // The smoke probe makes a SECOND egress decision after its primary resolves — a direct
        // `resolveDeviceDNS` — and its only guard was `permitsPhysicalInterfaceDNS()`, which
        // answers whether the LATCH allows physical-interface DNS, not whether a session is
        // still running (Codex P1, PR #522). The activity bit that first closed that was
        // itself one frame short: the fallback block runs on `resolverQueue` an async hop
        // after the primary's callback, and a stop/START completing in that gap makes a NEW
        // session satisfy "is there a session at all" — A's canary then egresses during B's
        // measurement window (Codex P1, PR #524). The guard must therefore compare the
        // probe's ADMITTED epoch against the live one, through the orchestrator's single
        // spelling of that rule.
        let provider = try readPacketTunnelProviderSource()
        let fallbackBlock = try sourceBlock(
            in: provider,
            startingAt: "let fallbackResult = self.resolveDeviceDNS(",
            endingBefore: "let fallbackSucceeded = DNSResolverSmokeProbe.acceptsResolutionResponse("
        )
        XCTAssertFalse(
            fallbackBlock.contains("guard"),
            "sanity: the guard belongs BEFORE the fallback call, not after it"
        )
        XCTAssertTrue(
            fallbackBlock.contains("admittedAtEpoch: admittedAtEpoch"),
            "the fallback ladder itself carries the probe's admitted epoch to the socket seam"
        )

        let probeCompletion = try sourceBlock(
            in: provider,
            startingAt: "purpose: .smokeProbe",
            endingBefore: "let fallbackResult = self.resolveDeviceDNS("
        )
        // The block ends immediately before the `resolveDeviceDNS` call, so a guard found
        // here necessarily precedes the egress it protects.
        XCTAssertTrue(
            probeCompletion.containsInOrder([
                "ResolverOrchestrator.workIsAdmitted(",
                "snapshot: admittedAtEpoch, live: self.currentResolverAdmissionEpoch()"
            ]),
            "the probe's own device fallback must not egress for any session but the one "
                + "that admitted it — an activity check admits the NEXT session's window"
        )
        XCTAssertFalse(
            probeCompletion.contains("guard self.currentTunnelLifecycleIsActive() else {"),
            "the activity-bit guard must not come back — it reads TRUE in exactly the bug "
                + "case (old probe, new live session)"
        )
    }

    func testTheResolverSocketBindingUsesOnlyTheVirtualInterface() throws {
        let provider = try readPacketTunnelProviderSource()
        let seam = try sourceBlock(
            in: provider,
            startingAt: "func currentResolverSocketBinding() -> ChainedResolverSocketBinding {",
            endingBefore: "func resolveOverTCP("
        )

        XCTAssertTrue(
            seam.contains("currentTunnelDataPathMode().isChainedUpstream"),
            "the binding must follow the LATCHED mode; a constant here means chained sessions "
                + "open sockets on the physical interface and nothing reports it"
        )
        XCTAssertFalse(
            seam.contains("chainedIsLatched: false") || seam.contains("chainedIsLatched: true"),
            "a literal latch value defeats the seam entirely"
        )
        XCTAssertTrue(
            seam.contains("virtualInterface.map { UInt32($0.index) }"),
            "the index comes from the provider's own virtual interface — iOS's authoritative 'this is "
                + "our utun', the only signal that establishes ownership"
        )
        // PR #558 (Codex): there is deliberately NO address-matched getifaddrs fallback. A tunnel's
        // assigned IPv4 is not device-unique, so even a SOLE utun match could be another VPN's or a
        // stale interface — and ownership cannot be established from an interface list, so binding to it
        // would leak DNS to (or blackhole it in) the wrong tunnel. `virtualInterface` is the only sound
        // ownership signal; when it is nil the binding refuses and fails closed (INV-DNS-1).
        XCTAssertFalse(
            seam.contains("resolvedTunnelInterfaceIndexFromLiveInterfaces(")
                || seam.contains("enumerateIPv4Interfaces("),
            "the resolver socket must NOT bind to a getifaddrs-address-matched utun (Codex, PR #558)"
        )
        XCTAssertFalse(
            seam.contains("tunnelInterfaceIndex: nil"),
            "a nil index literal makes every chained resolution refuse, which reads as a dead resolver "
                + "rather than as the wiring being absent"
        )
    }

    func testTheOrchestratorCannotBeBuiltWithoutAnEgressDecision() throws {
        // This replaces a name-presence pin that asserted the provider MENTIONED
        // `ChainedResolverEgressPolicy` and both ladder-suspension predicates once the build
        // flag was flipped. That pin was worse than no guard: a mention proves a name appears,
        // not that the value governs anything, so the flip would have looked protected while
        // forwarding, startup probes and recovery probes carried on egressing around the
        // tunnel.
        //
        // The enforcement is structural now and lives where it can be executed:
        // `ResolverOrchestrator.init` takes a required `EgressAllowance` with no default, and
        // `ResolverOrchestratorTests` proves behaviourally that `.chainedMode` refuses both the
        // device-DNS fallback and a device-DNS primary. What is left for a source pin is the
        // one thing the compiler cannot see — that the provider derives the allowance from the
        // latched mode instead of hardcoding the permissive one.
        let provider = try readPacketTunnelProviderSource()
        let construction = try Self.orchestratorConstructionBlock(in: provider)
        XCTAssertTrue(
            construction.contains("egressAllowance:"),
            "the orchestrator must be given an egress decision at construction"
        )
        // From the LATCHED mode, not the build capability. The build flag is process-wide
        // while the latch resolves per-session, so deriving from the flag gives `.chainedMode`
        // to sessions that latched DNS-only and returns SERVFAIL where they resolve today.
        XCTAssertTrue(
            construction.contains("currentTunnelDataPathMode()"),
            "the allowance must follow the LATCHED mode, not the build-wide capability flag"
        )
        XCTAssertFalse(
            construction.contains("buildSupportsChainedDataPath"),
            "deriving the allowance from the build flag suspends the fallback ladder for "
                + "DNS-only sessions the moment that flag flips"
        )
        // THE POLARITY, not just the derivation. The two assertions above are satisfied by an
        // INVERTED mapping — chained sessions egressing freely on the physical interface while
        // DNS-only sessions have their fallback ladder suspended — which is the wiring bug in
        // its most damaging form and which the whole executable suite survives, because every
        // behavioural test of the allowance constructs its own value rather than reading the
        // provider's. So the mapping is pinned as one whole expression.
        // The mapping is now a three-way fan-out (DNS-only / chained full / chained split), so
        // it is pinned as its arms rather than as one expression. The polarity property is
        // unchanged and is what these assert: a CHAINED session must never receive
        // `.dnsOnlyMode`, and the split-tunnel arm must come from the POLICY reading the
        // latched routing plan — not from a preference, and not from the mode alone.
        XCTAssertTrue(
            construction.contains("case .dnsOnly:\n                return .dnsOnlyMode"),
            "DNS-only must map to its own permissive allowance"
        )
        XCTAssertTrue(
            construction.contains(
                "ChainedResolverEgressPolicy.permitsTierOneFallbackOnPhysicalInterface(\n"
                    + "                    chainedIsLatched: true, routingPolicy: upstream.containsFullTunnel ? .fullTunnel : upstream.routingPolicy)\n"
                    + "                    ? .chainedSplitTunnelMode : .chainedMode"),
            "the chained arms must be chosen by the POLICY from the latched routing plan; "
                + "an inverted or preference-driven mapping satisfies every other assertion "
                + "here and leaks chained sessions onto the physical interface"
        )
        XCTAssertFalse(
            construction.contains("case .chainedUpstream(let upstream):\n                return .dnsOnlyMode"),
            "a chained session must never receive the permissive allowance"
        )
        // A CLOSURE, so the orchestrator is built once and never written. Storing the value
        // made it per-session, which meant rebuilding the orchestrator on every start — a
        // write to a property that per-query work reads from the CONCURRENT resolverQueue,
        // racing any resolution still in flight from the previous session.
        XCTAssertTrue(
            construction.contains("egressAllowance: {"),
            "the allowance must be a closure read per resolution; a stored value forces a "
                + "per-start rebuild, which races in-flight resolver work"
        )
        XCTAssertFalse(
            provider.contains("resolverOrchestrator = makeResolverOrchestrator()"),
            "the orchestrator must not be reassigned — a write races the concurrent readers"
        )
    }

    func testTheOrchestratorAdmitsWorkOnlyForTheLiveLifecycle() throws {
        // The provider half of generation-tagged admission. The orchestrator's own behaviour
        // is covered executably by `ResolverAdmissionEpochTests`; what only a pin can see is
        // that the provider feeds it a value which actually MOVES between sessions, and which
        // reports "no session" rather than a stale-but-plausible number.
        let provider = try readPacketTunnelProviderSource()
        let construction = try sourceBlock(
            in: provider,
            startingAt: "lazy var resolverOrchestrator = ResolverOrchestrator(",
            endingBefore: "lazy var resolverBootstrapService = ResolverBootstrapService("
        )
        XCTAssertTrue(
            construction.contains("admissionEpoch:"),
            "the orchestrator must be given a session identity at construction"
        )
        XCTAssertTrue(
            construction.contains("guard let self else { return 0 }"),
            "an absent provider must report NO session — any non-zero constant would admit "
                + "every resolution that outlived the tunnel"
        )

        // The activity bit is the load-bearing half. `tunnelLifecycleGeneration` alone still
        // holds the number the session ended on, so a resolution admitted in the dying
        // session would keep matching it between the stop and the next start — the window
        // the transports' quiesce covers today, reopened one layer up. This mirrors
        // `currentTunnelledPlainDNSRoute`, which draws the same distinction for the same
        // reason (PR #518 round 4).
        let epochBody = try sourceBlock(
            in: provider,
            startingAt: "func currentResolverAdmissionEpoch() -> UInt64 {",
            endingBefore: "func currentTunnelledPlainDNSRoute()"
        )
        XCTAssertTrue(
            epochBody.contains("self.tunnelLifecycleIsActive ? self.tunnelLifecycleGeneration : 0"),
            "an invalidated lifecycle must report 0, not the generation it ended on"
        )
        XCTAssertTrue(
            epochBody.contains("dnsStateQueue.sync(execute: read)"),
            "the lifecycle read is dnsStateQueue-confined (INV-QUEUE-1)"
        )
        XCTAssertTrue(
            epochBody.contains("DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true"),
            "and dual-entry, since the orchestrator consults it from paths already on that queue"
        )

        // WHERE the epoch ORIGINATES, which is the half a behavioural test of the
        // orchestrator cannot see. Eight rounds of this stack each found the same defect one
        // capture-site further out, because the token was being RE-captured below the
        // acceptance boundary — below the bounded FIFO, below the read loop's batch check —
        // and every re-capture names whatever session exists by then (Codex P1, PR #524).
        // The restructure gives the forwarding path exactly ONE origin per acceptance
        // boundary: the read loop's armed generation, the bootstrap wait's stored
        // generation, the serve queue's lifecycle token. Between an origin and the
        // orchestrator, NO capture may exist at all.
        // The smoke probe owns a SECOND egress decision the epoch does not reach: its
        // completion runs a direct `resolveDeviceDNS` gated only on
        // `permitsPhysicalInterfaceDNS()`. A stale probe whose orchestrator result is a
        // lifecycle refusal must stop THERE, or its canary is sent on the wire during the
        // next session — the one query the epoch was supposed to stop (Codex P1, PR #524).
        let probeCompletion = try sourceBlock(
            in: provider,
            startingAt: "purpose: .smokeProbe,",
            endingBefore: "let primarySucceeded = DNSResolverSmokeProbe.acceptsResolutionResponse("
        )
        // THE CATEGORY, for the same reason as the ladder stops below: a probe that abandoned only
        // on a lifecycle refusal would send its canary on the wire under a data path the user had
        // already replaced (PR #610).
        XCTAssertTrue(
            probeCompletion.contains("$0.outcome.endsTheResolutionLadder"),
            "the probe must abandon on either terminal refusal before its own device fallback"
        )
        // AND SAY WHICH ONE. The branch now catches a same-lifecycle relatch too, so a constant
        // "lifecycle-ended" would send a field capture looking for a tunnel restart that never
        // happened — erasing the distinction the outcome was added to draw (Codex P2, PR #610).
        XCTAssertTrue(
            probeCompletion.contains("terminalRefusal?.rawValue ?? \"lifecycle-ended\""),
            "the logged cause is derived from the refusal that actually ended the ladder")
        XCTAssertFalse(
            probeCompletion.contains("\"cause\": \"lifecycle-ended\""),
            "no constant cause: this branch has two reachable causes now")
        XCTAssertTrue(
            probeCompletion.contains("finish()"),
            "and release its work slot rather than falling through"
        )

        // The packet-borne origin: the read loop's DNS-only arm hands its OWN armed
        // generation to `handle`, which threads it into `handleDNSRequest` — the fence
        // every caller of that function must now name a session for.
        XCTAssertEqual(
            sourceOccurrenceCount(of: "expectedLifecycleGeneration: lifecycleGeneration", in: provider),
            1,
            "the read-loop path passes the batch's own generation — exactly once, in `handle`"
        )
        XCTAssertEqual(
            sourceOccurrenceCount(of: "expectedLifecycleGeneration: UInt64?", in: provider),
            2,
            "only the two REPLAYS keep an optional generation — the bootstrap wait's and the "
                + "wake reset's, each of which guard-unwraps it before handing the fence a "
                + "session (and SERVFAILs the nil); the fence itself takes a non-optional one"
        )

        // No re-capture below any origin: between `handleDNSRequest` and the orchestrator
        // the token flows as `admittedAtEpoch` parameters, and the ONLY remaining reads of
        // the live epoch in this file are the acceptance boundaries themselves (the smoke
        // probe's scheduling site, the DoQ bootstrap's synchronous entry, the orchestrator's
        // construction closure) and the egress-adjacent RECHECKS that compare the caller's
        // token against the live value (the probe's queued fallback, the two socket-seam
        // guards). A capture reappearing inside `forward`/`dispatchForwardResolution` shows
        // up as a count bump here before it ships (Codex P1, PR #524).
        for site in [
            "func forward(",
            "private func dispatchForwardResolution("
        ] {
            let block = try sourceBlock(
                in: provider, startingAt: site, endingBefore: "runBoundedResolverWork")
            XCTAssertFalse(
                block.contains("let admittedAtEpoch = currentResolverAdmissionEpoch()"),
                "\(site) must use the CALLER'S admitted epoch — a capture at this altitude "
                    + "names whatever session exists by the time the unit runs"
            )
            XCTAssertTrue(
                block.contains("admittedAtEpoch: UInt64"),
                "\(site) receives the admitting session as a parameter"
            )
        }
        XCTAssertEqual(
            sourceOccurrenceCount(of: "currentResolverAdmissionEpoch()", in: provider), 10,
            "Forwarding and bootstrap lifetime checks compare the original epoch; they never recapture it.")
        XCTAssertFalse(
            try sourceBlock(
                in: provider,
                startingAt: "func resolveDoQBootstrapAddresses(",
                endingBefore: "func resolveUDP("
            ).contains("currentResolverAdmissionEpoch()"),
            "the bootstrap ladder runs after the service's queue hop — a capture here "
                + "names whatever session is live by then and every downstream check "
                + "passes trivially"
        )

        // The fence itself: every packet names the session that accepted it, and a stale
        // one is DROPPED — `writeDNSResponse` has no lifecycle gate of its own, so a
        // SERVFAIL built for a retired session would be injected into the packet flow
        // that is live NOW (Codex, PR #508).
        let fence = try sourceBlock(
            in: provider,
            startingAt: "func handleDNSRequest(",
            endingBefore: "let question: DNSQuestion"
        )
        XCTAssertTrue(
            fence.containsInOrder([
                "guard isCurrentTunnelLifecycle(expectedLifecycleGeneration) else {",
                "return",
                "}"
            ]),
            "the fence refuses work for any session but the accepting one, before any "
                + "decision work runs"
        )
        XCTAssertFalse(
            fence.contains("writeServerFailures"),
            "and refuses by DROPPING — a stale session's answer written into the live "
                + "flow can fail a live query that reused the tuple and transaction ID"
        )
    }

    func testTheSocketSeamValidatesAdmissionPerWireAttempt() throws {
        // The plain/device ladders spend real UDP/TCP timeouts per rung, which is exactly
        // how a stale resolution gets late enough to egress into the next session. The
        // guard sits at the socket seam — the same placement where the tunnelled executor
        // validates its route triple (S6, PR #518) — so every wire attempt of every ladder
        // passes it, and the ladder above stops where it stands (Codex P1, PR #524).
        let provider = try readPacketTunnelProviderSource()
        // JUST ENOUGH SIGNATURE TO DISAMBIGUATE, and no more. A bare `func resolveUDP(`
        // would match either overload and this test is about the admission-guarded wrapper, not
        // the raw binding-taking one below it — so the marker has to reach the first parameter
        // line. But pinning the WHOLE signature made it move every time either seam gained a
        // parameter: once for the rung's egress interface (PR #590), and again for the rung's
        // data-path token (PR #610), each time failing as "start marker not found" rather than as
        // the admission behaviour this test is about. Specific about WHERE, permissive about the
        // rest.
        // Each seam carries its OWN end marker. They no longer share a `guard case .permitted`
        // tail — PR #747 turned the binding refusal into a `switch` that names the two cases —
        // so the UDP wrapper ends before the binding-taking overload beneath it, and the TCP
        // seam ends before the next declaration in its file.
        for (entry, endMarker) in [
            (
                "func resolveUDP(\n        _ query: Data, endpoint: ResolverEndpoint, admittedAtEpoch: UInt64,",
                "func resolveUDP(\n        _ query: Data, endpoint: ResolverEndpoint, bindingDecision:"
            ),
            (
                "func resolveOverTCP(\n        _ query: Data, endpoint: ResolverEndpoint, admittedAtEpoch: UInt64,",
                "func currentTunnelDataPathMode()"
            )
        ] {
            let block = try sourceBlock(
                in: provider, startingAt: entry, endingBefore: endMarker)
            XCTAssertTrue(
                block.containsInOrder([
                    "ResolverOrchestrator.workIsAdmitted(",
                    "snapshot: admittedAtEpoch, live: currentResolverAdmissionEpoch()",
                    "return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded)"
                ]),
                "each wire attempt validates the resolution's ADMITTED epoch before any "
                    + "socket exists — a check at the ladder's entry alone leaves every "
                    + "later rung ungated"
            )
        }

        // And the ladder STOPS on the refusal, keeping it last in `attempts` — the shape
        // the abandoned (neutral) aggregate classification keys on. One UDP stop, and one
        // per TCP rung.
        //
        // ASSERTED THROUGH THE CATEGORY, not an equality against one outcome. These three tests
        // were equality checks against `.refusedAfterLifecycleEnded`, and adding a SECOND terminal
        // refusal — `.refusedAfterLatchReplaced` — meant a ladder that walked on past a replaced
        // data path would still have satisfied all three (PR #610). Three places to update is
        // three places to miss; `endsTheResolutionLadder` is the one place a third such outcome
        // joins.
        let ladder = try sourceBlock(
            in: provider,
            startingAt: "func resolvePlainDNS(",
            endingBefore: "private func shouldAttemptTCPFallback(afterUDPOutcome"
        )
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "if udpResult.outcome.endsTheResolutionLadder {\n                break\n            }",
                in: ladder),
            1,
            "the UDP rung's refusal ends the ladder"
        )
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "if tcpResult.outcome.endsTheResolutionLadder {\n                    break\n                }",
                in: ladder),
            2,
            "both TCP rungs' refusals end the ladder"
        )
        // And the absent-provider branch must refuse rather than permit: a resolution
        // outliving its provider must not be the one path that egresses freely.
        let construction = try sourceBlock(
            in: provider,
            startingAt: "lazy var resolverOrchestrator = ResolverOrchestrator(",
            endingBefore: "lazy var resolverBootstrapService = ResolverBootstrapService("
        )
        XCTAssertTrue(
            construction.contains("guard let self else { return .chainedMode }"),
            "a resolution outliving its provider must fail closed, not permissive"
        )
    }

    /// The tunnel must NOT claim the T1 resolver's route.
    ///
    /// `openingRoutes(forFallbackResolvers:)` widened `AllowedIPs` so the tunnel would ROUTE the
    /// chosen alternative DNS, which made T1 depend on the peer forwarding it — i.e. on the
    /// peer being an exit node. rc9 (build 1787723354) measured three attempts to 1.1.1.1 through
    /// a Tailscale node with no route for it, three drops, nothing back. The method itself is
    /// deleted (the plan's S3); this pin outlives it because a widening is one line to write
    /// again, and nothing behavioural in the provider would notice.
    ///
    /// The rung's socket is UNBOUND, so it follows the routing table. Claiming the address here
    /// would put that route back inside the tunnel and the datagram would re-enter it regardless
    /// of the binding — the two halves only work together, which is why this is pinned beside
    /// the binding test rather than left implicit (Codex, PR #590).
    func testTheTunnelDoesNotClaimTheTierOneResolversRoute() throws {
        let provider = try readPacketTunnelProviderSource()
        let installer = try sourceBlock(
            in: provider,
            startingAt: "func installLatchedDataPathMode(",
            endingBefore: "func currentTunnelDataPathMode()")

        // The method is deleted, so this now pins that nothing REINTRODUCES it. Asserted on the
        // call form rather than the bare name because the block's own comment records why the
        // widening is gone — an assertion on the bare name fails on its own rationale, which is
        // how this test first went red.
        XCTAssertFalse(
            installer.contains("openingRoutes("),
            "claiming the resolver's route sends the physical rung back into the tunnel")
        XCTAssertTrue(
            installer.contains("let routedMode = mode"),
            "the latched mode must be installed unwidened")
    }

    /// The T1 rung overrides the chained socket binding at the UDP and TCP seams.
    ///
    /// `currentResolverSocketBinding()` keys only on whether chained is latched, so left to
    /// itself it pins the rung to the utun. A pin because the provider is the only place the
    /// override exists and no executable test in this package can observe which interface a
    /// datagram left on.
    func testTheTierOneRungOverridesTheChainedSocketBinding() throws {
        let provider = try readPacketTunnelProviderSource()

        // BOUNDED BY THE FUNCTION, not by a character count. This read `prefix(2600)`, which is a
        // pin on how LONG the function is rather than on what it contains: adding the rung's
        // data-path guard and its rationale pushed the binding logic past the window, and the
        // failure read as "the seam does not take the policy's binding" — the exact opposite of
        // what had changed (PR #611). A magic width silently stops covering the thing it pins.
        for seam in ["func resolveUDP(", "func resolveOverTCP("] {
            let body = try sourceBlock(in: provider, startingAt: seam, endingBefore: "\n    }\n")
            XCTAssertTrue(
                body.contains("ChainedResolverEgressPolicy.tierOneSocketBinding("),
                "\(seam) must take the rung's binding from the policy, not the chained seam")
            XCTAssertTrue(
                body.contains("case .physical:"),
                "\(seam) must fan out on the rung's egress interface")
            // F2: the physical rung's pin is scoped to the destination. An unscoped
            // `.boundToPhysical` (or the old `.systemChosen`) would either strand a
            // floor-claimed resolver or override the profile's own routes.
            XCTAssertTrue(
                body.contains("destinationIsFloorClaimed:"),
                "\(seam) must ask whether the destination is on the DNS capture floor")
            XCTAssertTrue(
                body.contains("destinationIsProfileCovered:"),
                "\(seam) must keep the user's own AllowedIPs authoritative")
            XCTAssertTrue(
                body.contains("currentPhysicalInterfaceIndex()"),
                "\(seam) must pin the interface the path actually observed")
        }
    }

    /// The device-DNS/plain egress binds a floor-claimed destination physically (F2).
    ///
    /// The provider is the only place this can be observed: the orchestrator hands a destination
    /// down and the socket layer applies whatever index it is given, so a seam left on the
    /// mode-only binding would pin a floor-claimed resolver back into the tunnel and strand
    /// Lava's own query. A pin because no executable test in this package can observe which
    /// interface a datagram left on.
    func testTheDeviceDNSEgressBindsTheFloorClaimedDestinationPhysically() throws {
        let provider = try readPacketTunnelProviderSource()
        let seam = try sourceBlock(
            in: provider,
            startingAt: "func currentResolverSocketBinding(for endpoint: ResolverEndpoint)",
            endingBefore: "\n    }\n")

        XCTAssertTrue(
            seam.contains("destinationSocketBinding("),
            "the destination-aware seam must decide through the one F2 policy")
        XCTAssertTrue(
            seam.contains("deviceResolverIsFloorClaimed("),
            "the floor term must come from the captured device resolvers, compared address-aware")
        XCTAssertTrue(
            seam.contains("physicalInterfaceIndex: currentPhysicalInterfaceIndex()"),
            "the pin must use the live physical index, never a guess")
        // While chained, device DNS is redirected through the tunnel and the physical path is the
        // leak — this seam must not acquire a physical escape there.
        XCTAssertTrue(
            seam.contains("isChainedUpstream"),
            "the chained branch must keep the mode-only tunnel binding")
        XCTAssertFalse(
            seam.contains("boundToTunnel"),
            "the destination-aware seam must not restate the tunnel pin; the mode-only seam owns it")
    }

    /// The floor-claim check requires a LATCHED CHAINED SPLIT and covers BOTH membership sources
    /// there — F1's curated public set and F3b's CAPTURED device resolvers — returning false in
    /// DNS-only.
    ///
    /// DNS-only claims nothing (the provider passes `[]`), so a curated address must NOT report as
    /// claimed there: a claim would draw the resolver's non-53 traffic into a path with no
    /// forwarding rung and silently drop it (the `https://1.1.1.1` breakage Kilo caught on
    /// PR #752). The captured resolvers are chained-split-only for the same reason they always
    /// were — the capture still runs in DNS-only, so its addresses survive in
    /// `deviceDNSResolverAddresses` and a check that read only that set would pin the device-DNS
    /// egress physically in a session that claims nothing. Full tunnel already claims every
    /// destination and ignores the floor. A source pin because the decision lives in the tunnel
    /// process and no executable test observes which interface a datagram left on.
    func testTheFloorClaimRequiresALatchedChainedSplitAndCoversCuratedAddresses() throws {
        let provider = try readPacketTunnelProviderSource()
        let helper = try sourceBlock(
            in: provider,
            startingAt: "func deviceResolverIsFloorClaimed(_ address: String) -> Bool",
            endingBefore: "func latchedChainedAllowedIPsCover(")

        XCTAssertTrue(
            helper.contains("currentTunnelDataPathMode()"),
            "the floor claim depends on the latched data path, not on a membership source alone")
        XCTAssertTrue(
            helper.contains(".splitTunnel"),
            "only the split plan carries the floor; full tunnel already claims everything")
        XCTAssertTrue(
            helper.contains("TunnelRoutePlan.dnsServerAddress"),
            "the tunnel's own v4 listener is never a floor claim")
        XCTAssertTrue(
            helper.contains("TunnelRoutePlan.chainedDNSServerIPv6Address"),
            "the tunnel's own v6 listener is never a floor claim")
        // F1: the curated set IS a floor claim in a chained split — both families ride the split
        // plan's host routes.
        XCTAssertTrue(
            helper.contains("DNSCaptureFloor.isCuratedPublicResolverAddress("),
            "a curated public resolver must be a floor claim inside the chained split")
        // The captured arm must apply the SAME on-link-gateway exclusion the plan wiring uses, or
        // a gateway the floor no longer claims would still be reported as claimed and the F2 seam
        // would pin (or refuse) a destination the routing table is free to choose.
        XCTAssertTrue(
            helper.contains("DNSCaptureFloorMembership.excludesAsOnLinkGatewayClass("),
            "the captured floor-claim check must mirror the plan wiring's gateway exclusion")
        // ORDER is the proof that DNS-only reports false: the listener guard, then the latched
        // chained-split guard, then the curated early-true, then the captured-set membership test.
        // A curated check placed BEFORE the mode guard would report a curated address claimed in
        // DNS-only, which is exactly the bug this ordering closes.
        XCTAssertTrue(
            sourceContainsInOrder([
                "TunnelRoutePlan.dnsServerAddress",
                "currentTunnelDataPathMode()",
                "configuration.effectiveRoutingPolicy == .splitTunnel",
                "DNSCaptureFloor.isCuratedPublicResolverAddress(",
                "currentDeviceDNSResolverAddresses().contains",
            ], in: helper),
            "the chained-split guard must precede the curated and captured membership tests")
        XCTAssertFalse(
            helper.contains("isChainedUpstream") || helper.contains("routingPolicy == .fullTunnel"),
            "a chained check that admits full tunnel is too broad: full tunnel ignores the floor")
    }

    /// The tunnelled route carries T0 ONLY — the conf's own `DNS =`, never the appended
    /// T1 set.
    ///
    /// Routing a public resolver through the peer made T1 depend on the peer being an exit
    /// node, which rc9 (build 1787723354) measured as three attempts dropped with nothing coming
    /// back. Leaving the appended set here would also spend a UDP receive budget per T1
    /// address through a peer that will not forward it, BEFORE the physical rung that works.
    ///
    /// A pin because the provider is the only place that decides it, and the orchestrator cannot
    /// see what it was handed: a route carrying the fallback again is one word, and every
    /// behavioural test would still pass because they build their own routes.
    func testTheTunnelledRouteCarriesTierZeroOnly() throws {
        let provider = try readPacketTunnelProviderSource()
        let derivation = try sourceBlock(
            in: provider,
            startingAt: "func currentTunnelledPlainDNSRoute()",
            endingBefore: "func chainedTunnelledDNSSurvivesPhysicalPathChange()")

        XCTAssertFalse(
            derivation.contains("fallbackResolverAddresses"),
            "the route type carries no T1 set at all any more (the plan's S3)")
        // T0 BY CONSTRUCTION, not by arithmetic. An earlier shape of this slice kept the
        // appending and sliced the suffix off; once the tunnel stopped claiming the T1 route
        // the selection would refuse those addresses anyway, so the honest derivation is simply
        // not to append them.
        XCTAssertTrue(
            derivation.contains("ChainedTunnelResolverSelection.selection(from: configuration)"),
            "the selection must carry the conf's own DNS and nothing else")
        XCTAssertFalse(
            derivation.contains("appending:"),
            "appending a T1 set puts it back on the wire the peer will not forward")
    }

    func testTheTunnelledRouteIsTheLatchedConfigurationsSelectedResolvers() throws {
        // The S6 carry's other required argument, pinned for the same reason as the
        // allowance: the orchestrator proves behaviourally that a supplied route carries
        // `.plainDNS` through the tunnelled executor, but only a pin can see WHAT the
        // provider derives the route from. The dangerous drifts are each one line: reading
        // `configuration.dnsAddresses` raw (a first-entry consumer sources from
        // `DNS = 0.0.0.0` — the exact failure the selection type exists to prevent),
        // deriving from something other than the latched mode, or answering a constant.
        let provider = try readPacketTunnelProviderSource()
        let construction = try Self.orchestratorConstructionBlock(in: provider)
        XCTAssertTrue(
            construction.contains("tunnelledPlainDNSRoute: { [weak self] in"),
            "the route must be a closure read per resolution, like the allowance"
        )
        // The derivation is ONE critical section: the latched payload, the selected
        // set, and the originating-lifecycle token are read together, or a stop/restart
        // between the reads hands the executor a route whose token the NEW lifecycle
        // honours (Codex, PR #518 round 2).
        XCTAssertTrue(
            construction.contains(
                "guard self.tunnelLifecycleIsActive,\n                case .chainedUpstream(let configuration) = self.latchedDataPathMode\n            else {"),
            "the route must derive from the LATCHED configuration payload of an ACTIVE "
                + "lifecycle — the latch outlives an invalidation until the async cleanup, "
                + "so the activity bit is what refuses the stop window"
        )
        // Still the SELECTED set — raw `dnsAddresses` would reintroduce the unusable-first-entry
        // failure. It is T0 ONLY now, and by construction rather than by slicing: the
        // selection is built without appending the T1 addresses at all, so `selection.resolvers`
        // IS the T0 set. `testTheTunnelledRouteCarriesTierZeroOnly` pins that half; this one
        // pins that the addresses come from the selection.
        XCTAssertTrue(
            construction.contains("ChainedTunnelResolverSelection.selection(")
                && construction.contains("resolverAddresses: selection.resolvers,"),
            "the route must carry the SELECTED set; raw dnsAddresses reintroduces the "
                + "unusable-first-entry failure"
        )
        XCTAssertTrue(
            construction.contains("originatingLifecycle: self.tunnelLifecycleGeneration,"),
            "the lifecycle token must be sealed into the route in the same critical "
                + "section as the addresses"
        )
        // And the LATCH EPOCH beside it: the lifecycle counter moves before the latch
        // is replaced and the construction downgrade rewrites the latch within one
        // counter value, so only the epoch names the latch the addresses came from
        // (Codex, PR #518 round 3).
        XCTAssertTrue(
            // CLOSING PAREN, not a comma. The T1 set used to follow this line, so the pin
            // was written against its trailing comma; deleting that argument (the plan's S3) made
            // the epoch the last one and turned a correct assertion red on a correct change.
            // Anchored on the paren now, which also pins that nothing was appended after it.
            construction.contains("originatingLatchEpoch: self.tunnelDataPathLatchEpoch)"),
            "the latch-epoch token must be sealed in the same critical section too"
        )
        // THE T1 SET IS NO LONGER ON THE ROUTE. PR #575 sealed the effective fallback set
        // here so the rescue-attribution set and the resolver set could not drift, both coming
        // from the one `selection(...)` over the latched fallback. S2 retires the premise rather
        // than the assertion: there is no tunnelled T1 to attribute, because routing a public
        // resolver through the peer made it depend on the peer being an exit node — rc9 measured
        // three attempts dropped with nothing back. The rung runs on the physical interface, and
        // its accounting is re-aimed in S3.
        //
        // The one-critical-section property the old assertion protected is unchanged and is still
        // pinned above: the addresses, the lifecycle token and the latch epoch are read together.
        XCTAssertFalse(
            construction.contains("fallbackResolverAddresses"),
            "the route type carries no T1 set at all any more; re-adding one sends the "
                + "query back through a peer that will not forward it"
        )
    }

    func testTheLatchHasExactlyOneWriterAndItBumpsTheEpoch() throws {
        // The epoch is only meaningful if EVERY latch install bumps it — a bare
        // assignment anywhere else silently re-opens the same-generation transition the
        // epoch exists to make visible. So the latch has exactly one writer, and the
        // writer stamps the epoch in the same critical section.
        let provider = try readPacketTunnelProviderSource()
        let assignments = provider.components(separatedBy: "latchedDataPathMode = ").count - 1
        XCTAssertEqual(
            assignments, 1,
            "the latch must have exactly ONE assignment site — the installer that bumps "
                + "the epoch; found \(assignments)"
        )
        let installer = try sourceBlock(
            in: provider,
            startingAt: "func installLatchedDataPathMode(",
            endingBefore: "func latchDataPathMode(for configuration:"
        )
        XCTAssertTrue(
            installer.contains("latchedDataPathMode = routedMode"),
            "the one assignment site must live inside the installer"
        )
        // ...and `routedMode` is the installer's OWN `mode` parameter, unmodified. Without this
        // the assertion above degrades to "some local is assigned", which a second source of
        // truth for the latch would satisfy.
        //
        // THE WIDENING IS GONE, and its assertion with it. PR #584 required
        // `openingRoutes(forFallbackResolvers:)` here so the tunnel would carry the chosen
        // alternative DNS rather than report that it could not — the whole point of the setting.
        // The setting's point is unchanged; the mechanism is. Routing the resolver through the
        // peer made it depend on the peer being an exit node, and rc9 measured three attempts
        // dropped with nothing back. It now egresses on the physical interface, on an unbound
        // socket, which only works while the tunnel does NOT claim its route — so the claim
        // must be absent, and `testTheTunnelDoesNotClaimTheTierOneResolversRoute` asserts that
        // directly (PR #590).
        XCTAssertTrue(
            installer.contains("let routedMode = mode"),
            "every mode must pass through untouched — a widened one re-enters the tunnel")
        XCTAssertTrue(
            installer.contains("latchedDataPathRefusal = refusal"),
            "both latch fields must publish together — a torn write leaves a mode and a "
                + "refusal that disagree (INV-QUEUE-1)"
        )
        XCTAssertTrue(
            installer.contains("tunnelDataPathLatchEpoch &+= 1"),
            "the installer must bump the latch epoch in the same critical section"
        )
        // The queue-confinement half the replaced pin carried, restored (Kilo, PR #518):
        // the install closure publishes on dnsStateQueue through the dual-entry pattern,
        // so both fields and the epoch land together whatever queue the caller is on.
        XCTAssertTrue(
            installer.contains(
                "if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {"),
            "the installer must be dual-entry per INV-QUEUE-1's helper contract"
        )
        XCTAssertTrue(
            installer.contains("dnsStateQueue.sync(execute: install)"),
            "an off-queue caller must publish through a dnsStateQueue.sync hop"
        )
        // WHOLE-PROVIDER scope, matching the claim: the rule is "selection is the one
        // consumer", and a raw read added anywhere in this file — a diagnostic, a probe,
        // a future executor — would violate it just as surely as one in the closure.
        XCTAssertFalse(
            provider.contains("configuration.dnsAddresses"),
            "the provider must never touch the raw DNS list; selection is the one consumer"
        )
    }

    func testTheSelfReconnectActorStandsDownWhileChained() throws {
        // The S6 carry made tunnelled timeouts classify as ordinary organic total
        // failures, which reach the physical-path reconnect machinery — machinery that
        // was unreachable while chained before the carry, and whose teardown would race
        // the outage driver's own bounded ladder and surrender path. The wedge-probe arm
        // is gated at its own seam (`permitsPhysicalInterfaceDNS`); this pins the OTHER
        // action on that effects list: the self-reconnect funnel refuses while the
        // latched mode is chained, before any policy decision or store read.
        let provider = try readPacketTunnelProviderSource()
        let funnel = try sourceBlock(
            in: provider,
            startingAt: "func selfReconnectIfPolicyAllows(",
            endingBefore: "let rawAttempts = Self.loadSelfReconnectAttemptTimes()"
        )
        XCTAssertTrue(
            funnel.contains("guard dnsHealthAuthority().physicalReconnectMayAct else {"),
            "the self-reconnect funnel must stand down while chained — it consults the one "
                + "DNSHealthAuthority (as the egress suspension and evidence recorder do), and "
                + "an ungated funnel tears the extension down mid-ladder on the driver's evidence"
        )
    }

    func testTheTunnelledExecutorRunsThePackageLoopOverThePinnedSocket() throws {
        // The executor body is deliberately thin — every decision lives in
        // `TunnelledPlainDNSResolution`, where it has executable tests. What only a pin can
        // see: the provider hands the loop its interface-pinned `resolveUDP` (the S8.7b
        // socket carry — a second socket path here would silently egress on the physical
        // interface), and it submits the observation THROUGH the route's own tokens in
        // one critical section — so the next lifecycle's accumulation is unreachable,
        // and a lifecycle that ends mid-resolve or mid-report drops the evidence rather
        // than handing it to a driver whose lifecycle is over.
        let provider = try readPacketTunnelProviderSource()
        let executor = try sourceBlock(
            in: provider,
            startingAt: "func resolveTunnelledPlainDNS(",
            endingBefore: "/// Submits a tunnel-DNS observation"
        )
        XCTAssertTrue(
            executor.containsInOrder([
                "TunnelledPlainDNSResolution.resolve(",
                "query: query,",
                "route: attemptRoute,",
                // Each failover rung reads the live backoff-path epoch at its own send (task #56, #565).
                "pathEpochAtAttempt: { self.currentResolverBackoffPathEpoch() }",
            ]),
            "the executor must run the package loop (with the per-attempt epoch), not a private copy of it"
        )
        // The wire I/O is the provider's own pinned resolveUDP, and each attempt's
        // binding decision is fused with a check against the lifecycle AND latch THE
        // ROUTE WAS DERIVED UNDER — a plain per-attempt re-read lets a failover loop
        // straddling a DNS-only relatch send the old route's query on the physical
        // interface; a token read separately from the route reopens the race one frame
        // earlier; and the lifecycle counter without the latch epoch misses the
        // same-generation latch transitions (Codex, PR #518, three rounds).
        XCTAssertTrue(
            executor.contains(
                "switch self.resolverSocketBinding(\n                forLifecycle: route.originatingLifecycle,\n                latchEpoch: route.originatingLatchEpoch)"),
            "every attempt must decide its egress atomically against the route's OWN "
                + "lifecycle and latch tokens, or a relatch mid-failover leaks the next attempt"
        )
        XCTAssertTrue(
            executor.contains(
                "originatingLifecycle: route.originatingLifecycle,\n                originatingLatchEpoch: route.originatingLatchEpoch)"),
            "the backoff-filtered route must carry the SAME tokens it was derived with"
        )
        XCTAssertTrue(
            executor.contains(
                "case .permitted(let bindingDecision):\n                return self.resolveUDP(\n                    cappedQuery, endpoint: endpoint, bindingDecision: bindingDecision, lifetime: lifetime)"),
            "the loop's wire I/O must be the provider's own pinned resolveUDP, fed the "
                + "lifecycle-checked binding — any other socket path egresses around the seam"
        )
        // A REFUSAL IS STILL A REFUSAL, and the two named ones are the only ways out besides
        // `.permitted`. Pinned because the enum made the refusal expressible in more than one
        // way: an arm that fell through to a permitted binding would leak exactly the attempt
        // the fused consult exists to stop.
        XCTAssertTrue(
            executor.contains(
                "case .lifecycleEnded:\n                return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded)"))
        XCTAssertTrue(
            executor.contains(
                "case .latchReplaced:\n                return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLatchReplaced)"))
        // And the lifecycle guard inside the binding accessor is what makes the check
        // atomic rather than advisory — fused with the seam consult in one on-queue
        // critical section.
        let bindingAccessor = try sourceBlock(
            in: provider,
            startingAt: "private func resolverSocketBinding(",
            endingBefore: "func resolveTunnelledPlainDNS("
        )
        // ALL THREE TERMS, STILL IN ONE CLOSURE. Split into two guards so the refusal can name
        // which term failed (PR #621) — the split is textual, not temporal: `decide` is the whole
        // critical section and both guards are inside it. Pinned as two adjacent statements so a
        // change that hoists either one out of `decide` fails here.
        XCTAssertTrue(
            bindingAccessor.contains(
                "guard self.tunnelLifecycleIsActive,\n                generation == self.tunnelLifecycleGeneration\n            else { return .lifecycleEnded }\n            guard latchEpoch == self.tunnelDataPathLatchEpoch else { return .latchReplaced }"),
            "the binding accessor must refuse an inactive, stale-lifecycle, or "
                + "stale-latch attempt inside the same critical section that consults "
                + "the seam — an invalidation generation must never validate as active"
        )
        XCTAssertTrue(
            bindingAccessor.contains("return .permitted(self.currentResolverSocketBinding())"),
            "the accessor must delegate to the ONE binding seam, never derive a second copy"
        )
        // The backoff ledger is consulted, through the same seam the DNS-only ladder
        // uses — without it a recorded tunnelled timeout is write-only and a dead
        // resolver in the selected set costs its full timeout on every resolution.
        XCTAssertTrue(
            executor.contains(
                "orderedResolverAddressesForAttempt(route.resolverAddresses)"),
            "the tunnelled loop must consult the backoff ledger like the DNS-only ladder"
        )
        XCTAssertTrue(
            executor.contains("outcome: .backedOff"),
            "an all-suppressed selection must answer fail-closed with .backedOff attempts, "
                + "not go unanswered"
        )
        // Both halves of the observation contract are SUBMITTED through the token
        // check, never via a returned driver: a validating read that returns the
        // driver leaves a read-to-call gap an invalidation can land in
        // (PR #518 round 6).
        XCTAssertTrue(
            executor.contains(
                "reportTunnelDNSObservation(\n                .answered,\n                forLifecycle: route.originatingLifecycle,\n                latchEpoch: route.originatingLatchEpoch)"),
            "the answered half must be submitted through the route's own tokens"
        )
        XCTAssertTrue(
            executor.contains(".unanswered(") && executor.contains("nameKey:")
                && executor.contains(
                    "forLifecycle: route.originatingLifecycle,\n                    latchEpoch: route.originatingLatchEpoch)"),
            "the unanswered half must be submitted through the route's own tokens with "
                + "the canonical name key"
        )
        XCTAssertFalse(
            executor.contains("let driver ="),
            "no driver reference may escape a token check into the executor body"
        )
        // And the submission method itself validates and delivers in ONE critical
        // section.
        let submission = try sourceBlock(
            in: provider,
            startingAt: "private func reportTunnelDNSObservation(",
            endingBefore: "func orderedResolverAddressesForAttempt("
        )
        XCTAssertTrue(
            submission.contains(
                "guard self.tunnelLifecycleIsActive,\n                generation == self.tunnelLifecycleGeneration,\n                latchEpoch == self.tunnelDataPathLatchEpoch,\n                let driver = self.chainedRuntime?.driver\n            else { return }\n            driver.reportTunnelDNSObservation(observation)"),
            "the submission must validate activity, lifecycle, and latch epoch in the "
                + "same critical section that delivers to the driver"
        )
    }

    func testDirectDNSPathsAreSuppressedWhileChained() throws {
        // The orchestrator's EgressAllowance governs everything routed THROUGH it, and two
        // paths are not: the DoQ bootstrap resolves a custom resolver's hostname with
        // `resolvePlainDNS(... .deviceDNS)` directly, and a failed smoke probe calls
        // `resolveDeviceDNS` directly. Both send a query on the interface the chained tunnel
        // routed everything away from, and both are invisible to the allowance AND to the
        // `refusedByEgressPolicy` diagnostics — so the leak would not even appear in a log.
        //
        // Pinned rather than executable because these live in the provider, which the package
        // tests cannot construct. What is pinned is the guard's PRESENCE at each call site,
        // which is the part a later edit would drop silently.
        let provider = try readPacketTunnelProviderSource()

        let bootstrap = try sourceBlock(
            in: provider,
            startingAt: "func resolveDoQBootstrapAddresses(",
            endingBefore: "return (ipv4, ipv6)"
        )
        XCTAssertTrue(
            bootstrap.contains("guard permitsPhysicalInterfaceDNS() else { return ([], []) }"),
            "the DoQ bootstrap must not resolve a hostname on the physical interface while "
                + "chained — the transports it bootstraps are refused anyway, so the query "
                + "buys nothing and costs the user's DNS going to their ISP"
        )

        // The suppression must sit BEFORE the call, not after it.
        let guardIdx = try XCTUnwrap(
            provider.range(of: "guard self.permitsPhysicalInterfaceDNS() else {")?.lowerBound)
        let callIdx = try XCTUnwrap(
            provider.range(of: "let fallbackResult = self.resolveDeviceDNS(")?.lowerBound)
        XCTAssertLessThan(
            guardIdx, callIdx,
            "the smoke probe's device fallback must be suppressed before it runs — a canary "
                + "that reaches the resolver by leaking reports the tunnel healthy at exactly "
                + "the moment it is not carrying DNS"
        )

        // And it must COMPLETE the probe, not abandon it. Returning without cancelling left
        // the timeout armed, so it fired seconds later and reported a synthetic FAILURE — a
        // deliberate policy decision feeding the health model as though the resolver had
        // misbehaved.
        let suppression = try sourceBlock(
            in: provider,
            startingAt: "guard self.permitsPhysicalInterfaceDNS() else {",
            endingBefore: "let fallbackResult = self.resolveDeviceDNS("
        )
        for required in ["timeout.cancel()", "completeResolverSmokeProbeResult(", "finish()"] {
            XCTAssertTrue(
                suppression.contains(required),
                "a suppressed probe must \(required) — otherwise the armed timeout reports a "
                    + "synthetic failure for a deliberate policy decision"
            )
        }
        XCTAssertTrue(
            suppression.contains(".refusedByEgressPolicy"),
            "the recorded fallback must say DECLINED, not failed or never-ran"
        )
    }

    func testTheSmokeProbeIsNotScheduledWhileChained() throws {
        // Suppressed at SCHEDULING, not merely refused when it runs, and the distinction is not
        // cosmetic. `lastWireSmokeProbeAt` and the `smokeProbeWire` counter are stamped before
        // the resolution is attempted, so a probe that is refused downstream still records a
        // wire query that never reached the wire — and NRG-3a's evidence-age suppression keys
        // on that stamp. The diagnostics would misreport the one thing they measure, and the
        // extension would wake on the probe interval to learn something structurally
        // unavailable while chained.
        //
        // Pinned rather than executable because it lives in the provider, which the package
        // tests cannot construct. What is pinned is the guard's POSITION: before the scheduling
        // view is taken and before anything is stamped.
        let provider = try readPacketTunnelProviderSource()
        let scheduler = try sourceBlock(
            in: provider,
            startingAt: "func scheduleResolverSmokeProbeIfNeeded(reason: String) {",
            endingBefore: "let schedulingView = currentResolverHealthSchedulingView()"
        )
        XCTAssertTrue(
            scheduler.contains("guard permitsPhysicalInterfaceDNS() else {"),
            "a chained session must not schedule a probe of the physical-interface resolver — "
                + "it is not the path in use, so its health is not a question this session has"
        )

        // BEFORE the stamps, or the suppression records the very thing it is preventing.
        //
        // All three indices are taken WITHIN the scheduler function's own block. The
        // previous version took them from the whole provider source, where the first match
        // of the guard string was a DIFFERENT guard (the DoQ bootstrap's), thousands of
        // lines ahead of the stamps — so the comparison held wherever the scheduler guard
        // sat, including after the stamps. An assertion that cannot fail is not an
        // assertion (S8-constraint audit, C3).
        let schedulerFunction = try sourceBlock(
            in: provider,
            startingAt: "func scheduleResolverSmokeProbeIfNeeded(reason: String) {",
            endingBefore: "private func resolverSmokeProbeTimeoutResult("
        )
        let guardIdx = try XCTUnwrap(
            schedulerFunction.range(of: "guard permitsPhysicalInterfaceDNS() else {")?.lowerBound)
        for stamp in ["lastWireSmokeProbeAt = Date()", "EnergyCounters.shared.bump(.smokeProbeWire)"] {
            let stampIdx = try XCTUnwrap(schedulerFunction.range(of: stamp)?.lowerBound)
            XCTAssertLessThan(
                guardIdx, stampIdx,
                "`\(stamp)` runs before the chained-mode suppression, so a suppressed probe "
                    + "still reports as a wire query"
            )
        }
    }

    func testThePhysicalInterfaceDNSSeamConsumesThePolicyDecision() throws {
        // C3: the probes must consume the SAME egress decision as the resolver, not a
        // private copy of it. The copy this replaces —
        // `!currentTunnelDataPathMode().isChainedUpstream` — was one of three restatements
        // of one rule, and a mutation proved the exposure: rewriting the body to
        // `return true` left every test green while the DoQ bootstrap, the probe fallback
        // and the probe scheduler were all disabled at once.
        let provider = try readPacketTunnelProviderSource()
        let body = try sourceBlock(
            in: provider,
            startingAt: "func permitsPhysicalInterfaceDNS() -> Bool {",
            endingBefore: "func resolveDoQBootstrapAddresses("
        )

        XCTAssertTrue(
            body.contains("ChainedResolverEgressPolicy.permitsPhysicalInterfaceHealthProbes("),
            "the seam must consume the egress policy's decision, not restate it"
        )
        XCTAssertTrue(
            body.contains("chainedIsLatched: currentTunnelDataPathMode().isChainedUpstream"),
            "the one input the provider contributes is the LATCHED mode"
        )
        // No literal answer of either polarity: `return true` silently disables every
        // suppression this seam guards, and the behavioural suite cannot see it because the
        // provider is not constructible there.
        XCTAssertFalse(body.contains("true"), "a literal answer defeats the seam")
        XCTAssertFalse(body.contains("false"), "a literal answer defeats the seam")
    }

    func testTheProbeTimersAreNotArmedWhileChained() throws {
        // C3's arming half. The probe HANDLERS are suppressed (above), but the timers that
        // wake them were armed regardless: the periodic probe wakes the extension every
        // 300 s for the whole chained session, and the two recovery armers were inert only
        // as a CONSEQUENCE of refusals scoring `declinedByPolicy` — a health-scoring change
        // away from a self-sustaining wedge loop. Each armer must decide at the seam,
        // before it commits its timer or work item.
        let provider = try readPacketTunnelProviderSource()
        for (armer, end, commit) in [
            ("func startPeriodicResolverSmokeProbe() {",
             "func stopPeriodicResolverSmokeProbe()",
             "timer.resume()"),
            ("func scheduleFallbackRecoverySmokeProbeIfNeeded() {",
             "func cancelFallbackRecoverySmokeProbe()",
             "fallbackRecoverySmokeProbeWorkItem = workItem"),
            ("func scheduleResolverWedgeRecoveryProbeIfNeeded() {",
             "func cancelResolverWedgeRecoveryProbe()",
             "resolverWedgeRecoveryWorkItem = workItem"),
        ] {
            let block = try sourceBlock(in: provider, startingAt: armer, endingBefore: end)
            let guardIdx = try XCTUnwrap(
                block.range(of: "guard permitsPhysicalInterfaceDNS() else { return }")?.lowerBound,
                "\(armer) has no chained-mode guard")
            let commitIdx = try XCTUnwrap(
                block.range(of: commit)?.lowerBound,
                "\(armer) no longer commits via `\(commit)` — re-anchor this pin")
            XCTAssertLessThan(
                guardIdx, commitIdx,
                "\(armer) commits its arm before the chained-mode guard"
            )
        }
    }

    func testTheModeIsLatchedInLoadInitialSharedState() throws {
        let provider = try readPacketTunnelProviderSource()
        let initialStateBlock = try sourceBlock(
            in: provider,
            startingAt: "func loadInitialSharedState() -> Bool",
            endingBefore: "func refreshConfigurationIfNeeded"
        )

        XCTAssertTrue(
            initialStateBlock.contains(
                "latchDataPathMode(for: configuration, configurationIsUnreadable: configurationIsUnreadable)"
            ),
            "The data path must be latched during the start-time shared-state load, which is "
                + "the only point that runs before network settings are applied — and it must "
                + "be told whether the configuration it is reading is real (INV-PERSIST-1)."
        )

        // Ordering inside the bootstrap: the latch reads the configuration this start
        // adopted, so it has to follow the adoption. Both statements are one-liners that
        // could be reordered without any other test noticing.
        let adoptIdx = try XCTUnwrap(
            initialStateBlock.range(of: "setAppConfiguration(configuration)")?.lowerBound
        )
        let latchIdx = try XCTUnwrap(
            initialStateBlock.range(of: "latchDataPathMode(for: configuration,")?.lowerBound
        )
        XCTAssertLessThan(adoptIdx, latchIdx, "The latch must read the configuration this start adopted.")
    }

    func testTheLatchIsResolvedBeforeAnyNetworkSettingsAreBuilt() throws {
        let provider = try readPacketTunnelProviderSource()
        let startBlock = try sourceBlock(
            in: provider,
            startingAt: "override func startTunnel",
            endingBefore: "override func stopTunnel"
        )

        let loadIdx = try XCTUnwrap(startBlock.range(of: "loadInitialSharedState()")?.lowerBound)
        let settingsIdx = try XCTUnwrap(
            startBlock.range(of: "makeTunnelNetworkSettingsForLatchedDataPath()")?.lowerBound
        )
        XCTAssertLessThan(
            loadIdx,
            settingsIdx,
            "Settings built before the latch resolves would claim the previous session's routes."
        )
    }

    func testAllSettingsCallSitesReadTheLatchAndTheOldLiveReadingSeamIsGone() throws {
        let provider = try readPacketTunnelProviderSource()

        // The old seam was named for reading the current configuration. Its absence is part
        // of the guarantee: a reintroduced `…ForCurrentConfiguration` would compile, pass
        // every other test, and quietly restore live routing.
        XCTAssertFalse(
            provider.contains("makeTunnelNetworkSettingsForCurrentConfiguration"),
            "Network settings must never be described as following the current configuration."
        )

        let occurrences = provider.components(
            separatedBy: "makeTunnelNetworkSettingsForLatchedDataPath()"
        ).count - 1
        XCTAssertEqual(
            occurrences,
            4,
            "Expected the latched-settings seam plus exactly its three call sites (initial install, "
                + "startup DNS patch drain and reapplyTunnelNetworkSettings). Another caller needs its own review: it "
                + "would be a new point at which routes can be re-claimed."
        )

        let reapplyBlock = try sourceBlock(
            in: provider,
            startingAt: "func reapplyTunnelNetworkSettings(",
            endingBefore: "private func recordNetworkSettingsReapplyFailure("
        )
        XCTAssertTrue(
            reapplyBlock.contains("makeTunnelNetworkSettingsForLatchedDataPath()"),
            "The flap/IPC reapply runs right after a forced configuration refresh — it is the "
                + "call site a live read would break first."
        )
        XCTAssertFalse(
            reapplyBlock.contains("currentAppConfiguration()"),
            "The reapply must not consult live configuration when choosing what to claim."
        )
    }

    func testTheLatchAccessorIsDualEntry() throws {
        let provider = try readPacketTunnelProviderSource()
        let accessorBlock = try sourceBlock(
            in: provider,
            startingAt: "func currentTunnelDataPathMode() -> TunnelDataPathMode",
            endingBefore: "private static func makeTunnelNetworkSettings("
        )

        // Not a style preference. Some lifecycle readers run off dnsStateQueue while the
        // callers of the reapply are already inside it, so a bare `.sync` deadlocks every
        // reapply — deterministically, on every network flap (INV-QUEUE-1).
        XCTAssertTrue(
            accessorBlock.contains("DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true"),
            "The latch accessor must take the on-queue branch directly."
        )
        XCTAssertTrue(
            accessorBlock.contains("dnsStateQueue.sync"),
            "The latch accessor must hop when called off dnsStateQueue."
        )
    }

    func testChainingIsNotPartOfTheResolverReconnectIdentity() throws {
        let provider = try readPacketTunnelProviderSource()
        let identityBlock = try sourceBlock(
            in: provider,
            startingAt: "static func resolverNetworkIdentity(",
            endingBefore: "func recordCacheHit()"
        )

        // resolverNetworkIdentity decides whether a configuration change is worth a visible
        // reconnect. Adding a chaining field would make a mid-session toggle trigger a
        // settings reapply that the latch then refuses to honour: the user would see a
        // reconnect, the routes would not change, and the logs would disagree with both.
        // Chained transitions go through a full restart instead.
        for field in ["chained", "Chained"] {
            XCTAssertFalse(
                identityBlock.contains(field),
                "Chaining must stay out of the resolver reconnect identity (plan D1)."
            )
        }
    }

    func testFlippingTheBuildFlagCannotShipWithPlaceholderInputs() throws {
        let provider = try readPacketTunnelProviderSource()
        let latchBlock = try sourceBlock(
            in: provider,
            startingAt: "func latchDataPathMode(",
            endingBefore: "func currentTunnelDataPathMode()"
        )
        // All three one-time placeholders were WIRED in S8.11b, and this pin now holds on
        // BOTH sides of the flag flip: the latch block must never hardcode an eligibility
        // input again. A hardcoded `false` for the exclusion marker re-admits a device the
        // jetsam backoff excluded; for readiness it is the term that stops a tunnel
        // claiming a route it cannot serve; for the override it is the preference-clearing
        // lie `deviceStateUnavailable` exists to prevent.
        for placeholder in [
            "experimentalOverrideEnabled: false",
            "hasStartupCrashLoopTripped: false",
            "readyUpstream: nil",
        ] {
            XCTAssertFalse(
                latchBlock.contains(placeholder),
                "`\(placeholder)` reappeared in the latch block; every eligibility input has "
                    + "a real source now."
            )
        }

        // And the wired forms, so a revert cannot pass by renaming the arguments. The two
        // extraction lines are part of the set: with them deleted, `readyUpstream:` still
        // reads a variable — one that is now always nil, so chained never latches and the
        // log blames the upstream. The argument text alone cannot see that.
        for wired in [
            "deviceLocalStateIsUnavailable: deviceStateUnavailable",
            "experimentalOverrideEnabled: deviceSnapshot?.experimentalOverrideEnabled ?? false",
            "hasStartupCrashLoopTripped: deviceSnapshot?.backoffState.hasTripped ?? false",
            // Consumption returns the complete live transactional snapshot. Reconstructing it
            // from the earlier provider read would restore a surrender an overlapping explicit
            // Guard start already cleared.
            //
            // These pins are TEXT, and this file cannot type-check the provider — a stale
            // expectation here passed against a call site that no longer compiled at all,
            // which only CI's app lane caught (the reason that lane is the check of
            // record). Renaming the field means updating both strings AND running the
            // xcodebuild lane locally.
            "deviceSnapshot = consumed",
            "isSurrenderSuppressed: (deviceSnapshot?.isSurrenderSuppressed ?? false)",
            "&& !(deviceSnapshot.map(strictProfileMayRetrySurrender) ?? false)",
            "if case .ready(let ready) = readiness {",
            "readyUpstreamConfiguration = ready.configuration",
            "readyUpstream: readyUpstreamConfiguration",
        ] {
            XCTAssertTrue(
                latchBlock.contains(wired),
                "Expected the wired input `\(wired)` in the latch block."
            )
        }
        XCTAssertFalse(
            latchBlock.contains("surrenderReasonLogValue: snapshot.surrenderReasonLogValue"),
            "the provider rebuilt its decision from a stale pre-recovery surrender")
    }

    func testTheEligibilityReadsAreGatedInTheLatchsOwnOrder() throws {
        let provider = try readPacketTunnelProviderSource()
        let latchBlock = try sourceBlock(
            in: provider,
            startingAt: "func latchDataPathMode(",
            endingBefore: "func currentTunnelDataPathMode()"
        )

        // `resolve` takes plain Bools, so eager evaluation would make every DNS-only start
        // pay a Keychain round-trip and a JSON decode inside a ~50 MB NE process
        // (INV-MEM-1). The gate mirrors the resolve guards that precede the gated terms —
        // and may include the entitlement, which precedes memory and exclusion inside
        // `ineligibilityReason` — but must NOT include the memory floor, whose answer
        // depends on the override the gate is deciding whether to read.
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "if !configurationIsUnreadable,",
                    "configuration.chainedUpstreamEnabled,",
                    "Self.buildSupportsChainedDataPath,",
                    "configuration.hasLavaSecurityPlus",
                    "store.read()",
                    "consumeUncleanTerminationEvidence",
                    "ChainedAvailability.isEligible(",
                    // The surrender term gates the readiness read in resolve's own order
                    // (C4): a surrendered device resolves DNS-only whatever the store
                    // holds, and must not pay the Keychain round-trip to learn something
                    // the latch will not consult.
                    "!snapshot.isSurrenderSuppressed",
                    "evaluateChainedUpstreamReadiness()",
                    "TunnelDataPathLatch.resolve(",
                ], in: latchBlock),
            "The expensive eligibility reads are not gated behind the latch's own cheap "
                + "terms, in the latch's own order."
        )
        let gateEnd = try XCTUnwrap(latchBlock.range(of: "store.read()"))
        let gate = String(latchBlock[..<gateEnd.lowerBound])
        XCTAssertFalse(
            gate.contains("physicalMemory"),
            "The gate consulted the memory floor, whose answer needs the override the gate "
                + "exists to read."
        )
    }

    func testAChainedResolutionMarksTheSessionOrDowngrades() throws {
        let provider = try readPacketTunnelProviderSource()
        let latchBlock = try sourceBlock(
            in: provider,
            startingAt: "func latchDataPathMode(",
            endingBefore: "func currentTunnelDataPathMode()"
        )

        // The lifecycle marker carries a stable build identity and a fresh nonce. A marker write
        // failure must downgrade before the latch publishes chained mode.
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "if resolution.mode.isChainedUpstream {",
                    "let lifecycleID = UUID().uuidString",
                    "markChainedSessionStarted(",
                    "buildIdentity: buildIdentity",
                    "lifecycleID: lifecycleID",
                    "mode: .dnsOnly, refusal: .deviceStateUnavailable)",
                    "installLatchedDataPathMode(",
                ], in: latchBlock),
            "The chained resolution is not marked-or-downgraded ahead of the latch write."
        )
    }

    func testLifecycleEvidenceUsesTheExactInstalledTunnelBinaryIdentity() throws {
        let provider = try readPacketTunnelProviderSource()

        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "static let chainedBuildIdentity: String? = {",
                    "ChainedInstalledBuildIdentity.make(",
                    "executableURL: Bundle.main.executableURL",
                ], in: provider),
            "local builds with the same marketing/build numbers must include the installed "
                + "tunnel executable in their lifecycle identity")

        let latch = try sourceBlock(
            in: provider,
            startingAt: "func latchDataPathMode(",
            endingBefore: "func currentTunnelDataPathMode()")
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "guard let currentBuildIdentity = Self.chainedBuildIdentity else {",
                    "deviceStateUnavailable = true",
                    "consumeUncleanTerminationEvidence(",
                    "currentBuildIdentity: currentBuildIdentity",
                ], in: latch),
            "an unreadable executable identity must fail chained startup closed instead of "
                + "falling back to a colliding version-only identity")
    }

    func testSavedChainingNeverStartsUnfiltered() throws {
        let provider = try readPacketTunnelProviderSource()
        let start = try sourceBlock(
            in: provider,
            startingAt: "override func startTunnel(",
            endingBefore: "override func stopTunnel(")
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "loadInitialSharedState()",
                    "buildChainedRuntimeIfLatched(lifecycleGeneration:",
                    "ChainedStartupContract.decide(",
                    "case .startDegraded(let refusal)",
                    "ChainedStartupFailureMarker.record(",
                ], in: start),
            "a readable saved chaining request must keep the latched DNS-only path filtering when the provider cannot honor it")
        XCTAssertTrue(start.contains("startTunnel-chaining-degraded"))
        XCTAssertFalse(
            start.contains("cleanUpTunnelRuntimeAfterFailedStart(reason: \"chaining-required-failed\")"),
            "the refusal must never fail the start")
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "readPackets(chainedDriver: chainedDriver",
                    "ChainedStartupFailureMarker.clear(",
                    "generation: self.chainedStartupFailureMarkerGeneration",
                    "startTunnel-ready",
                ], in: start),
            "only a fully installed, successful start may clear the refusal marker")
    }

    func testForwardingProofIsPersistedForTheExactLatchedLifecycle() throws {
        let provider = try readPacketTunnelProviderSource()
        let runtime = try sourceBlock(
            in: provider,
            startingAt: "func buildChainedRuntimeIfLatched(lifecycleGeneration: UInt64)",
            endingBefore: "private func downgradeChainedConstruction(")
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "let lifecycleEvidenceID = currentChainedLifecycleEvidenceID()",
                    "let deviceStateLifecycleLockURL = LavaSecAppGroup.chainedLifecycleEvidenceLockURL",
                    "onHealthyForwarding:",
                    "guard let lifecycleEvidenceID, let deviceStateAccessGroup,",
                    "let deviceStateLifecycleLockURL",
                    "lifecycleEvidenceLockURL: deviceStateLifecycleLockURL",
                    "try ChainedBoundedKeychainWork.perform { isStillWanted in",
                    "markChainedSessionProvenHealthy(",
                    "buildIdentity: buildIdentity",
                    "lifecycleID: lifecycleEvidenceID",
                    "isStillWanted: isStillWanted",
                    "chained-session-proven-healthy",
                    "completion(true)",
                    "chained-session-proof-write-failed",
                    "completion(false)",
                ], in: runtime),
            "real forwarding must prove only the build/lifecycle pair that created the marker; "
                + "the Keychain attempt itself must be bounded, fenced against a late write, "
                + "and transient persistence failures must remain retryable")
    }

    func testTheTeardownFunnelSettlesChainedTerminationEvidence() throws {
        let provider = try readPacketTunnelProviderSource()

        // Both teardown shapes reach one funnel, and the difference between them is the
        // difference between a phantom strike and a lost one: a failed start clears the
        // marker without resetting the streak (it is not evidence the device coped), and a
        // clean stop does both.
        XCTAssertTrue(
            provider.contains(
                "cleanUpTunnelRuntimeAfterStop(reason: \"stopTunnel\", endedByCleanStop: true)"),
            "stopTunnel does not declare itself a clean stop."
        )
        XCTAssertTrue(
            provider.contains(
                "cleanUpTunnelRuntimeAfterStop(reason: reason, endedByCleanStop: false, completion: completion)"),
            "The failed-start path does not declare itself an unclean one."
        )

        let funnel = try sourceBlock(
            in: provider,
            startingAt: "private func cleanUpTunnelRuntimeAfterStop(",
            endingBefore: "static func errorDebugDetails("
        )
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "if self.latchedDataPathMode.isChainedUpstream,",
                    "let lifecycleEvidenceID = self.latchedChainedLifecycleEvidenceID",
                    "finalizeChainedTerminationEvidence(",
                    "owningLifecycleID: lifecycleEvidenceID",
                    "endedByCleanStop: endedByCleanStop && self.tunnelStartupDidComplete)",
                    "drainAndPruneDNSEventLog",
                    "completion()",
                ], in: funnel),
            "The termination evidence does not settle inside the funnel's dnsStateQueue "
                + "block ahead of the stop completion, gated on a startup that actually "
                + "completed."
        )
        // The flag's lifecycle: set only in the post-settings success path, reset with the
        // per-session state, so a stopTunnel that cancels a pending start cannot reset the
        // streak — a cancelled start is not evidence the device coped (Codex, PR #499).
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "self?.tunnelStartLatencyOperationID = operationID",
                    "self.finishDNSPatchStartupSettings(",
                    "self.tunnelStartupDidComplete = true",
                    "completion(nil)",
                ], in: provider),
            "Startup completion is not recorded in the post-settings success path."
        )
        XCTAssertTrue(
            provider.contains("self.tunnelStartupDidComplete = false"),
            "The startup-completed flag is never reset, so the previous session's completed "
                + "startup vouches for the next session's cancelled one."
        )
        // ONE write settles both halves; the split two-write shape is what let a kill or
        // a failed save leave a cleared marker whose streak reset never landed
        // (Codex, PR #499).
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "func finalizeChainedTerminationEvidence(",
                    "owningLifecycleID: String, endedByCleanStop: Bool",
                    "settleTermination(",
                    "owningLifecycleID: owningLifecycleID",
                    "sessionRanAndStoppedCleanly: endedByCleanStop)",
                ], in: funnel),
            "The settlement is not the store's single-write transition."
        )
        XCTAssertFalse(
            funnel.contains("clearChainedSessionMarker"),
            "A separate marker clear reappeared in the funnel — the split-write shape."
        )
    }

    func testAStandingChainedFailureMarkerNeverRefusesTheStart() throws {
        let provider = try readPacketTunnelProviderSource()
        let start = try sourceBlock(
            in: provider,
            startingAt: "override func startTunnel(",
            endingBefore: "override func stopTunnel(")
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "ChainedStartupFailureMarker.state(",
                    "if let reason = startupFailureMarkerState.reason",
                    "startTunnel-chaining-marker-standing",
                    "let lifecycleGeneration = beginTunnelLifecycle",
                ], in: start),
            "a standing marker is disclosed and the latched DNS-only path starts; it must not refuse the relaunch")
        XCTAssertFalse(
            start.contains("startTunnel-chaining-marker-gated"),
            "the marker gate was removed: refusing the start left the device unfiltered (2026-09-17)")
        XCTAssertTrue(
            start.contains("generation: self.chainedStartupFailureMarkerGeneration"),
            "provider marker writes must be fenced to the revision captured at start")
        XCTAssertTrue(
            start.contains("storageURL: markerURL"),
            "provider marker reads and writes must use the durable App Group file")
        // 🔴 SCOPE. Only a CONFIRMED reason is terminal. This gate runs before
        // `loadInitialSharedState`, so the provider cannot yet know whether chaining is even
        // enabled — failing the start on an absent or momentarily unreadable marker took
        // DNS-only users, who never turned chaining on, off protection entirely, and bought
        // chained users nothing: `TunnelDataPathLatch.resolve` plus `ChainedStartupContract`
        // already hold them closed without this file (PR #636 review).
        XCTAssertFalse(
            start.contains("The saved VPN chaining state could not be located"),
            "an unresolvable App Group marker must not fail the start for users who never chained")
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "startTunnel-chaining-marker-read-failed",
                    "startTunnel-chaining-marker-url-missing",
                    "if let reason = startupFailureMarkerState.reason",
                ], in: start),
            "an unreadable or absent marker must fall through to the confirmed-reason gate "
                + "rather than completing the start with an error")
        // …and the explicit-retry CONSUME is fatal only when superseded. `beginExplicitRetry` sets
        // the handoff bit on every explicit Guard on / reconnect / Live Activity restart — it runs
        // in the app and cannot know whether chaining is enabled — so failing the start when the
        // chained Keychain is unreachable would take DNS-only users off protection on the ordinary
        // happy path, and unsigned/local builds every time (`chainedDeviceEligibilityStore()` is
        // nil without a shared access group). A chained user still fails closed by filtering: the
        // latch refuses to chain and `ChainedStartupContract` starts DNS-only under the refusal
        // (Codex, PR #636; fail-closed rework 2026-09-18).
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "catch is ChainedExplicitRetrySuperseded {",
                    "startTunnel-chaining-retry-superseded",
                    "startTunnel-chaining-retry-consume-unavailable",
                    "startupFailureMarkerState = readState",
                    "if let reason = startupFailureMarkerState.reason",
                ], in: start),
            "only a superseded retry may fail the start; an unreachable chained Keychain must "
                + "carry the pre-consume snapshot forward instead")
        XCTAssertTrue(
            start.contains("lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL"),
            "marker reads and writes must use the independent marker lock")
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "consumeExplicitChainedRetryIfRequested(",
                    "let lifecycleGeneration = beginTunnelLifecycle",
                    "let shouldBeginTransientBootstrapDNSWaitAfterNetworkSettings = loadInitialSharedState()",
                ], in: start),
            "an explicit retry must clear the persisted chained suppression before the provider latches its data path")

        // 🔴 The stale-provider fence has TWO gaps, and both must fail closed. The CAS can be lost
        // while `prepareForExplicitGuardStart` sits in the Keychain; and because the re-read takes
        // the marker lock again — a second transaction — a newer retry can advance the revision
        // between winning the CAS and reading it back. Adopting either newer generation hands a
        // retired provider ownership of an attempt it never consumed (Codex, PR #636).
        let consume = try sourceBlock(
            in: provider,
            startingAt: "private func consumeExplicitChainedRetryIfRequested(",
            endingBefore: "/// Evaluates upstream readiness against the shared credential store")
        XCTAssertTrue(
            consume.contains("guard consumed else {"),
            "a lost compare-and-set must be a superseded start")
        XCTAssertTrue(
            consume.contains("guard reread.generation == markerState.generation else {"),
            "the post-CAS re-read must not adopt a revision this start did not consume")
        XCTAssertEqual(
            sourceOccurrenceCount(of: "throw ChainedExplicitRetrySuperseded()", in: consume),
            2,
            "both fence gaps — lost CAS and post-CAS advance — must fail this start closed")
    }

    func testTheInExtensionCompileIsSuppressedWhileChained() throws {
        let provider = try readPacketTunnelProviderSource()
        let loadBlock = try sourceBlock(
            in: provider,
            startingAt: "func loadCompiledSnapshot(",
            endingBefore: "func retainedTunnelCompiledArtifactStoreIfPresent()"
        )

        // Plan D3 / INV-MEM-1. The streaming compile peaks ~32 MiB and the engine is resident
        // for the whole chained session, inside a ~50 MB ceiling.
        XCTAssertTrue(
            loadBlock.contains("if currentTunnelDataPathMode().isChainedUpstream {"),
            "The in-extension compile must be suppressed while the chained upstream is co-resident."
        )
        XCTAssertTrue(
            loadBlock.contains("loadSnapshot-compile-skipped-chained"),
            "A suppressed compile must be visible in the device log; a silent degrade is "
                + "indistinguishable from a snapshot that simply never loaded."
        )

        // The degrade target is what keeps INV-DNS-1 intact: last-known-good first, block-all
        // only if there is none. Returning nil, or an empty pass-through, would fail OPEN.
        let suppression = try sourceBlock(
            in: loadBlock,
            startingAt: "if currentTunnelDataPathMode().isChainedUpstream {",
            endingBefore: "        do {"
        )
        XCTAssertTrue(
            suppression.contains("return serveLastKnownGoodOrFailClosed()"),
            "A suppressed compile must degrade through the last-known-good/fail-closed ladder."
        )

        // Ordering: a superseded reload must bail before this point rather than spend a
        // multi-MB last-known-good decode it would discard.
        let staleIdx = try XCTUnwrap(
            loadBlock.range(of: "loadSnapshot-compile-skipped-stale")?.lowerBound
        )
        let chainedIdx = try XCTUnwrap(
            loadBlock.range(of: "if currentTunnelDataPathMode().isChainedUpstream {")?.lowerBound
        )
        XCTAssertLessThan(staleIdx, chainedIdx, "The doomed-reload guard must run before the chained degrade.")
    }

    func testTheLatchIsWrittenOnDNSStateQueue() throws {
        let provider = try readPacketTunnelProviderSource()
        let latchBlock = try sourceBlock(
            in: provider,
            startingAt: "func latchDataPathMode(",
            endingBefore: "func currentTunnelDataPathMode()"
        )

        XCTAssertTrue(
            latchBlock.contains("installLatchedDataPathMode(\n")
                && latchBlock.contains("resolution.mode, refusal: resolution.refusal,"),
            "The latch resolve must publish through the one installer, which writes the mode, "
                + "refusal, latched fallback and the epoch together on dnsStateQueue — a torn "
                + "write would leave them disagreeing (INV-QUEUE-1); the installer's own shape is "
                + "pinned by testTheLatchHasExactlyOneWriterAndItBumpsTheEpoch."
        )
    }

    /// The rung's plan is narrowed to the ADMITTED addresses, and absent when there are none.
    ///
    /// `resolvePlainDNS` returns on the first address that yields any packet, SERVFAIL included.
    /// A fallback preset that partially overlaps the conf's own `DNS =` would therefore re-ask the
    /// resolver that just declined the name and stop there, never reaching the address the panel
    /// reports as admitted — the rung asking the failed resolver again, which is precisely what it
    /// exists to avoid (Codex, PR #590).
    ///
    /// The admitted set is derived through the SAME `fallbackOutcomes` call the settings publisher
    /// uses, so the wire and the surface cannot disagree about which addresses count.
    func testTheTierOnePlanIsNarrowedToTheAdmittedAddresses() throws {
        let provider = try readPacketTunnelProviderSource()
        let plan = try sourceBlock(
            in: provider,
            startingAt: "func currentTierOneFallbackPlan() -> DNSResolverRuntimePlan? {",
            endingBefore: "func setAppConfiguration")
        XCTAssertTrue(
            plan.contains("restrictingPlainAddresses(to: admitted)"),
            "the rung must ask only what the panel calls admitted")
        XCTAssertTrue(
            plan.contains("if resolvesOverPlainDNS, admitted.isEmpty { return nil }"),
            "nothing admitted means no second opinion exists — so no rung")
        // AND THE GATE IS PLAIN-ONLY. An encrypted selection has no IPv4 literal to admit, so
        // running the emptiness check over it would delete the rung for every DoH/DoT/DoQ user —
        // which is the capability the plan's S4 exists to make reachable.
        // `admittedPlan`, not `plan`: since PR #603 the DEVICE FALLBACK leg is gated for every
        // selection, encrypted included, and only the PLAIN-address narrowing below is
        // transport-conditional. Returning the raw `plan` here would hand an encrypted selection
        // its unadmitted device capture, which is the leak PR #603 closed.
        XCTAssertTrue(
            plan.contains("guard resolvesOverPlainDNS else { return admittedPlan }"),
            "an encrypted plan keeps its plain addresses, but not an ungated device leg")
        // ONE DERIVATION, shared with the publisher. A second copy of "which addresses count" is
        // the drift that put a routing verdict in the provider once already (Kilo, PR #575).
        XCTAssertTrue(plan.contains("admittedTierOneAddressesOnQueue(upstream:"))
        let admitted = try sourceBlock(
            in: provider,
            startingAt: "private func admittedTierOneAddressesOnQueue(",
            endingBefore: "func setAppConfiguration")
        XCTAssertTrue(
            admitted.contains("Self.tierOneOutcomes("),
            "the admitted set must come from the one shared derivation")
        XCTAssertTrue(
            admitted.contains("dispatchPrecondition(condition: .onQueue(dnsStateQueue))"),
            "INV-QUEUE-1: the caller establishes the confinement this reads latched state under")
    }

    /// The orchestrator's T1 plan comes from the LATCH, not from a live configuration read.
    ///
    /// Nothing in the package suite can see which seam the provider hands the orchestrator, and
    /// the failure it guards against compiles perfectly: passing `currentAppConfiguration()`
    /// here instead would make a mid-session Alternative DNS change take effect immediately, so
    /// the settings panel's counters would describe a resolver the session had already stopped
    /// using — the same class of defect the latch exists to prevent (Codex, PR #575 P1).
    func testTheOrchestratorTakesTheTierOnePlanFromTheLatch() throws {
        let provider = try readPacketTunnelProviderSource()
        let construction = try Self.orchestratorConstructionBlock(in: provider)
        XCTAssertTrue(
            construction.contains("tierOneFallbackPlan:"),
            "the orchestrator must be given a T1 decision at construction, like the "
                + "allowance and the route"
        )
        XCTAssertTrue(
            construction.contains("currentTierOneFallbackPlan()"),
            "the rung's resolver must come from the latched alternative selection"
        )
    }

    /// A resolver change RELATCHES the rung in place, instead of telling the user to restart.
    ///
    /// The reload handler has always reapplied network settings — the visible blink — in both
    /// modes. In DNS-only that is enough: the resolver is read live from the configuration the
    /// handler just refreshed. A chained session reads the rung from
    /// `latchedChainedTierOneResolverConfiguration`, installed once at `startTunnel` and updated
    /// by nothing here — so it blinked and came back on the SAME resolver, and the panel said
    /// "Restart protection to apply". That sentence was accurate, which is why the fix is to
    /// remove the state rather than reword the copy.
    ///
    /// THREE THINGS MUST HAPPEN TOGETHER, and each one alone is a defect:
    ///
    /// - **the latch is replaced**, or nothing changes;
    /// - **the epoch is bumped**, or a rung admitted against the OLD resolver completes afterwards
    ///   and is credited to the new one — one resolver condemned for another's failure, the
    ///   attribution defect the per-session latch exists to prevent (Codex, PR #592);
    /// - **the outcomes are republished**, or `ChainedFallbackFreshness` keeps comparing against a
    ///   stale identity and reports `.awaitingRestart` about a change already applied.
    ///
    /// The nil-ness comparison is the `chainedTierOneFallbackEnabled` toggle, which moves without
    /// the identity changing — an identity-only test would miss it entirely.
    func testAResolverChangeRelatchesTheRungInPlace() throws {
        let provider = try readPacketTunnelProviderSource()
        let reload = try sourceBlock(
            in: provider,
            startingAt: "case LavaSecAppGroup.reloadConfigurationMessage:",
            endingBefore: "case LavaSecAppGroup.clearDiagnosticsMessage")

        XCTAssertTrue(
            reload.contains("self.latchedChainedTierOneResolverConfiguration = updated"),
            "the rung's latch must be replaced, or the session keeps the old resolver")
        XCTAssertTrue(
            reload.contains("self.tunnelDataPathLatchEpoch &+= 1"),
            "an in-flight rung against the old resolver must not be credited to the new one")
        XCTAssertTrue(
            reload.contains("self.publishChainedFallbackOutcomesOnQueue(configuration: upstream)"),
            "the panel compares the published identity; without this it still says restart")
        XCTAssertTrue(
            reload.contains("(previous == nil) != (updated == nil)"),
            "the toggle changes nil-ness without changing identity — both halves are compared")
        // THE POLICY IDENTITY, NOT THE RESOLVER IDENTITY. `chainedTierOneResolverIdentity` names
        // only the resolver the rung asks FIRST; since PR #596 the rung runs the full ladder, so
        // `fallbackToDeviceDNS`, `usesEncryptedDeviceDNSFallback` and `fallbackResolverPreset`
        // steer it too and move without touching that identity. Keyed on the resolver alone,
        // turning device fallback off left a running session still asking the device resolver on
        // T1 failure until restart (Codex P1, PR #599). Asserted as a NEGATIVE too, because
        // the two spellings differ by one word and the weaker one compiles.
        XCTAssertTrue(
            reload.contains("previous?.chainedTierOneRungPolicyIdentity"),
            "the whole ladder policy decides the relatch, not just which resolver is asked first")
        XCTAssertFalse(
            reload.contains("previous?.chainedTierOneResolverIdentity"),
            "the resolver-only identity misses every fallback-policy change")

        // ORDER. The republish must follow the latch it describes, and the epoch bump must land
        // before it too: publishing first would name the outgoing resolver, and bumping after the
        // publish would leave a window where evidence is admitted against a latch already gone.
        let latchIndex = try XCTUnwrap(
            reload.range(of: "latchedChainedTierOneResolverConfiguration = updated")?.lowerBound)
        let epochIndex = try XCTUnwrap(
            reload.range(of: "tunnelDataPathLatchEpoch &+= 1")?.lowerBound)
        let publishIndex = try XCTUnwrap(
            reload.range(of: "publishChainedFallbackOutcomesOnQueue")?.lowerBound)
        XCTAssertLessThan(latchIndex, epochIndex)
        XCTAssertLessThan(epochIndex, publishIndex)

        // ONLY WHILE CHAINED. Every T1 consumer reads the latch only in that mode, and a
        // DNS-only session has no upstream to publish against.
        XCTAssertTrue(
            reload.contains("if case .chainedUpstream(let upstream) = self.latchedDataPathMode {"),
            "the relatch is scoped to a chained session")
    }

    /// The T1 plan is built from the LATCHED ALTERNATIVE selection, and forbids device DNS.
    ///
    /// Three properties the compiler cannot check, each of which reintroduces a distinct defect
    /// if dropped: reading `latchedChainedTierOneResolverConfiguration` (rather than a live
    /// configuration read) is what keeps the rung on the resolver this session started with;
    /// `ignoresDeviceDNSFallbackMode: true` is what stops a device-wide fallback episode from
    /// rewriting the rung's plan into one that asks the network's own resolver (`LAV-87`); and
    /// nil-on-absent is what makes a Device-DNS selection produce no rung at all (Codex, PR #590).
    func testTheTierOnePlanComesFromTheLatchedAlternativeSelection() throws {
        let provider = try readPacketTunnelProviderSource()
        let plan = try sourceBlock(
            in: provider,
            startingAt: "func currentTierOneFallbackPlan() -> DNSResolverRuntimePlan? {",
            endingBefore: "func setAppConfiguration"
        )
        XCTAssertTrue(
            plan.contains("latchedChainedTierOneResolverConfiguration"),
            "the rung resolves the LATCHED selection, not a live configuration read"
        )
        XCTAssertTrue(
            plan.contains("ignoresDeviceDNSFallbackMode: true"),
            "a device-DNS fallback episode must not rewrite the rung into a device-DNS plan"
        )
        // FOUR VALUES since PR #603: the admitted DEVICE-FALLBACK set is derived inside the same
        // critical section as the capture it gates, for the same reason the capture itself is
        // returned rather than re-read — a second live read would gate one address list and hand
        // the plan another.
        XCTAssertTrue(
            plan.contains(
                "guard let (configuration, admitted, deviceResolvers, admittedDeviceFallback) = latched"),
            "no latched alternative means no rung — the closed direction"
        )
        XCTAssertTrue(
            plan.contains("dnsStateQueue.sync(execute: derive)")
                && plan.contains("DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey)"),
            "INV-QUEUE-1: dual-entry, because resolver work may already hold dnsStateQueue"
        )
    }

    /// An ENCRYPTED T1 selection is not narrowed to plain addresses it does not have.
    ///
    /// The narrowing exists so a plain rung cannot re-ask the conf's own resolver. A DoH/DoT/DoQ
    /// plan has no plain addresses to narrow, and the admitted set is empty for it by
    /// construction — so running either the emptiness guard or the narrowing over it would delete
    /// the rung for every encrypted user, which is exactly the capability S4 makes reachable.
    func testAnEncryptedTierOneSelectionIsNotNarrowedToPlainAddresses() throws {
        let provider = try readPacketTunnelProviderSource()
        let plan = try sourceBlock(
            in: provider,
            startingAt: "func currentTierOneFallbackPlan() -> DNSResolverRuntimePlan? {",
            endingBefore: "private func admittedTierOneAddressesOnQueue(")
        XCTAssertTrue(
            plan.contains(
                "let resolvesOverPlainDNS = transport == .plainDNS || transport == .deviceDNS"),
            "the transport decides whether the address gate applies at all, and DEVICE DNS is "
                + "address-routed too since PR #592 — `make` puts the live capture straight into "
                + "`plainAddresses`, so both gate questions are askable of it")
        // The early return now hands back `admittedPlan`, not the raw `plan`: PR #603 gates the
        // DEVICE FALLBACK leg for EVERY selection, and an encrypted selection has one too. Only
        // the plain-address narrowing below is transport-conditional.
        let guardRange = try XCTUnwrap(
            plan.range(of: "guard resolvesOverPlainDNS else { return admittedPlan }"))
        let narrowRange = try XCTUnwrap(plan.range(of: "restrictingPlainAddresses(to: admitted)"))
        XCTAssertLessThan(
            guardRange.lowerBound, narrowRange.lowerBound,
            "the encrypted plan must return before the plain narrowing, not through it")
        // AND THE DEVICE LEG IS GATED BEFORE THAT RETURN, or the encrypted path keeps the raw
        // capture — the case PR #603 exists for (Codex P2, PR #596).
        let deviceGate = try XCTUnwrap(
            plan.range(of: "restrictingDeviceDNSFallbackAddresses(to: admittedDeviceFallback)"))
        XCTAssertLessThan(
            deviceGate.lowerBound, guardRange.lowerBound,
            "an encrypted selection returns early, so its device leg must be gated above that")
    }

    /// The T1 resolver is latched from the user's ONE selection, never from a second setting.
    ///
    /// A second picker existed (`chainedFallbackResolverPresetID`), restricted to plain IPv4
    /// because the rung rode the tunnel. The rung egresses on the physical interface, so all four
    /// transports work and the second picker is deleted (the plan's S4). Only a pin can see which
    /// configuration the provider latches.
    func testTheTierOneResolverIsLatchedFromTheUsersOwnSelection() throws {
        let provider = try readPacketTunnelProviderSource()
        XCTAssertTrue(
            provider.contains(
                "chainedTierOneResolverConfiguration: resolution.mode.isChainedUpstream"),
            "the latch takes the one resolver selection, gated on chained mode")
        XCTAssertFalse(
            provider.contains("chainedFallbackResolverPresetID"),
            "the second picker is gone; a reference to it is the debt coming back")
    }

    /// The device executor carries the RUNG's egress interface rather than assuming one.
    ///
    /// A device resolver is a LAN address. The socket layer pins to the tunnel whenever chained
    /// THE PLAIN/DEVICE LADDER REFUSES AT THE WIRE SEAM WHEN THE LATCH MOVED, per attempt.
    ///
    /// `admittedAtEpoch` names the tunnel LIFECYCLE, and a relatch does not move it — it replaces
    /// the latched configuration inside a living session. So every `workIsAdmitted` guard passed
    /// straight through a resolver or fallback-policy change that had already taken effect
    /// everywhere else, and a multi-address plan spent its whole walk under the replaced policy:
    /// one wire attempt per remaining address, to the device resolver the user had just switched
    /// off (Codex P2, PR #608 → PR #610).
    ///
    /// PINNED AT THE SEAM, not at the ladder. `resolveUDP` and `resolveOverTCP` are the two
    /// functions every plain and device wire attempt passes through, which is why the lifecycle
    /// guard lives there too — one check below every loop covers each attempt however long the
    /// previous address blocked. A check at the top of `resolvePlainDNS` would fence the first
    /// address and none of the rest.
    ///
    /// AND THE REFUSAL IS ITS OWN OUTCOME. `.refusedAfterLifecycleEnded` would have been reused
    /// with no behaviour change, and it would have been a lie: the session is alive, the latch is
    /// what moved. A field capture reading "lifecycle-ended" sends whoever holds it looking for a
    /// tunnel restart that never happened.
    func testThePlainLadderRefusesEveryAddressAfterARelatch() throws {
        let provider = try readPacketTunnelProviderSource()

        for seam in ["func resolveUDP(", "func resolveOverTCP("] {
            let body = try sourceBlock(in: provider, startingAt: seam, endingBefore: "\n    }\n")
            XCTAssertTrue(
                body.contains("guard resolverLatchIsCurrent(admittedAtLatchEpoch) else {"),
                "\(seam) is a wire seam: it must refuse a rung whose data path was replaced")
            XCTAssertTrue(
                body.contains("outcome: .refusedAfterLatchReplaced"),
                "\(seam) must say WHY honestly — the lifecycle did not end")
        }

        // THREADED, not defaulted away. Both seams take the token with a `nil` default so every
        // DNS-only caller is unaffected; the ladder has to actually pass it or the default
        // silently disables the fence for the one caller that needs it.
        // ENDS AT `shouldAttemptTCPFallback`, which is the next declaration in the FILE.
        // `resolveOverTCP` reads like the natural boundary and is not one: it is declared far
        // ABOVE this function, so an end marker naming it can never be found after the start and
        // the block fails as "end marker not found" rather than as the behaviour under test.
        let ladder = try sourceBlock(
            in: provider,
            startingAt: "func resolvePlainDNS(",
            endingBefore: "private func shouldAttemptTCPFallback(")
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "admittedAtLatchEpoch: admittedAtLatchEpoch", in: ladder), 3,
            "the UDP rung and BOTH TCP rungs receive the token")

        // AND THE LADDER STOPS ON IT, via the category rather than an equality test — there are
        // four such tests here and an equality at each is four places a third terminal refusal has
        // to find.
        XCTAssertTrue(
            ladder.contains("if udpResult.outcome.endsTheResolutionLadder {"),
            "the UDP rung ends the walk on a terminal refusal")
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "if tcpResult.outcome.endsTheResolutionLadder {", in: ladder), 2,
            "and so do both TCP rungs")
        XCTAssertFalse(
            ladder.contains("== .refusedAfterLifecycleEnded"),
            "no equality test survives: it would walk on past a replaced data path")

        // THE DEVICE LEG IS THE PRIVACY-CRITICAL HALF and reaches the same seam through
        // `resolvePlainDNS`, so it must forward the token rather than drop it on the way.
        let device = try sourceBlock(
            in: provider,
            startingAt: "func resolveDeviceDNS(",
            endingBefore: "func resolvePlainDNS(")
        XCTAssertTrue(
            device.contains("admittedAtLatchEpoch: admittedAtLatchEpoch"),
            "the device ladder is the one that reaches an ISP resolver — it must carry the token")
    }

    /// is latched unless told otherwise, so a device-DNS rung that does not ask for `.physical`
    /// sends its query through the peer — which will not route a LAN address, making the rung a
    /// guaranteed timeout instead of a fallback. The orchestrator supplies the interface; only a
    /// pin can see that the provider threads it to the socket rather than defaulting.
    func testTheDeviceExecutorCarriesTheRungsEgressInterface() throws {
        let provider = try readPacketTunnelProviderSource()
        let executor = try sourceBlock(
            in: provider,
            // ANCHORED ON THE NAME, not the full parameter list. Pinning every parameter made this
            // block unfindable the moment the closure gained the latch token, and a missing start
            // marker fails as "start marker not found" rather than as the behaviour under test.
            startingAt: "resolveDevice: { [weak self] query, addresses,",
            endingBefore: "func resolvePlainDNS(")
        XCTAssertTrue(
            executor.contains("egressInterface: egressInterface"),
            "the closure must hand the caller's interface down, not drop it")
        let device = try sourceBlock(
            in: provider,
            startingAt: "func resolveDeviceDNS(",
            endingBefore: "func resolvePlainDNS(")
        XCTAssertTrue(
            device.contains("egressInterface: egressInterface"),
            "and resolveDeviceDNS must pass it to the socket, not default it")
        XCTAssertFalse(
            device.contains("egressInterface: .providerDefault"),
            "defaulting here is exactly the bug: the rung's datagram would ride the tunnel")
    }

    /// The SMOKE PROBE's device fallback keeps `.providerDefault`, and says so.
    ///
    /// `resolveDeviceDNS` has two callers and they want opposite answers: the T1 rung must
    /// escape the tunnel (`.physical`), while the probe belongs to the DNS-only health ladder and
    /// has always followed the provider's own mode. Making the parameter required rather than
    /// defaulted is what forces each caller to say which it is; this pin is the other half, so a
    /// future edit cannot quietly promote the probe onto the physical interface — which would
    /// egress device DNS beside a running tunnel, the leak `LAV-87` names.
    func testTheSmokeProbesDeviceFallbackStaysOnTheProviderDefault() throws {
        let provider = try readPacketTunnelProviderSource()
        let probeCall = try sourceBlock(
            in: provider,
            startingAt: "let fallbackResult = self.resolveDeviceDNS(",
            endingBefore: "let fallbackSucceeded = DNSResolverSmokeProbe.acceptsResolutionResponse(")
        XCTAssertTrue(
            probeCall.contains("egressInterface: .providerDefault"),
            "the probe is not the rung; it follows the provider's own mode")
        XCTAssertFalse(
            probeCall.contains("egressInterface: .physical"),
            "a probe on the physical interface is device DNS egressing beside a live tunnel")
    }

    /// The rung's plan derivation PUBLISHES, in the same critical section, so the panel names the
    /// set the rung is about to ask rather than the one T0 started with.
    ///
    /// The per-resolution publish runs from the route derive, which is BEFORE the synchronous
    /// T0 attempt; this plan is built AFTER it. For every selection but one that gap is
    /// harmless — the endpoints are fixed at latch. A device-DNS selection reads the live
    /// capture, and `refreshDeviceDNSResolverAddressesOnDNSQueue` can land inside T0's window,
    /// so the rung would query the new resolver while the published set still named the old one,
    /// and `recordChainedTierOneRungEvidence` does not republish (Codex P2, PR #592).
    ///
    /// Only a pin can see this: the fix is an ORDERING between two functions that no type
    /// signature relates, and a compiler is happy either way.
    func testTheRungPlanPublishesInTheSameCriticalSection() throws {
        let provider = try readPacketTunnelProviderSource()
        let plan = try sourceBlock(
            in: provider,
            startingAt: "func currentTierOneFallbackPlan() -> DNSResolverRuntimePlan? {",
            endingBefore: "private func admittedTierOneAddressesOnQueue(")
        XCTAssertTrue(
            plan.contains("self.publishChainedFallbackOutcomesOnQueue(configuration: upstream)"),
            "the plan derivation must publish, or the rung's evidence lands against the set "
                + "T0 started with")
        // INSIDE `derive`, and BEFORE the admitted derivation. Both halves matter: outside the
        // closure it would not share the critical section with the capture read, and after the
        // admitted line it would publish a set derived from a read it cannot prove came first.
        XCTAssertTrue(
            plan.containsInOrder([
                "case .chainedUpstream(let upstream) = self.latchedDataPathMode",
                "self.publishChainedFallbackOutcomesOnQueue(configuration: upstream)",
                "self.admittedTierOneAddressesOnQueue(upstream: upstream)",
                // No trailing paren: the capture is BOUND TO A LOCAL since PR #603, because two
                // consumers need the same read — the plan and the device-leg admission. The pin is
                // about the ORDER of the three reads, not about the capture being the last thing
                // in a tuple literal.
                "self.currentDeviceDNSResolverAddresses()"
            ]),
            "publish inside the derive closure, ahead of the admitted set and the capture it "
                + "must agree with")
        // THE CAPTURE IS CARRIED OUT OF THE CLOSURE, not read again after it. The first cut
        // published here and then let `make` take its own `currentDeviceDNSResolverAddresses()`
        // once the closure had returned — a second live read outside the very critical section
        // the comment above it claimed. A refresh in that gap gave the plan different addresses
        // from the published set, and a complete change emptied `restrictingPlainAddresses` into
        // nil: T1 silently skipped for a query T0 had already declined (Codex P2, #592).
        XCTAssertTrue(
            plan.contains("deviceDNSAddresses: deviceResolvers"),
            "the plan must use the carried capture, not a fresh read")
        XCTAssertEqual(
            sourceOccurrenceCount(of: "self.currentDeviceDNSResolverAddresses()", in: plan), 1,
            "exactly one capture read in this function — a second is the race itself")
    }

    /// A DEVICE-DNS selection publishes the tunnel's live capture as its LATCHED list, not [].
    ///
    /// `chainedTierOneResolverEndpoints` is empty for this transport by construction — a
    /// device-DNS selection names no addresses in the configuration. Reading it directly here
    /// would publish a snapshot whose outcomes enumerate real resolvers beside a "latched" set
    /// naming none of them: the panel's `.pendingDisable` copy would have nothing to name, and
    /// the bug report's redaction fold seeds from this list, so the captured addresses would
    /// reach a report unfolded. Both callers go through the one helper instead (PR #592).
    func testTheLatchedTierOneListIsTheDeviceCaptureForADeviceSelection() throws {
        let provider = try readPacketTunnelProviderSource()
        let helper = try sourceBlock(
            in: provider,
            startingAt: "static func tierOneEndpoints(",
            endingBefore: "func setAppConfiguration")
        XCTAssertTrue(
            helper.contains("latched.resolverPreset.transport == .deviceDNS"),
            "the transport is what selects the capture over the configuration's own endpoints")
        XCTAssertTrue(
            helper.contains("? deviceResolvers : latched.chainedTierOneResolverEndpoints"),
            "device DNS reads the live capture; every other transport reads the preset")

        let publish = try sourceBlock(
            in: provider,
            startingAt: "let latch = latchedChainedTierOneResolverConfiguration",
            endingBefore: "markHealthCountersUpdated()")
        XCTAssertTrue(
            publish.contains("Self.tierOneEndpoints(latched: $0, deviceResolvers: deviceResolvers)"),
            "the published latched list is the shared derivation, not a second read")
        XCTAssertFalse(
            publish.contains("latch?.chainedTierOneResolverEndpoints ?? []"),
            "reading the preset directly here is the drift this helper exists to prevent")
    }

    // MARK: - The latched rotation identity (task #21)

    /// STOP CLEARS IT, before the final forced persist.
    ///
    /// The mirror is its only other writer and no focus tick runs after stop, so without this the
    /// stopped session's rotation is what gets persisted — and the freshness policy keys on the
    /// generation alone, so changing or removing the stored configuration afterwards made the
    /// panel demand a restart for a session that no longer exists (Codex P2, PR #613).
    func testStopClearsTheRunningRotationBeforePersisting() throws {
        let source = try readPacketTunnelProviderSource()
        let cleanup = try sourceBlock(
            in: source,
            startingAt: "self.health.isChainedUpstreamActive = false",
            endingBefore: "self.persistDiagnosticsIfNeeded(force: true)")
        XCTAssertTrue(
            cleanup.contains("self.health.runningChainedUpstreamGeneration = 0"),
            "a stopped session must not leave its rotation in the persisted snapshot")
        // ORDER MATTERS: the clear has to happen before the forced flush, or the flush writes the
        // value the clear was meant to remove.
        let clearRange = try XCTUnwrap(
            cleanup.range(of: "self.health.runningChainedUpstreamGeneration = 0"))
        let persistRange = try XCTUnwrap(
            cleanup.range(of: "self.persistHealthIfNeeded(force: true)"))
        XCTAssertTrue(
            clearRange.upperBound <= persistRange.lowerBound,
            "the rotation must be cleared before the final forced persist, not after")
    }

    /// The published rotation SURVIVES the startup health reset, because it is derived.
    ///
    /// `startTunnel` latches, then calls `resetHealth()`, which asynchronously replaces the whole
    /// snapshot with a default. Any value whose only source was the latch install was written and
    /// erased on every single start (Codex P1, PR #613). Deriving it from the live runner on each
    /// mirror pass removes the hazard rather than working around it: the reset has nothing to
    /// erase that is not immediately recomputed.
    func testTheRunningRotationSurvivesTheStartupHealthReset() throws {
        let source = try readPacketTunnelProviderSource()
        // NOTHING STORES IT. A provider-held copy is what `resetHealth` raced; the mirror
        // recomputes instead.
        XCTAssertFalse(
            source.contains("var runningChainedUpstreamGeneration: UInt64"),
            "a stored copy reintroduces the value resetHealth erases")
        let mirror = try sourceBlock(
            in: source,
            startingAt: "func mirrorChainedHealthCountersIfChanged() {",
            endingBefore: "private func chainedMirrorFingerprint()")
        XCTAssertTrue(
            mirror.contains(
                "health.runningChainedUpstreamGeneration = runningChainedUpstreamGeneration()"),
            "the post-reset mirror must republish the rotation identity")
        let fingerprint = try sourceBlock(
            in: source,
            startingAt: "private func chainedMirrorFingerprint()",
            endingBefore: "/// Samples the chained engine's transport byte totals")
        XCTAssertTrue(
            fingerprint.contains("health.runningChainedUpstreamGeneration"),
            "every field the mirror writes must appear in its fingerprint")
    }

    /// A build that READ a rotation and then FAILED must not publish it.
    ///
    /// The read closure returns before `makeSession` constructs the `WireGuardSession` and the
    /// runner, and that construction can throw. The stash is therefore written on paths where no
    /// session ever adopted those credentials — and if that generation happened to match the
    /// store, publishing it would report "current" and HIDE the restart warning, which is worse
    /// than the false warning the stash exists to prevent (Codex P2, PR #613).
    ///
    /// `snapshotStatistics()` is nil exactly when the driver has no runner, so it is the
    /// success evidence, read at the same place and on the same queue as the mirror's existing
    /// `snapshotCounters()` call.
    func testAFailedRebuildDoesNotPublishTheRotationItRead() throws {
        let source = try readPacketTunnelProviderSource()
        let running = try sourceBlock(
            in: source,
            startingAt: "func runningChainedUpstreamGeneration() -> UInt64 {",
            endingBefore: "func mirrorChainedHealthCountersIfChanged() {")
        XCTAssertTrue(
            running.contains("chainedRuntime?.driver.acceptedUpstreamGeneration() ?? 0"),
            "one engine-queue read must answer both 'is a runner live' and 'which rotation'")
        // NOT THROUGH STATISTICS. `sampleStatistics()` is built from `session.statistics()`, which
        // can throw — so an engine error made a live runner look absent and silenced the panel for
        // as long as it persisted (Codex P2, PR #613). Runner identity is immutable and infallible
        // and must not be read through a fallible transport call.
        XCTAssertFalse(
            running.contains("snapshotStatistics()"),
            "identity must not be contingent on a statistics read that can fail")
        // NO FALLBACK TO THE LATCH. Republishing the startup latch while runnerless resurrected
        // a rotation the engine had already replaced, so an outage after a key-only rotation told
        // the user to restart for a configuration adopted rounds ago (Codex P2, PR #613).
        XCTAssertFalse(
            running.contains("latched"),
            "runnerless must publish 0, never the startup latch")
        // TWO READS WOULD NOT DO, and this is the assertion that says so: between a
        // runner-exists check and a separate generation read, the engine queue can retire the
        // runner and start a failing build, publishing a generation nothing is running.
        XCTAssertFalse(
            running.contains("snapshotStatistics() != nil"),
            "existence and generation must come from ONE snapshot, never two reads")
        // And the install must NOT publish: reading the stash there would hop to the engine queue
        // from inside the latch's critical section.
        let install = try sourceBlock(
            in: source,
            startingAt: "func installLatchedDataPathMode(",
            endingBefore: "func latchDataPathMode(")
        XCTAssertFalse(
            install.contains("runningChainedUpstreamGeneration()"),
            "the latch installs the value; the mirror is the single publisher")
    }

    /// What the ENGINE accepted wins over what the latch recorded.
    ///
    /// `ChainedSessionCredentialReader` compares CONFIGURATIONS, so a key-only rotation —
    /// byte-identical configuration, new key material, new generation — is accepted by the next
    /// build. Publishing the latched value after such a rebuild warns the user to restart into a
    /// rotation the session has already adopted (Codex P1, PR #613).
    func testTheRunningRotationPrefersWhatTheEngineAccepted() throws {
        let source = try readPacketTunnelProviderSource()
        let running = try sourceBlock(
            in: source,
            startingAt: "func runningChainedUpstreamGeneration() -> UInt64 {",
            endingBefore: "func mirrorChainedHealthCountersIfChanged() {")
        XCTAssertTrue(
            running.contains("acceptedUpstreamGeneration"),
            "the accepted generation is the engine's, stamped on the runner's own sample")
        XCTAssertTrue(
            running.contains("tunnelLifecycleIsActive"),
            "a rotation must never outlive the lifecycle that ran it")
        XCTAssertTrue(
            running.contains("?? 0"),
            "runnerless resolves to none, which the policy reads as no chained session")
        // A rotation must never outlive the session that ran it — the rule every other chained
        // field in the snapshot follows.
        XCTAssertTrue(
            running.contains("currentTunnelDataPathMode().isChainedUpstream"),
            "a non-chained session must publish no rotation")
    }

    /// The LATCH LOG names the rotation readiness approved, and only for a chained resolution.
    ///
    /// Diagnostics, not the published identity — a field capture is read without the app beside
    /// it, and `data-path-latched` could not previously say which rotation a session started on.
    /// The RESOLUTION gates it, never the readiness verdict: readiness can report ready while the
    /// latch still resolves `.dnsOnly` (the marker-write downgrade is one such path), and logging
    /// the verdict's rotation there would name one the session never ran.
    func testADowngradedLatchLogsNoUpstreamGeneration() throws {
        let source = try readPacketTunnelProviderSource()
        let latch = try sourceBlock(
            in: source,
            startingAt: "func latchDataPathMode(",
            endingBefore: "/// The device-local eligibility store")
        XCTAssertTrue(
            latch.contains("\"upstreamGeneration\""),
            "the latch log must name the rotation it latched")
        XCTAssertTrue(
            latch.contains("? String(readyUpstreamGeneration) : \"\""),
            "a non-chained resolution must log no rotation")
    }


    // MARK: - Token refusals name themselves (PR #621)

    /// A refusal that never reached a socket must not be reported as a socket failure.
    ///
    /// `.socketUnavailable` THROTTLES the endpoint for 30 s. That is correct for a socket we
    /// genuinely could not build, and a lie for a stale token or a deallocated provider — nothing
    /// is wrong with the resolver in either case. The lie was measured on device
    /// (2026-08-29T08:11Z): three token refusals at cold start benched the profile's only resolver
    /// and the next 23 lookups were answered SERVFAIL with the alternative DNS never asked.
    ///
    /// Pinned on the PROVIDER's tunnelled seam specifically. `SocketResolvers` keeps its own
    /// `.socketUnavailable` sites — those really are socket failures — so a blanket file-wide
    /// assertion would be both wrong and vacuous.
    func testATokenRefusalIsNotReportedAsASocketFailure() throws {
        let provider = try readPacketTunnelProviderSource()
        let executor = try sourceBlock(
            in: provider,
            startingAt: "func resolveTunnelledPlainDNS(",
            endingBefore: "private func reportTunnelDNSObservation("
        )
        XCTAssertTrue(executor.contains("outcome: .refusedAfterLifecycleEnded"))
        XCTAssertTrue(executor.contains("outcome: .refusedAfterLatchReplaced"))
        XCTAssertFalse(
            executor.contains("outcome: .socketUnavailable"),
            "the tunnelled executor reaches no socket on a token refusal — reporting one "
                + "throttles the user's resolver for 30 s over our own lifecycle bookkeeping"
        )
        // The provider-deallocated seam, in the executor CONSTRUCTION rather than the loop.
        let construction = try sourceBlock(
            in: provider,
            startingAt: "resolveTunnelledPlain: { [weak self] query, route in",
            endingBefore: "resolveDevice:"
        )
        XCTAssertTrue(
            construction.contains("outcome: .refusedAfterLifecycleEnded"),
            "an absent provider is the lifecycle ending, not a socket failing"
        )
        XCTAssertFalse(construction.contains("outcome: .socketUnavailable"))
    }

    /// The consult decides all three terms in ONE critical section, and names which refused.
    ///
    /// Splitting the guard to produce two distinct refusals is only safe while both halves stay
    /// inside the same closure: reading the lifecycle and the latch across two hops is the race
    /// the fused consult was written to close, and it would return here unnoticed because the
    /// outcome would still be a plausible refusal.
    func testTheEgressConsultStillDecidesInOneCriticalSection() throws {
        let provider = try readPacketTunnelProviderSource()
        let consult = try sourceBlock(
            in: provider,
            startingAt: "    ) -> TunnelledEgressConsult {",
            endingBefore: "return dnsStateQueue.sync(execute: decide)")
        XCTAssertTrue(
            consult.contains("let decide: () -> TunnelledEgressConsult = {"),
            "both halves of the guard must live in the one closure the queue runs")
        XCTAssertEqual(
            consult.components(separatedBy: "self.tunnelDataPathLatchEpoch").count - 1, 1,
            "the latch epoch is read exactly once, inside `decide`")
        XCTAssertEqual(
            consult.components(separatedBy: "self.tunnelLifecycleGeneration").count - 1, 1,
            "the lifecycle generation is read exactly once, inside `decide`")
    }

}

private extension String {
    func containsInOrder(_ needles: [String]) -> Bool {
        var searchRange = startIndex..<endIndex

        for needle in needles {
            guard let range = range(of: needle, range: searchRange) else {
                return false
            }
            searchRange = range.upperBound..<endIndex
        }

        return true
    }

}
