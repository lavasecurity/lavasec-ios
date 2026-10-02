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
    // MARK: - App messaging (IPC)

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let providerMessage = LavaSecProviderMessageCodec.decode(messageData) else {
            let completion = AppMessageCompletion(handler: completionHandler)
            completion.complete(nil)
            return
        }

        let message = providerMessage.kind
        #if DEBUG || LAVA_QA_TOOLS
        let trace = providerMessage.operationID.map { operationID in
            LatencyTrace(
                operationID: LatencyOperationID(rawValue: operationID),
                sink: LatencyDebugLogEventSink(operationKind: "providerMessage") { event, details in
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
                }
            )
        }
        trace?.record("provider.message.received", details: ["kind": message])
        let completion = AppMessageCompletion(
            handler: completionHandler,
            latencySpan: trace?.beginSpan("provider.message.reply", details: ["kind": message])
        )
        #else
        let completion = AppMessageCompletion(handler: completionHandler)
        #endif

        switch message {
        #if DEBUG || LAVA_QA_TOOLS
        case "qa-peer-blackout-20s":
            dnsStateQueue.async { [weak self] in
                guard let self,
                      case .chainedUpstream(let upstream) = self.latchedDataPathMode,
                      upstream.effectiveRoutingPolicy == .fullTunnel,
                      let profile = self.protocolConfiguration as? NETunnelProviderProtocol,
                      !profile.includeAllNetworks,
                      self.chainedRuntime != nil,
                      self.qaPeerBlackout.arm() else {
                    completion.complete(Data("refused".utf8))
                    return
                }
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "qa-peer-blackout-begin",
                    details: ["seconds": "20"])
                let blackout = self.qaPeerBlackout
                // Logging only. Packet admission expires independently, even if this queue stalls.
                self.dnsStateQueue.asyncAfter(deadline: .now() + 20) {
                    let counts = blackout.counters()
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "qa-peer-blackout-ended",
                        details: ["sentDrops": String(counts.sent), "receivedDrops": String(counts.received)])
                }
                completion.complete(Data("ok".utf8))
            }
        #endif
        case LavaSecAppGroup.reloadSnapshotMessage:
            requestSnapshotReload(
                reason: "appMessage",
                force: true,
                operationID: providerMessage.operationID.map(LatencyOperationID.init(rawValue:))
            )
            completion.complete(Data("ok".utf8))

        case LavaSecAppGroup.reloadProtectionPauseMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }
                // A pause command can be the FIRST tunnel wake after first unlock: with the
                // begin still boot-deferred, the mask in currentTemporaryProtectionPauseUntil
                // would swallow the just-written pause INDEFINITELY on an idle tunnel — this
                // handler is the only wake such a tunnel gets, and it previously never
                // flushed (Codex P2 round 15 on #377). Flush through the same forced config
                // refresh the reload-configuration message uses: a readable config lands the
                // begin before the pause read below; a still-locked one flushes nothing and
                // the mask correctly stays. Gated on a pending begin so the common pause
                // toggle remains a pure pause-state refresh.
                if self.hasPendingFreshProtectionVPNSessionBegin() {
                    // Capture the command's just-written pause BEFORE the flush: the begin
                    // mints a fresh session and clears the pause keys, which would turn the
                    // user's first post-unlock Pause tap into a silent no-op while the
                    // intent path already published .paused (Codex P2 round 16 on #377).
                    // Carrying is sound because EVERY sender of this message writes the
                    // pause keys immediately before sending (LavaProtectionCommandService
                    // and the in-app path both write-then-notify), so the captured state is
                    // the command's own payload: a resume arrives with the keys already
                    // CLEARED (nothing to carry), and a pre-reboot leftover cannot be
                    // captured through a just-overwritten store.
                    let commandPause = try? self.protectionPauseStore.storedPauseState()
                    self.refreshConfigurationIfNeeded(force: true)
                    // Re-issue the carried pause against the FRESH session for its remaining
                    // window — only once the begin actually landed (a still-locked config
                    // keeps deferring, and the mask must keep masking). Best-effort: a
                    // failed re-issue degrades to a one-command no-op, never a fail-open.
                    if !self.hasPendingFreshProtectionVPNSessionBegin(),
                       let commandPause,
                       commandPause.pausedUntil.timeIntervalSinceNow > 0,
                       let freshSessionID = try? self.protectionSessionStore.activeSessionID() {
                        _ = try? self.protectionPauseStore.pause(
                            for: commandPause.pausedUntil.timeIntervalSinceNow,
                            requestedSessionID: freshSessionID
                        )
                    }
                }
                self.refreshProtectionPauseStateOnly(reason: "protectionPause")
                completion.complete(Data("ok".utf8))
            }

        case LavaSecAppGroup.reloadConfigurationMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }

                // Always load the new config so non-resolver fields (diagnostics
                // toggles, paid status) take effect. But only reset the DNS
                // runtime and reapply tunnel network settings — a VISIBLE
                // reconnect — when the RESOLVER config actually changed. A
                // diagnostics-flag or paid-status change must never drop the
                // live connection (plan acceptance: config change does not
                // reconnect unless identity changed).
                let previousResolverIdentity = Self.resolverNetworkIdentity(self.currentAppConfiguration())
                self.refreshConfigurationIfNeeded(force: true)
                let resolverChanged = Self.resolverNetworkIdentity(self.currentAppConfiguration()) != previousResolverIdentity

                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "reload-configuration", details: [
                    "resolverChanged": "\(resolverChanged)"
                ])
                #endif

                // RELATCH THE T1 SELECTION, so a chained session picks up a resolver change the
                // way a DNS-only one already does.
                //
                // The reload path below has always reapplied network settings — the visible blink —
                // in BOTH modes. In DNS-only that is enough, because the resolver is read live from
                // the configuration this handler just refreshed. A chained session reads the rung
                // from `latchedChainedTierOneResolverConfiguration`, which was installed once at
                // `startTunnel` and which nothing here updated: so it blinked and came back on the
                // SAME resolver, and the settings panel told the user to restart protection by
                // hand. That instruction was accurate, which is what made it worth removing rather
                // than rewording.
                //
                // THE EPOCH BUMP IS REQUIRED, not incidental. Both rung consumers —
                // `recordChainedTierOneRungEvidence` and `reportTierOneRungRescue` — admit a
                // rung's result only while `originatingLatchEpoch` still matches, and a
                // rung admitted against the OLD resolver can complete after this line. Without the
                // bump its outcome would be credited to the resolver that replaced it — one
                // resolver condemned for another's failure, which is the attribution defect the
                // per-session latch was introduced to prevent (Codex, PR #592). The bump also
                // drops in-flight T0 observations and socket bindings, which fail CLOSED and
                // retry; a few queries pay a brief refusal, where today every query keeps going to
                // the old resolver until the user notices.
                //
                // Republished in the same critical section: the panel's latched identity is what
                // `ChainedFallbackFreshness` compares, so a relatch that did not republish would
                // leave it reporting `.awaitingRestart` about a change already applied.
                // pinned: TunnelDataPathLatchSourceTests.testAResolverChangeRelatchesTheRungInPlace
                if case .chainedUpstream(let upstream) = self.latchedDataPathMode {
                    let previous = self.latchedChainedTierOneResolverConfiguration
                    let updated = self.currentAppConfiguration().chainedTierOneResolverConfiguration
                    // BOTH HALVES. The nil-ness answers "any resolver at all", which is the
                    // `chainedTierOneFallbackEnabled` toggle and moves without the policy
                    // changing; the policy identity answers everything else.
                    //
                    // THE POLICY IDENTITY, NOT THE RESOLVER IDENTITY, and the difference is a
                    // fail-open. `chainedTierOneResolverIdentity` names only which resolver the
                    // rung asks FIRST. Since PR #596 the rung runs the full ladder
                    // (`INV-CHAIN-7`), so `fallbackToDeviceDNS`,
                    // `usesEncryptedDeviceDNSFallback` and `fallbackResolverPreset` steer it too
                    // — all three move without touching the resolver identity. Keyed on the
                    // resolver alone, turning device fallback OFF left this session sending
                    // failed T1 lookups to the device resolver until the next restart: the
                    // PR #575 privacy failure through a third door (Codex P1, PR #599).
                    let tierOneChanged = (previous == nil) != (updated == nil)
                        || previous?.chainedTierOneRungPolicyIdentity
                            != updated?.chainedTierOneRungPolicyIdentity
                    if tierOneChanged {
                        self.latchedChainedTierOneResolverConfiguration = updated
                        self.tunnelDataPathLatchEpoch &+= 1
                        self.publishChainedFallbackOutcomesOnQueue(configuration: upstream)
                        LavaSecDeviceDebugLog.append(
                            component: "tunnel", event: "chained-tier-one-relatched",
                            details: ["enabled": "\(updated != nil)"])
                    }
                }

                if resolverChanged {
                    self.applyResolverHealthEvent(.resolverConfigurationChanged(occurredAt: Date()))
                    self.invalidateResolverSmokeProbeToken()
                    self.replaceSnapshotResolver(self.currentAppConfiguration().resolverPreset)
                    self.refreshDNSRuntimeAfterSnapshotOrConfigurationChange()
                    self.reapplyTunnelNetworkSettings(reason: "configuration-changed", enforceThrottle: false)
                    self.scheduleResolverSmokeProbeIfNeeded(reason: "configuration-changed")
                }
                completion.complete(Data("ok".utf8))
            }

        case LavaSecAppGroup.clearDiagnosticsMessage, LavaSecAppGroup.clearFilteringCountsMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }

                // Route the clear through the SAME marker-gated control apply as the 60s poll (PST-7)
                // and the start force-apply, rather than an unconditional clearDomainHistory(clearedAt:
                // Date()) / clearFilteringCounts(). The app writes the diagnostics-control request
                // BEFORE sending this message, so this apply reads it and clears only what is strictly
                // newer than the durable applied-marker (requestedAt > lastApplied). Without this, the
                // poll could apply the clear first and THEN this handler would wipe a second time,
                // destroying any events recorded between the two — even though the request was already
                // satisfied (Codex #226). force:true bypasses only the coarse mtime pre-filter; the
                // per-request durable marker still dedups against the poll. Both clear messages are now
                // nudges to the same unified apply — the control file is the source of truth for WHAT
                // to clear, so each clear type stays independently marker-gated.
                self.applyDiagnosticsControlIfNeeded(force: true)
                self.persistDiagnosticsIfNeeded(force: true)
                completion.complete(Data("ok".utf8))
            }

        case LavaSecAppGroup.clearNetworkActivityLogMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }

                guard let networkActivityLogURL else {
                    completion.complete(Data("ok".utf8))
                    return
                }
                // CON-1: the clear must run on the SAME serial queue as the deferred
                // appends. Any append enqueued before this handler already sits ahead of
                // this clear on networkActivityLogIOQueue, so the wipe runs last and wins —
                // otherwise a pending append would recreate the log the user just cleared.
                // This queue is NOT drained by the terminal self-reconnect `sync`, so the
                // clear stays BLOCKING/reliable (a privacy wipe must not drop) without any
                // risk of stalling DNS or teardown (Codex #200 P2).
                Self.networkActivityLogIOQueue.async {
                    NetworkActivityLogPersistence.clear(at: networkActivityLogURL)
                    completion.complete(Data("ok".utf8))
                }
            }

        case LavaSecAppGroup.clearIncidentLedgerMessage:
            guard let containerURL = LavaSecAppGroup.containerURL else {
                completion.complete(Data("ok".utf8))
                return
            }
            let ledgerURL = containerURL.appendingPathComponent(LavaSecAppGroup.incidentLedgerFilename)
            // Same ordering discipline as clearNetworkActivityLogMessage (CON-1): take a
            // dnsStateQueue turn FIRST. Several recordIncident sites (wedge, rejected-probe,
            // fail-closed serve) run inside dnsStateQueue blocks; hopping straight to
            // appGroupLogIOQueue would let an already-queued DNS-state block enqueue its
            // append AFTER this clear and resurrect the ledger. Draining dnsStateQueue means
            // every such block has already enqueued its append ahead of the clear, so the
            // clear runs last on appGroupLogIOQueue and the privacy wipe wins.
            //
            // NON-BLOCKING `tryClear` (Codex #200 P2): this runs on appGroupLogIOQueue, the
            // queue the terminal self-reconnect commit drains via `sync`. A blocking clear
            // here could wait indefinitely on the ledger flock a suspended app holds (its
            // bounded sweepExpired can be suspended mid-critical-section) and stall the
            // teardown behind it. Dropping on contention is safe: the app's own direct
            // `clear` (blocking, off the teardown path) already removed the file, so at worst
            // a pre-clear append this handler just drained survives until retention ages it.
            dnsStateQueue.async { [weak self] in
                guard self != nil else {
                    completion.complete(nil)
                    return
                }
                Self.appGroupLogIOQueue.async {
                    IncidentLedgerPersistence.tryClear(at: ledgerURL)
                    completion.complete(Data("ok".utf8))
                }
            }

        case LavaSecAppGroup.resolveBootstrapHostMessage:
            handleResolveBootstrapHostMessage(providerMessage, completion: completion)

        case LavaSecAppGroup.flushTunnelHealthMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }

                // A Feedback capture can race the deferred-begin flush: opened seconds
                // after first unlock, before any serve/refresh tick has run the flush's
                // locked→readable transition, the sampled payload would carry populated
                // lockedBoot* counters with a "none" window-end stamp — a completed
                // locked window indistinguishable from a still-locked or dead session
                // (Codex review, #381). This handler is dnsStateQueue-confined like the
                // flush, so it may stamp: if the content became readable while the
                // stores still reflect the locked boot, record the window end at the
                // conservative observed-locked boundary. The flag and the store reload
                // stay untouched — those are the flush's heavier duties, and the flush's
                // own later stamp is idempotent (first transition wins).
                // pinned: TunnelPreUnlockGuardSourceTests.testHealthFlushMessageStampsAnUnstampedEndedLockedWindow
                if self.diagnosticsStoresReflectLockedBoot, self.sharedProtectedContentIsReadable() {
                    self.health.markLockedBootWindowEnded(at: self.lastObservedLockedSharedContentAt ?? Date())
                }
                self.health.networkKind = self.currentNetworkKind()
                self.health.updatedAt = Date()
                // Re-mirror the chained counters so a manual "Refresh sample" reflects the LIVE
                // chained health, not the last tick's — otherwise a refresh during the ~60 s
                // startup window would just re-persist the stale DNS-only flag (Slice 3 review).
                // dnsStateQueue-confined here, like the mirror requires.
                self.mirrorChainedHealthCountersIfChanged()
                self.persistHealthIfNeeded(force: true)
                // This message IS the app's capture boundary — the Feedback sheet awaits it
                // before reading the debug log — so hand back the unanswered-query
                // suppressor's tail here rather than leaving it stranded until the next 60 s
                // poll (Codex P2, PR #620). Inside the completion's block so the appended
                // lines are on disk before the app is told the flush is done.
                self.flushSuppressedUnansweredDNSQueries()
                completion.complete(Data("ok".utf8))
            }

        case LavaSecAppGroup.readTunnelHealthMessage:
            // Visible Nerd stats samples current observations without forcing file
            // persistence, suppressor flushes, probes or configuration work (#248).
            // pinned: NerdStatsFreshnessSourceTests.testVisibleStatsCaptureIsReadOnlyAndQueueConfined
            dnsStateQueue.async { [weak self] in
                guard let self, self.tunnelLifecycleIsActive else { completion.complete(nil); return }
                var sample = self.health
                sample.updatedAt = Date()
                sample.networkKind = self.currentNetworkKind()
                sample.isChainedUpstreamActive = self.currentTunnelDataPathMode().isChainedUpstream
                if sample.isChainedUpstreamActive, let counters = self.chainedRuntime?.driver.snapshotCounters() {
                    sample.chainedTunnelDNSAnsweredCount = counters.tunnelDNSAnsweredObservationCount
                    sample.chainedTunnelDNSUnansweredCount = counters.tunnelDNSUnansweredObservationCount
                    sample.chainedTunnelDNSOutageCount = counters.tunnelDNSOutageCount
                    sample.chainedLinkOutageCount = counters.offlinePathCount
                    sample.chainedUnansweredDestinationCount = counters.unansweredDestinationCount
                    sample.chainedLongestUnansweredDestinationSeconds = counters.longestUnansweredDestinationSeconds
                }
                sample.runningChainedUpstreamGeneration = self.runningChainedUpstreamGeneration()
                completion.complete(try? JSONEncoder().encode(sample))
            }

        case LavaSecAppGroup.readProtectionStatusMessage:
            // A status query must not invoke the flush, pause-expiry cleanup, or the
            // handshake sampler's QA probe. Copy only the running provider's observations.
            dnsStateQueue.async { [weak self] in
                guard let self else { completion.complete(nil); return }
                let now = Date()
                let chained = self.tunnelLifecycleIsActive && self.currentTunnelDataPathMode().isChainedUpstream
                let runtime = chained ? self.chainedRuntime?.driver.snapshotStatusEvidence() : nil
                let stats = runtime?.statistics
                let pause = self.protectionPauseStateQueue.sync { self.cachedTemporaryProtectionPauseUntil }
                let evidence = ProtectionStatusEvidence(sampledAt: now,
                    lifecycleIsActive: self.tunnelLifecycleIsActive, health: self.health,
                    pauseUntil: pause, isChained: chained,
                    sessionGeneration: stats?.sessionGeneration, forwardedBytes: stats?.forwardedNonDNSByteCount,
                    transportGeneration: stats?.transportGeneration,
                    setupReady: self.tunnelStartupDidComplete && stats?.setupReady == true,
                    providerLifecycleID: chained ? self.latchedChainedLifecycleEvidenceID : nil,
                    verificationEpoch: runtime?.verificationEpoch,
                    forwardingBaseline: runtime?.forwardingBaseline ?? 0,
                    runtimeCondition: runtime?.runtimeCondition ?? (chained ? .recovering : .normal))
                completion.complete(try? JSONEncoder().encode(evidence))
            }

        case LavaSecAppGroup.chainedHandshakeStatusMessage:
            // Prompt, lightweight runtime read for the connected lifecycle — deliberately NO
            // mirror/persist (unlike the flush above), so the app can sample immediately and ~1 s
            // while establishing, then keep a lower-cadence chained monitor without health-file
            // churn. dnsStateQueue-confined like the sampler that reads the same driver stats;
            // snapshotStatistics() hops to the engine queue (reentrant-safe).
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }
                let state = self.currentChainedHandshakeState()
                let status = LavaSecAppGroup.ChainedHandshakeStatus(
                    isChained: state.isChained,
                    hasHandshake: state.hasHandshake,
                    everHandshaked: state.everHandshaked,
                    receivedByteCount: state.receivedByteCount,
                    sessionGeneration: state.sessionGeneration,
                    lifecycleIsActive: self.tunnelLifecycleIsActive,
                    transportGeneration: state.transportGeneration, setupReady: state.setupReady,
                    providerLifecycleID: state.providerLifecycleID,
                    verificationEpoch: state.verificationEpoch,
                    forwardingBaseline: state.forwardingBaseline,
                    runtimeCondition: state.runtimeCondition,
                    health: self.health)
                completion.complete(status.encoded())
            }

        default:
            completion.complete(nil)
        }
    }

    static func latencyOperationID(from options: [String: NSObject]?) -> LatencyOperationID? {
        guard let rawValue = options?[LavaSecAppGroup.latencyOperationIDOptionKeyName] as? String,
              !rawValue.isEmpty
        else {
            return nil
        }

        return LatencyOperationID(rawValue: rawValue)
    }

    #if DEBUG || LAVA_QA_TOOLS
    static func makeLatencyTrace(operationID: LatencyOperationID?, operationKind: String) -> LatencyTrace {
        LatencyTrace(
            operationID: operationID ?? .make(),
            sink: LatencyDebugLogEventSink(operationKind: operationKind) { event, details in
                LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
            }
        )
    }
    #endif
}
