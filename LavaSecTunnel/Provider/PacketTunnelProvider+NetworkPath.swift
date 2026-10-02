@preconcurrency import ActivityKit
import Foundation
import Darwin
import os
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
    // MARK: - Health reset & network path monitoring

    func resetHealth() {
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.health = TunnelHealthSnapshot(networkKind: self.currentNetworkKind())
            // The manual-rule diagnostic is per-session evidence; a reused provider instance must
            // not carry the previous session's dedup into the next.
            self.manualRuleDiagnosticState.withLock { $0.loggedKeys.removeAll() }
            // These delivery-only suppression markers are not reducer evidence.
            // A reused provider instance must not carry them into the next session.
            self.lastSelfReconnectSuppressionSignature = nil
            self.lastSelfReconnectSuppressionLogAt = nil
            self.lastSelfReconnectPathSkipLogAt = nil
            // The previous session's completed startup must not vouch for this one's.
            self.tunnelStartupDidComplete = false
            // A fresh tunnel session re-captures Device DNS at cold start, so any
            // pending masked-handoff capture retry from the previous session is moot.
            self.cancelDeviceDNSCaptureRetry()
            self.applyResolverHealthEvent(.lifecycleReset(occurredAt: Date()))
        }
    }

    func startPathMonitor(lifecycleGeneration: UInt64) {
        // A cancelled NWPathMonitor never delivers again, and cleanup cancels the
        // monitor on every stop AND every failed start. Reusing the same object
        // across a same-instance restart (manual stop/start without a process
        // kill, or a setTunnelNetworkSettings-error retry) would leave this handler
        // permanently silent. Create a FRESH monitor each start so the handler can
        // fire again. Cancel the outgoing one first (idempotent — cleanup may have
        // already cancelled it) so we never strand a live monitor on the old object.
        pathMonitor.cancel()
        let monitor = Network.NWPathMonitor()
        pathMonitor = monitor

        // Reset the observed-path state on dnsStateQueue (its owning queue), enqueued
        // BEFORE `start(queue:)` below so it lands ahead of any update the fresh
        // monitor delivers. Without this, a stale "satisfied" could survive the
        // restart: `latestMonitoredPathIsSatisfied` would keep the self-reconnect
        // teardown guard reading true (cancel-into-dead-network), and the stale
        // last-observed path would suppress the fresh monitor's first update as a
        // no-op change, skipping the network-change reset. Optimistic default (true)
        // for latestMonitoredPathIsSatisfied matches "no adverse path info yet"; the
        // last-observed pair goes nil so the first fresh update is treated as initial.
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }
            guard self.isCurrentTunnelLifecycle(lifecycleGeneration) else { return }
            self.chainedBootRecoveryPathGate = ChainedBootRecoveryPathGate(generation: lifecycleGeneration)
            self.chainedBootRecoveryPathObservation = 0
            self.latestMonitoredPathIsSatisfied = true
            self.resolverTierObservedPathKind = nil
            self.lastObservedPathKind = nil
            self.lastObservedPathIsSatisfied = nil
            // F2: the physical interface index is observed-path state too. A stale index from
            // the previous monitor would pin a floor-claimed resolver to an interface the new
            // path no longer routes over, which is worse than no pin at all.
            self.latestPhysicalInterfaceIndex = nil
        }

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self,
                  self.isCurrentTunnelLifecycle(lifecycleGeneration) else {
                return
            }

            let update = NetworkPathUpdate(
                kind: Self.tunnelNetworkKind(for: path),
                isSatisfied: path.status == .satisfied,
                statusDescription: Self.pathStatusDescription(path.status)
            )
            // Stamp the freshest delivered path state HERE (this handler already runs
            // on dnsStateQueue), before deferring the heavier handleNetworkPathUpdate to
            // a second turn. The self-reconnect teardown guard reads this rather than
            // `health.networkPathIsSatisfied` (which lands a hop later) so it can't cancel
            // into a path update that's been delivered but not yet applied.
            let nextPhysicalIndex = Self.routedInterface(on: path).map { UInt32($0.index) }
            if self.resolverTierObservedPathKind != update.kind
                || self.latestMonitoredPathIsSatisfied != update.isSatisfied
                || self.latestPhysicalInterfaceIndex != nextPhysicalIndex {
                // Fence old-path evidence HERE, not in the deferred health transition. A
                // queued old timeout must not authorize recapture on a newly delivered link.
                // Same-kind interface changes matter even when the aggregate path stays healthy.
                self.resolverBackoffPathEpoch += 1
                self.resetResolverTierEvidence()
                self.resolverBackoffStateQueue.sync { self.resolverBackoffPolicy.reset() }
            }
            self.resolverTierObservedPathKind = update.kind
            self.latestMonitoredPathIsSatisfied = update.isSatisfied
            self.chainedBootRecoveryPathObservation += 1
            let bootObservation = self.chainedBootRecoveryPathObservation
            self.chainedBootRecoveryPathGate.observePhysical(generation: lifecycleGeneration,
                serial: bootObservation, isSatisfied: update.isSatisfied)
            self.chainedBootRecoveryPathDidChange()
            // F2: the live primary physical interface index, captured HERE because this is the
            // one hook holding the full `Network.NWPath`. `availableInterfaces` is the set the
            // path CAN use, not the one it routes over, and its `.first` can be a foreign
            // `utun` (or cellular while Wi-Fi carries the route) — so the index comes from the
            // SAME route-truth derivation the chained interface pick uses
            // (`Self.routedInterface(on:)`). Index 0 is not a real interface and the policy
            // refuses it. dnsStateQueue-confined (this handler runs on that queue), read
            // through `currentPhysicalInterfaceIndex()`.
            self.latestPhysicalInterfaceIndex = nextPhysicalIndex
            // The chained runtime's path feed lives HERE, the one hook holding the full
            // `Network.NWPath` — `NetworkPathUpdate` deliberately discards interface
            // identity, and a same-kind interface swap is exactly what the chained
            // socket must rebuild for.
            self.noteChainedPathObservation(path, satisfied: update.isSatisfied)
            self.dnsStateQueue.async { [weak self] in
                guard let self,
                      self.isCurrentTunnelLifecycle(lifecycleGeneration) else {
                    return
                }
                self.handleNetworkPathUpdate(update)
                self.chainedBootRecoveryPathGate.observeHealth(generation: lifecycleGeneration,
                    serial: bootObservation,
                    isSatisfied: self.currentResolverHealthSchedulingView().networkPathIsSatisfied)
                self.chainedBootRecoveryPathDidChange()
            }
        }

        monitor.start(queue: dnsStateQueue)
    }

    /// Feeds one path observation to the chained runtime: stash the egress policy's
    /// answer (deriving the identity-change signal), then tell the driver.
    ///
    /// Runs on `dnsStateQueue` (the monitor's delivery queue); the driver hop is
    /// `enqueue` — asynchronous — because `pathChanged` runs inline on the engine queue
    /// and a synchronous wait from this side would couple the two confinements
    /// (`INV-QUEUE-1`). Ordering across observations is preserved by the serial engine
    /// queue.
    private func noteChainedPathObservation(_ path: Network.NWPath, satisfied: Bool) {
        guard let runtime = chainedRuntime else { return }
        let eligible = Self.eligibleChainedInterface(on: path)
        let identityChanged = runtime.interfaceStash.update(eligible)
        // An identity change is what arms the rebind machinery, so its moment is incident
        // evidence and logs in every build; the per-callback observation line is QA capture
        // volume (brief-stall protocol: pair these against `chained-transport-*` lines and
        // the liveness deltas to attribute a stall to a spurious rebind vs the socket).
        if identityChanged {
            LavaSecDeviceDebugLog.append(
                component: "tunnel", event: "chained-path-identity-changed",
                details: [
                    "eligible": Self.chainedInterfaceLogValue(eligible),
                    "satisfied": "\(satisfied)",
                ])
        }
        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(
            component: "tunnel", event: "chained-path-observation",
            details: [
                "eligible": Self.chainedInterfaceLogValue(eligible),
                "identityChanged": "\(identityChanged)",
                "satisfied": "\(satisfied)",
            ])
        #endif
        runtime.engineQueue.enqueue { [weak driver = runtime.driver] in
            driver?.pathChanged(satisfied: satisfied, interfacesChanged: identityChanged)
        }
    }

    /// `en0/wifi`-shaped, or "nil" — an interface name and kind are diagnostics, not PII.
    private static func chainedInterfaceLogValue(_ interface: ChainedBindableInterface?) -> String {
        interface.map { "\($0.name)/\($0.kind.rawValue)" } ?? "nil"
    }

    /// Clear the coalesced encrypted-fallback log throttle so the NEXT wedge episode logs
    /// its first carried query immediately. The throttle is episode-scoped, so it must be
    /// cleared wherever a fallback episode ends (primary recovery) or a fresh
    /// resolver/network context begins — otherwise a marker logged <interval ago carries
    /// over and swallows the new episode's first carry.
    func clearEncryptedFallbackLogThrottle(phase: String = "episode-end") {
        // Flush any carried queries suppressed since the last marker before zeroing, so a
        // short/high-volume wedge that ends before the throttle interval still reports how
        // many queries the fallback saved (the whole point of the count) instead of
        // discarding them. Only emits when there is a pending remainder, so it stays quiet
        // when the throttle is already clear (the common no-op reset).
        //
        // `phase` labels the flush honestly: "episode-end" when the primary genuinely
        // recovered (organic primary query or ordered smoke-recovery effect),
        // "context-reset" when the episode was instead interrupted by a fresh network/resolver
        // context or a reused-instance session start — the count is still real, but the episode
        // did not "end" via recovery.
        if encryptedFallbackCarriedSinceLastLog > 0 {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-encrypted-fallback", details: [
                "phase": phase,
                "carriedSinceLastLog": "\(encryptedFallbackCarriedSinceLastLog)"
            ])
        }
        lastEncryptedFallbackLogAt = nil
        encryptedFallbackCarriedSinceLastLog = 0
    }

    // Cancels a scheduled fallback-recovery probe and retires the actor-owned
    // smoke token so a probe already in flight can't apply after the runtime moved
    // on. Independent of the fallback decision: wake() invalidates stale probes
    // without clearing fallback, while a network-path transition clears fallback
    // before invoking this fence.
    func invalidateInFlightSmokeProbes() {
        cancelFallbackRecoverySmokeProbe()
        invalidateResolverSmokeProbeToken()
    }

    func invalidateResolverSmokeProbeToken() {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        resolverHealthCoordinator.assumeIsolated { $0.invalidateInFlightSmokeProbe() }
    }

    private func handleNetworkPathUpdate(_ update: NetworkPathUpdate) {
        let previousKind = lastObservedPathKind
        let previousIsSatisfied = lastObservedPathIsSatisfied
        let isInitialPathUpdate = previousKind == nil && previousIsSatisfied == nil
        let didMeaningfullyChange = previousKind != update.kind || previousIsSatisfied != update.isSatisfied
        let now = Date()

        lastObservedPathKind = update.kind
        lastObservedPathIsSatisfied = update.isSatisfied
        networkKind = update.kind
        health.networkKind = update.kind
        // task #56: a physical roam that leaves the chained tunnelled plain-DNS carry intact must NOT
        // trigger the reducer's destructive resolver reset + pending-SERVFAIL. Evaluate the carry
        // BEFORE the event so the reducer decides against pre-reset route state.
        let chainedCarryUnchanged = chainedTunnelledDNSSurvivesPhysicalPathChange()
        applyResolverHealthEvent(
            .networkPathObserved(
                previousKind: previousKind,
                previousIsSatisfied: previousIsSatisfied,
                kind: update.kind,
                isSatisfied: update.isSatisfied,
                observedAt: now,
                chainedTunnelledDNSCarryUnchanged: chainedCarryUnchanged
            ),
            hooks: ResolverHealthEffectHooks(
                beforeResolverRuntimeReset: {
                    self.invalidateInFlightSmokeProbes()
                    self.refreshDeviceDNSResolverAddressesOnDNSQueue(
                        reason: "network-path-changed"
                    )
                },
                afterResolverRuntimeReset: {
                    self.resolverBootstrapService.invalidateAll()
                },
                beforeProtectionNotification: {
                    // A down path cannot settle a proactive resolver probe.
                    self.resolverProbeCoalescer.cancel()
                },
                beforePendingResolverFailures: { pendingResponses, _, resolverIdentifier in
                    LavaSecDeviceDebugLog.append(
                        component: "tunnel",
                        event: "network-path-changed",
                        details: [
                            "previousKind": previousKind?.rawValue ?? "nil",
                            "kind": update.kind.rawValue,
                            "previousSatisfied": previousIsSatisfied.map { "\($0)" } ?? "nil",
                            "isSatisfied": "\(update.isSatisfied)",
                            "status": update.statusDescription,
                            "pendingResponses": "\(pendingResponses.count)",
                            "resolverIdentifier": resolverIdentifier
                        ]
                    )
                }
            )
        )
        // A satisfied path callback is the "network is back / network moved" signal. When we are
        // DNS-only BECAUSE of a surrender, ANY satisfied update is a chance to recover the chain, so
        // attempt it HERE — ahead of the meaningful-change guard below. That guard's
        // `didMeaningfullyChange` is computed from the COARSE network kind + satisfaction bit only;
        // the full NWPath interface identity is observed by `noteChainedPathObservation`, whose
        // chained runtime is ABSENT while surrendered. So a same-kind Wi-Fi→Wi-Fi roam (both
        // satisfied, no intervening unsatisfied status) is invisible to the guard and would otherwise
        // never reach recovery, leaving the tunnel Paused until a different-kind/status transition or
        // a manual Reset (Codex, PR #569 round 13). The attempt is internally gated on the surrender
        // latch (a cheap no-op otherwise) and coalesced per lifecycle, so firing it on every
        // satisfied update is safe; a genuinely dead chain converges to DNS-only via the recovery cap.
        //
        // `completeAbortedOnly: isInitialPathUpdate`: the INITIAL update only FINISHES an aborted
        // handoff whose surrender a PREVIOUS lifecycle already cleared — a new lifecycle can start
        // latched `.chainedSurrendered` while that prior task's fenced-off cancel left the store
        // cleared — and never initiates a fresh recovery that would clear a genuine startup surrender.
        // A later satisfied update runs the full recovery. Placed ahead of the reapply because it may
        // restart the tunnel outright.
        if update.isSatisfied {
            if attemptChainedSurrenderAutoRecoveryIfNeeded(completeAbortedOnly: isInitialPathUpdate) {
                // ADMITTED: the attempt IS this lifecycle's handoff completion (it will read the cleared
                // store and restart). Claim a retained signal so the attempt's OWN marker release does
                // not re-pump a DUPLICATE complete-only task that races to cancel the same lifecycle
                // (Codex, PR #569 round 17).
                chainedHandoffRecoveryPending = false
            } else {
                // NOT admitted. Do NOT blind-clear: the attempt COALESCED (an in-flight task owns this
                // generation's marker and may itself DECLINE — clearing would strand a stationary
                // session, Codex PR #569 round 18), OR the lifecycle is not surrendered (the signal is
                // moot). Route through the pump: it PRESERVES the signal while a task holds the marker
                // (that task's release re-pumps) and DRAINS it (no-op attempt) once the lifecycle is
                // ready and chained.
                pumpChainedHandoffRecoveryIfIdle()
            }
        }
        guard !isInitialPathUpdate, didMeaningfullyChange else {
            return
        }

        if update.isSatisfied {
            reapplyTunnelNetworkSettings(reason: "network-path-changed", enforceThrottle: true)
            #if DEBUG || LAVA_QA_TOOLS
            // A meaningful satisfied path change while chained is the OTHER moment DNS is
            // expected to be briefly down (the socket must recover onto the new interface
            // before a resolver reply can return). Open the recovery window so the roam gap is
            // measured the same way cold-start is. No-op when not chained (guards on runtime).
            openChainedRecoveryWindow(
                reason: "path-change:\(previousKind?.rawValue ?? "nil")->\(update.kind.rawValue)")
            #endif
            // Coalesce the proactive resolver rebuild (bootstrap pre-warm + smoke
            // probe) so a flap burst re-handshakes once after the path settles,
            // not once per flap (plan item 430). Settings reapply keeps its own
            // ≥1 s throttle above.
            resolverProbeCoalescer.noteUnsettled()
            // dns-recovery optimization C: the immediate capture above (and the
            // +1.5s settle re-capture) can come back empty on a masked handoff,
            // stranding a device-DNS user on the previous network's unreachable
            // resolvers. Re-read on a short cadence until the capture is non-empty
            // so resolution recovers in place instead of waiting on a restart.
            scheduleDeviceDNSCaptureRetryIfNeeded(reason: "network-path-changed")
        } else {
            // Path is down: stop re-reading resolvers into a dead network; the next
            // satisfied update re-arms the retry.
            cancelDeviceDNSCaptureRetry()
        }
    }

    /// Bounded hands-free recovery from a surrendered DNS-only state (Slice 2 of the
    /// surrender-recovery plan). Called on `dnsStateQueue` from the satisfied-path handler.
    ///
    /// The `.chainedSurrendered` refusal is the whole gate: `TunnelDataPathLatch` reaches it only
    /// after chaining is enabled, the build supports it, and the device is eligible — so the
    /// refusal alone means "everything but a standing surrender would select chained". The
    /// Keychain read+write and the restart run OFF the DNS queue (`INV-QUEUE-1`); the restart is
    /// the same `cancelTunnelWithError` the surrender itself uses, which re-runs the latch — now
    /// with the surrender cleared, so it re-selects chained. `ChainedSurrenderAutoRecoveryPolicy`
    /// bounds it to a rolling window so a dead chain on a flapping path converges to DNS-only
    /// (until a user turn-on) rather than looping recover→surrender→recover.
    /// pinned: ChainedSurrenderAutoRecoverySourceTests.testASatisfiedPathTriggersBoundedAutoRecovery
    /// Whether a pending hands-free recovery task should still commit: the originating lifecycle
    /// is current AND the freshest delivered path is still satisfied. Read on `dnsStateQueue`
    /// (the stamp's confinement) via the same specific-key dual-entry as ``isCurrentTunnelLifecycle``.
    /// The path term guards a satisfied→unsatisfied FLAP landing while the async Keychain work is
    /// pending — the same generation, so the lifecycle fence alone would still permit a cancel into
    /// a dead path (Codex, PR #569); the self-reconnect teardown revalidates the same stamp.
    private func chainedAutoRecoveryRemainsViable(generation: UInt64) -> Bool {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return generation == tunnelLifecycleGeneration && latestMonitoredPathIsSatisfied
        }
        return dnsStateQueue.sync {
            generation == tunnelLifecycleGeneration && latestMonitoredPathIsSatisfied
        }
    }

    /// - Parameter completeAbortedOnly: when true (a new lifecycle's initial satisfied update),
    ///   restart ONLY to finish an aborted handoff whose surrender the store already shows cleared;
    ///   never clear a standing surrender. Keeps a fresh startup surrender DNS-only until a real
    ///   network change, while still completing the handoff gap (Codex, PR #569).
    /// - Returns: `true` only if a recovery task was ADMITTED (the coalescing marker was claimed and a
    ///   global task dispatched). `false` at every early guard — not surrendered, on-demand off,
    ///   COALESCED (another in-flight task owns this generation's marker), or store unavailable. The
    ///   caller uses this to decide whether a retained handoff signal was consumed: a coalesced attempt
    ///   consumes NOTHING, so the signal must be preserved for the in-flight task's marker release, not
    ///   cleared (Codex, PR #569 round 18).
    @discardableResult
    private func attemptChainedSurrenderAutoRecoveryIfNeeded(completeAbortedOnly: Bool = false) -> Bool {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        // The refusal must be `.chainedSurrendered` AND belong to the CURRENT lifecycle — symmetric
        // with the pump's readiness gate and the final cancel fence. In the startup window
        // (beginTunnelLifecycle bumped the generation but loadInitialSharedState has not yet installed
        // this lifecycle's latch) the refusal is a stale carry-over from the previous lifecycle; a
        // direct path callback cannot reach here then (the monitor is armed after the latch), so the
        // generation term is defense-in-depth, but it keeps this gate structurally consistent with the
        // pump — which was hardened for exactly this window (Codex round 16; adversarial agent round 18).
        guard latchedDataPathRefusal == .chainedSurrendered,
            latchedDataPathRefusalGeneration == tunnelLifecycleGeneration
        else { return false }
        // A cancel only RECOVERS if Connect-On-Demand is armed to relaunch the tunnel. Without it,
        // cancelling tears the WORKING DNS-only surrender state (C4 — the tunnel is up and still
        // filtering, INV-DNS-1) down into NO tunnel with no automatic recovery: a fail-OPEN,
        // strictly worse than the surrendered state this path exists to improve. (The surrender's
        // OWN unconditional cancel is safe because a surrendered CHAINED tunnel blackholes every
        // destination — VPN-off is strictly better there; here DNS-only WORKS, so VPN-off is
        // strictly worse.) The self-reconnect path gates its cancel the same way, and for the same
        // reason. Checked FIRST, ahead of the epoch spend and surrender clear, so the protected
        // DNS-only state and the recovery budget survive intact when we cannot relaunch (Codex, PR
        // #569 round-3 adversarial hunt).
        guard Self.isOnDemandConfirmedEnabled() else { return false }
        // Captured on the DNS queue: the restart must fence to THIS lifecycle so a slow Keychain
        // op that outlives it cannot tear down a newer, healthy session (Codex, PR #569); it also
        // keys the coalescing marker below.
        let generation = tunnelLifecycleGeneration
        // Coalesce: at most ONE CONCURRENTLY IN-FLIGHT recovery task per lifecycle (the marker is held
        // from here until the task's completion clears it), or a flapping surrendered network would
        // pile up blocked global tasks on a wedged Keychain until the NE is jetsammed (INV-MEM-1,
        // Codex, PR #569). Keyed on the owning generation, not a process-wide flag, so a task wedged
        // by an old, since-replaced lifecycle cannot block THIS lifecycle's recovery forever (round
        // 13); a wedged SecItem still holds the slot for its OWN generation, correctly suppressing
        // that lifecycle's repeats, and releases it when securityd recovers. NOTE this bounds
        // CONCURRENCY, not the lifetime count: the marker frees at the store read's completion, before
        // the async cancel lands, so a same-generation task CAN be admitted sequentially — the final
        // cancel's per-generation idempotence (chainedRecoveryCancelIssuedGeneration) is what prevents
        // that from double-cancelling (adversarial panel, PR #569 round 17).
        guard chainedAutoRecoveryInFlightGeneration != generation else { return false }
        // PROCESS-WIDE ceiling across ALL generations (INV-MEM-1). The per-generation marker above lets
        // each new lifecycle admit its own recovery even while an OLD generation's task is wedged in an
        // unbounded SecItem call (round 13). Without this, reconnect churn during a securityd wedge
        // would dispatch one blocked global task per generation, each retaining self, until jetsam.
        // Refusing here leaves the safe DNS-only surrender standing; recovery resumes when securityd
        // recovers and the count drains (Codex, PR #569 round 19) — but a stationary path gets no
        // further callback, so retain a capacity-waiting attempt (generation + mode) that a slot drain
        // will retry, or the tunnel stays surrendered until manual action (Codex, PR #569 round 20).
        guard chainedRecoveryInFlightTaskCount < Self.maxConcurrentChainedRecoveryTasks else {
            chainedRecoveryCapacityWaitingGeneration = generation
            chainedRecoveryCapacityWaitingCompleteAbortedOnly = completeAbortedOnly
            return false
        }
        guard let store = chainedDeviceEligibilityStore() else { return false }
        chainedAutoRecoveryInFlightGeneration = generation
        chainedRecoveryInFlightTaskCount += 1
        // The Keychain read+write and the restart never touch the DNS queue (INV-QUEUE-1).
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // The whole decision (already-cleared bypass → reason gate → cap → clear) lives in the
            // store, in ONE read, so the cap can never pre-empt the already-cleared plain restart
            // (the aborted-final-recovery case), and the write is fenced on the originating
            // lifecycle (a stale task must not clear a newer lifecycle's surrender).
            let outcome: ChainedDeviceEligibilityStore.AutoRecoveryOutcome
            do {
                outcome = try store.recordSurrenderAutoRecovery(
                    nowEpoch: Date().timeIntervalSince1970,
                    onlyIfAlreadyCleared: completeAbortedOnly,
                    isRecoverableReason: {
                        // Only a surrender a NETWORK CHANGE can clear (budgetExhausted). A
                        // non-transient fault (engine/contract/clock), or an unknown reason
                        // string, is left surrendered — retrying it just re-enters the broken chain.
                        ChainedReconnectPolicy.Surrender(rawValue: $0)?.isResolvableByNetworkChange
                            ?? false
                    },
                    isStillWanted: { self.chainedAutoRecoveryRemainsViable(generation: generation) })
            } catch {
                self.clearChainedAutoRecoveryInFlight(generation: generation)
                LavaSecDeviceDebugLog.append(
                    component: "tunnel", event: "chained-surrender-autorecovery-skipped",
                    details: ["reason": "persist-failed", "error": "\(error)"])
                return
            }
            self.clearChainedAutoRecoveryInFlight(generation: generation)
            guard outcome == .restart else {
                // Non-transient reason, cap exhausted, unreadable store, or a lost fence at write
                // time — the working DNS-only tunnel stands and (if a transient surrender remains)
                // the next satisfied path change retries.
                LavaSecDeviceDebugLog.append(
                    component: "tunnel", event: "chained-surrender-autorecovery-skipped",
                    details: ["reason": "\(outcome)"])
                return
            }
            // Final fence AND cancel on ONE dnsStateQueue turn, mirroring
            // `performGuardedSelfReconnectTeardown`: reading the guards + issuing the cancel in the
            // same block means none can flip between the check and the teardown.
            // `cancelTunnelWithError` is async to iOS, so issuing it here does not block or deadlock
            // — and this task runs on the GLOBAL queue, not the engine queue whose dnsStateQueue
            // wait 11496 forbids. On a lost lifecycle, a flapped path, or on-demand having gone off we
            // simply DON'T cancel: the surrender is already cleared, so the next satisfied path change
            // (this lifecycle or the new one) finishes the recovery with a plain restart once the
            // guards hold again — no state to reinstate.
            self.dnsStateQueue.async { [weak self] in
                guard let self else { return }
                // RE-READ the on-demand gate here, not just at attempt-start (6633): the guard runs on
                // the initial turn, but the Keychain decision above runs on the global queue and its
                // SecItem read is slow/unbounded. If the user disables Connect-On-Demand OUT OF APP
                // (iOS Settings) during that window, AppViewModel's reconcile writes the confirmed
                // mirror false WITHOUT stopping the running tunnel — generation, latch stamp, active,
                // and path all still hold — so the four ownership terms alone would still pass and we
                // would cancel a WORKING DNS-only surrender into no-tunnel-with-no-relaunch: a
                // fail-OPEN (INV-DNS-1), exactly what the attempt-start gate prevents. The sibling
                // self-reconnect teardown re-reads on-demand in its own final block for the same
                // reason (adversarial panel, PR #569 round 16).
                //
                // The remaining terms fence the cancel to a LIVE lifecycle that OWNS its latch — not
                // just a matching generation, which can be a stopped provider (post-invalidate) or a
                // startTunnel that bumped the generation but not yet installed its latch (Codex, round 16).
                guard Self.isOnDemandConfirmedEnabled(),
                    self.tunnelLifecycleIsActive,
                    self.tunnelLifecycleGeneration == generation,
                    self.latchedDataPathRefusalGeneration == generation,
                    self.latestMonitoredPathIsSatisfied
                else {
                    LavaSecDeviceDebugLog.append(
                        component: "tunnel", event: "chained-surrender-autorecovery-skipped",
                        details: ["reason": "lifecycle-or-path-changed-before-cancel"])
                    // A NEWER lifecycle superseded us AFTER we committed the clear (outcome == .restart
                    // above): the clear is orphaned to it, and its own initial complete-only read may
                    // have raced AHEAD of our just-committed write (the store is non-atomic across the
                    // process boundary), leaving it latched DNS-only with no further callback on a
                    // stationary path. Retain a durable pending signal and pump it when the in-flight
                    // marker is next free — EVENT-DRIVEN, so it waits for the racing read to actually
                    // finish rather than a fixed timer that an unbounded SecItem read can outlast
                    // (Codex, PR #569 round 15). A SAME-generation flap (path unsatisfied) needs no
                    // handoff: this lifecycle is still live; its next satisfied path update finishes it.
                    if self.tunnelLifecycleGeneration != generation {
                        self.chainedHandoffRecoveryPending = true
                        self.pumpChainedHandoffRecoveryIfIdle()
                    }
                    return
                }
                // Idempotent per generation. `cancelTunnelWithError` is async, so issuing it does NOT
                // bump the generation synchronously — the fence terms above stay true until iOS tears
                // the session down. A SECOND recovery task reaching this fence for the SAME generation
                // (a late fenced-off task that re-armed the handoff pump, or a same-generation
                // re-admission after the coalescing marker freed but before this cancel lands) would
                // otherwise cancel one lifecycle twice. Refuse to cancel a generation we already
                // cancelled (adversarial panel, PR #569 round 17).
                guard self.chainedRecoveryCancelIssuedGeneration != generation else {
                    LavaSecDeviceDebugLog.append(
                        component: "tunnel", event: "chained-surrender-autorecovery-skipped",
                        details: ["reason": "cancel-already-issued"])
                    return
                }
                self.chainedRecoveryCancelIssuedGeneration = generation
                LavaSecDeviceDebugLog.append(
                    component: "tunnel", event: "chained-surrender-autorecovery", details: [:])
                // Logged BEFORE the cancel, which tears this process down (the surrender path's
                // CON-1 reasoning): the OS restarts the tunnel and the latch re-selects chained.
                self.cancelTunnelWithError(nil)
            }
        }
        // Admitted: the marker is claimed and the global task dispatched. The caller may now treat a
        // retained handoff signal as consumed by THIS task.
        return true
    }

    /// Runs at a recovery task's completion (exactly once per dispatched task). It ALWAYS decrements
    /// the process-wide in-flight count — even for a stale task whose marker a newer generation
    /// overwrote, since that task still incremented and its physical work has now finished
    /// (`INV-MEM-1`, Codex PR #569 round 19). It releases the per-generation coalescing marker ONLY if
    /// `generation` still owns it: a task wedged by an old lifecycle can return long after a newer
    /// lifecycle admitted its own recovery, and a blind clear would release the newer task's slot and
    /// let a flap re-launch a duplicate (round 13). A wedged `SecItem*` never reaches here, so it keeps
    /// holding its count slot and its marker until securityd recovers — exactly the bound we want.
    /// pinned: ChainedSurrenderAutoRecoverySourceTests.testASatisfiedPathTriggersBoundedAutoRecovery
    private func clearChainedAutoRecoveryInFlight(generation: UInt64) {
        dnsStateQueue.async { [weak self] in
            guard let self else { return }
            self.chainedRecoveryInFlightTaskCount = max(0, self.chainedRecoveryInFlightTaskCount - 1)
            if self.chainedAutoRecoveryInFlightGeneration == generation {
                self.chainedAutoRecoveryInFlightGeneration = nil
                // The marker is now free: a handoff a superseded lifecycle could not restart can run,
                // strictly AFTER the read that just released the marker finished — the event that a
                // fixed timer could not wait for (Codex, PR #569 round 15).
                self.pumpChainedHandoffRecoveryIfIdle()
            }
            // A slot just drained: retry a recovery that was refused for capacity. AFTER the marker
            // clear above, so the retry's fresh marker is never niled by this same task's clear.
            self.drainChainedRecoveryCapacityWaiter()
        }
    }

    /// Retries a recovery that the process-wide ceiling refused, once a slot has drained. Fenced to the
    /// CURRENT lifecycle: a stale waiting generation is dropped (a newer lifecycle drives its own
    /// recovery from its own path callbacks). Preserves the refused mode so an initial-update refusal
    /// stays complete-only. On no capacity yet, it leaves the waiter for the next drain (Codex, PR #569
    /// round 20).
    /// pinned: ChainedSurrenderAutoRecoverySourceTests.testASatisfiedPathTriggersBoundedAutoRecovery
    private func drainChainedRecoveryCapacityWaiter() {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        guard let waiting = chainedRecoveryCapacityWaitingGeneration else { return }
        guard waiting == tunnelLifecycleGeneration else {
            chainedRecoveryCapacityWaitingGeneration = nil
            return
        }
        guard chainedRecoveryInFlightTaskCount < Self.maxConcurrentChainedRecoveryTasks else { return }
        // DEFER (retain the waiter) while THIS generation's marker is held: the re-attempt below would
        // hit the per-generation coalescing guard and return false WITHOUT re-setting the waiter (only
        // the ceiling path re-sets it), silently losing it. E.g. the handoff pump — which runs just
        // before this drain in clearChainedAutoRecoveryInFlight — can admit a complete-only task for
        // this generation; that task would coalesce our full-recovery re-attempt and then decline a
        // standing surrender, leaving a stationary path stuck. The marker-holder's own completion
        // re-drains us with the marker free (adversarial agent, PR #569 round 20 follow-up). Only nil
        // the waiter once we are about to actually admit.
        guard chainedAutoRecoveryInFlightGeneration != tunnelLifecycleGeneration else { return }
        let mode = chainedRecoveryCapacityWaitingCompleteAbortedOnly
        chainedRecoveryCapacityWaitingGeneration = nil
        attemptChainedSurrenderAutoRecoveryIfNeeded(completeAbortedOnly: mode)
    }

    /// Runs a pending cross-lifecycle handoff completion once no recovery task holds the marker.
    ///
    /// A superseded lifecycle's recovery clears the store surrender then fails to restart (its cancel
    /// fenced off); the newer lifecycle's initial complete-only read can race AHEAD of that clear
    /// write, so it declines and — on a stationary path — nothing else re-reads. The superseded task
    /// records `chainedHandoffRecoveryPending`; this pump re-drives a complete-only attempt for the
    /// CURRENT lifecycle, but ONLY when `chainedAutoRecoveryInFlightGeneration == nil` so it cannot be
    /// coalesced away by the very read it is meant to follow (the round-14 timer's flaw). Gating on
    /// the free marker makes it event-driven, immune to the unbounded `SecItem*` read duration. It is
    /// pumped from every marker release, so a still-in-flight read defers it to that read's completion.
    /// `completeAbortedOnly: true` keeps a GENUINE startup surrender DNS-only; the attempt's own latch
    /// gate no-ops if this lifecycle is no longer surrendered (Codex, PR #569 round 15).
    /// pinned: ChainedSurrenderAutoRecoverySourceTests.testASatisfiedPathTriggersBoundedAutoRecovery
    private func pumpChainedHandoffRecoveryIfIdle() {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        guard chainedHandoffRecoveryPending else { return }
        // A running attempt still owns the marker; its release re-pumps. Deferring here is what makes
        // the re-attempt land AFTER the racing read instead of coalescing into it.
        guard chainedAutoRecoveryInFlightGeneration == nil else { return }
        // RETAIN the signal until an ACTIVE lifecycle owns its OWN latch. A generation mismatch is not
        // proof a newer lifecycle is ready: `tunnelLifecycleGeneration` bumps on invalidate (no active
        // lifecycle) and at startTunnel BEFORE loadInitialSharedState installs the latch, while
        // `latchedDataPathRefusal` still holds the PREVIOUS lifecycle's `.chainedSurrendered`. Firing
        // across either window could re-drive a restart and cancel a STOPPED provider or a freshly
        // starting healthy lifecycle (Codex, PR #569 round 16). Not cleared here: the ready lifecycle's
        // first satisfied path update re-pumps (and its own initial attempt also completes the handoff).
        guard tunnelLifecycleIsActive,
            latchedDataPathRefusalGeneration == tunnelLifecycleGeneration
        else { return }
        chainedHandoffRecoveryPending = false
        attemptChainedSurrenderAutoRecoveryIfNeeded(completeAbortedOnly: true)
    }

    /// Post a path change when a snapshot adoption LOOSENED filtering, so apps holding long-lived
    /// connections re-resolve instead of retrying addresses they can no longer reach.
    ///
    /// This is the fix for the 2026-09-02 report: the Extra → Balanced switch applied correctly and
    /// Messenger still could not connect for over two hours, until the Guard was manually cycled.
    /// `reapplyTunnelNetworkSettings` was reached only on a RESOLVER change, so a filter-only
    /// change posted nothing and every held connection stayed pointed at what it had.
    ///
    /// Only loosening, and only on a real change — see `FilterLooseningReapplyPolicy` for why the
    /// asymmetry is deliberate, why the signal is two counts rather than a rule diff under
    /// `INV-MEM-1`, and which case that trade knowingly misses.
    ///
    /// UNTHROTTLED, like the configuration-change caller and unlike the network-flap one. A
    /// dropped nudge IS the bug this path exists to fix, so the flap caller's drop-on-contention is
    /// exactly the wrong behaviour here. An earlier revision instead made the throttle DEFER for
    /// this caller — trailing timer, lifecycle-fenced pending slot, per-schedule token, bounded post
    /// retry — and every one of those parts drew its own review finding, several of them defects in
    /// the part added one round before. A redundant path post is cheap and idempotent; that
    /// machinery was not (PR #645).
    /// pinned: FilterLooseningReapplySourceTests.testALooseningAdoptionNudgesConnectedApps
    func recordAdoptedRuleCounts(
        _ adopted: FilterLooseningReapplyPolicy.RuleCounts,
        recoveringFromFailClosed: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        do {
            let previous = self.lastAdoptedRuleCounts
            self.lastAdoptedRuleCounts = adopted

            // EXITING FAIL-CLOSED IS ALWAYS A LOOSENING, whatever the counts say. A fail-closed
            // resident blocks everything, and it does not update this baseline — only real-snapshot
            // commits do — so recovery compares against the last HEALTHY ruleset instead of against
            // the block-all one the user was actually just on. A recovery into a tighter filter than
            // that old healthy one reads as a tightening and posts nothing, leaving every app that
            // failed during the fail-closed window stuck exactly as the 2026-09-02 reporter was
            // (Codex review, PR #645).
            let isLoosening = recoveringFromFailClosed
                || FilterLooseningReapplyPolicy.isLoosening(previous: previous, adopted: adopted)

            // COUNTED BEFORE THE GATE, which is the whole point: the question is how often the
            // ruleset changes AT ALL, and every adoption that does not loosen returns below without
            // leaving a trace anywhere else. `loosened` splits the total into the two arms, so one
            // event answers both "how often would nudging on every adoption fire" and "how much of
            // that the policy currently suppresses".
            //
            // `loosened`, NOT `nudged`: this is the policy's VERDICT, and a verdict of true does not
            // guarantee a post. A commit landing in the `stopTunnel` window reaches
            // `reapplyTunnelNetworkSettings` after the lifecycle bit is already false, and it skips
            // — so a field named for the outcome would overstate nudges and bias the very ratio this
            // event exists to measure (Codex review, PR #647). The verdict is also the RIGHT signal
            // for the comparison being made: nudging on every adoption would meet the same lifecycle
            // guard, so the skip cancels out of the ratio, and `network-settings-reapply-skipped`
            // already records each skip for anyone who needs post-level counts.
            // pinned: FilterLooseningReapplySourceTests.testEveryAdoptionIsCountedForQA
            adoptedSnapshotCount += 1
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "ruleset-adopted", details: [
                "adoptionCount": "\(adoptedSnapshotCount)",
                "loosened": "\(isLoosening)"
            ])

            guard isLoosening else {
                return
            }
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "ruleset-loosened-nudge", details: [
                "recoveringFromFailClosed": "\(recoveringFromFailClosed)",
                "previousBlockRuleCount": "\(previous?.blockRuleCount ?? -1)",
                "blockRuleCount": "\(adopted.blockRuleCount)",
                "previousAllowRuleCount": "\(previous?.allowRuleCount ?? -1)",
                "allowRuleCount": "\(adopted.allowRuleCount)",
                "previousGuardrailRuleCount": "\(previous?.guardrailRuleCount ?? -1)",
                "guardrailRuleCount": "\(adopted.guardrailRuleCount)"
            ])
            self.reapplyTunnelNetworkSettings(reason: "ruleset-loosened", enforceThrottle: false)
        }
    }

    /// INV-QUEUE-1: dnsStateQueue-confined. Every caller is already inside the queue — the settings
    /// accessor is dual-entry precisely for that.
    func reapplyTunnelNetworkSettings(
        reason: String, enforceThrottle: Bool, isRetryOfFailedPost: Bool = false
    ) {
        // A POST NEEDS A LIVE SESSION, and this PR is what made that reachable.
        //
        // `stopTunnel` runs `invalidateTunnelLifecycle` SYNCHRONOUSLY, while the cleanup that calls
        // `invalidateSnapshotReloadGeneration` is dispatched with `dnsStateQueue.async`. In the
        // window between them the activity bit is already false but the reload generation still
        // passes, so a decode finishing right then commits, the commit closure records the counts,
        // and the nudge posted `setTunnelNetworkSettings` into a provider being torn down (Codex
        // review, PR #645). The two pre-existing callers are network/config events that cannot land
        // in that window; the snapshot-commit caller this PR adds is precisely the one that can.
        //
        // The activity BIT, not the generation: this asks "is there a session at all", the same
        // distinction `currentTunnelLifecycleIsActive` documents.
        // pinned: FilterLooseningReapplySourceTests.testASettingsPostIsFencedToALiveLifecycle
        guard tunnelLifecycleIsActive else {
            // Only `reason` (which caller wanted the post). The event name already carries the
            // cause, and there is exactly one way to reach it — a second key would be a new entry
            // in `BugReportBundle.allowedDetailKeys` for nothing, and an emitted-but-unlisted key
            // exports as `_withheld`.
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "network-settings-reapply-skipped", details: [
                "reason": reason
            ])
            return
        }

        // Discovery preparation and the startup drain own all cold settings posts. A satisfied
        // path/configuration/filter update during that window must join their latest snapshot,
        // rather than post before initial discovery or race a settings callback (INV-DNS-7).
        // pinned: DNSPatchRouteDiscoverySourceTests.testOrdinarySettingsReapplyCannotBypassTheStartupInstallDrain
        if let action = dnsPatchStartupInstallPolicy?.requestSettingsReapply(
            lifecycleGeneration: tunnelLifecycleGeneration), action != .reapply {
            return
        }

        // MONOTONIC, and clamped at zero. A wall-clock `Date` marker made this guard fire
        // backwards: a rollback turns the interval negative, the `>=` fails, and the post is dropped
        // for the duration of the correction (Codex review, PR #645). `DispatchTime` cannot run
        // backwards. Computed in `Double` rather than on `UInt64` so an out-of-order pair could not
        // trap in the NE process either.
        // pinned: FilterLooseningReapplySourceTests.testTheThrottleUsesAMonotonicClock
        let now = DispatchTime.now()
        let elapsed = lastNetworkSettingsReapplyUptime.map {
            max(0, Double(now.uptimeNanoseconds) - Double($0.uptimeNanoseconds)) / 1_000_000_000
        } ?? .greatestFiniteMagnitude
        // DROPS, and only the network-flap caller opts in. The loosening caller deliberately does
        // NOT: for it a dropped nudge IS the bug this path exists to fix, and an earlier revision of
        // this PR answered that by making the throttle DEFER instead — a trailing timer, a pending
        // slot fenced by lifecycle generation and a per-schedule token, a bounded post retry. Every
        // one of those parts drew its own review finding, several of them defects in the part added
        // one round earlier. The nudge is cheap and idempotent, so the burst it would have collapsed
        // costs a few redundant path posts; the machinery cost far more than that (PR #645).
        guard !enforceThrottle || elapsed >= Self.networkSettingsReapplyMinimumInterval else {
            return
        }

        lastNetworkSettingsReapplyUptime = now
        // Latched, not live: this runs on a network flap and on the reload-configuration IPC
        // path, immediately after refreshConfigurationIfNeeded(force: true) has installed a
        // NEW configuration. Reading the chaining flag here instead of the latch is exactly
        // how a settings write would silently re-route a running session.
        //
        // F4: the claimed-destination box is republished HERE, at the same point the route plan's
        // capture-floor routes are re-derived, so the classifier's `:853` drop can never lag the
        // routes after a roam. The value comes from the SAME helper the plan's floor uses and the
        // same live `currentDeviceDNSResolverAddresses()`, so the two cannot disagree. A nil box
        // means no chained runtime is latched (DNS-only), so there is nothing to republish.
        chainedClaimedResolverDestinations?.update(
            makeClaimedResolverDestinations(for: currentTunnelDataPathMode()))
        let settingsBundle = makeTunnelNetworkSettingsForLatchedDataPath()

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "network-settings-reapply-begin", details: [
            "reason": reason,
            "kind": currentNetworkKind().rawValue,
            "dnsServerAddress": settingsBundle.dnsServerAddress,
            "route": settingsBundle.routeDescription,
            // The ordinary reapply site. The device log is 8 MB-capped and keeps one prior
            // generation, and a bug report reads the last 40 entries — so on a long-lived session
            // the startup record ages out of what a capture can see and this becomes the only
            // settings-apply evidence left (`INV-DNS-7`, Codex PR #728). Logging the scope at one
            // site only would make the coverage answerable for a session that flapped recently and
            // not for one that did not — the opposite of the intent.
            "dnsCapture": settingsBundle.dnsCaptureScope.logValue,
            "dataPath": settingsBundle.mode.logValue
        ])

        let postedForLifecycle = tunnelLifecycleGeneration
        setTunnelNetworkSettings(settingsBundle.settings) { [weak self] error in
            guard let self else {
                return
            }

            if let error {
                LavaSecDeviceDebugLog.append(
                    component: "tunnel",
                    event: "network-settings-reapply-error",
                    details: Self.errorDebugDetails(error)
                )
            } else {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "network-settings-reapply-success", details: [
                    "reason": reason,
                    "kind": self.currentNetworkKind().rawValue
                ])
            }

            if let error {
                self.recordNetworkSettingsReapplyFailure(error, reason: reason)
                // RETRY ONCE, because a failed post is unrecoverable rather than merely unlucky.
                //
                // `recordAdoptedRuleCounts` advanced `lastAdoptedRuleCounts` before calling here, so
                // an identical later reload compares equal, reads as no loosening, and posts
                // nothing — the apps this path exists for stay stuck (Codex review, PR #645).
                //
                // RETRY THE POST, NOT A REWIND OF THE BASELINE. The baseline records what is
                // RESIDENT and the resident genuinely changed; only the notification was lost.
                // Rewinding it would make it disagree with the snapshot it describes, and that
                // inconsistency would be load-bearing for every later comparison.
                //
                // `isRetryOfFailedPost` is a plain parameter and is sound BECAUSE this path no
                // longer defers: a previous revision bounded the retry with a `-retry` suffix on the
                // reason, and the trailing timer rewrote that reason to `…-retry-deferred`, defeating
                // the bound and posting settings once a second forever. With no timer there is no
                // hop to survive and nothing to rewrite the flag.
                //
                // Unthrottled, whatever the original caller asked for: the floor spaces real path
                // changes, and a post that failed produced none.
                // pinned: FilterLooseningReapplySourceTests.testAFailedPostIsRetriedOnce
                guard !isRetryOfFailedPost else {
                    return
                }
                self.dnsStateQueue.async { [weak self] in
                    guard let self,
                          self.tunnelLifecycleIsActive,
                          self.tunnelLifecycleGeneration == postedForLifecycle else {
                        return
                    }
                    self.reapplyTunnelNetworkSettings(
                        reason: "\(reason)-retry", enforceThrottle: false,
                        isRetryOfFailedPost: true)
                }
            }
        }
    }

    private func recordNetworkSettingsReapplyFailure(_ error: Error, reason: String) {
        let now = Date()
        let failureReason = "\(reason): \(Self.errorSummary(error))"
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.health.lastNetworkSettingsReapplyFailureAt = now
            self.health.lastNetworkSettingsReapplyFailureReason = failureReason
            self.health.networkSettingsReapplyFailureCount += 1
            self.applyResolverHealthEvent(
                .networkSettingsReapplyFailed(
                    reason: failureReason,
                    occurredAt: now
                )
            )
        }
    }
}
