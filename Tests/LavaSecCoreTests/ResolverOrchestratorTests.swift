import XCTest
import LavaSecDNS
@testable import LavaSecCore
@testable import LavaSecKit

final class ResolverOrchestratorTests: XCTestCase {
    private let query = Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01])

    func testTierEvidenceKeepsFailedSelectionSeparateFromItsDeviceRescue() throws {
        let orchestrator = Self.orchestrator(
            recorder: ExecutorRecorder(), egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: nil, outcome: .timeout),
            plainResult: Self.wireResult(address: "9.9.9.9", outcome: .timeout, transport: .plainDNS, response: nil),
            tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())
        let result = try XCTUnwrap(resolveUpstreamSync(orchestrator, plan: Self.plainPlan()))
        XCTAssertEqual(result.tierEvidence.map(\.tier), [.tierZero, .tierOne, .tierTwo])
        XCTAssertEqual(result.tierEvidence.map(\.outcome), [.failure, .failure, .served])
        XCTAssertEqual(result.tierEvidence.map(\.resolverKind), [.upstream, .fixed, .device])
        XCTAssertEqual(result.tierEvidence.map(\.egress), [.tunnel, .physical, .physical])
        XCTAssertEqual(result.tierEvidence.map(\.resolverAddresses), [["10.64.0.1"], ["9.9.9.9"], ["192.168.1.1"]])
        XCTAssertEqual(result.tierEvidence.map(\.originatingLifecycle), [7, 7, 7])
        XCTAssertEqual(result.tierEvidence.map(\.originatingLatchEpoch), [3, 3, 3])
        XCTAssertEqual(result.recordingDuration(since: Date()).tierEvidence, result.tierEvidence)
    }

    func testDNSOnlyTierEvidenceUsesSelectedTierNumbers() throws {
        let orchestrator = Self.orchestrator(
            recorder: ExecutorRecorder(),
            dohResults: [.init(response: nil, outcome: .timeout)])
        let result = try XCTUnwrap(resolveUpstreamSync(orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true)))
        XCTAssertEqual(result.tierEvidence.map(\.tier), [.tierOne, .tierTwo])
        XCTAssertEqual(result.tierEvidence.map(\.outcome), [.failure, .served])
        XCTAssertEqual(result.tierEvidence.map(\.egress), [.physical, .physical])
    }

    func testDeviceSelectionFailureSurvivesFixedFallbackRescue() throws {
        let alternative = DNSResolverRuntimePlan.make(
            resolver: .device, fallbackToDeviceDNS: false, usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"], networkKind: .wifi, deviceDNSFallbackModeActive: false)
        let orchestrator = Self.orchestrator(
            recorder: ExecutorRecorder(), dohResults: [.init(response: Self.reply(rcode: 0), outcome: .success)],
            egressAllowance: .chainedSplitTunnelMode, tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: nil, outcome: .timeout),
            deviceResult: Self.wireResult(address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS, response: nil),
            tierOneFallbackPlan: alternative)
        let result = try XCTUnwrap(resolveUpstreamSync(orchestrator, plan: Self.plainPlan()))
        XCTAssertEqual(result.tierEvidence.map(\.tier), [.tierZero, .tierOne, .tierTwo])
        XCTAssertEqual(result.tierEvidence.map(\.resolverKind), [.upstream, .device, .fixed])
        XCTAssertEqual(result.tierEvidence.map(\.outcome), [.failure, .failure, .served])
    }

    func testPromotedDeviceFallbackKeepsItsConfiguredTierNumber() throws {
        let plan = DNSResolverRuntimePlan.make(
            resolver: .quad9UnfilteredDoH, fallbackToDeviceDNS: true,
            deviceDNSAddresses: ["192.168.1.1"], networkKind: .wifi, deviceDNSFallbackModeActive: true)
        let result = try XCTUnwrap(resolveUpstreamSync(Self.orchestrator(recorder: ExecutorRecorder()), plan: plan))
        XCTAssertEqual(result.tierEvidence.map(\.tier), [.tierTwo])
        XCTAssertEqual(result.tierEvidence.first?.resolverKind, .device)
    }

    func testSoleEnabledSavedTierTwoKeepsItsNumberInDNSOnlyAndChainedSplitExecution() throws {
        let upstreamRoute = try Self.chainedRoute()
        for resolver in [DNSResolverPreset.device, .cloudflareDoH] {
            var configuration = AppConfiguration()
            try configuration.applyDNSResolutionSelections([
                .init(id: DNSResolverPreset.quad9UnfilteredDoH.id, isEnabled: false),
                .init(id: resolver.id, isEnabled: true)
            ], allowsCustom: false)
            let plan = DNSResolverRuntimePlan.make(
                configuration: configuration, deviceDNSAddresses: ["192.168.1.1"],
                networkKind: .wifi, deviceDNSFallbackModeActive: false)
            for chained in [false, true] {
                let orchestrator = Self.orchestrator(
                    recorder: ExecutorRecorder(),
                    dohResults: [.init(response: Self.reply(rcode: 0), outcome: .success)],
                    egressAllowance: chained ? .chainedSplitTunnelMode : .dnsOnlyMode,
                    tunnelledRoute: chained ? upstreamRoute : nil,
                    tunnelledResult: Self.plannedResult(response: nil, outcome: .timeout),
                    tierOneFallbackPlan: plan)
                let result = try XCTUnwrap(resolveUpstreamSync(orchestrator, plan: plan))
                XCTAssertEqual(result.tierEvidence.map(\.tier), chained ? [.tierZero, .tierTwo] : [.tierTwo])
                let effective = try XCTUnwrap(result.tierEvidence.last)
                XCTAssertEqual(effective.resolverKind, resolver.transport == .deviceDNS ? .device : .fixed)
                XCTAssertEqual(effective.outcome, .served)
                XCTAssertEqual(effective.egress, .physical)
                XCTAssertNil(result.tierOneSelectionOutcome)
                if chained {
                    let physicalLadder = try XCTUnwrap(result.tierOneRung)
                    XCTAssertNil(physicalLadder.outcome, "Disabled T1 receives no selection credit")
                    XCTAssertTrue(physicalLadder.ladderServed, "T2 still rescues the permitted physical ladder")
                }
            }
        }
    }

    func testFullTunnelAndAuthoritativeNegativeDoNotFabricatePhysicalEvidence() throws {
        for allowance in [ResolverOrchestrator.EgressAllowance.chainedMode, .chainedSplitTunnelMode] {
            let orchestrator = Self.orchestrator(
                recorder: ExecutorRecorder(), egressAllowance: allowance,
                tunnelledRoute: try Self.chainedRoute(),
                tunnelledResult: Self.plannedResult(response: Self.reply(rcode: 3), outcome: .success))
            let result = try XCTUnwrap(resolveUpstreamSync(orchestrator, plan: Self.plainPlan()))
            XCTAssertEqual(result.tierEvidence.map(\.tier), [.tierZero])
            XCTAssertEqual(result.tierEvidence.first?.outcome, .served)
        }
        let full = Self.orchestrator(
            recorder: ExecutorRecorder(), egressAllowance: .chainedMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: nil, outcome: .timeout),
            tierOneFallbackPlan: Self.deviceDNSPlan())
        let failed = try XCTUnwrap(resolveUpstreamSync(full, plan: Self.plainPlan()))
        XCTAssertEqual(failed.tierEvidence.map(\.tier), [.tierZero])
        XCTAssertEqual(failed.tierEvidence.first?.outcome, .failure)
    }

    func testDoHSuccessRecordsAttemptWithNegotiatedProtocol() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(
                response: Data([0x01]),
                outcome: .success,
                negotiatedHTTPProtocolName: "h3"
            )]
        )

        let result = resolveUpstreamSync(orchestrator, plan: Self.dohPlan(endpointHosts: ["one.example"]))

        XCTAssertEqual(result?.response, Data([0x01]))
        XCTAssertEqual(result?.successfulResolverAddress, "doh:https://one.example/dns-query")
        XCTAssertEqual(result?.attempts.count, 1)
        XCTAssertEqual(result?.attempts.first?.outcome, .success)
        XCTAssertEqual(result?.attempts.first?.transport, .dnsOverHTTPS)
        XCTAssertEqual(result?.attempts.first?.negotiatedDoHProtocol, "h3")
        XCTAssertEqual(result?.negotiatedDoHProtocol, "h3")
        XCTAssertEqual(recorder.dohCallCount, 1)
        XCTAssertEqual(recorder.plainCallCount, 0)
        XCTAssertEqual(recorder.deviceCallCount, 0)
    }

    func testTimeoutFailsOverToNextEndpoint() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [
                DNSTransportResponse(response: nil, outcome: .timeout),
                DNSTransportResponse(response: Data([0x02]), outcome: .success)
            ]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example", "two.example"])
        )

        XCTAssertEqual(result?.response, Data([0x02]))
        XCTAssertEqual(result?.successfulResolverAddress, "doh:https://two.example/dns-query")
        XCTAssertEqual(result?.attempts.map(\.outcome), [.timeout, .success])
        XCTAssertEqual(recorder.dohCallCount, 2)
    }

    func testAllEndpointsFailingAccumulatesAttemptsWithoutResponse() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [
                DNSTransportResponse(response: nil, outcome: .receiveFailed),
                DNSTransportResponse(response: nil, outcome: .timeout)
            ]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example", "two.example"])
        )

        XCTAssertNil(result?.response)
        XCTAssertNil(result?.successfulResolverAddress)
        XCTAssertEqual(result?.attempts.map(\.outcome), [.receiveFailed, .timeout])
        XCTAssertEqual(result?.failureSummary, "timeout")
    }

    func testBackedOffEndpointSkipsWireAndAdvancesToNextEndpoint() {
        let recorder = ExecutorRecorder()
        recorder.backedOffAddresses = ["doh:https://one.example/dns-query"]
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: Data([0x03]), outcome: .success)]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example", "two.example"])
        )

        XCTAssertEqual(result?.response, Data([0x03]))
        XCTAssertEqual(result?.attempts.map(\.outcome), [.backedOff, .success])
        XCTAssertEqual(
            recorder.dohCallCount,
            1,
            "A backed-off endpoint must not touch the wire."
        )
        XCTAssertEqual(result?.attempts.first?.address, "doh:https://one.example/dns-query")
    }

    func testEmptyEncryptedEndpointsDegradeToPlainDNS() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder)

        let result = resolveUpstreamSync(orchestrator, plan: Self.dohPlan(endpointHosts: []))

        XCTAssertEqual(recorder.plainCallCount, 1)
        XCTAssertEqual(recorder.lastPlainAddresses, ["9.9.9.9"])
        XCTAssertEqual(recorder.lastPlainTransport, .plainDNS)
        XCTAssertEqual(result?.response, ExecutorRecorder.plainResponse)
    }

    func testDeviceFallbackRunsOnlyWhenPrimaryFailsAndPlanAllowsIt() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: nil, outcome: .receiveFailed)]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true)
        )

        XCTAssertEqual(recorder.deviceCallCount, 1)
        XCTAssertEqual(recorder.lastDeviceAddresses, ["192.168.1.1"])
        XCTAssertEqual(result?.response, ExecutorRecorder.deviceResponse)
        XCTAssertEqual(result?.transport, .deviceDNS)
        XCTAssertEqual(result?.deviceDNSFallbackAttempted, true)
        XCTAssertEqual(result?.deviceDNSFallbackSucceeded, true)
        XCTAssertEqual(result?.attempts.map(\.outcome), [.receiveFailed, .success])
    }

    func testNoDeviceFallbackWhenPlanDisallowsIt() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: nil, outcome: .receiveFailed)]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: false)
        )

        XCTAssertEqual(recorder.deviceCallCount, 0)
        XCTAssertNil(result?.response)
        XCTAssertEqual(result?.deviceDNSFallbackAttempted, false)
    }

    // MARK: - Chained mode suspends egress around the tunnel

    func testChainedModeRefusesTheDeviceFallbackTheSamePlanWouldOtherwiseTake() {
        // The leak, and the reason it is dangerous: nothing breaks when it happens. The tunnel
        // is up, pages load, filtering works, and the user's queries are quietly still going
        // out on the interface the tunnel routed everything away from. Chained mode claims
        // 0.0.0.0/0, so every rung of this ladder IS egress on the physical interface — and
        // the ladder runs precisely when the tunnelled resolver is struggling.
        //
        // Identical plan and identical failing primary as
        // `testDeviceFallbackRunsOnlyWhenPrimaryFailsAndPlanAllowsIt`, which reaches device
        // DNS. The only difference is the allowance, so this pins the allowance rather than
        // anything about the plan.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: nil, outcome: .receiveFailed)],
            egressAllowance: .chainedMode
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true)
        )

        XCTAssertEqual(recorder.deviceCallCount, 0, "device DNS ran while chained — this is the leak")
        XCTAssertNotEqual(result?.response, ExecutorRecorder.deviceResponse)
        XCTAssertEqual(result?.deviceDNSFallbackAttempted, false)
    }

    // MARK: - The T1 allowance dimension (split-tunnel physical egress)

    /// The split-tunnel allowance suspends the T0 ladder EXACTLY as full tunnel does.
    ///
    /// This is the property that keeps the new dimension from being a relaxation of the old
    /// ones. A split tunnel changes nothing about where the PRIMARY resolves — it changes only
    /// whether a second rung, reached after T0 has already failed to serve, may leave on a
    /// path the user's own traffic is already taking. If these two allowances ever differ in
    /// any dimension but the fourth, a configured DoH primary would start egressing around the
    /// tunnel, which is the leak `EgressAllowance` exists to make unrepresentable.
    func testTheChainedAllowancesDifferOnlyInTheTierOneDimension() {
        let full = ResolverOrchestrator.EgressAllowance.chainedMode
        let split = ResolverOrchestrator.EgressAllowance.chainedSplitTunnelMode

        let everyTransport: [DNSResolverTransport] = [
            .deviceDNS, .plainDNS, .dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC,
        ]
        for transport in everyTransport {
            XCTAssertEqual(
                full.permits(transport), split.permits(transport),
                "\(transport) must egress identically in both chained shapes")
            XCTAssertFalse(
                split.permits(transport),
                "the T0 ladder stays suspended in a split tunnel too")
        }

        XCTAssertFalse(full.permitsTierOneFallbackOnPhysicalInterface)
        XCTAssertTrue(split.permitsTierOneFallbackOnPhysicalInterface)
    }

    /// DNS-only has no T1 rung: there the user's chosen resolver IS the primary, reached by
    /// the ordinary ladder. Granting the dimension would be a second mechanism for a permission
    /// the other three already give.
    func testDNSOnlyModeHasNoTierOneRung() {
        let allowance = ResolverOrchestrator.EgressAllowance.dnsOnlyMode
        XCTAssertFalse(allowance.permitsTierOneFallbackOnPhysicalInterface)
        XCTAssertNil(allowance.tierOneFallbackAllowance)
    }

    /// The derived rung allowance reaches every transport the user can pick, and never spawns a
    /// rung of its own.
    ///
    /// DEVICE DNS IS PERMITTED, and this test previously pinned the opposite. What the refusal
    /// was protecting is still protected, one layer up: a device-wide fallback EPISODE cannot
    /// rewrite the rung into a device-DNS plan, because the plan is built with
    /// `ignoresDeviceDNSFallbackMode: true`. This allowance answers a different question — may
    /// the rung resolve the plan it was GIVEN — and when the user's one selection is Device DNS
    /// that plan is theirs by choice (founder, 2026-08-27, PR #592).
    ///
    /// No-recursion is unchanged and still the sharp edge: a rung that could derive a rung would
    /// re-enter the ladder indefinitely.
    func testTheTierOneRungPermitsEveryTransportAndNeverSpawnsARung() {
        guard
            let rung = ResolverOrchestrator.EgressAllowance.chainedSplitTunnelMode
                .tierOneFallbackAllowance
        else { return XCTFail("a split-tunnel allowance must derive a rung") }

        for transport in [
            DNSResolverTransport.deviceDNS, .plainDNS, .dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC
        ] {
            XCTAssertTrue(
                rung.permits(transport),
                "\(transport) is a selection the user can make, so the rung must resolve it")
        }
        XCTAssertFalse(
            rung.permitsTierOneFallbackOnPhysicalInterface, "a rung must not spawn a rung")
        XCTAssertNil(rung.tierOneFallbackAllowance)
    }

    /// ...and the T0 allowances are untouched: device DNS while chained is still the leak.
    ///
    /// This is the half that must not move. A device-DNS PRIMARY while chained egresses on the
    /// interface the tunnel routed everything away from, and nothing breaks visibly when it
    /// happens. Widening the rung says nothing about the primary.
    func testTheChainedPrimaryAllowancesStillRefuseDeviceDNS() {
        for allowance in [
            ResolverOrchestrator.EgressAllowance.chainedMode, .chainedSplitTunnelMode
        ] {
            XCTAssertFalse(
                allowance.permits(.deviceDNS),
                "the T0 ladder is suspended while chained, rung or no rung")
        }
    }

    /// The rung honours the transport the user picked, plain IP included.
    ///
    /// Resolved decision D1 (plan `2026-08-26-unified-resolver-picker-...`): a split tunnel
    /// already discloses the destination and the TLS SNI to the same observer, and silently
    /// substituting an encrypted transport would override an explicit choice. The UI discloses
    /// it instead.
    func testTheTierOneRungHonoursEveryChosenTransportIncludingPlainIP() {
        guard
            let rung = ResolverOrchestrator.EgressAllowance.chainedSplitTunnelMode
                .tierOneFallbackAllowance
        else { return XCTFail("a split-tunnel allowance must derive a rung") }

        XCTAssertTrue(rung.permits(.plainDNS), "an explicitly chosen plain-IP resolver is honoured")
        for encrypted: DNSResolverTransport in [.dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC] {
            XCTAssertTrue(rung.permits(encrypted), "\(encrypted) is the better path and must run")
        }
    }

    func testChainedModeRefusesPlainDNSWhenNoRouteIsSupplied() {
        // The gap the other two chained-mode tests did not close. `EgressAllowance` carried two
        // booleans for five transports, and `.plainDNS` is neither device DNS nor encrypted, so
        // it fell between both guards and resolved unconditionally — in the type whose stated
        // purpose is making egress around the tunnel unrepresentable.
        //
        // Worse than an edge case: `.plainDNS` is the DEFAULT transport, both on the
        // orchestrator's own initialiser and as `DNSResolverRuntimePlan`'s `effectiveTransport`
        // fallback. Any user without an encrypted resolver configured took this path.
        //
        // Refused even though plain UDP DNS is the one transport the design CARRIES through
        // the tunnel (S6): with no tunnelled route supplied, "permitted" can only mean "on
        // the physical interface", which is the leak. The route consult sits BEFORE the
        // allowance — this assertion is about the physical interface and stays true with or
        // without a route; the with-route half is
        // `testATunnelledRouteCarriesPlainDNSThroughTheSessionNotThePhysicalInterface`.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, egressAllowance: .chainedMode)

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.plainCallCount, 0, "plain DNS ran on the physical interface while chained")
        XCTAssertNotNil(result, "the query must be answered, not left to time out")
        XCTAssertNil(result?.response)
        XCTAssertEqual(result?.attempts.last?.outcome, .refusedByEgressPolicy)
        XCTAssertEqual(result?.attempts.last?.transport, .plainDNS)
        // Not an empty attempts array: `failureSummary` reads `attempts.last?.outcome` and the
        // smoke-probe log renders `failureSummary ?? "success"`, so a refusal with no attempt
        // recorded is logged as a successful resolution.
        XCTAssertEqual(result?.attempts.isEmpty, false)
    }

    func testDegradingAnEncryptedPlanToPlainDNSStillObeysThePlainAllowance() {
        // The guard above the transport switch tests `plan.transport` — what was PLANNED — but
        // an encrypted plan with no endpoints of its own DEGRADES to plain DNS. So a DoH plan
        // was admitted on the encrypted allowance and then egressed as plain DNS, which the
        // allowance may separately forbid: the guard and the actual egress were about different
        // transports.
        //
        // Needs a MIXED allowance to reach, which neither shipping constant is — `dnsOnlyMode`
        // permits everything, `chainedMode` permits nothing, so the encrypted plan is refused
        // before it can degrade. The S6 carry deliberately kept it that way: the tunnelled
        // route rides the `.plainDNS` arm, not an allowance dimension, so the shipping
        // allowances stay uniform and this guard stays the backstop for any future
        // allowance whose dimensions differ. The chained-shaped instance of the same
        // decision is `testADegradedEncryptedPlanIsRefusedNotTunnelled`.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: ResolverOrchestrator.EgressAllowance(
                permitsDeviceDNS: false,
                permitsEncryptedTransports: true,
                permitsPlainDNS: false,
                permitsTierOneFallbackOnPhysicalInterface: false)
        )

        // No DoH endpoints, so the plan degrades to plain DNS.
        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: [])
        )

        XCTAssertEqual(
            recorder.plainCallCount, 0,
            "a degraded encrypted plan egressed as plain DNS while plain DNS was refused")
        XCTAssertEqual(result?.attempts.last?.outcome, .refusedByEgressPolicy)
    }

    func testDNSOnlyModeStillResolvesPlainDNS() {
        // The other direction, so the guard above is not merely a blanket refusal. A check that
        // rejects the shipping path would be caught by every other test in this file, but
        // stating it here keeps the pair readable together.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, egressAllowance: .dnsOnlyMode)

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.plainCallCount, 1)
        XCTAssertNotNil(result?.response)
    }

    func testEveryTransportGetsAnExplicitAnswerFromBothAllowances() {
        // Enumerated rather than spot-checked. The defect this guards was not a wrong answer —
        // it was a transport nobody had been asked about, so the test that would have caught it
        // is one that asks about all of them. `permits(_:)` switches without a `default`, so a
        // sixth case is a build error; this asserts the two shipping allowances agree with
        // their documented intent for the five that exist.
        let all: [DNSResolverTransport] = [.deviceDNS, .plainDNS, .dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC]

        for transport in all {
            XCTAssertTrue(
                ResolverOrchestrator.EgressAllowance.dnsOnlyMode.permits(transport),
                "DNS-only mode suspends nothing, but refused \(transport)")
            XCTAssertFalse(
                ResolverOrchestrator.EgressAllowance.chainedMode.permits(transport),
                "chained mode permitted \(transport) on the physical interface")
        }
    }

    func testChainedModeRefusesADeviceDNSPrimaryRatherThanResolvingIt() {
        // The other way in. Suppressing only the FALLBACK leaves a user whose configured
        // resolver IS device DNS resolving on the physical interface as their primary, which
        // is the same leak by a shorter path.
        //
        // This is the NO-ROUTE shape (none is supplied here): device DNS on the physical
        // interface is refused. When a tunnelled route exists the same primary rides the session
        // instead — device DNS is plain UDP, so the route consult precedes this refusal exactly
        // as it does for `.plainDNS`. That leg is
        // `testChainedModeCarriesADeviceDNSPrimaryThroughTheTunnelWhenARouteExists`.
        //
        // Refused with an ANSWER, not a hang: INV-DNS-1 is about never failing OPEN, and an
        // unanswered query times out indistinguishably from a network problem and invites a
        // retry against the same refusal.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, egressAllowance: .chainedMode)

        let result = resolveUpstreamSync(orchestrator, plan: Self.devicePlan())

        XCTAssertEqual(recorder.deviceCallCount, 0)
        XCTAssertNotNil(result, "the query must be answered, not left to time out")
        XCTAssertNil(result?.response)
        // Not `deviceDNSUnavailable` — that means "no captured resolver address", which is a
        // configuration failure, and this is the tunnel working as designed. See
        // `testAPolicyRefusalIsNotReportedAsAMissingResolver`.
        XCTAssertEqual(result?.deviceDNSUnavailable, false)
    }

    func testChainedModeRefusesEncryptedPrimariesToo() {
        // Device DNS is not the only physical-interface egress. DoH/DoT/DoQ open their own
        // TCP/QUIC connections on the ordinary interface, so while chained a configured
        // encrypted primary leaks exactly as device DNS does — and less visibly, because the
        // user believes encrypted DNS is the safer setting.
        //
        // Refused rather than tunnelled: they are TCP or QUIC, and carrying those through a
        // userspace WireGuard session needs a TCP implementation this feature is not growing.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: ExecutorRecorder.plainResponse, outcome: .success)],
            egressAllowance: .chainedMode)

        let result = resolveUpstreamSync(
            orchestrator, plan: Self.dohPlan(endpointHosts: ["one.example"]))

        XCTAssertNil(result?.response, "an encrypted primary resolved while chained")
        XCTAssertNotNil(result, "the query must be answered, not left to time out")
    }

    func testChainedModeRefusesTheEncryptedRungOfTheLadderToo() {
        // The other direction of the ladder: a device-DNS primary falling back to encrypted.
        // Suppressing only the device rung would leave this one egressing on the physical
        // interface at exactly the moment the tunnelled resolver is struggling.
        //
        // The plan must actually CONFIGURE the encrypted fallback, or this proves nothing —
        // an earlier version of this test used a plan with `shouldFallbackToEncrypted: false`,
        // so deleting the gate under test failed nothing. Mutation testing caught it.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, egressAllowance: .chainedMode)
        let plan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device-chained",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false,
            shouldFallbackToEncrypted: true,
            encryptedFallbackEndpoints: [DNSResolverRuntimePlan.defaultEncryptedFallbackEndpoint]
        )

        let result = resolveUpstreamSync(orchestrator, plan: plan)

        XCTAssertEqual(recorder.deviceCallCount, 0, "the device primary ran while chained")
        XCTAssertEqual(recorder.dohCallCount, 0, "the encrypted fallback ran while chained")
        XCTAssertFalse(result?.usedEncryptedFallback ?? true)
        XCTAssertNil(result?.response)
    }

    func testAPolicyRefusalIsNotReportedAsAMissingResolver() {
        // `deviceDNSUnavailable` was minted for "no captured resolver address was available".
        // Reusing it for a policy refusal conflates the tunnel working as designed with a
        // configuration failure, and the two send whoever reads the field report to different
        // places.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, egressAllowance: .chainedMode)
        let result = resolveUpstreamSync(orchestrator, plan: Self.devicePlan())
        XCTAssertEqual(
            result?.deviceDNSUnavailable, false,
            "a chained-mode refusal must not present as a missing resolver")
    }

    func testAPolicyRefusalIsNotRenderedAsASuccess() {
        // The sharp end of returning `attempts: []`. `failureSummary` reads
        // `attempts.last?.outcome`, so an empty array made it nil — and the smoke-probe log
        // renders `failureSummary ?? "success"`. A refusal that PREVENTS A DNS LEAK was being
        // logged as a successful resolution, and the evidence recorder saw
        // `.totalFailure(reason: nil)` at the same time.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, egressAllowance: .chainedMode)

        for (label, plan) in [
            ("device primary", Self.devicePlan()),
            ("encrypted primary", Self.dohPlan(endpointHosts: ["one.example"])),
        ] {
            let result = resolveUpstreamSync(orchestrator, plan: plan)
            XCTAssertEqual(
                result?.failureSummary, "refused-by-egress-policy",
                "\(label): a refusal with no attempts renders as \"success\" in the probe log")
            XCTAssertNil(result?.response, "\(label)")
        }
    }

    func testARefusedResolverIsNamedSoTheLogSaysWhichOneWasDeclined() {
        // "refused-by-egress-policy" with no identity cannot distinguish a user's configured
        // DoH endpoint from the fallback, which is the first question a field report raises.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, egressAllowance: .chainedMode)
        let result = resolveUpstreamSync(
            orchestrator, plan: Self.dohPlan(endpointHosts: ["one.example"]))
        XCTAssertEqual(result?.attempts.map(\.address), ["one.example"])
        XCTAssertEqual(result?.attempts.map(\.transport), [.dnsOverHTTPS])
    }

    func testDNSOnlyModeIsUnchangedWhichIsWhatShipsToday() {
        // The other half of the guard: suppressing unconditionally would break the shipping
        // DNS-only path for a mode nobody is in. This is the same assertion as the sibling
        // fallback test, kept here so a regression in the allowance shows up as a chained-mode
        // failure rather than as a mysterious change somewhere else.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: nil, outcome: .receiveFailed)],
            egressAllowance: .dnsOnlyMode
        )
        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true)
        )
        XCTAssertEqual(recorder.deviceCallCount, 1)
        XCTAssertEqual(result?.response, ExecutorRecorder.deviceResponse)
    }

    func testNoDeviceFallbackWhenPrimarySucceeds() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: Data([0x04]), outcome: .success)]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true)
        )

        XCTAssertEqual(recorder.deviceCallCount, 0)
        XCTAssertEqual(result?.response, Data([0x04]))
    }

    func testIsolatedConnectionFlagReachesDoTAndDoQExecutors() {
        let recorder = ExecutorRecorder()
        recorder.dotResults = [DNSTransportResponse(response: Data([0x05]), outcome: .success)]
        recorder.doqResults = [DNSTransportResponse(response: Data([0x06]), outcome: .success)]
        let orchestrator = Self.orchestrator(recorder: recorder)

        _ = resolveUpstreamSync(
            orchestrator,
            plan: Self.dotPlan(hostnames: ["dot.example"]),
            usesIsolatedEncryptedConnections: true
        )
        _ = resolveUpstreamSync(
            orchestrator,
            plan: Self.doqPlan(hostnames: ["doq.example"]),
            usesIsolatedEncryptedConnections: true
        )

        XCTAssertEqual(recorder.lastDoTIsolated, true)
        XCTAssertEqual(recorder.lastDoQIsolated, true)

        recorder.dotResults = [DNSTransportResponse(response: Data([0x05]), outcome: .success)]
        _ = resolveUpstreamSync(orchestrator, plan: Self.dotPlan(hostnames: ["dot.example"]))
        XCTAssertEqual(recorder.lastDoTIsolated, false)
    }

    func testPlainAndDeviceTransportsRouteDirectly() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder)

        let plainResult = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())
        XCTAssertEqual(recorder.plainCallCount, 1)
        XCTAssertEqual(plainResult?.response, ExecutorRecorder.plainResponse)

        let devicePlan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false
        )
        let deviceResult = resolveUpstreamSync(orchestrator, plan: devicePlan)
        XCTAssertEqual(recorder.deviceCallCount, 1)
        XCTAssertEqual(recorder.lastDeviceAddresses, ["10.0.0.1"])
        XCTAssertEqual(deviceResult?.response, ExecutorRecorder.deviceResponse)
    }

    func testATunnelledRouteCarriesPlainDNSThroughTheSessionNotThePhysicalInterface() throws {
        // S6's central property at the orchestrator seam: with a route supplied, `.plainDNS`
        // resolves through the tunnelled executor and NOTHING touches a physical-interface
        // executor — the zero counts below are the capture assertion at this seam, and the
        // allowance is `.chainedMode` throughout, because the carry never consults it.
        let recorder = ExecutorRecorder()
        let route = try XCTUnwrap(
            ResolverOrchestrator.TunnelledPlainDNSRoute(
                resolverAddresses: ["10.64.0.1", "10.64.0.2"], originatingLifecycle: 7,
                originatingLatchEpoch: 3))
        let orchestrator = Self.orchestrator(
            recorder: recorder, egressAllowance: .chainedMode, tunnelledRoute: route)

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.tunnelledCallCount, 1)
        XCTAssertEqual(
            recorder.lastTunnelledRoute, route,
            "the executor must be handed the SELECTED set, nothing else")
        XCTAssertEqual(
            recorder.plainCallCount, 0,
            "the plain executor is the physical interface — calling it while chained is the leak")
        XCTAssertEqual(recorder.deviceCallCount, 0)
        XCTAssertEqual(recorder.dohCallCount, 0)
        XCTAssertEqual(result?.response, ExecutorRecorder.tunnelledResponse)
    }

    func testChainedModeCarriesADeviceDNSPrimaryThroughTheTunnelWhenARouteExists() throws {
        // The device-DNS sibling of the plain test above, and the leg the field actually hit:
        // the app DEFAULTS to device DNS, so a chained user with no plain/encrypted resolver
        // configured lands here. Device DNS is plain UDP, so with a route supplied it rides the
        // SESSION to the upstream's resolver — the plain-DNS carry (S6) extended to its sibling
        // transport — and NOTHING touches a physical-interface executor. The zero counts are the
        // capture assertion at this seam; the allowance is `.chainedMode` throughout because the
        // carry never consults it. Device-verified (chimmy, 2026-08-14): before this, a device-DNS
        // user saw a total DNS blackhole the moment they chained. The no-route half — where the
        // same primary is refused — is `testChainedModeRefusesADeviceDNSPrimaryRatherThanResolvingIt`.
        let recorder = ExecutorRecorder()
        let route = try XCTUnwrap(
            ResolverOrchestrator.TunnelledPlainDNSRoute(
                resolverAddresses: ["100.100.100.100"], originatingLifecycle: 7,
                originatingLatchEpoch: 3))
        let orchestrator = Self.orchestrator(
            recorder: recorder, egressAllowance: .chainedMode, tunnelledRoute: route)

        let result = resolveUpstreamSync(orchestrator, plan: Self.devicePlan())

        XCTAssertEqual(recorder.tunnelledCallCount, 1)
        XCTAssertEqual(
            recorder.lastTunnelledRoute, route,
            "the executor must be handed the SELECTED set, nothing else")
        XCTAssertEqual(
            recorder.deviceCallCount, 0,
            "the device executor is the physical interface — calling it while chained is the leak")
        XCTAssertEqual(recorder.plainCallCount, 0)
        XCTAssertEqual(recorder.dohCallCount, 0)
        XCTAssertEqual(result?.response, ExecutorRecorder.tunnelledResponse)
    }

    func testTheRouteConsultPrecedesTheAllowanceRatherThanBeingGatedByIt() throws {
        // The ordering pin, behavioural: the route wins even under the permissive
        // `.dnsOnlyMode` allowance, which proves the consult sits BEFORE the allowance
        // rather than inside its chained branch. Production never supplies a route outside
        // chained mode — the provider derives it from the latched mode — so this leg is
        // about the seam's shape, not a product behaviour.
        let recorder = ExecutorRecorder()
        let route = try XCTUnwrap(
            ResolverOrchestrator.TunnelledPlainDNSRoute(
                resolverAddresses: ["10.64.0.1"], originatingLifecycle: 7,
                originatingLatchEpoch: 3))
        let orchestrator = Self.orchestrator(
            recorder: recorder, egressAllowance: .dnsOnlyMode, tunnelledRoute: route)

        _ = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.tunnelledCallCount, 1)
        XCTAssertEqual(recorder.plainCallCount, 0)
    }

    func testWhileChainedEveryTransportRidesTierZeroIncludingADegradedEncryptedPlan() throws {
        // REPLACES `testADegradedEncryptedPlanIsRefusedNotTunnelled`, whose premise the T1
        // model retires. That test pinned "a degraded DoH plan must never ride the tunnel route",
        // on the reasoning that answering via the upstream's plain resolver would silently change
        // the operator the user chose. True while their selection WAS the chained primary; false
        // now that it is T1. The conf's own `DNS =` is the chained primary for every
        // transport, and the user's selection is reached only for a name T0 did not serve.
        //
        // THE HOIST ALSO CLOSED A BLACKHOLE. The tunnelled consult used to live inside the
        // `.plainDNS` / `.deviceDNS` arms only, so a chained user whose preset was encrypted was
        // refused at the transport gate and never reached the tunnel — every query answered
        // SERVFAIL with the upstream's own resolver sitting there, willing and unasked.
        let recorder = ExecutorRecorder()
        let route = try XCTUnwrap(
            ResolverOrchestrator.TunnelledPlainDNSRoute(
                resolverAddresses: ["10.64.0.1"], originatingLifecycle: 7,
                originatingLatchEpoch: 3))
        let orchestrator = Self.orchestrator(
            recorder: recorder, egressAllowance: .chainedMode, tunnelledRoute: route)

        // A DoH plan with no endpoints — the degraded shape — and a full DoH plan both ride it.
        for plan in [Self.dohPlan(endpointHosts: []), Self.dohPlan(endpointHosts: ["one.example"])] {
            recorder.resetCallCounts()
            let result = resolveUpstreamSync(orchestrator, plan: plan)

            XCTAssertEqual(recorder.tunnelledCallCount, 1, "T0 is the conf's resolver")
            XCTAssertEqual(recorder.dohCallCount, 0, "the user's encrypted preset is not T0")
            XCTAssertEqual(recorder.plainCallCount, 0)
            XCTAssertEqual(result?.response, ExecutorRecorder.tunnelledResponse)
        }
    }

    // MARK: - The chained T1 rung on the physical interface (S2)

    /// A well-formed reply with the complete response code, including OPT for extended errors.
    private static func reply(rcode: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[2] = 0x80              // QR = response
        bytes[3] = rcode & 0x0F
        if rcode > 15 {
            bytes[11] = 1
            bytes.append(contentsOf: [0, 0, 41, 4, 208, rcode >> 4, 0, 0, 0, 0, 0])
        }
        return Data(bytes)
    }

    private static func plannedResult(response: Data?, outcome: ResolverAttemptOutcome) -> DNSResolutionResult {
        DNSResolutionResult(
            response: response,
            successfulResolverAddress: response == nil ? nil : "10.64.0.1",
            attempts: [
                ResolverAttempt(address: "10.64.0.1", outcome: outcome, transport: .plainDNS)
            ],
            transport: .plainDNS,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false)
    }

    private static func chainedRoute(
        latchEpoch: UInt64 = 3
    ) throws -> ResolverOrchestrator.TunnelledPlainDNSRoute {
        try XCTUnwrap(
            ResolverOrchestrator.TunnelledPlainDNSRoute(
                resolverAddresses: ["10.64.0.1"], originatingLifecycle: 7,
                originatingLatchEpoch: latchEpoch))
    }

    /// T0 SERVFAILs in a SPLIT tunnel, so the user's chosen resolver is tried on the physical
    /// interface — the whole point of the slice. Both rungs' attempts survive, because a field
    /// capture has to show that the tunnel was tried and what it said.
    func testASplitTunnelTierOneRungRunsOnThePhysicalInterface() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: Self.reply(rcode: 2), outcome: .success))

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.tunnelledCallCount, 1, "T0 is always tried first")
        XCTAssertEqual(recorder.plainCallCount, 1, "the rung runs on the picked transport")
        XCTAssertEqual(recorder.lastPlainAddresses, ["9.9.9.9"], "the user's resolver, not the conf's")
        XCTAssertEqual(result?.response, ExecutorRecorder.plainResponse)
        XCTAssertEqual(
            result?.attempts.map(\.address), ["10.64.0.1", "9.9.9.9"],
            "both rungs' attempts survive — a capture must show the tunnel was tried")
    }

    /// NO PLAN, NO RUNG.
    ///
    /// The provider answers nil whenever there is nothing to ask — a Device-DNS selection, which
    /// may never be the rung, or a plain selection whose every address is already the conf's own
    /// resolver. Before this, the rung re-resolved the CALLER's plan, so a split-tunnel user had
    /// their primary resolver contacted on the physical interface whether or not that was the
    /// resolver meant for the rung (Codex, PR #590).
    ///
    /// Failing closed here means T0's own answer is what the client gets, exactly as under
    /// `chainedMode`.
    func testNoRungRunsWhenTheUserHasNotOptedIntoATierOneFallback() throws {
        let recorder = ExecutorRecorder()
        let servfail = Self.reply(rcode: 2)
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: servfail, outcome: .success),
            tierOneFallbackPlan: nil)

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.tunnelledCallCount, 1, "T0 still runs")
        XCTAssertEqual(
            recorder.plainCallCount, 0,
            "no opt-in means nothing leaves on the physical interface, split tunnel or not")
        XCTAssertEqual(
            result?.response, servfail, "T0's real answer stands, as it does in full tunnel")
    }

    /// The rung resolves the user's chosen ALTERNATIVE, not their primary.
    ///
    /// The two pickers are separate settings today. Reusing the caller's plan meant a user who
    /// switched Alternative DNS on and picked a different resolver got their PRIMARY contacted
    /// instead — the setting was displayed, stored, and ignored (Codex, PR #590).
    ///
    /// The caller's plan and the rung's plan carry deliberately different addresses so the
    /// assertion cannot pass by coincidence.
    func testTheRungResolvesTheAlternativePlanRatherThanThePrimary() throws {
        let recorder = ExecutorRecorder()
        let alternative = DNSResolverRuntimePlan(
            transport: .plainDNS,
            plainAddresses: ["1.1.1.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "alternative-test",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false)
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: Self.reply(rcode: 2), outcome: .success),
            tierOneFallbackPlan: alternative)

        _ = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.plainCallCount, 1, "the rung ran")
        XCTAssertEqual(
            recorder.lastPlainAddresses, ["1.1.1.1"],
            "the rung asks the ALTERNATIVE resolver — the primary's 9.9.9.9 would mean the "
                + "user's Alternative DNS selection was ignored")
    }

    /// The T1 rung runs the WHOLE ladder, not just its primary route.
    ///
    /// This is the fix for a chained user having a strictly shorter fallback chain than a
    /// DNS-only user asking the identical question. The rung used to be dispatched into
    /// `resolvePrimaryUpstream`, which runs "only the plan's primary route, including ordered
    /// endpoint failover but no cross-route fallback" — so the rung got one route and stopped.
    /// A DNS-only query with the same plan got the device and encrypted fallbacks beneath it.
    ///
    /// The field shape that forced it: a split-tunnel user on a train whose one resolver
    /// selection was Device DNS. T0 declines a name, the rung asks device resolvers captured
    /// at connect time on a tower the phone has since left, and there is nothing below the rung
    /// (founder, 2026-08-27;
    /// `lavasec-infra plans/2026-08-27-chained-resolver-adaptation-and-tier-three.md`).
    ///
    /// The EGRESS INTERFACE assertion is the half that is easy to get wrong. A fallback beneath a
    /// physical rung must also leave physically; reverting to `.providerDefault` would aim the
    /// rescue query back down the tunnel that just failed to answer it.
    func testTheTierOneRungRunsTheFullFallbackLadder() throws {
        let recorder = ExecutorRecorder()
        let alternative = DNSResolverRuntimePlan(
            transport: .plainDNS,
            plainAddresses: ["1.1.1.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "rung-with-ladder",
            deviceDNSFallbackAddresses: ["192.168.1.1"],
            shouldFallbackToDeviceDNS: true,
            usesDeviceDNSFallbackMode: false)
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            // T0 declines: SERVFAIL is a non-answer, which is what opens the rung.
            tunnelledResult: Self.plannedResult(response: Self.reply(rcode: 2), outcome: .success),
            // ...and the rung's own primary route then gets nothing back, which is what opens
            // the rung's device fallback. Before this change nothing opened.
            plainResult: DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: [
                    ResolverAttempt(address: "1.1.1.1", outcome: .timeout, transport: .plainDNS)
                ],
                transport: .plainDNS,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false),
            tierOneFallbackPlan: alternative)

        _ = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            recorder.plainCallCount, 1,
            "the rung asked its own resolver first — the ladder is BENEATH the rung, not "
                + "instead of it")
        XCTAssertEqual(
            recorder.deviceCallCount, 1,
            "and when that produced nothing the rung fell through to the device fallback. Zero "
                + "here is the defect: a chained second opinion one route deep where DNS-only's "
                + "is three")
        XCTAssertEqual(recorder.lastDeviceAddresses, ["192.168.1.1"])
        XCTAssertEqual(
            recorder.lastDeviceEgressInterface, .physical,
            "a fallback beneath a PHYSICAL rung must also leave physically — `.providerDefault` "
                + "would send the rescue back down the tunnel that just declined the name")
    }

    /// The rung's ladder reaches the encrypted fallback too, and the gate that used to refuse it
    /// keeps refusing the case it was actually written for.
    ///
    /// `tunnelledPlainDNSRoute() == nil` was a proxy for "this would re-enter T0". It is now
    /// stated directly as `!rung.consultsTunnelledRoute`, which is false for `.planned` (so the
    /// re-entry PR #590 fixed stays fixed — see
    /// `testTheEncryptedFallbackDoesNotReRunTheChainedLadder`) and true for the rung, which
    /// cannot re-enter anything because the T0 block is unreachable from it.
    func testTheRungsLadderReachesTheEncryptedFallback() throws {
        let recorder = ExecutorRecorder()
        let alternative = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "rung-encrypted-ladder",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false,
            shouldFallbackToEncrypted: true,
            encryptedFallbackEndpoints: [DNSResolverRuntimePlan.defaultEncryptedFallbackEndpoint],
            treatsResolverRejectionAsFallbackTrigger: true)
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: Self.reply(rcode: 2), outcome: .success),
            // THE DEVICE EXECUTOR, not the plain one. A `.deviceDNS` plan is routed to
            // `executors.resolveDevice`, so overriding `plainResult` here would leave the rung's
            // primary succeeding and the fallback correctly unreached — a test that passes for
            // the wrong reason.
            deviceResult: DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: [
                    ResolverAttempt(address: "10.0.0.1", outcome: .timeout, transport: .deviceDNS)
                ],
                transport: .deviceDNS,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false),
            tierOneFallbackPlan: alternative)

        _ = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            recorder.tunnelledCallCount, 1,
            "T0 consulted once — the rung must not re-enter it")
        XCTAssertEqual(
            recorder.dohCallCount, 1,
            "the rung's stale device resolver timed out and the encrypted fallback rescued it. "
                + "This is the T2 a chained user did not have")
    }

    /// DNS-only's device fallback still leaves on the PROVIDER'S OWN MODE.
    ///
    /// `executors.resolveDevice`'s egress argument used to be the literal `.providerDefault`,
    /// pinned as source text by
    /// `PacketTunnelDNSRuntimeSourceTests.testResolverFallbackRunsInlineToAvoidQueueStarvation`
    /// precisely so a later edit could not conflate this ladder with the T1 rung's. The rung
    /// now shares the ladder (`INV-CHAIN-7`), so the argument is `rung.egressInterface` and the
    /// literal is gone.
    ///
    /// The GUARANTEE is not gone, and this asserts it where text cannot be argued with: for a
    /// DNS-only resolution the interface must still be `.providerDefault`. If a future change
    /// made the rung's `.physical` leak into the primary path, every DNS-only user's device
    /// fallback would start bypassing the provider's mode — silently, because nothing else looks.
    func testTheDNSOnlyDeviceFallbackStillFollowsTheProvidersMode() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .dnsOnlyMode,
            // No tunnelled route and no rung: this is the DNS-only ladder, the other caller.
            tunnelledRoute: nil,
            plainResult: DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: [
                    ResolverAttempt(address: "9.9.9.9", outcome: .timeout, transport: .plainDNS)
                ],
                transport: .plainDNS,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false),
            tierOneFallbackPlan: nil)
        let plan = DNSResolverRuntimePlan(
            transport: .plainDNS,
            plainAddresses: ["9.9.9.9"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "dns-only-device-fallback",
            deviceDNSFallbackAddresses: ["192.168.1.1"],
            shouldFallbackToDeviceDNS: true,
            usesDeviceDNSFallbackMode: false)

        _ = resolveUpstreamSync(orchestrator, plan: plan)

        XCTAssertEqual(recorder.deviceCallCount, 1, "the DNS-only device fallback still runs")
        XCTAssertEqual(
            recorder.lastDeviceEgressInterface, .providerDefault,
            "and still follows the provider's own mode — `.physical` here would be the rung's "
                + "interface leaking into the primary path")
    }

    /// The rung reports its outcome, because nothing else can tell the counters it happened.
    ///
    /// The tunnelled route carries no T1 set, and the T0 verdict carries no T1 terms
    /// at all since they were deleted with it (the plan's S3). This field is the ONLY mutation
    /// path for the chained fallback counters. Without it every physical rung, successful rescues
    /// included, would leave the panel on "Ready — not needed yet" and the field telemetry at
    /// zero (Codex, PR #590).
    ///
    /// The three cases are the three the panel distinguishes, and a fourth that must NOT be one:
    /// a rung the allowance refused never reached the wire, and counting local refusals as
    /// attempts is what once had the panel blaming the peer for queries it was never sent.
    func testTheRungReportsItsOutcomeForTheFallbackCounters() throws {
        func rungResult(_ outcome: ResolverAttemptOutcome, response: Data?) -> DNSResolutionResult {
            DNSResolutionResult(
                response: response,
                successfulResolverAddress: response == nil ? nil : "1.1.1.1",
                attempts: [
                    ResolverAttempt(address: "1.1.1.1", outcome: outcome, transport: .plainDNS)
                ],
                transport: .plainDNS,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false)
        }
        let cases: [(ResolverAttemptOutcome, Data?, ResolverOrchestrator.TierOneRungOutcome)] = [
            (.success, Self.reply(rcode: 0), .served),
            (.success, Self.reply(rcode: 2), .answered),
            (.truncatedAnswer, nil, .answered),
            (.timeout, nil, .attempted),
            (.receiveFailed, nil, .attempted)
        ]

        for (outcome, response, expected) in cases {
            let orchestrator = Self.orchestrator(
                recorder: ExecutorRecorder(),
                egressAllowance: .chainedSplitTunnelMode,
                tunnelledRoute: try Self.chainedRoute(),
                tunnelledResult: Self.plannedResult(
                    response: Self.reply(rcode: 2), outcome: .success),
                plainResult: rungResult(outcome, response: response))

            let evidence = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())?.tierOneRung
            XCTAssertEqual(
                evidence?.outcome, expected,
                "\(outcome) must report \(expected) — the panel tells these three apart")
            // STAMPED WITH THE SESSION THE RUNG RAN UNDER. Without these the provider's guard is
            // a fresh read compared against itself, so a late rung from an ended session credits
            // whichever session is live (Codex, PR #590).
            XCTAssertEqual(evidence?.originatingLifecycle, 7, "the route's lifecycle, carried")
            XCTAssertEqual(evidence?.originatingLatchEpoch, 3, "and its latch epoch")
        }
    }

    /// A RELATCH MID-LADDER STOPS THE RUNG'S DEVICE LEG FROM EGRESSING.
    ///
    /// The window is real and it is seconds long: the rung's selection spends its full timeout,
    /// and its device leg is admitted afterwards by a `shouldFallbackToDeviceDNS` read from a plan
    /// captured BEFORE that timeout. Turn device fallback off during it and the leg still went to
    /// the device resolver — `INV-DNS-1`'s direction reversed, and the PR #575 privacy failure one
    /// rung down (Codex P2, PR #599 → PR #608).
    ///
    /// `admittedAtEpoch` does not cover this: it names the tunnel LIFECYCLE, which a relatch does
    /// not move, so every `admissionIsCurrent` guard passes straight through. T0 is fenced
    /// because its route seals a latch epoch the executor validates per attempt; the rung's plan
    /// carried no such token until this change.
    func testARelatchStopsTheRungsDeviceLegFromEgressing() throws {
        let recorder = ExecutorRecorder()
        // Latch epoch 3 opens the rung; the reload lands while the selection is timing out, so
        // every later read sees epoch 4.
        let routes = RouteSequenceBox([
            try Self.chainedRoute(),
            try Self.chainedRoute(latchEpoch: 4)
        ])
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRouteProvider: { routes.next() },
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            plainResult: Self.wireResult(
                address: "9.9.9.9", outcome: .timeout, transport: .plainDNS, response: nil),
            tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            recorder.plainCallCount, 1,
            "the selection ran — it was admitted under the latch that was installed then")
        XCTAssertEqual(
            recorder.deviceCallCount, 0,
            "but the device leg must NOT egress under a data path that has been replaced")
        // FAILS CLOSED. Refusing the leg leaves the selection's own failure, which folds onto
        // T0's answer exactly as a failed device leg would.
        XCTAssertEqual(
            result?.attempts.map(\.address), ["10.64.0.1", "9.9.9.9"],
            "and the refusal adds no attempt of its own — nothing was sent")
        XCTAssertEqual(
            result?.tierOneRung?.outcome, .attempted,
            "the selection's own verdict is unchanged: it did attempt, and it did not answer")
    }

    /// THE RUNG'S DATA-PATH TOKEN REACHES THE EXECUTORS, which is where the wire actually is.
    ///
    /// PR #608 fenced every boundary the ORCHESTRATOR owns — each endpoint iteration and before
    /// each fallback leg — but the token stopped there. A multi-address plain or device plan walks
    /// its remaining addresses INSIDE one `resolvePlain` / `resolveDevice` call, which saw only the
    /// lifecycle epoch, and a relatch does not move that. So the walk continued under a policy the
    /// user had already replaced, one wire attempt per address, sending to the device resolver they
    /// had just switched off (Codex P2, PR #608 → PR #610).
    ///
    /// The provider validates it at the same socket seam it already validates the lifecycle epoch
    /// at, which is the last point before the datagram leaves. This asserts the token gets there;
    /// `TunnelDataPathLatchSourceTests` pins what the provider does with it.
    func testTheRungsLatchTokenReachesThePlainAndDeviceExecutors() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(latchEpoch: 9),
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            plainResult: Self.wireResult(
                address: "9.9.9.9", outcome: .timeout, transport: .plainDNS, response: nil),
            tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())

        _ = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            recorder.lastPlainLatchEpoch, .some(9),
            "the selection's executor gets the latch the rung was admitted under")
        XCTAssertEqual(
            recorder.lastDeviceLatchEpoch, .some(9),
            "and so does its device leg — the privacy-critical half of the same walk")
    }

    /// THE TOKEN ALSO REACHES THE ENCRYPTED EXECUTORS, whose transports queue.
    ///
    /// PR #610 carried the rung's data path to the plain and device seams. The encrypted ones were
    /// left: `DoTConnection` and `DoQConnection` append to a pending list and send only after the
    /// query ahead of them finishes and the handshake completes, so a query can reach the wire
    /// seconds after every gate above it passed (Codex P2, PR #608 → PR #611).
    ///
    /// Asserted on DoH because the shared helper's DoH executor is the one that records; the DoT
    /// and DoQ executors take the token in the same position and the transports assert their own
    /// refusal behaviour directly (`DoTTransportLifecycleTests`).
    func testTheRungsLatchTokenReachesTheEncryptedExecutors() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: nil, outcome: .timeout)],
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(latchEpoch: 11),
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            tierOneFallbackPlan: Self.dohPlan(endpointHosts: ["one.example"]))

        _ = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            recorder.lastEncryptedLatchEpoch, .some(11),
            "the encrypted executor gets the latch the rung was admitted under, so its transport "
                + "can refuse at the send rather than trusting the enqueue")
    }

    /// ...AND A DNS-ONLY RESOLUTION CARRIES NONE.
    ///
    /// `.planned` has no latch token, and the provider's check passes anything without one without
    /// reading state at all. Asserted because the alternative failure is silent: a token leaking
    /// onto the DNS-only ladder would make every device fallback refusable by a relatch that has
    /// nothing to do with it.
    ///
    /// `.some(nil)` rather than `nil` — the executor WAS called and carried no token, which is a
    /// different fact from never having been called.
    func testADNSOnlyResolutionCarriesNoLatchToken() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .dnsOnlyMode,
            tunnelledRoute: nil,
            plainResult: Self.wireResult(
                address: "9.9.9.9", outcome: .timeout, transport: .plainDNS, response: nil),
            tierOneFallbackPlan: nil)

        _ = resolveUpstreamSync(orchestrator, plan: Self.rungPlanWithDeviceFallback())

        XCTAssertEqual(
            recorder.lastPlainLatchEpoch, .some(nil),
            "a DNS-only selection is called, and carries no data-path token")
        XCTAssertEqual(
            recorder.lastDeviceLatchEpoch, .some(nil),
            "and neither does its device fallback — the ladder is untouched by the rung's fence")
    }

    /// ...INCLUDING THROUGH THE ENCRYPTED TRANSPORTS.
    ///
    /// The same negative one transport over: a token leaking onto DNS-only encrypted queries would
    /// make every DoH/DoT/DoQ lookup on the device refusable by a relatch that has nothing to do
    /// with it, and the plain-path negative above would not notice.
    func testADNSOnlyEncryptedResolutionCarriesNoLatchToken() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: nil, outcome: .timeout)],
            egressAllowance: .dnsOnlyMode,
            tunnelledRoute: nil,
            tierOneFallbackPlan: nil)

        _ = resolveUpstreamSync(
            orchestrator, plan: Self.dohPlan(endpointHosts: ["one.example"]))

        XCTAssertEqual(
            recorder.lastEncryptedLatchEpoch, .some(nil),
            "a DNS-only encrypted query is sent, and carries no data-path token")
    }

    /// ...AND EVERY ENDPOINT IS FENCED, not only the first.
    ///
    /// THE HALF THE FIRST CUT MISSED, and it is the longer window of the two. The rung's encrypted
    /// ladder re-enters itself per endpoint, and each iteration follows a wire attempt that took
    /// real time — a DoH/DoT/DoQ list can spend seconds walking. Guarding only before the ladder
    /// starts left every endpoint after the first sending from a plan the user had already
    /// replaced (Codex P2, PR #608).
    ///
    /// The PR body originally described the selection's window as "near-zero", which was wrong:
    /// it is near-zero only for a single-endpoint plain plan.
    func testARelatchStopsTheRungsLaterEndpointsFromEgressing() throws {
        let recorder = ExecutorRecorder()
        // Epoch 3 opens the rung and admits the FIRST endpoint; the reload lands during its
        // attempt, so the walk to the second endpoint sees epoch 4.
        let routes = RouteSequenceBox([
            try Self.chainedRoute(),
            try Self.chainedRoute(),
            try Self.chainedRoute(latchEpoch: 4)
        ])
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [
                DNSTransportResponse(response: nil, outcome: .timeout),
                DNSTransportResponse(response: nil, outcome: .timeout)
            ],
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRouteProvider: { routes.next() },
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            tierOneFallbackPlan: Self.dohPlan(endpointHosts: ["one.example", "two.example"]))

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            recorder.dohCallCount, 1,
            "the first endpoint was admitted under the latch installed then; the second must not "
                + "be sent from a plan that has since been replaced")
        XCTAssertEqual(
            result?.attempts.map(\.address),
            ["10.64.0.1", "doh:https://one.example/dns-query"],
            "the endpoint that really ran stays in the record, and the abandoned one adds nothing")
    }

    /// ...AND AN UNCHANGED LATCH STILL LETS IT THROUGH.
    ///
    /// The negative half. A fence that refused every device leg would silently delete the rung's
    /// ladder — the feature PR #596 added — and every assertion above would still pass.
    func testAnUnchangedLatchStillLetsTheRungsDeviceLegRun() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            plainResult: Self.wireResult(
                address: "9.9.9.9", outcome: .timeout, transport: .plainDNS, response: nil),
            tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())

        _ = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            recorder.deviceCallCount, 1,
            "the latch never moved, so the rung's ladder runs exactly as before")
    }

    /// A DNS-ONLY RESOLUTION IS NOT FENCED BY THIS AT ALL.
    ///
    /// `.planned` carries no latch token, so `rungLatchIsCurrent` passes it through without even
    /// consulting the route. Asserted because the guard sits on the shared ladder path: a version
    /// that refused `.planned` whenever chained mode was absent would break every DNS-only
    /// fallback on the device, and no chained test would notice.
    func testTheLatchFenceDoesNotTouchTheDNSOnlyLadder() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .dnsOnlyMode,
            // No chained route at all — the shape every DNS-only user is in.
            tunnelledRoute: nil,
            plainResult: Self.wireResult(
                address: "9.9.9.9", outcome: .timeout, transport: .plainDNS, response: nil),
            tierOneFallbackPlan: nil)

        _ = resolveUpstreamSync(orchestrator, plan: Self.rungPlanWithDeviceFallback())

        XCTAssertEqual(
            recorder.deviceCallCount, 1,
            "the DNS-only device fallback is untouched by the rung's fence")
    }

    /// A RESCUE BY THE RUNG'S OWN FALLBACK IS NOT THE SELECTION'S RESCUE.
    ///
    /// Since PR #596 the rung runs the FULL ladder, so `rung.response` can come from the rung's
    /// device-DNS or encrypted leg rather than from the resolver the user picked. The counters
    /// were derived from the MERGED result, so a selection that answered nothing was counted
    /// `.served` the moment a fallback leg rescued the query: `chainedFallbackRescueCount` moved,
    /// both falling streaks reset, and the panel rendered `.working(rescues:)` for a dead
    /// resolver. `.notForwarded` and `.answeringWithoutResolving` became unreachable — the two
    /// verdicts that name the failure the user actually has (PR #606).
    ///
    /// BOTH HALVES ARE ASSERTED, because they fail differently. The client must still receive the
    /// fallback's answer — the rescue is a real rescue and suppressing it would be a worse bug
    /// than the one being fixed — while the counters must describe the selection, which failed.
    func testARescueByTheRungsOwnFallbackIsNotCreditedToTheSelection() throws {
        let orchestrator = Self.orchestrator(
            recorder: ExecutorRecorder(),
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            // The user's chosen alternative resolver: a datagram left, nothing came back.
            plainResult: Self.wireResult(
                address: "9.9.9.9", outcome: .timeout, transport: .plainDNS, response: nil),
            // The rung's own device leg rescues it.
            deviceResult: Self.wireResult(
                address: "192.168.1.1", outcome: .success, transport: .deviceDNS,
                response: Self.reply(rcode: 0)),
            tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            result?.response, Self.reply(rcode: 0),
            "the client still gets the rescue — the answer is real whoever produced it")
        // WHICH LEG PRODUCED IT, now asserted three ways. `deviceDNSFallbackSucceeded` was
        // dropped by `merging` when PR #606 was written, so that PR could only assert the resolver
        // address and transport and filed the gap; PR #612 carries the flag through, and this is
        // the assertion that gap was standing in for.
        XCTAssertEqual(
            result?.deviceDNSFallbackSucceeded, true,
            "the merged result records that a device leg produced the answer, which is what "
                + "`ResolverHealthOrganicEvidence` reads to avoid crediting the selection")
        XCTAssertEqual(
            result?.successfulResolverAddress, "192.168.1.1",
            "the answer came from the device leg, and the merge says so")
        XCTAssertEqual(
            result?.transport, .deviceDNS,
            "on the device leg's transport, not the selection's")
        XCTAssertEqual(
            result?.tierOneRung?.outcome, .attempted,
            "but the selection answered nothing, so the panel must not count a rescue for it")
        // AND IT SURVIVES ONTO THE MERGED RESULT. `merging` is the one rebuild that does not copy
        // its inputs field by field, so the stamp was dropped there while every doc comment said
        // it is carried — leaving the public property nil at the only point a caller can read it
        // (Codex P2, PR #606).
        XCTAssertEqual(
            result?.tierOneSelectionOutcome, .attempted,
            "the merged result carries the selection's own verdict, as its documentation says")
        // AND THE LADDER'S VERDICT ALONGSIDE IT, which is the half the outage driver reads. The
        // selection failed and the user still got a real answer from the fallback they
        // configured; a consumer that could only see `.attempted` here would conclude the user
        // was blackholed and surrender chaining on behalf of someone who never lost a lookup.
        XCTAssertEqual(
            result?.tierOneRung?.ladderServed, true,
            "the rung as a whole served the name — a T2 rescue is still an answer")
    }

    /// A SELECTION THAT NEVER REACHED THE WIRE STILL REPORTS THE LADDER'S RESCUE.
    ///
    /// THE HOLE THIS CLOSES was in the shape where it matters most. `tierOneRung` used to be
    /// built through `rung.tierOneSelectionOutcome.map { … }`, and that verdict is `nil` — not
    /// `.attempted` — whenever the selection sent nothing: every endpoint `.backedOff`, or a
    /// mid-ladder relatch refusing the leg. So the whole evidence vanished exactly when the
    /// user's configured T2 was doing the work, the provider's `guard let evidence` returned
    /// before any credit, and repeated T0 misses still walked to surrender while T2 answered
    /// every query (Codex P1, PR #639).
    ///
    /// BOTH HALVES ARE ASSERTED, because they must disagree here: the ladder served, and the
    /// selection's own verdict stays nil so the counters keep refusing to credit a resolver that
    /// was never asked (PR #575).
    func testASuppressedSelectionStillReportsItsFallbacksRescue() throws {
        let recorder = ExecutorRecorder()
        // The selection's own result, built inline rather than through `wireResult`: its whole
        // point is an attempt that did NOT reach the wire, which is the opposite of what that
        // helper documents itself as producing.
        //
        // A RESULT, not `recorder.backedOffAddresses`. `isEndpointBackedOff` gates the ENDPOINT
        // ladder (DoH/DoT/DoQ); a plain selection hands its whole address list to `resolvePlain`,
        // which decides suppression itself and reports it in the attempt. Setting the recorder's
        // set instead left the selection resolving normally and the test asserting nothing.
        let suppressedSelection = DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: [
                ResolverAttempt(address: "9.9.9.9", outcome: .backedOff, transport: .plainDNS)
            ],
            transport: .plainDNS,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false)
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            plainResult: suppressedSelection,
            // ...and the rung's own device leg answers the name.
            deviceResult: Self.wireResult(
                address: "192.168.1.1", outcome: .success, transport: .deviceDNS,
                response: Self.reply(rcode: 0)),
            tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            result?.response, Self.reply(rcode: 0),
            "precondition: the device leg rescued the query, so the user has an answer")
        let evidence = try XCTUnwrap(
            result?.tierOneRung,
            "the rung ran and served — dropping its evidence loses the one rescue the outage "
                + "driver most needs to hear about")
        XCTAssertTrue(
            evidence.ladderServed,
            "the ladder served the name, so the user was not blackholed")
        XCTAssertNil(
            evidence.outcome,
            "and the selection never reached the wire, so the counters must still credit nothing")
    }

    /// Malformed replies cannot displace a usable reply or earn outage-recovery credit.
    func testAMalformedRungReplyIsNotCreditedAsARescue() throws {
        // Header-valid NOERROR claiming one answer record that is not there.
        var bytes = [UInt8](Self.reply(rcode: 0))
        bytes[6] = 0x00
        bytes[7] = 0x01
        let damaged = Data(bytes)
        XCTAssertFalse(
            DNSWireMessage.hasWellFormedResourceRecords(damaged),
            "precondition: this is the shape `completeForward` turns into SERVFAIL")

        let orchestrator = Self.orchestrator(
            recorder: ExecutorRecorder(),
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            plainResult: Self.wireResult(
                address: "9.9.9.9", outcome: .success, transport: .plainDNS, response: damaged),
            tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        let evidence = try XCTUnwrap(result?.tierOneRung, "the rung ran, so it reports")
        XCTAssertFalse(
            evidence.ladderServed,
            "a reply the client is handed SERVFAIL for must not disarm the outage cause")
        XCTAssertEqual(result?.response, Self.reply(rcode: 2),
            "retain the well-formed T0 failure when the rung offers only malformed bytes")
        XCTAssertEqual(result?.tierOneRung?.outcome, .answered,
            "the selected resolver replied but did not serve the query")
    }

    /// A well-formed error proves a reply arrived, but cannot earn serving credit.
    func testAFailureRCodeFromTheRungIsNotCreditedAsARescue() throws {
        for rcode: UInt8 in [1, 2, 4, 5, 16, 32] {
            let orchestrator = Self.orchestrator(
                recorder: ExecutorRecorder(),
                egressAllowance: .chainedSplitTunnelMode,
                tunnelledRoute: try Self.chainedRoute(),
                tunnelledResult: Self.plannedResult(
                    response: Self.reply(rcode: 2), outcome: .success),
                plainResult: Self.wireResult(
                    address: "9.9.9.9", outcome: .success, transport: .plainDNS,
                    response: Self.reply(rcode: rcode)),
                tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())

            let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

            XCTAssertEqual(
                result?.tierOneRung?.ladderServed, false,
                "rcode \(rcode) is a failed lookup for the user — it must not disarm the cause")
        }
    }

    /// ...while NXDOMAIN IS a rescue, which is the edge the rcode gate must not overrun.
    ///
    /// An authoritative negative is a legitimate result: the user asked whether a name exists and
    /// was told, correctly, that it does not. Refusing credit for it would let a browser's
    /// ordinary stream of NXDOMAINs walk a perfectly healthy chain to surrender — the defect this
    /// PR exists to fix, re-entered through its own guard.
    func testANameThatDoesNotExistIsStillARescue() throws {
        let orchestrator = Self.orchestrator(
            recorder: ExecutorRecorder(),
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            plainResult: Self.wireResult(
                address: "9.9.9.9", outcome: .success, transport: .plainDNS,
                response: Self.reply(rcode: 3)),
            tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            result?.tierOneRung?.ladderServed, true,
            "an authoritative negative answered the user's question — the rung served it")
    }

    /// A RUNG THAT SERVED NOTHING SAYS SO, which is the other half of `ladderServed`.
    ///
    /// The flag has to be able to read false, or the outage driver's credit is unconditional and
    /// the tunnel-DNS cause can never declare again — trading a false surrender for a resolver
    /// that fails closed forever, which is the worse of the two (`INV-DNS-1`).
    func testARungThatServedNothingReportsTheLadderUnserved() throws {
        let orchestrator = Self.orchestrator(
            recorder: ExecutorRecorder(),
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            // Every leg of the ladder times out: the selection AND its device fallback.
            plainResult: Self.wireResult(
                address: "9.9.9.9", outcome: .timeout, transport: .plainDNS, response: nil),
            deviceResult: Self.wireResult(
                address: "192.168.1.1", outcome: .timeout, transport: .deviceDNS, response: nil),
            tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            result?.tierOneRung?.ladderServed, false,
            "nothing beneath T0 answered, so the rung is not evidence the user has DNS")
        XCTAssertEqual(
            result?.tierOneRung?.outcome, .attempted,
            "and the selection's own verdict agrees — a datagram left, nothing came back")
    }

    /// A RUNG'S FALLBACK FLAGS SURVIVE THE MERGE, so health scoring can tell who answered.
    ///
    /// `merging` rebuilds the T0/T1 result field by hand and dropped all four of the
    /// rung's fallback flags. `ResolverHealthOrganicEvidence` branches on
    /// `usedEncryptedFallback` and `deviceDNSFallbackSucceeded` to decide whether a resolution was
    /// a fallback or the SELECTED resolver answering — so with both false on every merged chained
    /// result, a T1 selection that never answered was scored `.selectedResolver` each time its
    /// own leg rescued the query. That credits a failing resolver with healthy resolutions,
    /// which is backwards for exactly the user whose alternative DNS is broken (PR #612).
    ///
    /// THE SPLIT IS THE POINT: the flags describing ACTIVITY union, and the ones describing THE
    /// ANSWER follow `served`. Asserted separately below, because a version that unioned all four
    /// would pass a test that only checked the rescue case.
    func testTheRungsFallbackFlagsSurviveTheMergeWhenItServed() throws {
        let orchestrator = Self.orchestrator(
            recorder: ExecutorRecorder(),
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            plainResult: Self.wireResult(
                address: "9.9.9.9", outcome: .timeout, transport: .plainDNS, response: nil),
            deviceResult: Self.wireResult(
                address: "192.168.1.1", outcome: .success, transport: .deviceDNS,
                response: Self.reply(rcode: 0)),
            tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            result?.deviceDNSFallbackAttempted, true,
            "the ladder reached the device leg — an activity fact, true whoever answered")
        XCTAssertEqual(
            result?.deviceDNSFallbackSucceeded, true,
            "and that leg produced the answer the client received")
    }

    /// ...AND THE ANSWER-DESCRIBING ONES DO NOT SURVIVE A RUNG THAT DID NOT SERVE.
    ///
    /// The half a blanket union would get wrong. Here the rung's device leg replies SERVFAIL, so
    /// `served` is false and T0's answer is the one the client receives — the device leg
    /// produced nothing it got. Carrying `deviceDNSFallbackSucceeded` through anyway would tell
    /// health scoring a fallback answered when the fallback did not.
    func testTheRungsAnswerFlagsDoNotSurviveARungThatDidNotServe() throws {
        let orchestrator = Self.orchestrator(
            recorder: ExecutorRecorder(),
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            plainResult: Self.wireResult(
                address: "9.9.9.9", outcome: .timeout, transport: .plainDNS, response: nil),
            deviceResult: Self.wireResult(
                address: "192.168.1.1", outcome: .success, transport: .deviceDNS,
                response: Self.reply(rcode: 2)),
            tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            result?.deviceDNSFallbackAttempted, true,
            "the leg still RAN, and that is an activity fact regardless of whose answer won")
        XCTAssertEqual(
            result?.deviceDNSFallbackSucceeded, false,
            "but it produced nothing the client received — T0's answer is the selected one")
    }

    /// ...and the FALLBACK'S REPLY IS NOT THE SELECTION'S REPLY EITHER.
    ///
    /// THE HALF THAT CANNOT BE DERIVED AFTER THE MERGE, which is why the selection's verdict is
    /// stamped rather than recomputed. `.served` could be recovered from `deviceDNSFallbackSucceeded`
    /// and `usedEncryptedFallback`; `.answered` vs `.attempted` cannot, because `attempts` is the
    /// selection's and the fallback's concatenated with no boundary. Here the device leg REPLIES
    /// (SERVFAIL), so the merged attempt list contains a `.success` outcome while the selection
    /// itself only ever timed out — and the old classifier read that as the selection replying.
    ///
    /// The difference is the diagnosis the operator is given: `.attempted` repeated is
    /// "your peer is not forwarding DNS", `.answered` repeated is "your resolver replies but
    /// cannot resolve". Only the first is true here.
    func testTheRungsFallbackReplyIsNotCountedAsTheSelectionReplying() throws {
        let orchestrator = Self.orchestrator(
            recorder: ExecutorRecorder(),
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            plainResult: Self.wireResult(
                address: "9.9.9.9", outcome: .timeout, transport: .plainDNS, response: nil),
            // A REPLY, not a rescue: the device leg answers SERVFAIL.
            deviceResult: Self.wireResult(
                address: "192.168.1.1", outcome: .success, transport: .deviceDNS,
                response: Self.reply(rcode: 2)),
            tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            result?.tierOneRung?.outcome, .attempted,
            "the SELECTION never replied; the reply in `attempts` belongs to the device leg")
        XCTAssertEqual(
            result?.attempts.map(\.address), ["10.64.0.1", "9.9.9.9", "192.168.1.1"],
            "and every leg's attempt still survives for the capture")
    }

    /// A SELECTION THAT SERVES IS STILL `.served`, fallback ladder present or not.
    ///
    /// The negative half of the two tests above: scoping the counters to the selection must not
    /// cost a real rescue its credit. Same plan, same device leg available — the selection simply
    /// answers first, so the fallback never runs.
    func testASelectionThatAnswersIsStillCreditedWithTheRescue() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(
                response: Self.reply(rcode: 2), outcome: .success),
            plainResult: Self.wireResult(
                address: "9.9.9.9", outcome: .success, transport: .plainDNS,
                response: Self.reply(rcode: 0)),
            tierOneFallbackPlan: Self.rungPlanWithDeviceFallback())

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(
            result?.tierOneRung?.outcome, .served,
            "the selection served the name — this is the rescue the feature exists for")
        XCTAssertEqual(
            result?.tierOneRung?.ladderServed, true,
            "and the ladder served it too — the selection IS the ladder when it answers first")
        XCTAssertEqual(
            recorder.deviceCallCount, 0,
            "and the device leg never ran, so there is nothing to misattribute")
    }

    /// ...and a DEVICE-DNS rung is SERVED and STAMPED, where it used to be refused and uncounted.
    ///
    /// THIS TEST ASSERTED THE OPPOSITE, and the inversion is the point of PR #592. It read: "a
    /// device-DNS plan is refused by the rung's allowance, so no datagram leaves" — true then,
    /// and the reason the evidence had to stay nil. The rung's allowance now permits every
    /// transport the user can pick, so a device-DNS selection reaches the wire like any other and
    /// its outcome is real evidence the panel may count.
    ///
    /// The invariant that test was protecting — a rung that never reached the wire must not grow
    /// the unanswered streak, or the panel reports "your VPN isn't forwarding" about a query
    /// nobody sent (the PR #575 failure, one tier along) — is unchanged and still covered, by the
    /// paths where no rung runs at all: `testNoRungRunsWhenTheUserHasNotOptedIntoATierOneFallback`
    /// and `testAResolutionWithoutARungReportsNoOutcome`. What is gone is the ability to reach it
    /// through an egress REFUSAL, because no shipping allowance refuses a rung's transport any
    /// more; `testAFullTunnelNeverRunsTheRung` covers the shape that still says no, and it says
    /// no by deriving no rung at all rather than by refusing one.
    func testADeviceDNSRungIsServedAndStampedRatherThanRefused() throws {
        let orchestrator = Self.orchestrator(
            recorder: ExecutorRecorder(),
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: Self.reply(rcode: 2), outcome: .success),
            tierOneFallbackPlan: Self.deviceDNSPlan())

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertNotEqual(
            result?.attempts.last?.outcome, .refusedByEgressPolicy,
            "the rung's allowance no longer refuses the transport the user selected")
        XCTAssertEqual(
            result?.tierOneRung?.outcome, .served,
            "a rung that reached the wire and answered is evidence the panel may count")
        // STAMPED WITH THE SESSION THE RUNG RAN UNDER, exactly as every other transport is —
        // without these the provider's guard compares a fresh read against itself and a late rung
        // from an ended session credits whichever session is live (Codex, PR #590).
        XCTAssertEqual(result?.tierOneRung?.originatingLifecycle, 7, "the route's lifecycle")
        XCTAssertEqual(result?.tierOneRung?.originatingLatchEpoch, 3, "and its latch epoch")
    }

    /// And a resolution with NO rung reports nothing, so the field cannot inflate the counters
    /// on the ordinary path.
    func testAResolutionWithoutARungReportsNoOutcome() {
        let orchestrator = Self.orchestrator(
            recorder: ExecutorRecorder(), egressAllowance: .dnsOnlyMode)

        XCTAssertNil(resolveUpstreamSync(orchestrator, plan: Self.plainPlan())?.tierOneRung)
    }

    /// The encrypted device-DNS fallback must NOT re-enter the chained ladder.
    ///
    /// The hoist put the tunnelled T0 consult at the top of `resolvePrimaryUpstream`, ahead
    /// of the transport gate that used to refuse this path under `.chainedMode`. So the outer
    /// fallback's re-entry consulted the tunnel a SECOND time, ignored the encrypted fallback
    /// plan it was called with, and could spawn a second T1 rung — another full ladder, and
    /// the rung's evidence counted twice in the counters this PR exists to make trustworthy
    /// (Codex, PR #590).
    ///
    /// THE SETUP IS THE TEST. A first version of this passed with the gate deleted, because it
    /// never drove the re-entry at all (Kilo, PR #590): the rung SERVED, so the merged result
    /// carried a response, `isWedgeRejection` was false with the default trigger, and
    /// `deviceUsable` was therefore true — the branch returned at its own guard before reaching
    /// the re-entrant call. Two things are required to reach it, and both are set below:
    ///
    /// - `treatsResolverRejectionAsFallbackTrigger: true`, so a SERVFAIL counts as a wedge
    ///   rejection rather than an authoritative answer;
    /// - a rung that serves NOTHING, so `merging` keeps T0's SERVFAIL as the response — a
    ///   complete DNS header so the fixture exercises a real resolver error.
    ///
    /// Only then is `deviceUsable` false and the re-entry live.
    ///
    /// Asserted on the CALL COUNTS, which are the only assertions that can observe a duplicate
    /// ladder. `dohCallCount` cannot: the re-entry's DoH plan is refused by the chained allowance
    /// before the executor runs, so it stays zero whether or not the gate exists.
    func testTheEncryptedFallbackDoesNotReRunTheChainedLadder() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: Self.reply(rcode: 2), outcome: .success),
            // The rung reaches the wire and gets nothing back, so T0's SERVFAIL survives the
            // merge and becomes the response the outer branch judges.
            plainResult: DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: [
                    ResolverAttempt(address: "9.9.9.9", outcome: .timeout, transport: .plainDNS)
                ],
                transport: .plainDNS,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false))
        let plan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device-chained-rung",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false,
            shouldFallbackToEncrypted: true,
            encryptedFallbackEndpoints: [DNSResolverRuntimePlan.defaultEncryptedFallbackEndpoint],
            treatsResolverRejectionAsFallbackTrigger: true
        )

        let result = resolveUpstreamSync(orchestrator, plan: plan)

        // WITHOUT THE GATE both of these are 2: the re-entry runs the hoisted consult again and
        // opens a second rung. They are the whole point of the test.
        XCTAssertEqual(
            recorder.tunnelledCallCount, 1,
            "the tunnelled route must be consulted ONCE — a second consult is a duplicate ladder")
        XCTAssertEqual(
            recorder.plainCallCount, 1,
            "and the T1 rung exactly once, or its evidence is counted twice")
        // Not a detector, kept as a statement of the surviving contract: the encrypted fallback
        // never egresses while chained, gate or no gate.
        XCTAssertEqual(recorder.dohCallCount, 0)
        XCTAssertEqual(
            result?.response, Self.reply(rcode: 2),
            "the chained ladder's own answer completes the resolution")
    }

    /// A LOCAL refusal of T0 must not open the physical rung.
    ///
    /// The rung exists for one thing: the UPSTREAM's own resolver could not serve the name. A
    /// T0 result with no reply is only evidence of that if a datagram actually left the
    /// device. Two ordinary shapes never do — `.backedOff`, where the provider returns every
    /// address backed off WITHOUT running the tunnelled loop, and `.socketUnavailable` /
    /// `.tunnelInterfaceUnavailable` / `.physicalInterfaceUnavailable`, which fire on a local
    /// interface condition (the startup `virtualInterface` lag, or F2's missing physical pin).
    ///
    /// Opening the rung on those put DNS on the PHYSICAL interface because of a LOCAL condition,
    /// for the whole backoff window or the whole connect gap, while the upstream had never been
    /// asked (adversarial review, PR #590). It is the same error PR #575 fixed one layer up, where
    /// counting local refusals made the panel blame the peer for queries never sent.
    func testALocalRefusalOfTierZeroDoesNotOpenThePhysicalRung() throws {
        for outcome: ResolverAttemptOutcome in [
            .backedOff, .socketUnavailable, .tunnelInterfaceUnavailable,
            .physicalInterfaceUnavailable, .sendFailed,
        ] {
            let recorder = ExecutorRecorder()
            let orchestrator = Self.orchestrator(
                recorder: recorder,
                egressAllowance: .chainedSplitTunnelMode,
                tunnelledRoute: try Self.chainedRoute(),
                tunnelledResult: Self.plannedResult(response: nil, outcome: outcome))

            let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

            XCTAssertEqual(recorder.tunnelledCallCount, 1, "T0 is still consulted")
            XCTAssertEqual(
                recorder.plainCallCount, 0,
                "\(outcome) never reached the wire — the upstream was not asked, so it is no "
                    + "evidence the upstream declined")
            XCTAssertNil(result?.response, "T0's own non-answer stands and fails closed")
            XCTAssertNil(result?.tierOneRung, "and no rung evidence is fabricated")
        }
    }

    /// ...while a T0 non-answer that DID reach the wire still opens it, so the narrowing did
    /// not simply disable the feature.
    func testATierZeroNonAnswerThatReachedTheWireStillOpensTheRung() throws {
        for outcome: ResolverAttemptOutcome in [.timeout, .receiveFailed] {
            let recorder = ExecutorRecorder()
            let orchestrator = Self.orchestrator(
                recorder: recorder,
                egressAllowance: .chainedSplitTunnelMode,
                tunnelledRoute: try Self.chainedRoute(),
                tunnelledResult: Self.plannedResult(response: nil, outcome: outcome))

            _ = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

            XCTAssertEqual(
                recorder.plainCallCount, 1,
                "\(outcome) is silence AFTER a send — that is the upstream failing to serve")
        }
    }

    /// A FULL tunnel keeps the suspension whole: T0 SERVFAILs and nothing leaves physically.
    /// The client receives the upstream's real failure, not a fallback answer.
    func testAFullTunnelNeverRunsTheRung() throws {
        let recorder = ExecutorRecorder()
        let servfail = Self.reply(rcode: 2)
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: servfail, outcome: .success))

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.tunnelledCallCount, 1)
        XCTAssertEqual(recorder.plainCallCount, 0, "full tunnel hides the destination — nothing leaks")
        XCTAssertEqual(result?.response, servfail)
    }

    /// AUTHORITATIVE NEGATIVES ARE T0'S TO GIVE, and the rung must not second-guess them.
    ///
    /// This is the PR #589 failure arriving by a different route: re-asking a public resolver
    /// about a name the upstream's own resolver just answered negatively is how a split-DNS name
    /// receives a stranger's NXDOMAIN instead of its real negative. Only a failed or missing reply opens the rung.
    func testAnAuthoritativeNegativeFromTierZeroIsNotSecondGuessed() throws {
        for rcode: UInt8 in [0, 3] {  // NOERROR (incl. NODATA) and NXDOMAIN
            let recorder = ExecutorRecorder()
            let negative = Self.reply(rcode: rcode)
            let orchestrator = Self.orchestrator(
                recorder: recorder,
                egressAllowance: .chainedSplitTunnelMode,
                tunnelledRoute: try Self.chainedRoute(),
                tunnelledResult: Self.plannedResult(response: negative, outcome: .success))

            let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

            XCTAssertEqual(
                recorder.plainCallCount, 0,
                "rcode \(rcode) is T0 answering — re-asking it replaces a real negative")
            XCTAssertEqual(result?.response, negative)
        }
    }

    /// T0's silence opens the rung too — nothing came back that the client could be given.
    func testTierZeroSilenceOpensTheRung() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: nil, outcome: .timeout))

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.plainCallCount, 1)
        XCTAssertEqual(result?.response, ExecutorRecorder.plainResponse)
    }

    /// When the rung serves nothing, T0'S REAL ANSWER is what the client gets — the same rule
    /// the tunnelled loop applies internally. A genuine SERVFAIL from the upstream is worth more
    /// than a synthesized one, and a failed rung does not erase it.
    func testTheRungKeepsTierZerosAttemptsAndItsAnswerWhenNothingServed() throws {
        let recorder = ExecutorRecorder()
        let servfail = Self.reply(rcode: 2)
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: servfail, outcome: .success),
            // The rung reaches the wire and gets nothing back — the shape that makes T0's
            // real answer worth keeping.
            plainResult: DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: [
                    ResolverAttempt(address: "9.9.9.9", outcome: .timeout, transport: .plainDNS)
                ],
                transport: .plainDNS,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false))

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.tunnelledCallCount, 1)
        XCTAssertEqual(recorder.plainCallCount, 1, "the rung ran and came back empty")
        XCTAssertEqual(
            result?.response, servfail,
            "the upstream's real failure survives a rung that served nothing")
        XCTAssertEqual(
            result?.attempts.first?.address, "10.64.0.1", "T0's attempt is not dropped")
        XCTAssertGreaterThan(
            result?.attempts.count ?? 0, 1, "the rung's own attempt is appended, not swallowed")
    }

    /// The TCP flags UNION across the rungs rather than following the served answer.
    ///
    /// They are activity counters, not a description of what the client got:
    /// `ResolverHealthOrganicEvidence.applyAttemptMetrics` bumps `tcpFallbackAttemptCount` once
    /// per resolution that attempted a TCP retry. So a retry T0 made is still a retry after
    /// the rung's answer wins, and dropping it would undercount the transport the counter exists
    /// to observe — which is why this does NOT reuse `served` the way `udpTruncated` does.
    ///
    /// The T0 shape here is deliberately one the tunnelled path cannot produce today
    /// (`TunnelledPlainDNSResolution` has no TCP rung and hard-codes both flags false). The merge
    /// contract is what is under test, so it is supplied through the executor seam: the assertion
    /// is that the union is written for the invariant, not for today's arithmetic.
    func testTheRungUnionsTheTCPFlagsRatherThanFollowingTheServedAnswer() throws {
        let recorder = ExecutorRecorder()
        let answer = Self.reply(rcode: 0)
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: [
                    ResolverAttempt(address: "10.64.0.1", outcome: .timeout, transport: .plainDNS)
                ],
                transport: .plainDNS,
                udpTruncated: true,
                tcpFallbackAttempted: true,
                tcpFallbackSucceeded: true),
            // The rung serves, so `served` is true and every answer-shaped field takes the
            // rung's value. The TCP flags must not.
            plainResult: DNSResolutionResult(
                response: answer,
                successfulResolverAddress: "1.1.1.1",
                attempts: [
                    ResolverAttempt(address: "1.1.1.1", outcome: .success, transport: .plainDNS)
                ],
                transport: .plainDNS,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false))

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(result?.response, answer, "the rung served, so its answer wins")
        XCTAssertEqual(
            result?.udpTruncated, false,
            "truncation still follows the answer the client actually got")
        XCTAssertEqual(
            result?.tcpFallbackAttempted, true,
            "T0's TCP attempt is a fact about the resolution and survives the rung's answer")
        XCTAssertEqual(
            result?.tcpFallbackSucceeded, true,
            "and so does its outcome — the counters are per-resolution, not per-rung")
    }

    /// THE RUNG ASKS FOR THE PHYSICAL INTERFACE, and the request reaches the executor.
    ///
    /// The allowance is only half the decision: the socket layer separately picks an interface,
    /// and in the packet tunnel it pins to the utun whenever chained is latched. Without this
    /// parameter the rung's datagram went to the peer and timed out — the exact failure the rung
    /// exists to remove (Codex, PR #590). Nothing else in the suite can see which interface a
    /// resolution left on, which is why this asserts on the executor's argument.
    func testTheRungAsksForThePhysicalInterface() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: Self.reply(rcode: 2), outcome: .success))

        _ = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.lastPlainEgressInterface, .physical)
    }

    /// ...and an ordinary DNS-only resolution does not, so nothing outside the rung changes.
    func testADNSOnlyResolutionKeepsTheProviderDefaultInterface() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, egressAllowance: .dnsOnlyMode)

        _ = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.lastPlainEgressInterface, .providerDefault)
    }

    /// A T1 SERVFAIL must NOT displace T0's answer.
    ///
    /// `response != nil` is not the bar: a SERVFAIL is a packet, so it would count as served and
    /// replace T0's real answer, resolver address and transport — with a failure of exactly
    /// the class that opened the rung in the first place (Codex, PR #590). Both halves of the
    /// contract read the same predicate.
    func testATierOneServerFailureDoesNotDisplaceTierZero() throws {
        for rcode: UInt8 in [2, 5] {
            let recorder = ExecutorRecorder()
            let plannedFailure = Self.reply(rcode: 2)
            let orchestrator = Self.orchestrator(
                recorder: recorder,
                egressAllowance: .chainedSplitTunnelMode,
                tunnelledRoute: try Self.chainedRoute(),
                tunnelledResult: Self.plannedResult(
                    response: plannedFailure, outcome: .success),
                plainResult: DNSResolutionResult(
                    response: Self.reply(rcode: rcode),
                    successfulResolverAddress: "9.9.9.9",
                    attempts: [
                        ResolverAttempt(
                            address: "9.9.9.9", outcome: .success, transport: .plainDNS)
                    ],
                    transport: .plainDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false))

            let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

            XCTAssertEqual(recorder.plainCallCount, 1, "the rung ran")
            XCTAssertEqual(
                result?.response, plannedFailure,
                "rcode \(rcode) from the rung is not serving — T0's answer stands")
            XCTAssertEqual(
                result?.successfulResolverAddress, "10.64.0.1",
                "the serving address must not be credited to a resolver that failed")
        }
    }

    /// A complete rung answer is NOT flagged truncated because T0 was.
    ///
    /// T0 fails closed on a truncated answer, so the rung opens with `udpTruncated: true`
    /// behind it. Unioning the two flags returned a complete answer marked truncated, which
    /// `ResolverHealthOrganicEvidence` counts as a `udpTruncatedResponseCount` for a resolution
    /// that was never truncated (Kilo, PR #590).
    func testACompleteRungAnswerIsNotReportedAsTruncated() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            // The tunnelled loop's fail-closed truncation shape: no response, flag set.
            tunnelledResult: DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: [
                    ResolverAttempt(
                        address: "10.64.0.1", outcome: .truncatedAnswer, transport: .plainDNS)
                ],
                transport: .plainDNS,
                udpTruncated: true,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false))

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(result?.response, ExecutorRecorder.plainResponse, "the rung served")
        XCTAssertEqual(
            result?.udpTruncated, false,
            "the answer the client got was complete — flagging it truncated inflates the "
                + "truncated-response count")
    }

    /// ...and when the rung serves nothing, T0's truncation still stands: truncation was seen
    /// and no resolver completed, which is exactly the shape the counters exist to distinguish.
    func testTierZerosTruncationSurvivesARungThatServedNothing() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: [
                    ResolverAttempt(
                        address: "10.64.0.1", outcome: .truncatedAnswer, transport: .plainDNS)
                ],
                transport: .plainDNS,
                udpTruncated: true,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false),
            plainResult: DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: [
                    ResolverAttempt(address: "9.9.9.9", outcome: .timeout, transport: .plainDNS)
                ],
                transport: .plainDNS,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false))

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertNil(result?.response)
        XCTAssertEqual(result?.udpTruncated, true)
    }

    /// The rung NEVER reaches device DNS, whatever the plan says. That is the DHCP-assigned
    /// resolver — a different threat model (`LAV-87`) — and the derived allowance refuses it.
    /// A DEVICE-DNS SELECTION IS RESOLVED BY THE RUNG, on the physical interface.
    ///
    /// This replaces `testTheRungRefusesADeviceDNSPlan`, which pinned the opposite. The refusal
    /// conflated two acts: device DNS IMPOSED on the rung by a device-wide fallback episode
    /// (still forbidden, by `ignoresDeviceDNSFallbackMode` where the plan is built) and device
    /// DNS SELECTED by the user as their one resolver. Native Tailscale with MagicDNS and no
    /// global nameservers falls through to exactly those resolvers, so refusing it left a chained
    /// user worse off than running their VPN's own client (founder, 2026-08-27).
    ///
    /// The interface assertion is the load-bearing half: a device resolver is a LAN address, and
    /// the socket layer pins to the tunnel while chained unless told otherwise — so without
    /// `.physical` this rung is a guaranteed timeout rather than a fallback.
    func testTheRungResolvesADeviceDNSSelectionOnThePhysicalInterface() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedSplitTunnelMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: Self.reply(rcode: 2), outcome: .success),
            tierOneFallbackPlan: Self.deviceDNSPlan())

        let result = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.tunnelledCallCount, 1, "T0 is still tried first")
        XCTAssertEqual(recorder.deviceCallCount, 1, "the user's own selection is the rung")
        XCTAssertEqual(
            recorder.lastDeviceEgressInterface, .physical,
            "a LAN resolver sent through the peer is a guaranteed timeout")
        XCTAssertEqual(result?.response, ExecutorRecorder.deviceResponse)
    }

    /// FULL TUNNEL STILL REFUSES IT, because there is no rung there at all — the allowance, not
    /// the transport, is what decides.
    func testAFullTunnelStillRefusesADeviceDNSRung() throws {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            egressAllowance: .chainedMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: Self.reply(rcode: 2), outcome: .success),
            tierOneFallbackPlan: Self.deviceDNSPlan())

        _ = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.deviceCallCount, 0, "full tunnel has no physical path to offer")
    }

    func testTheTunnelledRouteRefusesToCarryNothing() {
        XCTAssertNil(
            ResolverOrchestrator.TunnelledPlainDNSRoute(resolverAddresses: [], originatingLifecycle: 7, originatingLatchEpoch: 3),
            "an empty route would hand the executor nowhere to resolve — unrepresentable, not a runtime case")
    }

    func testDeviceDNSPrimaryFallsBackToEncryptedWhenWedged() {
        let dohResponse = Data([0xCC])
        let box = ResultBox()

        let orchestrator = ResolverOrchestrator(executors: ResolverOrchestrator.Executors(
            isEndpointBackedOff: { _ in false },
            resolveDoH: { _, _, _, completion in
                completion(DNSTransportResponse(response: dohResponse, outcome: .success))
            },
            resolveDoT: { _, _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolveDoQ: { _, _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolvePlain: { _, addresses, transport, _, _, _ in
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .timeout, transport: transport)],
                    transport: transport,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveTunnelledPlain: { _, route in
                // Not the transport under test; a selection here is itself the failure.
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: route.resolverAddresses.first ?? "none", outcome: .unsupported, transport: .plainDNS)],
                    transport: .plainDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveDevice: { _, addresses, _, _, _, _ in
                // Primary Device DNS is wedged (no response).
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .timeout, transport: .deviceDNS)],
                    transport: .deviceDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            }
        ), egressAllowance: { .dnsOnlyMode }, tunnelledPlainDNSRoute: { nil }, admissionEpoch: { 1 },
            tierOneFallbackPlan: { nil })

        let endpoint = DNSResolverRuntimePlan.defaultEncryptedFallbackEndpoint
        let plan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false,
            shouldFallbackToEncrypted: true,
            encryptedFallbackEndpoints: [endpoint]
        )

        orchestrator.resolveUpstream(Data([0x01, 0x02]), plan: plan) { box.store($0) }

        // Device primary wedged → encrypted (Quad9 DoH) fallback carries the query.
        // The last recorded attempt is the Quad9 endpoint, proving DoH was hit.
        XCTAssertEqual(box.value?.attempts.last?.address, endpoint.cacheIdentifier)
        XCTAssertEqual(box.value?.attempts.last?.transport, .dnsOverHTTPS)
        XCTAssertEqual(box.value?.response, dohResponse)
        XCTAssertEqual(box.value?.transport, .dnsOverHTTPS)
        // Observable for diagnostics, and preserved through recordingDuration (the
        // provider applies it before recordUpstreamResult reads the flag).
        XCTAssertTrue(box.value?.usedEncryptedFallback ?? false)
        XCTAssertTrue(box.value?.recordingDuration(since: Date()).usedEncryptedFallback ?? false)
        // Encrypted fallback must NOT masquerade as the device-DNS fallback mode.
        XCTAssertFalse(box.value?.deviceDNSFallbackAttempted ?? true)
    }

    func testEncryptedFallbackIsNotUsedWhenDeviceDNSResolves() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder)
        let plan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false,
            shouldFallbackToEncrypted: true,
            encryptedFallbackEndpoints: [DNSResolverRuntimePlan.defaultEncryptedFallbackEndpoint]
        )

        let result = resolveUpstreamSync(orchestrator, plan: plan)

        // The shared factory's device executor succeeds → no DoH fallback attempted.
        XCTAssertEqual(result?.response, ExecutorRecorder.deviceResponse)
        XCTAssertEqual(recorder.dohCallCount, 0)
        XCTAssertFalse(result?.usedEncryptedFallback ?? true)
    }

    func testEncryptedPrimaryRefusedReplyDoesNotSpillToDeviceDNS() {
        // SERVFAIL/REFUSED from a configured encrypted resolver is an authoritative
        // verdict (DNSSEC validation / policy). The device-DNS fallback contract is
        // "no response only" — retrying such a reply on the less-filtered Device DNS
        // would change/leak the answer, so it must pass straight through.
        let refusedReply = Data([0x12, 0x34, 0x80, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: refusedReply, outcome: .success)]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true)
        )

        XCTAssertEqual(result?.response, refusedReply)
        XCTAssertEqual(result?.transport, .dnsOverHTTPS)
        XCTAssertEqual(recorder.deviceCallCount, 0, "A resolver-declared failure must not be retried on Device DNS.")
        XCTAssertFalse(result?.deviceDNSFallbackAttempted ?? true)
    }

    func testWholeCodeDeviceFallbackRequiresWedgeAndPreservesNegatives() {
        for code: UInt8 in [0, 1, 2, 3, 4, 5, 16, 32] {
            for wedged in [false, true] {
                let recorder = ExecutorRecorder()
                let reply = Self.reply(rcode: code)
                let fallback = Self.reply(rcode: 0)
                let orchestrator = Self.orchestrator(
                    recorder: recorder,
                    dohResults: [.init(response: fallback, outcome: .success)],
                    deviceResult: Self.wireResult(
                        address: "192.0.2.1", outcome: .success, transport: .deviceDNS, response: reply))
                let plan = DNSResolverRuntimePlan(
                    transport: .deviceDNS, plainAddresses: ["192.0.2.1"],
                    dohEndpoints: [], dotEndpoints: [], doqEndpoints: [], cacheIdentifier: "device",
                    deviceDNSFallbackAddresses: [], shouldFallbackToDeviceDNS: false,
                    usesDeviceDNSFallbackMode: false, shouldFallbackToEncrypted: true,
                    encryptedFallbackEndpoints: [DNSResolverRuntimePlan.defaultEncryptedFallbackEndpoint],
                    treatsResolverRejectionAsFallbackTrigger: wedged)
                let result = resolveUpstreamSync(orchestrator, plan: plan)
                let shouldFallback = wedged && code != 0 && code != 3
                XCTAssertEqual(recorder.dohCallCount, shouldFallback ? 1 : 0, "RCODE \(code), wedge \(wedged)")
                XCTAssertEqual(result?.response, shouldFallback ? fallback : reply)
            }
        }
    }

    func testWholeCodeChainedFallbackHonorsSplitAndFullEgress() throws {
        for code: UInt8 in [0, 1, 2, 3, 4, 5, 16, 32] {
            for split in [false, true] {
                let recorder = ExecutorRecorder()
                let reply = Self.reply(rcode: code)
                let orchestrator = Self.orchestrator(
                    recorder: recorder, egressAllowance: split ? .chainedSplitTunnelMode : .chainedMode,
                    tunnelledRoute: try Self.chainedRoute(),
                    tunnelledResult: Self.plannedResult(response: reply, outcome: .success))
                _ = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())
                XCTAssertEqual(recorder.tunnelledCallCount, 1)
                XCTAssertEqual(recorder.plainCallCount, split && code != 0 && code != 3 ? 1 : 0,
                               "RCODE \(code), split \(split)")
            }
        }
    }

    func testWholeCodeEncryptedErrorsNeverSpillToDeviceDNS() {
        for code: UInt8 in [1, 2, 4, 5, 16, 32] {
            let recorder = ExecutorRecorder()
            let reply = Self.reply(rcode: code)
            let orchestrator = Self.orchestrator(
                recorder: recorder, dohResults: [.init(response: reply, outcome: .success)])
            let result = resolveUpstreamSync(
                orchestrator, plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true))
            XCTAssertEqual(result?.response, reply)
            XCTAssertEqual(recorder.deviceCallCount, 0, "RCODE \(code)")
        }
    }

    func testStaleDeviceDNSRefusedReplyTriggersEncryptedFallback() {
        let dohResponse = Data([0xDD])
        let box = ResultBox()

        // A reachable-but-stale Device-DNS resolver answers with REFUSED (rcode 5):
        // a non-nil wire packet with a `.success` attempt outcome. The fallback guard
        // must treat this as a failure, not hand the useless reply back to the client.
        let refusedReply = Data([0x12, 0x34, 0x80, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        let orchestrator = ResolverOrchestrator(executors: ResolverOrchestrator.Executors(
            isEndpointBackedOff: { _ in false },
            resolveDoH: { _, _, _, completion in
                completion(DNSTransportResponse(response: dohResponse, outcome: .success))
            },
            resolveDoT: { _, _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolveDoQ: { _, _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolvePlain: { _, addresses, transport, _, _, _ in
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .timeout, transport: transport)],
                    transport: transport,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveTunnelledPlain: { _, route in
                // Not the transport under test; a selection here is itself the failure.
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: route.resolverAddresses.first ?? "none", outcome: .unsupported, transport: .plainDNS)],
                    transport: .plainDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveDevice: { _, addresses, _, _, _, _ in
                // Stale resolver: reachable, returns a REFUSED packet (wire success).
                DNSResolutionResult(
                    response: refusedReply,
                    successfulResolverAddress: addresses.first,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .success, transport: .deviceDNS)],
                    transport: .deviceDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            }
        ), egressAllowance: { .dnsOnlyMode }, tunnelledPlainDNSRoute: { nil }, admissionEpoch: { 1 },
            tierOneFallbackPlan: { nil })

        let endpoint = DNSResolverRuntimePlan.defaultEncryptedFallbackEndpoint
        let plan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false,
            shouldFallbackToEncrypted: true,
            encryptedFallbackEndpoints: [endpoint],
            // Health has confirmed the resolver is broadly wedged, so a REFUSED reply
            // is treated as wedge evidence rather than an authoritative verdict.
            treatsResolverRejectionAsFallbackTrigger: true
        )

        orchestrator.resolveUpstream(Data([0x12, 0x34, 0x01, 0x00]), plan: plan) { box.store($0) }

        // The REFUSED reply is discarded in favor of the encrypted fallback answer.
        XCTAssertEqual(box.value?.response, dohResponse)
        XCTAssertEqual(box.value?.transport, .dnsOverHTTPS)
        XCTAssertTrue(box.value?.usedEncryptedFallback ?? false)
        XCTAssertEqual(box.value?.attempts.last?.address, endpoint.cacheIdentifier)
    }

    func testHealthyDeviceDNSRefusalIsHonoredNotSentToEncryptedFallback() {
        // A REFUSED reply on a resolver that is NOT health-confirmed as wedged is an
        // authoritative per-domain verdict (a managed-network block / DNSSEC failure).
        // It must pass straight through — not be re-asked on the encrypted fallback,
        // which would bypass the verdict and leak the lookup to Quad9.
        let refusedReply = Data([0x12, 0x34, 0x80, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let box = ResultBox()

        let orchestrator = ResolverOrchestrator(executors: ResolverOrchestrator.Executors(
            isEndpointBackedOff: { _ in false },
            resolveDoH: { _, _, _, completion in
                // Must NOT be reached: the refusal is honored, not escalated.
                completion(DNSTransportResponse(response: Data([0xEE]), outcome: .success))
            },
            resolveDoT: { _, _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolveDoQ: { _, _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolvePlain: { _, addresses, transport, _, _, _ in
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .timeout, transport: transport)],
                    transport: transport,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveTunnelledPlain: { _, route in
                // Not the transport under test; a selection here is itself the failure.
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: route.resolverAddresses.first ?? "none", outcome: .unsupported, transport: .plainDNS)],
                    transport: .plainDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveDevice: { _, addresses, _, _, _, _ in
                DNSResolutionResult(
                    response: refusedReply,
                    successfulResolverAddress: addresses.first,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .success, transport: .deviceDNS)],
                    transport: .deviceDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            }
        ), egressAllowance: { .dnsOnlyMode }, tunnelledPlainDNSRoute: { nil }, admissionEpoch: { 1 },
            tierOneFallbackPlan: { nil })

        let endpoint = DNSResolverRuntimePlan.defaultEncryptedFallbackEndpoint
        let plan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false,
            shouldFallbackToEncrypted: true,
            encryptedFallbackEndpoints: [endpoint],
            // Resolver is healthy (not wedged) → refusal is an authoritative verdict.
            treatsResolverRejectionAsFallbackTrigger: false
        )

        orchestrator.resolveUpstream(Data([0x12, 0x34, 0x01, 0x00]), plan: plan) { box.store($0) }

        XCTAssertEqual(box.value?.response, refusedReply)
        XCTAssertEqual(box.value?.transport, .deviceDNS)
        XCTAssertFalse(box.value?.usedEncryptedFallback ?? true)
        XCTAssertNotEqual(box.value?.attempts.last?.address, endpoint.cacheIdentifier)
    }

    func testEncryptedFallbackGetsOneRecoveryLaunchWhileBackedOff() {
        let box = ResultBox()
        let endpoint = DNSResolverRuntimePlan.defaultEncryptedFallbackEndpoint
        let recorder = ExecutorRecorder()
        recorder.enableRecovery(for: [endpoint.cacheIdentifier])

        let orchestrator = ResolverOrchestrator(executors: ResolverOrchestrator.Executors(
            // The Quad9 endpoint is already backed off (blocked / timing out).
            isEndpointBackedOff: { $0 == endpoint.cacheIdentifier },
            claimEncryptedRecovery: { recorder.claimRecovery(from: $0) },
            resolveDoH: { _, _, _, completion in
                completion(DNSTransportResponse(response: Self.reply(rcode: 0), outcome: .success))
            },
            resolveDoT: { _, _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolveDoQ: { _, _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolvePlain: { _, addresses, transport, _, _, _ in
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .timeout, transport: transport)],
                    transport: transport,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveTunnelledPlain: { _, route in
                // Not the transport under test; a selection here is itself the failure.
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: route.resolverAddresses.first ?? "none", outcome: .unsupported, transport: .plainDNS)],
                    transport: .plainDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveDevice: { _, addresses, _, _, _, _ in
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .timeout, transport: .deviceDNS)],
                    transport: .deviceDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            }
        ), egressAllowance: { .dnsOnlyMode }, tunnelledPlainDNSRoute: { nil }, admissionEpoch: { 1 },
            tierOneFallbackPlan: { nil })

        let plan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false,
            shouldFallbackToEncrypted: true,
            encryptedFallbackEndpoints: [endpoint]
        )

        orchestrator.resolveUpstream(Data([0x01, 0x02]), plan: plan) { box.store($0) }

        XCTAssertEqual(box.value?.response, Self.reply(rcode: 0))
        XCTAssertTrue(box.value?.usedEncryptedFallback ?? false)
        XCTAssertEqual(recorder.recoveryLaunchCount, 1)
        orchestrator.resolveUpstream(Data([0x01, 0x02]), plan: plan) { box.store($0) }
        // Further queries in the same recovery interval retain the ordinary backoff.
        XCTAssertNil(box.value?.response)
        XCTAssertFalse(box.value?.usedEncryptedFallback ?? true)
        XCTAssertEqual(box.value?.transport, .deviceDNS)
        XCTAssertEqual(box.value?.attempts.last?.outcome, .backedOff)
    }

    func testAllSuppressedEncryptedSelectionsLaunchOnlyOneEndpointPerInterval() {
        for plan in [Self.dohPlan(endpointHosts: ["one.example", "two.example"]),
                     Self.dotPlan(hostnames: ["one.example", "two.example"]),
                     Self.doqPlan(hostnames: ["one.example", "two.example"])] {
            let recorder = ExecutorRecorder()
            let addresses = plan.dohEndpoints.map(\.cacheIdentifier)
                + plan.dotEndpoints.map(\.cacheIdentifier) + plan.doqEndpoints.map(\.cacheIdentifier)
            recorder.enableRecovery(for: addresses)
            let orchestrator = Self.orchestrator(recorder: recorder)
            for _ in 0..<100 {
                _ = resolveUpstreamSync(orchestrator, plan: plan)
            }
            XCTAssertEqual(recorder.recoveryLaunchCount, 1)
            XCTAssertEqual(recorder.dohCallCount + recorder.dotCallCount + recorder.doqCallCount, 1,
                "a failed recovery must not walk every suppressed endpoint")
        }
    }

    func testDuplicateEncryptedEndpointsConsumeOnlyOneRecoveryLaunch() throws {
        for plan in [Self.dohPlan(endpointHosts: ["one.example", "one.example"]),
                     Self.dotPlan(hostnames: ["one.example", "one.example"]),
                     Self.doqPlan(hostnames: ["one.example", "one.example"])] {
            let recorder = ExecutorRecorder()
            let addresses = plan.dohEndpoints.map(\.cacheIdentifier)
                + plan.dotEndpoints.map(\.cacheIdentifier) + plan.doqEndpoints.map(\.cacheIdentifier)
            recorder.enableRecovery(for: addresses)
            let result = try XCTUnwrap(resolveUpstreamSync(Self.orchestrator(recorder: recorder), plan: plan))
            XCTAssertEqual(recorder.dohCallCount + recorder.dotCallCount + recorder.doqCallCount, 1)
            XCTAssertEqual(result.attempts.last?.outcome, .backedOff)
        }
    }

    func testEveryEncryptedTransportCanRecoverAsTheSoleTierTwo() throws {
        for fallback in [Self.dohPlan(endpointHosts: ["one.example"]),
                         Self.dotPlan(hostnames: ["one.example"]),
                         Self.doqPlan(hostnames: ["one.example"])] {
            let recorder = ExecutorRecorder()
            recorder.enableRecovery(for: fallback.dohEndpoints.map(\.cacheIdentifier)
                + fallback.dotEndpoints.map(\.cacheIdentifier) + fallback.doqEndpoints.map(\.cacheIdentifier))
            let response = DNSTransportResponse(response: Self.reply(rcode: 0), outcome: .success)
            recorder.dotResults = [response]
            recorder.doqResults = [response]
            let orchestrator = Self.orchestrator(recorder: recorder, dohResults: [response],
                deviceResult: Self.wireResult(address: "192.168.1.1", outcome: .timeout,
                    transport: .deviceDNS, response: nil))
            let plan = DNSResolverRuntimePlan(transport: .deviceDNS, plainAddresses: ["192.168.1.1"],
                dohEndpoints: [], dotEndpoints: [], doqEndpoints: [], cacheIdentifier: "device",
                deviceDNSFallbackAddresses: [], shouldFallbackToDeviceDNS: false,
                usesDeviceDNSFallbackMode: false, shouldFallbackToEncrypted: true,
                encryptedFallback: DNSResolverFallbackPlan(fallback))
            let result = resolveUpstreamSync(orchestrator, plan: plan)
            XCTAssertEqual(result?.response, Self.reply(rcode: 0))
            XCTAssertTrue(result?.usedEncryptedFallback ?? false)
            XCTAssertEqual(result?.transport, fallback.transport)
            XCTAssertEqual(recorder.recoveryLaunchCount, 1)
        }
    }

    func testConcurrentQueriesShareTheEncryptedRecoveryCooldown() {
        let plan = Self.dohPlan(endpointHosts: ["one.example"])
        let recorder = ExecutorRecorder()
        recorder.enableRecovery(for: plan.dohEndpoints.map(\.cacheIdentifier))
        let orchestrator = Self.orchestrator(recorder: recorder,
            dohResults: [DNSTransportResponse(response: Self.reply(rcode: 0), outcome: .success)])
        let query = query
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            orchestrator.resolveUpstream(query, plan: plan) { _ in }
        }
        XCTAssertEqual(recorder.dohCallCount, 1)
        XCTAssertEqual(recorder.recoveryLaunchCount, 1)
    }

    func testFullTunnelDoesNotClaimPhysicalEncryptedRecovery() throws {
        let plan = Self.dohPlan(endpointHosts: ["one.example"])
        let recorder = ExecutorRecorder()
        recorder.enableRecovery(for: plan.dohEndpoints.map(\.cacheIdentifier))
        let orchestrator = Self.orchestrator(recorder: recorder, egressAllowance: .chainedMode,
            tunnelledRoute: try Self.chainedRoute(),
            tunnelledResult: Self.plannedResult(response: nil, outcome: .timeout),
            tierOneFallbackPlan: plan)
        _ = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())
        XCTAssertEqual(recorder.recoveryLaunchCount, 0)
        XCTAssertEqual(recorder.dohCallCount, 0)
    }

    // MARK: - Fixtures

    private func resolveUpstreamSync(
        _ orchestrator: ResolverOrchestrator,
        plan: DNSResolverRuntimePlan,
        usesIsolatedEncryptedConnections: Bool = false
    ) -> DNSResolutionResult? {
        let box = ResultBox()
        orchestrator.resolveUpstream(
            query,
            plan: plan,
            usesIsolatedEncryptedConnections: usesIsolatedEncryptedConnections
        ) { result in
            box.store(result)
        }
        // Fake executors complete synchronously, so the result is already set.
        return box.value
    }

    private static func orchestrator(
        recorder: ExecutorRecorder,
        dohResults: [DNSTransportResponse] = [],
        egressAllowance: ResolverOrchestrator.EgressAllowance = .dnsOnlyMode,
        admissionEpoch: @escaping @Sendable () -> UInt64 = { 1 },
        tunnelledRoute: ResolverOrchestrator.TunnelledPlainDNSRoute? = nil,
        // Overrides `tunnelledRoute` when the route must CHANGE across a single resolution — the
        // only way to model a relatch landing mid-ladder, which is what the rung's latch fence
        // exists to refuse.
        tunnelledRouteProvider: (@Sendable () -> ResolverOrchestrator.TunnelledPlainDNSRoute?)? = nil,
        tunnelledResult: DNSResolutionResult? = nil,
        plainResult: DNSResolutionResult? = nil,
        // Defaults to nil = the always-succeeding device executor every existing test relies on.
        // Overridden only where a FAILING device resolver is the point — the shape the T1
        // rung meets on a network whose captured resolvers have gone stale.
        deviceResult: DNSResolutionResult? = nil,
        // LAST, because the call sites pass it last and Swift requires the two orders to agree.
        // Defaults to the SAME plan the rung used to inherit from the caller, so every test
        // written before the rung had its own plan keeps asserting what it always asserted.
        // Pass `nil` for "the user never opted into a T1 fallback".
        tierOneFallbackPlan: DNSResolverRuntimePlan? = ResolverOrchestratorTests.plainPlan()
    ) -> ResolverOrchestrator {
        recorder.dohResults = dohResults
        return ResolverOrchestrator(executors: ResolverOrchestrator.Executors(
            isEndpointBackedOff: { address in
                recorder.isBackedOff(address)
            },
            claimEncryptedRecovery: { recorder.claimRecovery(from: $0) },
            resolveDoH: { _, _, latchEpoch, completion in
                recorder.recordEncryptedLatchEpoch(latchEpoch)
                completion(recorder.nextDoHResult())
            },
            resolveDoT: { _, _, isolated, _, completion in
                recorder.recordDoT(isolated: isolated)
                completion(recorder.nextDoTResult())
            },
            resolveDoQ: { _, _, isolated, _, completion in
                recorder.recordDoQ(isolated: isolated)
                completion(recorder.nextDoQResult())
            },
            resolvePlain: { _, addresses, transport, _, latchEpoch, egressInterface in
                recorder.recordPlain(
                    addresses: addresses, transport: transport, egressInterface: egressInterface,
                    latchEpoch: .some(latchEpoch))
                if let plainResult {
                    return plainResult
                }
                return DNSResolutionResult(
                    response: ExecutorRecorder.plainResponse,
                    successfulResolverAddress: addresses.first,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .success, transport: transport)],
                    transport: transport,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveTunnelledPlain: { _, route in
                recorder.recordTunnelled(route: route)
                if let tunnelledResult {
                    return tunnelledResult
                }
                return DNSResolutionResult(
                    response: ExecutorRecorder.tunnelledResponse,
                    successfulResolverAddress: route.resolverAddresses.first,
                    attempts: [ResolverAttempt(address: route.resolverAddresses.first ?? "none", outcome: .success, transport: .plainDNS)],
                    transport: .plainDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveDevice: { _, addresses, _, latchEpoch, egressInterface, _ in
                recorder.recordDevice(
                    addresses: addresses, egressInterface: egressInterface,
                    latchEpoch: .some(latchEpoch))
                if let deviceResult {
                    return deviceResult
                }
                return DNSResolutionResult(
                    response: ExecutorRecorder.deviceResponse,
                    successfulResolverAddress: addresses.first,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .success, transport: .deviceDNS)],
                    transport: .deviceDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            }
        ), egressAllowance: { egressAllowance },
        tunnelledPlainDNSRoute: tunnelledRouteProvider ?? { tunnelledRoute },
        admissionEpoch: admissionEpoch, tierOneFallbackPlan: { tierOneFallbackPlan })
    }

    private static func dohPlan(
        endpointHosts: [String],
        shouldFallbackToDeviceDNS: Bool = false
    ) -> DNSResolverRuntimePlan {
        DNSResolverRuntimePlan(
            transport: .dnsOverHTTPS,
            plainAddresses: ["9.9.9.9"],
            dohEndpoints: endpointHosts.map { host in
                DNSOverHTTPSEndpoint(
                    url: URL(string: "https://\(host)/dns-query")!,
                    bootstrapIPv4Servers: [],
                    bootstrapIPv6Servers: []
                )
            },
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "doh-test",
            deviceDNSFallbackAddresses: ["192.168.1.1"],
            shouldFallbackToDeviceDNS: shouldFallbackToDeviceDNS,
            usesDeviceDNSFallbackMode: false
        )
    }

    /// A plan whose PRIMARY transport is device DNS, which chained mode must refuse outright.
    private static func devicePlan() -> DNSResolverRuntimePlan {
        DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["192.168.1.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device-test",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false
        )
    }

    private static func dotPlan(hostnames: [String]) -> DNSResolverRuntimePlan {
        DNSResolverRuntimePlan(
            transport: .dnsOverTLS,
            plainAddresses: ["9.9.9.9"],
            dohEndpoints: [],
            dotEndpoints: hostnames.map { hostname in
                DNSOverTLSEndpoint(
                    hostname: hostname,
                    port: 853,
                    bootstrapIPv4Servers: [],
                    bootstrapIPv6Servers: []
                )
            },
            doqEndpoints: [],
            cacheIdentifier: "dot-test",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false
        )
    }

    private static func doqPlan(hostnames: [String]) -> DNSResolverRuntimePlan {
        DNSResolverRuntimePlan(
            transport: .dnsOverQUIC,
            plainAddresses: ["9.9.9.9"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: hostnames.map { hostname in
                DNSOverQUICEndpoint(
                    hostname: hostname,
                    port: 853,
                    bootstrapIPv4Servers: [],
                    bootstrapIPv6Servers: []
                )
            },
            cacheIdentifier: "doq-test",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false
        )
    }

    /// A device-DNS primary, for pinning that the T1 rung refuses it.
    private static func deviceDNSPlan() -> DNSResolverRuntimePlan {
        DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["192.168.1.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device-test",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false
        )
    }

    /// A rung plan that HAS a device-DNS fallback leg, which `plainPlan` deliberately does not.
    ///
    /// The rescue-attribution tests need a rung whose ladder can rescue it, because the defect
    /// only exists once the rung has somewhere below itself to fall.
    private static func rungPlanWithDeviceFallback() -> DNSResolverRuntimePlan {
        DNSResolverRuntimePlan(
            transport: .plainDNS,
            plainAddresses: ["9.9.9.9"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "rung-with-device-leg",
            deviceDNSFallbackAddresses: ["192.168.1.1"],
            shouldFallbackToDeviceDNS: true,
            usesDeviceDNSFallbackMode: false
        )
    }

    /// One attempt that reached the wire, with the response it did or did not produce.
    private static func wireResult(
        address: String, outcome: ResolverAttemptOutcome,
        transport: DNSResolverTransport, response: Data?
    ) -> DNSResolutionResult {
        DNSResolutionResult(
            response: response,
            successfulResolverAddress: response == nil ? nil : address,
            attempts: [
                ResolverAttempt(address: address, outcome: outcome, transport: transport)
            ],
            transport: transport,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false)
    }

    private static func plainPlan() -> DNSResolverRuntimePlan {
        DNSResolverRuntimePlan(
            transport: .plainDNS,
            plainAddresses: ["9.9.9.9"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "plain-test",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false
        )
    }

    // MARK: - A refusal before the wire is not an answer

    private func refusal(_ outcomes: [ResolverAttemptOutcome]) -> DNSResolutionResult {
        DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: outcomes.map {
                ResolverAttempt(address: "9.9.9.9", outcome: $0, transport: .plainDNS)
            },
            transport: .plainDNS,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false)
    }

    /// `SERVFAIL` asserts that the DNS system tried and failed. When nothing was sent, that is a
    /// statement about US, and a stub cannot tell the difference — it drops the name for the life
    /// of the page. The predicate is what lets the forwarding path stay silent instead.
    func testARefusalBeforeTheWireIsNotAnAnswer() {
        // Every outcome that proves nothing left the device — enumerated rather than listed, so
        // a new one joins this assertion automatically. The hand-written version omitted
        // `.resolverPortUnavailable`, the case this PR's own predecessor added (Kilo, PR #623).
        for outcome in ResolverAttemptOutcome.allCases where !outcome.reachedTheWire {
            XCTAssertTrue(
                refusal([outcome]).wasRefusedBeforeTheWire,
                "\(outcome.rawValue) sent nothing, so it cannot report the name as failed")
        }
        // A resolution with no attempts at all sent nothing either.
        XCTAssertTrue(refusal([]).wasRefusedBeforeTheWire)
        // THE CONTROL, and the reason this is a discrimination rather than a blanket silence: an
        // upstream that was actually asked and let us down still owes the client an honest
        // SERVFAIL. `.timeout` and `.receiveFailed` are silence AFTER a send — a real fact.
        for outcome: ResolverAttemptOutcome in [
            .timeout, .receiveFailed, .mismatchedResponse, .unexpectedSourceResponse,
            .httpStatusFailure,
        ] {
            XCTAssertFalse(
                refusal([outcome]).wasRefusedBeforeTheWire,
                "\(outcome.rawValue) reached the wire — the failure is the resolver's to report")
        }
        // And a resolution that produced a response is never a refusal, whatever its attempts.
        let served = DNSResolutionResult(
            response: Data([0x00]), successfulResolverAddress: "9.9.9.9",
            attempts: [ResolverAttempt(address: "9.9.9.9", outcome: .backedOff, transport: .plainDNS)],
            transport: .plainDNS, udpTruncated: false, tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false)
        XCTAssertFalse(served.wasRefusedBeforeTheWire)
    }

    /// Retrying a dead lifecycle reproduces it exactly, so the budget must not be spent on it.
    ///
    /// The two predicates deliberately disagree here: a ladder-ending refusal is still not an
    /// answer (silence is right), it is merely not worth re-asking on the way to that silence.
    func testALadderEndingRefusalIsNotWorthRetrying() {
        for outcome: ResolverAttemptOutcome in [
            .refusedAfterLifecycleEnded, .refusedAfterLatchReplaced,
        ] {
            let result = refusal([outcome])
            XCTAssertTrue(result.wasRefusedBeforeTheWire, "still not an answer")
            XCTAssertFalse(
                result.isWorthRetryingBeforeTheWire,
                "\(outcome.rawValue) reproduces itself — retrying only spends the budget")
        }
        // The transient ones ARE worth retrying; that is the whole rescue.
        for outcome: ResolverAttemptOutcome in [
            .socketUnavailable, .sendFailed, .resolverPortUnavailable,
        ] {
            XCTAssertTrue(
                refusal([outcome]).isWorthRetryingBeforeTheWire,
                "\(outcome.rawValue) is transient — a second attempt is the point")
        }
        // A ladder-ender ANYWHERE in the attempts disqualifies the retry, not just as the first —
        // and it does so even alongside a genuinely transient rung, because the session that would
        // carry the retry is the thing that ended.
        XCTAssertFalse(
            refusal([.socketUnavailable, .refusedAfterLatchReplaced]).isWorthRetryingBeforeTheWire)
    }

    /// ONLY the three transient local failures are retried — the allowlist, asserted exhaustively.
    ///
    /// This test reverses two cases an earlier version of it asserted the other way, and the
    /// reversal is the finding: `.refusedByEgressPolicy` is derived from the latched egress
    /// allowance and `.tunnelInterfaceUnavailable` from an interface lag measured in seconds, so
    /// neither can clear inside a 40 ms retry window. Retrying them added ~80 ms to every
    /// fail-closed answer and held a bounded resolver slot for the duration (Codex, PR #622).
    ///
    /// Driven off `allCases` so a NEW outcome fails here until it is classified on purpose —
    /// which is the property the allowlist exists to have.
    func testOnlyTransientLocalFailuresAreWorthRetrying() {
        let retryable: Set<ResolverAttemptOutcome> = [
            .sendFailed, .socketUnavailable, .resolverPortUnavailable,
        ]
        for outcome in ResolverAttemptOutcome.allCases {
            XCTAssertEqual(
                outcome.isTransientLocalFailure, retryable.contains(outcome),
                "\(outcome.rawValue) is classified against the allowlist, not by default")
        }
        // The two that motivated the fix, stated as behaviour rather than as classification.
        XCTAssertFalse(
            refusal([.refusedByEgressPolicy]).isWorthRetryingBeforeTheWire,
            "a latched egress-allowance refusal reproduces itself exactly — retrying it delays "
                + "every fail-closed answer and holds one of the eight resolver slots")
        XCTAssertFalse(
            refusal([.tunnelInterfaceUnavailable]).isWorthRetryingBeforeTheWire,
            "the interface lag is seconds; a 40 ms retry cannot outlast it")
        XCTAssertFalse(
            refusal([.backedOff]).isWorthRetryingBeforeTheWire,
            "a 30 s backoff penalty is not a 40 ms condition")
        // And a resolution with NO transient rung at all is not retried even though nothing in it
        // ends the ladder — the old predicate's blind spot, in one assertion.
        let stable = refusal([.refusedByEgressPolicy, .invalidAddress])
        XCTAssertTrue(stable.wasRefusedBeforeTheWire, "still not an answer")
        XCTAssertFalse(
            stable.attempts.contains { $0.outcome.endsTheResolutionLadder },
            "neither outcome ends the ladder — which is exactly why the old predicate retried it")
        XCTAssertFalse(stable.isWorthRetryingBeforeTheWire)
    }
}

/// Hands out a scripted sequence of routes, so a test can relatch the data path mid-resolution.
private final class RouteSequenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [ResolverOrchestrator.TunnelledPlainDNSRoute?]
    private var last: ResolverOrchestrator.TunnelledPlainDNSRoute?

    init(_ routes: [ResolverOrchestrator.TunnelledPlainDNSRoute?]) {
        remaining = routes
        last = routes.last ?? nil
    }

    func next() -> ResolverOrchestrator.TunnelledPlainDNSRoute? {
        lock.lock()
        defer { lock.unlock() }
        guard !remaining.isEmpty else { return last }
        return remaining.removeFirst()
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DNSResolutionResult?

    var value: DNSResolutionResult? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return stored
    }

    func store(_ result: DNSResolutionResult) {
        lock.lock()
        stored = result
        lock.unlock()
    }
}

private final class ExecutorRecorder: @unchecked Sendable {
    static let plainResponse = Data([0xAA, 0x00, 0x81, 0x80, 0, 0, 0, 0, 0, 0, 0, 0])
    static let deviceResponse = Data([0xBB, 0x00, 0x81, 0x80, 0, 0, 0, 0, 0, 0, 0, 0])
    static let tunnelledResponse = Data([0xCD, 0x00, 0x81, 0x80, 0, 0, 0, 0, 0, 0, 0, 0])

    private let lock = NSLock()

    var backedOffAddresses: Set<String> = []
    private var recoveryPolicy: ResolverBackoffPolicy?
    private let recoveryNow = Date(timeIntervalSince1970: 1_000)
    private(set) var recoveryLaunchCount = 0
    private(set) var dotCallCount = 0
    private(set) var doqCallCount = 0

    func enableRecovery(for addresses: [String]) {
        lock.lock()
        defer { lock.unlock() }
        backedOffAddresses = Set(addresses)
        var policy = ResolverBackoffPolicy()
        policy.record(addresses.map { .init(address: $0, outcome: .timeout) }, now: recoveryNow)
        recoveryPolicy = policy
    }

    func claimRecovery(from addresses: [String]) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let address = recoveryPolicy?.claimEncryptedRecovery(from: addresses, now: recoveryNow)
        if address != nil { recoveryLaunchCount += 1 }
        return address
    }

    var dohResults: [DNSTransportResponse] = []
    var dotResults: [DNSTransportResponse] = []
    var doqResults: [DNSTransportResponse] = []

    private(set) var dohCallCount = 0
    private(set) var plainCallCount = 0
    private(set) var deviceCallCount = 0
    private(set) var lastPlainAddresses: [String]?
    private(set) var lastPlainTransport: DNSResolverTransport?
    private(set) var lastPlainEgressInterface: ResolverOrchestrator.EgressInterface?
    /// The rung's data-path token as the EXECUTOR received it — `.some(nil)` when a call happened
    /// and carried none, `nil` when no call happened at all. The two are different failures.
    private(set) var lastPlainLatchEpoch: UInt64??
    private(set) var lastDeviceAddresses: [String]?
    private(set) var lastDeviceEgressInterface: ResolverOrchestrator.EgressInterface?
    private(set) var lastDeviceLatchEpoch: UInt64??
    private(set) var lastEncryptedLatchEpoch: UInt64??
    private(set) var tunnelledCallCount = 0
    private(set) var lastTunnelledRoute: ResolverOrchestrator.TunnelledPlainDNSRoute?
    private(set) var lastDoTIsolated: Bool?
    private(set) var lastDoQIsolated: Bool?

    func isBackedOff(_ address: String) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return backedOffAddresses.contains(address)
    }

    func nextDoHResult() -> DNSTransportResponse {
        lock.lock()
        defer {
            lock.unlock()
        }
        dohCallCount += 1
        return dohResults.isEmpty
            ? DNSTransportResponse(response: nil, outcome: .receiveFailed)
            : dohResults.removeFirst()
    }

    func nextDoTResult() -> DNSTransportResponse {
        lock.lock()
        defer {
            lock.unlock()
        }
        dotCallCount += 1
        return dotResults.isEmpty
            ? DNSTransportResponse(response: nil, outcome: .receiveFailed)
            : dotResults.removeFirst()
    }

    func nextDoQResult() -> DNSTransportResponse {
        lock.lock()
        defer {
            lock.unlock()
        }
        doqCallCount += 1
        return doqResults.isEmpty
            ? DNSTransportResponse(response: nil, outcome: .receiveFailed)
            : doqResults.removeFirst()
    }

    func recordDoT(isolated: Bool) {
        lock.lock()
        lastDoTIsolated = isolated
        lock.unlock()
    }

    func recordDoQ(isolated: Bool) {
        lock.lock()
        lastDoQIsolated = isolated
        lock.unlock()
    }

    func recordPlain(
        addresses: [String], transport: DNSResolverTransport,
        egressInterface: ResolverOrchestrator.EgressInterface = .providerDefault,
        latchEpoch: UInt64?? = nil
    ) {
        lock.lock()
        plainCallCount += 1
        lastPlainLatchEpoch = latchEpoch
        lastPlainAddresses = addresses
        lastPlainTransport = transport
        lastPlainEgressInterface = egressInterface
        lock.unlock()
    }

    /// Zeroes the per-transport call counters so one test can drive several plans through the
    /// same orchestrator without the assertions accumulating across iterations.
    func resetCallCounts() {
        lock.lock()
        dohCallCount = 0
        plainCallCount = 0
        tunnelledCallCount = 0
        deviceCallCount = 0
        lock.unlock()
    }

    func recordTunnelled(route: ResolverOrchestrator.TunnelledPlainDNSRoute) {
        lock.lock()
        tunnelledCallCount += 1
        lastTunnelledRoute = route
        lock.unlock()
    }

    func recordEncryptedLatchEpoch(_ epoch: UInt64?) {
        lock.lock()
        lastEncryptedLatchEpoch = .some(epoch)
        lock.unlock()
    }

    func recordDevice(
        addresses: [String], egressInterface: ResolverOrchestrator.EgressInterface,
        latchEpoch: UInt64?? = nil
    ) {
        lock.lock()
        deviceCallCount += 1
        lastDeviceLatchEpoch = latchEpoch
        lastDeviceAddresses = addresses
        lastDeviceEgressInterface = egressInterface
        lock.unlock()
    }

}
