import XCTest

@testable import LavaSecCore

/// Cross-process/cross-target wiring for the QA DNS leak-canary emitter (leak rig #8). Pinned rather
/// than executed: the emitter lives in the packet-tunnel target and the arm control in the app
/// target, so the load-bearing facts — that the emit is a REAL physical-path leak (`.systemChosen`),
/// is compiled out of Release, fires exactly once per established chained session, and is armed via
/// the shared App Group — are cross-target wiring no in-package test can reach.
final class DNSLeakCanaryEmitterSourceTests: XCTestCase {
    private func emitterBlock() throws -> String {
        try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "func fireChainedDNSLeakCanaryIfArmed() {",
            endingBefore: "func resolveOverTCP(")
    }

    func testTheEmitterSendsOnTheSystemChosenPhysicalPath() throws {
        let emitter = try emitterBlock()
        // THE leak: an unbound-while-chained socket egresses on the PHYSICAL interface. If this ever
        // became a tunnel-bound send the canary would ride the tunnel, the analyzer would never see
        // it, and the whole positive control (#8) would silently certify nothing. This is the single
        // most important line in the emitter.
        XCTAssertTrue(
            emitter.contains("binding: .systemChosen"),
            "the canary MUST egress on the physical path (.systemChosen); a tunnel-bound send is not a leak")
        XCTAssertFalse(
            emitter.contains("boundToTunnel"),
            "a tunnel-bound canary defeats the positive control — it must never bind to the tunnel")
        // Built by the shared canary builder, armed via the shared App-Group keys.
        XCTAssertTrue(emitter.contains("DNSLeakCanary.query(nonce: nonce)"))
        XCTAssertTrue(emitter.contains("LavaSecAppGroup.leakCanaryArmedNonceKey"))
        XCTAssertTrue(emitter.contains("LavaSecAppGroup.leakCanaryResolverIPKey"))
        // Only while actually chained, and the blocking send is off dnsStateQueue (INV-QUEUE-1).
        XCTAssertTrue(emitter.contains("currentTunnelDataPathMode().isChainedUpstream"))
        XCTAssertTrue(emitter.contains("resolverQueue.async"))
        // Fires only for the nonce armed at THIS launch, so a mid-session arm cannot fire before the
        // capture — it waits for a post-arm reconnect (Codex, PR #563).
        XCTAssertTrue(emitter.contains("nonce == leakCanaryEligibleNonce"))
        // Only a REAL send is "fired": an outcome proving no datagram left the interface (a sendto
        // failure on a changing route) un-latches the generation so a later tick retries, instead of
        // logging a blind capture as fired (Codex, PR #563).
        XCTAssertTrue(emitter.contains("chained-dns-leak-canary-retry"))
        XCTAssertTrue(emitter.contains("case .sendFailed"))
        XCTAssertTrue(
            emitter.contains("chainedLeakCanaryFiredForGeneration = 0"),
            "a no-datagram outcome must drop the fire latch so the next tick can retry")
        // The un-latch is scoped to the ORIGINATING lifecycle (sessionGeneration restarts at 1 per
        // lifecycle), so an outstanding attempt from a prior lifecycle can't clear a new latch and
        // double-fire (Codex, PR #563).
        XCTAssertTrue(emitter.contains("tunnelLifecycleGeneration == firedLifecycle"))
    }

    func testTheEligibleNonceIsSnapshottedAtStartTunnelBeforeAnyHandshake() throws {
        let load = try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "func loadInitialSharedState() -> Bool {",
            endingBefore: "switch loadConfigurationClassified()")
        // Snapshotted at startTunnel (pre-handshake), so only a post-arm connect's session is eligible.
        XCTAssertTrue(load.contains("leakCanaryEligibleNonce = LavaSecAppGroup.sharedDefaults.string("))
        XCTAssertTrue(load.contains("LavaSecAppGroup.leakCanaryArmedNonceKey"))
        // The fire-once latch is ALSO reset per start — a reused provider retains the prior lifecycle's
        // value, but a fresh driver restarts sessionGeneration at 1, so a stale latch would block the
        // whole new session (Codex, PR #563).
        XCTAssertTrue(load.contains("chainedLeakCanaryFiredForGeneration = 0"))
    }

    func testTheEmitterIsCompiledOutOfRelease() throws {
        let emitter = try emitterBlock()
        // The whole body is behind the internal QA build flag — nothing to send in Release. Build the
        // flag string dynamically so this assertion cannot trip the public-QA-enablement guard on its
        // own source text.
        let guardName = ["LAVA", "QA", "TOOLS"].joined(separator: "_")
        XCTAssertTrue(
            emitter.contains("#if DEBUG || \(guardName)"),
            "the physical-path emit must be compiled out of Release")
    }

    func testTheEmitterSelfLatchesAndFiresFromATunnelOwnedTick() throws {
        let source = try readPacketTunnelProviderSource()
        let emitter = try emitterBlock()
        // Self-latches on the driver's sessionGeneration → fires exactly once per established chained
        // session; a full rebuild bumps the generation and re-arms, a rebind keeps it (no re-fire).
        XCTAssertTrue(emitter.contains("stats.hasHandshake"))
        XCTAssertTrue(emitter.contains("chainedLeakCanaryFiredForGeneration != stats.sessionGeneration"))
        XCTAssertTrue(emitter.contains("let firedGeneration = stats.sessionGeneration"))
        XCTAssertTrue(emitter.contains("chainedLeakCanaryFiredForGeneration = firedGeneration"))
        // Driven from the TUNNEL-OWNED Focus tick so it fires regardless of app foreground state — an
        // app-poll-only trigger would miss a backgrounded / Connect-On-Demand establishment during a
        // capture (Codex, PR #563). Anchored beside the sibling tunnel-owned QA liveness emit.
        let focusTick = try sourceBlock(
            in: source,
            startingAt: "private func reloadSnapshotIfConfigurationGenerationAdvanced() {",
            endingBefore: "mirrorChainedHealthCountersIfChanged()")
        XCTAssertTrue(
            focusTick.contains("fireChainedDNSLeakCanaryIfArmed()"),
            "the canary must be driven from the tunnel-owned Focus tick, not only the app poll")
        XCTAssertTrue(focusTick.contains("emitChainedSessionLivenessIfChained()"))
    }

    func testTheAppArmsTheCanaryViaTheSameAppGroupKeys() throws {
        let arm = try sourceBlock(
            in: try readAppViewModelSource(),
            startingAt: "func armDNSLeakCanaryForQA(resolverIP: String) {",
            endingBefore: "func disarmDNSLeakCanaryForQA")
        // Writes the SAME shared keys the extension reads, and surfaces the nonce for the analyzer.
        XCTAssertTrue(arm.contains("LavaSecAppGroup.leakCanaryArmedNonceKey"))
        XCTAssertTrue(arm.contains("LavaSecAppGroup.leakCanaryResolverIPKey"))
        XCTAssertTrue(arm.contains("--canary-nonce"))
        // The Admin/QA control is wired to the arm + disarm actions.
        let qaView = try readSource(.adminQAView)
        XCTAssertTrue(qaView.contains("viewModel.armDNSLeakCanaryForQA(resolverIP:"))
        XCTAssertTrue(qaView.contains("viewModel.disarmDNSLeakCanaryForQA()"))
    }

    func testTheAppGroupDefinesTheLeakCanaryKeys() throws {
        let group = try readSource(.appGroup)
        XCTAssertTrue(group.contains("static let leakCanaryArmedNonceKey"))
        XCTAssertTrue(group.contains("static let leakCanaryResolverIPKey"))
    }
}
