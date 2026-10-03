import XCTest

@testable import LavaSecKit

/// Pins the provider wiring of hands-free surrender auto-recovery (Slice 2): the executable
/// policy + store tests cover the decision and the persistence; this covers the seam the
/// compiler cannot — that the satisfied-path handler actually invokes it, gated on the surrender
/// refusal, bounded by the policy, off the DNS queue.
final class ChainedSurrenderAutoRecoverySourceTests: XCTestCase {
    func testASatisfiedPathTriggersBoundedAutoRecovery() throws {
        let source = try readPacketTunnelProviderSource()

        // A satisfied path update attempts the bounded recovery BEFORE the meaningful-change guard.
        // That guard's `didMeaningfullyChange` is coarse (network kind + satisfaction bit); a
        // same-kind Wi-Fi→Wi-Fi roam is invisible to it, so gating recovery behind it strands the
        // tunnel Paused until a different-kind/status transition or a manual Reset (Codex, PR #569
        // round 13). The attempt threads `completeAbortedOnly: isInitialPathUpdate` — the initial
        // update only finishes an aborted handoff whose surrender a previous lifecycle cleared; a
        // later update runs the full recovery.
        let recoveryAttempt = try XCTUnwrap(
            source.range(
                of: "attemptChainedSurrenderAutoRecoveryIfNeeded(completeAbortedOnly: isInitialPathUpdate)"),
            "a satisfied path update must attempt recovery threading completeAbortedOnly with "
                + "isInitialPathUpdate, so a same-kind roam still recovers and a startup surrender is "
                + "not cleared")
        let meaningfulGuard = try XCTUnwrap(
            source.range(of: "guard !isInitialPathUpdate, didMeaningfullyChange else"),
            "the meaningful-change guard must exist")
        XCTAssertLessThan(
            recoveryAttempt.lowerBound, meaningfulGuard.lowerBound,
            "the recovery attempt must precede the coarse meaningful-change guard, or a same-kind "
                + "Wi-Fi→Wi-Fi roam never reaches recovery and the tunnel stays Paused")

        // Cross-lifecycle handoff completion must be EVENT-DRIVEN, never a fixed settle timer: a
        // superseded lifecycle's clear can be orphaned to a newer lifecycle whose initial complete-only
        // read raced ahead of the clear write, and a fixed deadline cannot bound the explicitly
        // unbounded SecItem read it must outlast (Codex, PR #569 round 15). The pump wiring is asserted
        // below, once the recovery + clear source blocks are in scope.
        XCTAssertFalse(
            source.contains("scheduleChainedHandoffCompletionRecheck")
                || source.contains("chainedHandoffCompletionSettle"),
            "handoff completion must not use a fixed settle timer — an unbounded SecItem read can "
                + "outlast it; use the event-driven marker-release pump")

        let recovery = try sourceBlock(
            in: source,
            startingAt: "private func attemptChainedSurrenderAutoRecoveryIfNeeded(completeAbortedOnly: Bool = false) -> Bool {",
            endingBefore: "func reapplyTunnelNetworkSettings(")
        // The attempt reports whether it ADMITTED (claimed the marker + dispatched); the caller clears
        // the handoff signal only on admit, never on a coalesced no-op (Codex, PR #569 round 18).
        XCTAssertTrue(
            recovery.contains("return true"),
            "the attempt must return true when admitted, so a coalesced attempt does not look like a "
                + "handoff completion")

        // Gated strictly on the surrender refusal — never fires against a healthy chain or a
        // DNS-only latch that happened for any other reason (ineligible, disabled, unreadable) — AND
        // the refusal must belong to the CURRENT lifecycle (symmetric with the pump + final fence), or
        // a stale startup-window carry-over could admit a task (adversarial agent, PR #569 round 18).
        let firstGuardRegion = String(
            recovery[..<(try XCTUnwrap(recovery.range(of: "guard Self.isOnDemandConfirmedEnabled()")).lowerBound)])
        XCTAssertTrue(
            firstGuardRegion.contains("latchedDataPathRefusal == .chainedSurrendered")
                && firstGuardRegion.contains(
                    "latchedDataPathRefusalGeneration == tunnelLifecycleGeneration"),
            "the recovery must gate on the surrender refusal AND its generation being current, not on "
                + "any DNS-only latch nor a stale refusal carried across a lifecycle boundary")
        // Connect-On-Demand gate FIRST: without it, cancelling tears the working DNS-only
        // surrender state into NO tunnel with no relaunch — a fail-open (Codex, PR #569 round 3).
        // It must precede the epoch spend + surrender clear so the safe state + budget survive.
        let onDemandGate = try XCTUnwrap(
            recovery.range(of: "guard Self.isOnDemandConfirmedEnabled() else { return false }"),
            "the auto-recovery must refuse to cancel when Connect-On-Demand is not armed, or it "
                + "fails open — tearing a working DNS-only tunnel down with no automatic relaunch")
        XCTAssertLessThan(
            onDemandGate.lowerBound,
            try XCTUnwrap(recovery.range(of: "recordSurrenderAutoRecovery(")).lowerBound,
            "the on-demand gate must come BEFORE the recovery decision, so the DNS-only state and "
                + "budget survive intact when a relaunch would not follow")
        // Coalesce: at most one in-flight recovery per LIFECYCLE, keyed on the OWNING generation, so
        // a task wedged by an old, since-replaced lifecycle (a reused provider instance) cannot block
        // a new lifecycle's recovery forever — a process-wide Bool would (Codex, PR #569 round 13).
        let inFlightGuard = try XCTUnwrap(
            recovery.range(
                of: "guard chainedAutoRecoveryInFlightGeneration != generation else { return false }"),
            "the recovery must coalesce per lifecycle on the owning generation, not a process-wide "
                + "flag that a reused provider instance would wedge (INV-MEM-1)")
        XCTAssertTrue(
            recovery.contains("chainedAutoRecoveryInFlightGeneration = generation"),
            "the in-flight marker must be set to the owning generation before the async Keychain work")
        // The clear is generation-matched: a stale task returning after a newer lifecycle admitted
        // its own recovery must not release the newer task's slot. Pin BOTH the call site AND the
        // clear body's `== generation` guard — without the body pin a refactor dropping the guard to
        // an unconditional nil would keep every other assertion green (the call signature is
        // unchanged) while silently reintroducing the double-launch this fix prevents (adv-panel P3,
        // Codex PR #569 round 13).
        XCTAssertTrue(
            recovery.contains("clearChainedAutoRecoveryInFlight(generation: generation)"),
            "the in-flight marker must be cleared for its OWN generation")
        let clearBody = try sourceBlock(
            in: source,
            startingAt: "private func clearChainedAutoRecoveryInFlight(generation: UInt64) {",
            endingBefore: "private func drainChainedRecoveryCapacityWaiter(")
        XCTAssertTrue(
            clearBody.contains("self.chainedAutoRecoveryInFlightGeneration == generation")
                && clearBody.contains("self.chainedAutoRecoveryInFlightGeneration = nil"),
            "the clear must guard on `== generation` BEFORE niling the marker, or a stale task's "
                + "late return releases a newer lifecycle's admission and a flap double-launches")
        XCTAssertLessThan(
            inFlightGuard.lowerBound,
            try XCTUnwrap(recovery.range(of: "DispatchQueue.global")).lowerBound,
            "the in-flight guard must gate BEFORE launching the global Keychain task")

        // PROCESS-WIDE ceiling across generations (INV-MEM-1): the per-generation marker admits a new
        // lifecycle's recovery even while an old generation's task is wedged, so reconnect churn during
        // a securityd wedge could pile up one blocked task per generation. Bound the TOTAL in-flight
        // count and decrement it for EVERY task (even a stale one whose marker was overwritten), Codex
        // PR #569 round 19.
        let memBound = try XCTUnwrap(
            recovery.range(
                of: "guard chainedRecoveryInFlightTaskCount < Self.maxConcurrentChainedRecoveryTasks else {"),
            "the recovery must gate on a process-wide in-flight ceiling, or lifecycle churn during a "
                + "securityd wedge accumulates blocked tasks until jetsam (INV-MEM-1)")
        XCTAssertLessThan(
            memBound.lowerBound,
            try XCTUnwrap(recovery.range(of: "DispatchQueue.global")).lowerBound,
            "the process-wide ceiling must gate BEFORE launching the global Keychain task")
        XCTAssertTrue(
            recovery.contains("chainedRecoveryInFlightTaskCount += 1"),
            "the in-flight count must be incremented before the global task is dispatched")
        XCTAssertTrue(
            clearBody.contains("chainedRecoveryInFlightTaskCount = max(0, self.chainedRecoveryInFlightTaskCount - 1)"),
            "the in-flight count must be decremented UNCONDITIONALLY on completion (before the "
                + "generation-matched marker clear), or a stale task leaks a slot (INV-MEM-1)")
        // The ceiling refusal RETAINS a capacity-waiting attempt (generation + mode), and a slot drain
        // (count decrement) retries it — else a stationary surrendered path stays Paused after capacity
        // frees, because the draining tasks decline and never set the handoff pending (Codex round 20).
        XCTAssertTrue(
            recovery.contains("chainedRecoveryCapacityWaitingGeneration = generation")
                && recovery.contains(
                    "chainedRecoveryCapacityWaitingCompleteAbortedOnly = completeAbortedOnly"),
            "the ceiling refusal must retain the refused attempt's generation AND mode")
        XCTAssertTrue(
            clearBody.contains("drainChainedRecoveryCapacityWaiter()"),
            "a slot drain must retry a capacity-refused recovery")
        let drain = try sourceBlock(
            in: source,
            startingAt: "private func drainChainedRecoveryCapacityWaiter() {",
            endingBefore: "private func pumpChainedHandoffRecoveryIfIdle(")
        XCTAssertTrue(
            drain.contains("waiting == tunnelLifecycleGeneration")
                && drain.contains(
                    "chainedRecoveryInFlightTaskCount < Self.maxConcurrentChainedRecoveryTasks"),
            "the drain must fence to the CURRENT lifecycle (drop a stale waiter) and require real capacity")
        // Defer while this generation's marker is held: re-attempting then would COALESCE (return
        // false) without re-setting the waiter, silently losing it — the marker-holder's own
        // completion re-drains with the marker free (adversarial agent, PR #569 round 20 follow-up).
        let deferGuard = try XCTUnwrap(
            drain.range(of: "guard chainedAutoRecoveryInFlightGeneration != tunnelLifecycleGeneration else { return }"),
            "the drain must DEFER while this generation's marker is held, or a coalesced re-attempt "
                + "loses the waiter and a stationary path stays Paused")
        let drainReattempt = try XCTUnwrap(
            drain.range(of: "attemptChainedSurrenderAutoRecoveryIfNeeded(completeAbortedOnly: mode)"),
            "the drain must retry with the PRESERVED mode, so an initial-update refusal stays "
                + "complete-only and never clears a genuine startup surrender")
        // GUARDED, NOT ASSERTED — the commitRegion slice below is built from these two
        // independently-searched ranges (Codex P2, PR #605).
        guard deferGuard.lowerBound < drainReattempt.lowerBound else {
            return XCTFail("the marker-held defer must precede the re-attempt")
        }
        // The waiter is niled only BETWEEN the defer guard and the re-attempt — i.e. only once we are
        // about to actually admit — so a DEFERRED drain retains the waiter for the next drain.
        let commitRegion = String(drain[deferGuard.upperBound..<drainReattempt.lowerBound])
        XCTAssertTrue(
            commitRegion.contains("chainedRecoveryCapacityWaitingGeneration = nil"),
            "the waiter must be niled only after the defer guard passes, never before, or a deferred "
                + "drain loses it")

        // Event-driven cross-lifecycle handoff completion (Codex, PR #569 round 15). A recovery whose
        // clear is orphaned to a NEWER lifecycle retains a durable pending signal; releasing the
        // in-flight marker pumps it, so the re-attempt lands strictly AFTER the racing read finished
        // (a fixed timer could not — the SecItem read is unbounded).
        XCTAssertTrue(
            recovery.contains("if self.tunnelLifecycleGeneration != generation {")
                && recovery.contains("self.chainedHandoffRecoveryPending = true")
                && recovery.contains("self.pumpChainedHandoffRecoveryIfIdle()"),
            "a clear orphaned to a NEWER lifecycle must retain a pending signal and pump it, or the "
                + "newer session stays latched DNS-only until a manual Reset")
        XCTAssertTrue(
            clearBody.contains("pumpChainedHandoffRecoveryIfIdle()"),
            "releasing the in-flight marker must pump a pending handoff completion — that release is "
                + "the event the round-14 timer lacked")
        let pump = try sourceBlock(
            in: source,
            startingAt: "private func pumpChainedHandoffRecoveryIfIdle() {",
            endingBefore: "func reapplyTunnelNetworkSettings(")
        XCTAssertTrue(
            pump.contains("guard chainedHandoffRecoveryPending else { return }"),
            "the pump must no-op when no handoff completion is pending")
        XCTAssertTrue(
            pump.contains("guard chainedAutoRecoveryInFlightGeneration == nil else { return }"),
            "the pump must DEFER until the marker is free, or it coalesces into the very read it "
                + "follows (the round-14 timer's flaw)")
        // The pump must RETAIN the signal until an ACTIVE lifecycle owns its latch: the generation
        // bumps on invalidate and at startTunnel before loadInitialSharedState installs the latch,
        // and latchedDataPathRefusal holds the PREVIOUS lifecycle's value across that window — firing
        // there could cancel a stopped or freshly-starting session (Codex, PR #569 round 16).
        XCTAssertTrue(
            pump.contains("guard tunnelLifecycleIsActive,")
                && pump.contains("latchedDataPathRefusalGeneration == tunnelLifecycleGeneration"),
            "the pump must gate on an ACTIVE lifecycle that OWNS its latch, not a bare generation "
                + "match — retaining the signal across invalidate / pre-latch-install windows")
        XCTAssertTrue(
            pump.contains("attemptChainedSurrenderAutoRecoveryIfNeeded(completeAbortedOnly: true)"),
            "the pump must re-run the COMPLETE-ONLY attempt so it finishes an aborted handoff but "
                + "never clears a genuine startup surrender")
        // The latch's sole writer stamps the generation it was installed for, so ownership is decidable.
        XCTAssertTrue(
            source.contains("latchedDataPathRefusalGeneration = self.tunnelLifecycleGeneration"),
            "the latch writer must stamp latchedDataPathRefusalGeneration, or the pump/cancel cannot "
                + "tell a ready lifecycle's refusal from a stale one carried across a boundary")
        // A satisfied path update clears the pending signal ONLY when the attempt was ADMITTED; a
        // COALESCED attempt consumed nothing, so the signal is routed through the pump (preserved for
        // the in-flight task's marker release) instead of discarded — else a stationary session stays
        // Paused (Codex, PR #569 round 17 claim, round 18 admitted-gate).
        XCTAssertTrue(
            source.contains(
                "if attemptChainedSurrenderAutoRecoveryIfNeeded(completeAbortedOnly: isInitialPathUpdate) {"),
            "the satisfied path update must branch on whether the attempt was ADMITTED")
        // GUARDED: `recoveryAttempt` and `meaningfulGuard` are searched independently over the
        // whole source with no ordering check at all, so a reorder traps here and takes the test
        // bundle down instead of failing this test (Codex P2, PR #605).
        guard recoveryAttempt.upperBound < meaningfulGuard.lowerBound else {
            return XCTFail(
                "the recovery attempt must precede the meaningful-change guard")
        }
        let claimRegion = String(source[recoveryAttempt.upperBound..<meaningfulGuard.lowerBound])
        XCTAssertTrue(
            claimRegion.contains("chainedHandoffRecoveryPending = false"),
            "an ADMITTED attempt must claim the pending signal so its own marker release does not "
                + "re-pump a duplicate")
        XCTAssertTrue(
            claimRegion.contains("} else {")
                && claimRegion.contains("pumpChainedHandoffRecoveryIfIdle()"),
            "a NOT-admitted (coalesced/moot) attempt must route through the pump, which PRESERVES the "
                + "signal while a task holds the marker instead of discarding it (Codex round 18)")
        // The whole decision runs in the store in ONE read (nowEpoch passed in); the provider does
        // not read epochs or evaluate the policy separately.
        XCTAssertTrue(
            recovery.contains("recordSurrenderAutoRecovery(") && recovery.contains("nowEpoch:")
                && recovery.contains("onlyIfAlreadyCleared: completeAbortedOnly"),
            "the recovery must call the store's decision with nowEpoch, threading the "
                + "complete-only mode so a fresh startup surrender is not cleared")
        XCTAssertTrue(
            recovery.contains("cancelTunnelWithError(nil)"),
            "the recovery must restart so the latch re-selects chained")
        // The Keychain read+write must not run on the DNS-serving queue (INV-QUEUE-1).
        XCTAssertTrue(
            recovery.contains("DispatchQueue.global"),
            "the Keychain work must run off the DNS queue (INV-QUEUE-1)")

        // The cancel is gated on the store reporting it should restart, then the FINAL fence +
        // cancel run in ONE dnsStateQueue turn (Codex, PR #569 round 8): the lifecycle + path are
        // read and the cancel issued in the same block, so neither can flip between the check and
        // the teardown (mirrors performGuardedSelfReconnectTeardown). There is NO reinstatement — a
        // lost fence simply does not cancel; the store surrender stays cleared and the next
        // satisfied path change finishes the recovery with a plain restart (round 10).
        let cancelIndex = try XCTUnwrap(recovery.range(of: "cancelTunnelWithError(nil)")).lowerBound
        let beforeCancel = String(recovery[..<cancelIndex])
        let restartGate = try XCTUnwrap(
            beforeCancel.range(of: "guard outcome == .restart else"),
            "the cancel must be gated on the store's outcome being .restart")
        // The final fence + cancel are one dnsStateQueue turn, entered AFTER the gate.
        let atomicTurn = try XCTUnwrap(
            beforeCancel.range(of: "self.dnsStateQueue.async"),
            "the final fence + cancel must run on one dnsStateQueue turn, not separate hops")
        XCTAssertLessThan(
            restartGate.lowerBound, atomicTurn.lowerBound,
            "the atomic fence+cancel turn is entered only after the store gate")
        // The FINAL fence must RE-READ the on-demand gate, not rely on the attempt-start read: the
        // Keychain decision runs on the global queue with a slow/unbounded SecItem read, and an
        // out-of-app Connect-On-Demand disable during that window would otherwise let the cancel tear a
        // WORKING DNS-only surrender into no-tunnel-no-relaunch — a fail-open on INV-DNS-1 (adversarial
        // panel, PR #569 round 16; mirrors performGuardedSelfReconnectTeardown's own re-read).
        let finalFence = String(beforeCancel[atomicTurn.lowerBound...])
        XCTAssertTrue(
            finalFence.contains("Self.isOnDemandConfirmedEnabled()"),
            "the final cancel fence must re-read on-demand inside the atomic turn, or an out-of-app "
                + "disable during the async Keychain window fails open (INV-DNS-1)")
        // The cancel is IDEMPOTENT per generation: cancelTunnelWithError is async (no synchronous
        // generation bump), so a second recovery task reaching this fence for the SAME generation — a
        // late fenced-off task that re-armed the handoff, or a same-generation re-admission after the
        // coalescing marker freed — must not cancel one lifecycle twice (adversarial panel, PR #569
        // round 17).
        XCTAssertTrue(
            finalFence.contains("guard self.chainedRecoveryCancelIssuedGeneration != generation else")
                && finalFence.contains("self.chainedRecoveryCancelIssuedGeneration = generation"),
            "the final cancel must record + gate on chainedRecoveryCancelIssuedGeneration so one "
                + "generation is cancelled at most once")
        // Inside the turn, the lifecycle AND path are read DIRECTLY (we are on their confinement),
        // in one guard; a lost fence just returns (no reinstatement). The fence requires a LIVE
        // lifecycle that OWNS its latch (active + latchedDataPathRefusalGeneration == generation), not
        // just a matching generation — a bare generation match can be a stopped provider or a
        // pre-latch-install startTunnel, and a cancel there tears down the wrong session (Codex, PR
        // #569 round 16).
        XCTAssertTrue(
            beforeCancel.contains("self.tunnelLifecycleIsActive")
                && beforeCancel.contains("self.tunnelLifecycleGeneration == generation")
                && beforeCancel.contains("self.latchedDataPathRefusalGeneration == generation")
                && beforeCancel.contains("self.latestMonitoredPathIsSatisfied"),
            "the atomic fence must re-check an ACTIVE lifecycle that owns its latch AND the freshest "
                + "path, not merely the generation")
        XCTAssertFalse(
            recovery.contains("reinstateSurrenderAfterAbandonedRecovery"),
            "the recovery must NOT reinstate — a lost fence leaves the surrender cleared and the "
                + "next satisfied path change restarts (round 10 removed the racy reinstate)")
        // The WRITE (which clears the shared surrender) is itself fenced — lifecycle + path — not
        // just the cancel: a stale task must not clear a newer lifecycle's surrender, and a flap
        // to unsatisfied must not spend an attempt + cancel into a dead path (Codex, PR #569).
        XCTAssertTrue(
            recovery.contains(
                "isStillWanted: { self.chainedAutoRecoveryRemainsViable(generation: generation) }"),
            "the recovery write must be fenced on the lifecycle AND a still-satisfied path")
        // Viability revalidates the freshest delivered path (like the self-reconnect teardown),
        // not just the lifecycle generation.
        let viable = try sourceBlock(
            in: source,
            startingAt: "private func chainedAutoRecoveryRemainsViable(generation: UInt64) -> Bool {",
            endingBefore: "private func attemptChainedSurrenderAutoRecoveryIfNeeded(")
        XCTAssertTrue(
            viable.contains("latestMonitoredPathIsSatisfied")
                && viable.contains("generation == tunnelLifecycleGeneration"),
            "recovery viability must require BOTH the current lifecycle and a satisfied path")
        // Only a NETWORK-TRANSIENT surrender (budgetExhausted) is auto-recovered — a fault a path
        // change cannot clear (engine/contract/clock) must be left surrendered (Codex, PR #569).
        XCTAssertTrue(
            recovery.contains("isRecoverableReason:")
                && recovery.contains(".isResolvableByNetworkChange"),
            "the recovery must gate on the surrender REASON being resolvable by a network change, "
                + "not fire for every .chainedSurrendered latch regardless of why it surrendered")
    }
    /// 🔴 THE SEAM THAT MADE EVERY TEST IN THIS FILE VACUOUS IN THE FIELD, now closed by removing
    /// the gate entirely. Auto-recovery only runs from a lifecycle whose latch resolved
    /// `.chainedSurrendered` (`attemptChainedSurrenderAutoRecoveryIfNeeded`'s first guard). The
    /// startup marker gate ran BEFORE `loadInitialSharedState`, so while it refused a surrender
    /// marker no such lifecycle could exist and the recovery below could never be entered. A
    /// 2026-09-01 capture: four surrenders, zero `chained-surrender-autorecovery-*` events in five
    /// hours, one surrender relaunching 82 times in 27 seconds with every start refused. The
    /// fail-closed rework (2026-09-18) removed the remaining gate: a standing marker never refuses
    /// a start, so the DNS-only lifecycle always comes up. The marker is NOT consumed — the
    /// suppression stands, the latch still refuses chaining, and the app reads the marker to
    /// disclose the degraded mode without disarming Connect-On-Demand.
    func testAStandingSurrenderMarkerNeverRefusesTheStart() throws {
        let source = try readPacketTunnelProviderSource()
        let gate = try sourceBlock(
            in: source,
            startingAt: "        if let reason = startupFailureMarkerState.reason {",
            endingBefore: "chainedStartupFailureMarkerGeneration = startupFailureMarkerState")
        XCTAssertTrue(
            gate.contains("startTunnel-chaining-marker-standing"),
            "a standing marker must be disclosed, not turned into a refusal")
        XCTAssertFalse(
            gate.contains("completion("),
            "no marker reason may refuse the start")
        // Keep the marker through admission; successful start owns its generation-fenced clear.
        XCTAssertFalse(
            sourceCodeOnly(gate).contains("clear("),
            "a permitted start must not consume the marker")
    }

