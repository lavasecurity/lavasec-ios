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
    // MARK: - Snapshot reload orchestration

    func requestSnapshotReload(reason: String, force: Bool = false, operationID: LatencyOperationID? = nil) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.requestSnapshotReload(reason: reason, force: force, operationID: operationID)
            }
            return
        }

        let pauseUntil = refreshTemporaryProtectionPauseState(synchronizesDefaults: true)
        let pauseIsActive = pauseUntil.map { $0 > Date() } ?? false
        let didChangePauseActivity = pauseIsActive != lastAppliedTemporaryProtectionPauseIsActive
        lastAppliedTemporaryProtectionPauseIsActive = pauseIsActive
        scheduleProtectionPauseResumeIfNeeded(reason: reason)

        guard force || didChangePauseActivity else {
            #if DEBUG || LAVA_QA_TOOLS
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "snapshot-reload-skipped", details: [
                "reason": reason,
                "pauseActive": "\(pauseIsActive)"
            ])
            #endif
            return
        }

        loadSnapshotInBackground(
            reason: reason,
            operationID: operationID,
            resetsDNSRuntimeOnChange: true
        )
    }

    private func nextSnapshotReloadGeneration() -> UInt64 {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            return dnsStateQueue.sync {
                nextSnapshotReloadGeneration()
            }
        }

        return snapshotReloadCoordinator.assumeIsolated { $0.begin() }
    }

    /// Clear the in-flight marker when a load resolves, but ONLY if it is still the latest reload — an
    /// overlapping newer load (a concurrent app provider-message reload) keeps ownership and clears it itself.
    /// dnsStateQueue-confined, mirroring the other reload-generation bookkeeping.
    private func clearSnapshotReloadInFlight(ifCurrentGeneration generation: UInt64) {
        dnsStateQueue.async { [weak self] in
            guard let self else { return }
            // INV-QUEUE-1: see advanceFocusConfigurationWatermark — the clear is FIFO-after the watermark
            // advance only because both run on this queue. Assert so an off-queue refactor trips.
            dispatchPrecondition(condition: .onQueue(self.dnsStateQueue))
            self.snapshotReloadCoordinator.assumeIsolated { $0.finish(generation) }
            // A deferred recovery force fires only when the coordinator is actually idle —
            // after the LAST reload fully finished — so it can never invalidate productive
            // work, and it converges even when the reload the flush yielded to was the
            // pre-unlock ABORT (which adopts nothing; Codex P1 round 8 on #377). The
            // in-flight re-check matters: a stale clear (finish above no-ops because a
            // newer reload superseded this generation) must keep the handoff armed for the
            // newer reload's own clear — firing on a stale clear would advance the
            // generation and discard that in-flight snapshot, the same double-reload the
            // yield exists to prevent. A PRODUCTIVE reload disarms the handoff when it
            // commits (see the adoption path in loadSnapshotInBackground, FIFO-before this
            // clear). A resident-snapshot no-op also safely satisfies the handoff: the
            // equality gate now runs before any DNS-runtime reset, so proving the resident
            // current never drains live queries merely to acknowledge recovery.
            if self.deferredRecoveryReloadPending,
               !self.snapshotReloadCoordinator.assumeIsolated({ $0.isReloadInFlight }) {
                self.deferredRecoveryReloadPending = false
                self.requestSnapshotReload(reason: "config-recovered-after-unlock-deferred", force: true)
            }
            if self.snapshotReloadCoordinator.assumeIsolated({ $0.isCurrent(generation) }) {
                self.scheduleProtectionNotificationIfNeeded()
            }
        }
    }

    func isCurrentSnapshotReloadGeneration(_ generation: UInt64) -> Bool {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            return dnsStateQueue.sync {
                isCurrentSnapshotReloadGeneration(generation)
            }
        }

        return snapshotReloadCoordinator.assumeIsolated { $0.isCurrent(generation) }
    }

    func invalidateSnapshotReloadGeneration(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.invalidateSnapshotReloadGeneration(reason: reason)
            }
            return
        }

        // Invalidation fences the abandoned load and clears ownership so the Focus poll cannot remain wedged.
        let generation = snapshotReloadCoordinator.assumeIsolated { $0.invalidate() }
        // Invalidation supersedes ALL prior reload work — including a deferred recovery
        // handoff still waiting on the superseded reload's clear. Left armed, that clear
        // would see the coordinator idle (invalidate dropped reloadInFlight) and fire a
        // forced snapshot reload into a stopped lifecycle, racing teardown or the next
        // start (Codex P2 round 9 on #377). Stop needs no recovery: the next start
        // re-classifies the config from scratch.
        deferredRecoveryReloadPending = false

        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "snapshot-reload-invalidated", details: [
            "reason": reason,
            "generation": "\(generation)"
        ])
        #endif
    }

    func loadSnapshotInBackground(reason: String, operationID: LatencyOperationID? = nil, resetsDNSRuntimeOnChange: Bool = false) {
        let generation = nextSnapshotReloadGeneration()
        #if DEBUG || LAVA_QA_TOOLS
        // Joins the caller's operation (tunnel start or a provider reload) so
        // app action spans and the tunnel's snapshot work share one id.
        let trace = Self.makeLatencyTrace(operationID: operationID, operationKind: "snapshotReload")
        let loadSpan = trace.beginSpan("tunnel.snapshotLoad", details: [
            "reason": reason,
            "generation": "\(generation)"
        ])
        #endif

        Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                #if DEBUG || LAVA_QA_TOOLS
                loadSpan.end(details: ["status": "missing-provider"])
                #endif
                return
            }
            // Clear the in-flight marker once the (expensive) load body finishes via ANY of its returns, so the
            // poll can fire the next reload. Generation-gated, so a newer overlapping load keeps the marker.
            // INV-QUEUE-1: this clear is `dnsStateQueue.async`, enqueued from `defer`
            // when the SYNCHRONOUS body returns — therefore strictly FIFO-AFTER the watermark advance the body
            // already enqueued (advanceFocusConfigurationWatermark). A poll tick that later observes the marker
            // cleared is dequeued after this clear, hence after that watermark advance, so it never sees a stale
            // watermark. Do NOT move a watermark advance into a nested async block that could run AFTER this
            // defer, or that invariant breaks.
            defer { self.clearSnapshotReloadInFlight(ifCurrentGeneration: generation) }

            let startedAt = Date()
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-begin", details: [
                "generation": "\(generation)",
                "reason": reason
            ])

            let configuration: AppConfiguration
            switch self.loadConfigurationClassified() {
            case .loaded(let loaded):
                configuration = loaded
            case .absentOrCorrupt:
                configuration = self.currentAppConfiguration()
            case .unreadable:
                // INV-PERSIST-1 × INV-DNS-1: with the on-disk config merely LOCKED (a boot
                // start before first unlock), the in-memory fallback is the boot placeholder
                // — an EMPTY config whose "reload" would replace the fail-closed bootstrap
                // with the unfiltered pass-through. Abort keeping the resident snapshot; the
                // nil refresh marker keeps re-adopting attempts alive and the Focus poll's
                // generation watermark (still at its 0 seed — nothing was adopted) drives a
                // fresh reload once the real config is readable.
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-aborted-config-unreadable", details: [
                    "generation": "\(generation)",
                    "reason": reason
                ])
                #if DEBUG || LAVA_QA_TOOLS
                loadSpan.end(details: ["status": "aborted-config-unreadable"])
                #endif
                return
            }

            // Pre-decode no-op gate: if the on-disk artifact would reproduce the
            // resident snapshot, skip the multi-megabyte decode entirely. This
            // is the common pull-to-refresh-with-no-content-change case and
            // avoids the 2x-resident memory peak that jetsams the extension on
            // large multi-list snapshots.
            if self.residentSnapshotSatisfiesReload(configuration: configuration) {
                // Resident already satisfies the reload → it is a healthy real snapshot.
                self.clearResidentFailClosedDueToUnavailableSnapshot(ifCurrentGeneration: generation)
                // The resident already covers this config ⇒ the tunnel has effectively ADOPTED this
                // generation, so advance the Focus config-poll watermark here too — otherwise a config-only
                // / equivalent-filter generation bump would never advance it and the poll would force a
                // reload (+ DNS-runtime reset) every interval. Same guarded advance as a full adopt.
                self.advanceFocusConfigurationWatermark(
                    toAdoptedGeneration: configuration.configurationGeneration,
                    ifCurrentReloadGeneration: generation
                )
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-reload-noop", details: [
                    "generation": "\(generation)",
                    "reason": reason
                ])
                loadSpan.end(details: ["status": "noop"])
                #endif
                return
            }

            if resetsDNSRuntimeOnChange {
                // Only a GENUINE snapshot/configuration change may invalidate live DNS work.
                // requestSnapshotReload intentionally does not reset the runtime: app launch
                // commonly sends a forced reload for a snapshot that is already resident, and
                // resetting before the equality gate turns that harmless handshake into
                // SERVFAIL for every query already in flight. Re-check the generation on the
                // DNS queue so a superseded load cannot drain a newer reload's queries.
                let preparedDNSRuntimeForReload = self.dnsStateQueue.sync {
                    guard self.isCurrentSnapshotReloadGeneration(generation) else {
                        return false
                    }
                    self.resetDNSRuntimeForProtectionPolicyChange(reason: reason)
                    return true
                }
                guard preparedDNSRuntimeForReload else {
                    #if DEBUG || LAVA_QA_TOOLS
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-skipped-stale-before-runtime-reset", details: [
                        "generation": "\(generation)",
                        "reason": reason
                    ])
                    loadSpan.end(details: ["status": "stale-before-runtime-reset"])
                    #endif
                    return
                }
            }

            // Each artifact candidate enforces its budget before decoding; exhaust the
            // shared fallback search before deciding that filtering is unavailable.
            // Genuine change replacing a resident snapshot with a new lists-enabled
            // (large) one. Freeing the resident BEFORE decoding keeps peak memory ~1x,
            // but it is only safe to discard last-known-good when the new snapshot is
            // all-but-certain to load. We free pre-decode ONLY when a reusable, in-budget
            // on-disk compact artifact is present (the fast path that cannot fail short of
            // a rare GC race). If there is NO reusable artifact — the new config can only
            // be satisfied by an in-extension recompile, which CAN fail (e.g. a blocklist
            // whose upstream rotated past the catalog's pinned hash) — we keep the resident
            // so a failed reload degrades to "keep the last-known-good lists" instead of
            // wedging fail-closed into a self-reconnect flicker loop. Skipped at tunnel
            // start (no resident yet) where peak is already 1x.
            let hasResidentSnapshot = self.currentResidentSnapshotIdentity() != nil
            let hasReusableArtifact = self.readCompactSnapshotSummary(configuration: configuration) != nil
            let freedResidentBeforeDecode = hasResidentSnapshot
                && hasReusableArtifact
                && !configuration.enabledBlocklistIDs.isEmpty
                && self.isCurrentSnapshotReloadGeneration(generation)
            if freedResidentBeforeDecode {
                self.replaceSnapshot(
                    FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset),
                    identity: nil,
                    generation: generation
                )
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-failclosed-before-decode", details: [
                    "generation": "\(generation)",
                    "reason": reason
                ])
                #endif
            }

            guard let loaded = await self.loadCompiledSnapshot(configuration: configuration, generation: generation) else {
                guard self.isCurrentSnapshotReloadGeneration(generation) else {
                    #if DEBUG || LAVA_QA_TOOLS
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-skipped-stale-missing", details: [
                        "generation": "\(generation)",
                        "reason": reason
                    ])
                    loadSpan.end(details: ["status": "stale-missing"])
                    #endif
                    return
                }

                // The new snapshot could not be built. If we still hold a real FILTERING
                // resident (we did NOT free it above), KEEP it serving — a transient build
                // failure (e.g. a stale-pinned-hash refresh) must degrade to "keep last-known-
                // good", never to fail-closed + a self-reconnect loop. The resident stays
                // healthy, so clear the snapshot-unavailable marker. (hasResidentSnapshot/
                // freedResidentBeforeDecode are read pre-await but the generation guard above
                // already rejected any reload that committed a newer snapshot meanwhile, so
                // they still describe the live resident here.)
                //
                // We must NOT keep a pass-through resident: a non-nil identity also covers the
                // permissive snapshot built for an empty config. If the user just enabled a
                // blocklist (new config non-empty) and that compile failed, keeping the
                // pass-through would leave protection connected but serving NO filtering — a
                // silent fail-OPEN. So require the resident to be a genuine filtering snapshot;
                // otherwise fall through and fail CLOSED below.
                if hasResidentSnapshot && !freedResidentBeforeDecode && self.currentResidentSnapshotHasEnabledFilters(),
                   self.currentResidentSnapshotIdentity()?.hasSameConfigurationInputs(as: configuration) == true {
                    self.clearResidentFailClosedDueToUnavailableSnapshot(ifCurrentGeneration: generation)
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-reload-failed-keeping-resident", details: [
                        "generation": "\(generation)",
                        "reason": reason
                    ])
                    #if DEBUG || LAVA_QA_TOOLS
                    loadSpan.end(details: ["status": "kept-resident"])
                    #endif
                    return
                }

                // No resident to fall back on (tunnel start), or we already freed it: fail
                // closed. Mark it snapshot-unavailable so the DNS smoke-probe failure this
                // block-all causes does NOT escalate to a self-reconnect restart loop —
                // restarting cannot rebuild a snapshot the config can't compile.
                var didCommitFailClosed = false
                if !configuration.enabledBlocklistIDs.isEmpty {
                    let failClosedSnapshot = FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)
                    let wasFailClosedBeforeBuildFailure = self.isResidentFailClosedDueToUnavailableSnapshot()
                    didCommitFailClosed = self.replaceSnapshot(
                        failClosedSnapshot,
                        failClosedDueToUnavailableSnapshot: true,
                        generation: generation
                    )
                    // Commit-landed AND transition-gated, like the over-budget site.
                    if didCommitFailClosed, !wasFailClosedBeforeBuildFailure {
                        Self.recordIncident(.failClosedEntered, reason: "snapshot-unavailable")
                    }
                    self.dnsStateQueue.async { [weak self] in
                        guard let self, self.isCurrentSnapshotReloadGeneration(generation) else {
                            return
                        }

                        self.refreshDNSRuntimeAfterSnapshotOrConfigurationChange()
                    }
                } else {
                    // Filters disabled (pass-through resident, not a fail-closed): clear any
                    // stale snapshot-unavailable marker so a later genuine DNS wedge can still
                    // self-reconnect. Generation-gated so a stale reload can't erase a newer
                    // reload's fail-closed marker.
                    self.clearResidentFailClosedDueToUnavailableSnapshot(ifCurrentGeneration: generation)
                }

                if didCommitFailClosed {
                    self.failTransientBootstrapDNSWait(reason: "snapshot-unavailable-\(reason)")
                }
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-missing", details: [
                    "generation": "\(generation)",
                    "reason": reason
                ])
                #if DEBUG || LAVA_QA_TOOLS
                loadSpan.end(details: [
                    "status": configuration.enabledBlocklistIDs.isEmpty ? "missing" : "fail-closed"
                ])
                #endif
                return
            }

            guard self.isCurrentSnapshotReloadGeneration(generation) else {
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-skipped-stale", details: [
                    "generation": "\(generation)",
                    "reason": reason
                ])
                loadSpan.end(details: ["status": "stale"])
                #endif
                return
            }

            let runtimeSnapshot = ResolverAdjustedRuntimeSnapshot(
                base: loaded.snapshot,
                resolver: configuration.resolverPreset
            )
            let runtimePolicySnapshot = ResolverAdjustedRuntimeSnapshot(
                base: loaded.snapshot,
                resolver: configuration.resolverPreset
            )
            // Coverage walks resident threat entries. Compute off dnsStateQueue, then
            // publish only if replaceSnapshot commits this generation below.
            let adoptedRuleCounts = FilterLooseningReapplyPolicy.RuleCounts(snapshot: runtimeSnapshot)
            self.dnsStateQueue.sync {
                // Generation-gate like every other dnsStateQueue access in this method (and like
                // replaceSnapshot below): a stale prior-lifecycle load must not refresh the
                // configuration bookkeeping — those markers belong to the current lifecycle's
                // loadInitialSharedState, which now also writes them on this queue.
                guard self.isCurrentSnapshotReloadGeneration(generation) else {
                    return
                }
                self.refreshConfigurationIfNeeded(force: true)
            }
            // A real snapshot is now resident; replaceSnapshot clears the snapshot-
            // unavailable marker atomically (default false) so a genuine DNS wedge later
            // can still escalate to self-reconnect.
            let exitsFailClosed = self.isResidentFailClosedDueToUnavailableSnapshot()
            let didCommitRealSnapshot = self.replaceSnapshot(
                runtimeSnapshot,
                protectionPolicySnapshot: runtimePolicySnapshot,
                identity: loaded.identity,
                residentHasEnabledFilters: !configuration.enabledBlocklistIDs.isEmpty,
                generation: generation,
                onCommittedWhileHoldingQueue: { [self] replacedBlockAllResident in
                    // `replacedBlockAllResident` is read from the snapshot being replaced, not from
                    // a marker. Every path that installs a block-all resident sets a different one
                    // — the unavailable marker, the pre-decode free, the startup bootstrap — and
                    // enumerating them here missed a different case on each of three rounds
                    // (Codex review, PR #645). What matters is only whether every lookup was
                    // failing a moment ago, which the resident itself answers.
                    recordAdoptedRuleCounts(
                        adoptedRuleCounts,
                        recoveringFromFailClosed: replacedBlockAllResident)
                }
            )
            if exitsFailClosed, didCommitRealSnapshot {
                // The marker-backed fail-closed window (over-budget / unbuildable) just
                // ended with a real snapshot commit. (The transient bootstrap window keeps
                // its marker false by design, so its exit is not separately recorded: a
                // SERVED transient window's serve-path record is bounded by this commit's
                // loadSnapshot-loaded debug-log line, which ships in reports — pairing it
                // here would need a cross-queue served-this-window latch on the reload
                // commit path for no added diagnostic value.)
                Self.recordIncident(.failClosedExited)
            }

            // Adopted a full snapshot ⇒ advance the Focus config-poll watermark (LAV-100 Phase 4 P4d).
            self.advanceFocusConfigurationWatermark(
                toAdoptedGeneration: configuration.configurationGeneration,
                ifCurrentReloadGeneration: generation
            )

            let duration = Date().timeIntervalSince(startedAt)
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-loaded", details: [
                "generation": "\(generation)",
                "reason": reason,
                "durationMs": "\(Int((duration * 1_000).rounded()))",
                "blockRuleCount": "\(runtimeSnapshot.blockRuleCount)",
                "allowRuleCount": "\(runtimeSnapshot.allowRuleCount)",
                "guardrailRuleCount": "\(runtimeSnapshot.guardrailRuleCount)",
                "footprintMB": Self.currentMemoryFootprintMB(),
                "resolver": configuration.resolverDiagnosticDisplayName
            ])
            #if DEBUG || LAVA_QA_TOOLS
            loadSpan.end(details: [
                "status": "loaded",
                "blockRuleCount": "\(runtimeSnapshot.blockRuleCount)",
                "footprintMB": Self.currentMemoryFootprintMB()
            ])
            #endif

            self.dnsStateQueue.async { [weak self] in
                guard let self else {
                    return
                }
                guard self.isCurrentSnapshotReloadGeneration(generation) else {
                    return
                }

                self.refreshDNSRuntimeAfterSnapshotOrConfigurationChange()
                self.drainTransientBootstrapDNSWait(reason: "snapshot-loaded-\(reason)")
                self.refreshConfigurationIfNeeded(force: true)
                // This adoption just replaced the boot placeholder with a real snapshot, so
                // a recovery handoff armed by the flush (which yielded to THIS reload) is
                // satisfied — disarm it before our own clear runs (FIFO: this block was
                // enqueued before the defer's clear). Left armed, the clear would still
                // schedule a redundant forced reload behind a successful recovery. Its
                // equality gate is DNS-safe, but the extra disk work and coordination are
                // unnecessary (Codex P2 round 13 on #377).
                self.deferredRecoveryReloadPending = false
                self.applyDiagnosticsControlIfNeeded(force: true)
                self.scheduleProtectionPauseResumeIfNeeded(reason: "snapshot-loaded-\(reason)")
                if self.diagnosticsPersistence.isDirty {
                    self.persistDiagnosticsIfNeeded(force: true)
                }
            }
        }
    }
}