    /// The latch's recoverability still comes from the SAME snapshot the latch resolved from — a
    /// second store read could return a reason the latch never saw. The startup contract no
    /// longer consumes it: every refusal starts the latched DNS-only path (fail closed), so
    /// recoverability only drives the surrender auto-recovery policy.
    func testTheLatchRecoverabilityComesFromTheResolvedSnapshot() throws {
        let source = try readPacketTunnelProviderSource()
        XCTAssertTrue(
            source.contains(
                "let latchedSurrenderIsRecoverable = deviceSnapshot?.surrenderReasonLogValue.map {"),
            "recoverability must be computed from the snapshot the latch resolved from")
        // 🔴 THE WHOLE CHAIN, not just its ends. The first version of this pin asserted the
        // computation and the assignment separately, and both held while the code was a
        // SELF-ASSIGNMENT: `installLatchedDataPathMode` is a different function, so the
        // unqualified right-hand side resolved to the instance property rather than the local,
        // and the latched value stayed `false` forever (Codex, PR #638). Asserting that the
        // computed value is PASSED is what closes the gap between them.
        XCTAssertTrue(
            source.contains("surrenderIsRecoverable: latchedSurrenderIsRecoverable)"),
            "the computed value must be passed to the installer, not re-read inside it")
        XCTAssertTrue(
            source.contains("self.latchedSurrenderIsRecoverable = surrenderIsRecoverable"),
            "and latched from that parameter, atomically with the refusal it qualifies")
    }

}
