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
    // MARK: - Focus filter switch config poll (LAV-100 Phase 4 P4d)

    /// Start the periodic poll that adopts a Focus-committed filter switch made by the App Intents
    /// extension while Lava is closed. The extension commits config + library + the artifact-pointer flip
    /// (that part works headless); this is how the always-on tunnel NOTICES — it reads the on-disk
    /// configuration generation each tick and reloads through the EXISTING `requestSnapshotReload` entry
    /// when it advances past the generation the tunnel last loaded. Reliable where a Darwin observer is not
    /// (the tunnel run loop does not service Darwin notifications when idle). Does NOT touch DNS recovery.
    ///
    /// DESIGN / ENERGY TRADE-OFF (NRG — deferred, no behavior change here):
    /// Polls configuration and diagnostics controls every ~60 seconds, with 10-second leeway.
    /// Darwin notifications delivered 0 callbacks in 14 idle-extension device probes. A vnode
    /// source watches an inode that atomic temp+rename writes replace, so it cannot reliably
    /// replace this poll either. Unchanged generations and in-flight reloads skip snapshot work.
    /// Retiring the timer requires idle-device evidence and a replacement for both Focus adoption
    /// and diagnostics-control pickup; the steady-state tick performs no network I/O.
    func startFocusConfigurationPoll() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.startFocusConfigurationPoll()
            }
            return
        }

        // Do NOT seed the watermark from disk here: the on-disk generation may already reflect a closed-app
        // switch the tunnel has NOT yet ADOPTED (config-leads-pointer), and seeding from it would suppress the
        // retry forever. Leave the watermark at whatever the startup snapshot LOAD adopted — the load advances
        // it at its adopt point — so the first tick reloads iff the on-disk generation is genuinely ahead of
        // what the tunnel actually adopted.
        //
        // 10 s leeway: the ~60 s Focus-adoption promise tolerates the jitter, no tick is
        // phase-dependent (retry-until-adopt re-fires every tick regardless), and the
        // kernel can coalesce the wake. The poll itself is a hard invariant and stays.
        // (start() re-arms safely — the driver cancels any prior timer first.)
        // Synchronous isolated access: this method is dnsStateQueue-confined (hop guard
        // above), which IS the actor's executor — assumeIsolated traps on a wrong queue
        // where the old dispatchPrecondition merely asserted in debug.
        focusConfigurationPollTimer.assumeIsolated { timer in
            timer.start(
                interval: Self.focusConfigurationPollInterval,
                leeway: .seconds(10)
            ) { [weak self] in
                self?.reloadSnapshotIfConfigurationGenerationAdvanced()
            }
        }
    }

    func stopFocusConfigurationPoll() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.stopFocusConfigurationPoll()
            }
            return
        }

        focusConfigurationPollTimer.assumeIsolated { $0.stop() }
    }

    /// Advance the Focus config-poll watermark to a generation the tunnel has ADOPTED — either via a full
    /// snapshot decode or because the resident snapshot already satisfies the reload. Guarded by the live
    /// reload-generation token (like `replaceSnapshot`) so a superseded load doesn't record. Passive
    /// bookkeeping only — never touches the recovery/fail-closed flow. A reload that fail-closed never
    /// reaches an adopt point, so the poll keeps retrying until the flipped artifact is adopted; a successful
    /// foreground/app-message reload advances it too, so the poll never redundantly reloads after one.
    func advanceFocusConfigurationWatermark(toAdoptedGeneration adoptedGeneration: Int, ifCurrentReloadGeneration generation: UInt64) {
        dnsStateQueue.async { [weak self] in
            guard let self else { return }
            // INV-QUEUE-1: the watermark advance and in-flight-marker clear are both enqueued on
            // dnsStateQueue so they stay strictly FIFO-ordered. Assert here so an off-queue refactor
            // trips instead of silently breaking snapshot-reload ordering.
            dispatchPrecondition(condition: .onQueue(self.dnsStateQueue))
            guard self.isCurrentSnapshotReloadGeneration(generation) else { return }
            self.lastObservedConfigurationGeneration = max(self.lastObservedConfigurationGeneration, adoptedGeneration)
        }
    }

    /// One poll tick (dnsStateQueue): if the on-disk configuration generation advanced past the last one the
    /// tunnel last ADOPTED, reload the snapshot. `force: true` because a Focus switch changed the published
    /// artifact + config, not the pause state (the only thing the non-force path acts on). Reuses the same
    /// reload entry the app's `reload-snapshot` provider message drives.
    ///
    /// The watermark (`lastObservedConfigurationGeneration`) is advanced by the snapshot LOAD on a successful
    /// adopt — NOT here. The extension writes app-configuration.json BEFORE flipping the artifact pointer
    /// (config-leads-pointer), so a poll can observe the new generation during that window; advancing the
    /// watermark on mere observation would skip the retry if this reload runs before the flip (loads the old
    /// pointer / fail-closes). Leaving the watermark to the adopt point means the poll keeps retrying every
    /// interval until the flipped artifact is actually adopted, and a foreground provider-message reload (which
    /// also adopts) advances it too, so the poll never redundantly reloads after a foreground switch.
    ///
    /// In-flight guard: never re-request while the latest reload is still running. Each request begins a new
    /// coordinator generation, which invalidates the in-flight load (and resets the DNS runtime), so a
    /// load/compile slower than the poll interval would be restarted forever and never adopt.
    /// We retry on the NEXT tick after it resolves — preserving the retry-until-adopted behavior (which is what
    /// correctly picks up the artifact-pointer FLIP in the config-leads-pointer window) without starving a slow
    /// load. The poll deliberately does NOT permanently bound a non-adopting generation: a same-generation
    /// pointer flip must still be retried (the extension cannot send a provider reload), so the only cost of a
    /// genuinely-unadoptable config is one in-flight-gated reload per interval until the generation advances or
    /// a publish makes it adoptable.
    private func reloadSnapshotIfConfigurationGenerationAdvanced() {
        // The dormant boot owner has no private timer. Reuse this existing wake to
        // invalidate explicit Off or lost chaining/Plus/on-demand eligibility.
        revalidateChainedBootRecoveryIfNeeded()
        // Re-read completed app repair evidence even when chained DNS has no resolver probe
        // and the configuration generation is unchanged. Reuse this existing 60-second wake.
        if filteringUnavailableNoticeStartedAt != nil { scheduleProtectionNotificationIfNeeded() }
        // PST-7 defense-in-depth: pick up a mid-session diagnostics-clear whose IPC message
        // was dropped, off the tunnel-start force-apply. `force: false` respects the durable
        // applied-marker (PST-1), so a re-run over an already-satisfied clear can't re-wipe
        // history accumulated since — the mtime gate then short-circuits every later tick
        // until a genuinely newer control request lands. Runs on THIS existing 60s poll's
        // dnsStateQueue (where the store is confined and the snapshot-loaded apply already
        // runs) — no new timer, no cadence change, and BEFORE the config-generation guards
        // so it fires every tick regardless of whether a Focus switch needs adopting.
        #if DEBUG || LAVA_QA_TOOLS
        EnergyCounters.shared.bump(.focusPollTick)   // NRG focus-poll lever: count the 60 s wakes
        EnergySignpost.event("focus-poll-tick")      // NRG Phase 2: mark the poll wake for Instruments
        if let dnsEventLog {
            // NRG SQLite lever (UR-53 follow-up): pull the depth store's write-path window
            // (flushes/rows/prunes/WAL frames) into the counters on the same existing tick —
            // no new timer, no per-event logging. The snapshot's queue.sync can wait behind
            // an in-flight retry commit that is itself riding the 2s busy_timeout against a
            // cross-process clear writer — a rare, bounded ≤~2s stall on this 60s QA-only
            // tick (OCR, lavasec-ios#54 sync review); everything else on the log's queue
            // originates from this same dnsStateQueue and is therefore already serialized.
            EnergyCounters.shared.recordSQLiteWindow(dnsEventLog.writeInstrumentationSnapshotAndReset())
        }
        // THE REGISTRY'S OWN PRESSURE, which was counted and never read: `refusedAtCapacityCount()`
        // existed only for tests, so on device a capacity refusal and a genuine socket-creation
        // failure were the same silent `.socketUnavailable`. Reading it here is what identified
        // the cause of the field failures this fix closes.
        //
        // The elimination that makes it the question worth asking: the tunnelled UDP path's other
        // socket-creation exits are excluded — a binding refusal reports
        // `.tunnelInterfaceUnavailable`, not this; `socket(2)` and `SO_RCVTIMEO` failures are not
        // credible at this rate on a healthy device; and descriptor exhaustion is ruled out by the
        // in-flight ceiling (`maxConcurrentResolverQueries`). That left the port claim.
        EnergyCounters.shared.recordChainedResolverPortPressure(
            refusedAtCapacity: ownResolverPorts.refusedAtCapacityCount(),
            refusedAtGraceCapacity: ownResolverPorts.refusedAtGraceCapacityCount(),
            evictedWhileLive: ownResolverPorts.evictedWhileLiveCount(),
            liveClaims: ownResolverPorts.claimedCount())
        EnergyCounters.shared.flushIfDue()           // NRG: flush the per-window counter summary (piggybacks this tick)
        emitChainedSessionLivenessIfChained()
        // Same 60 s tick, no new timer: hand back whatever the unanswered-query suppressor is
        // still holding, so a burst that stopped inside its 30 s window does not strand its tail.
        // Deliberately OUTSIDE `emitChainedSessionLivenessIfChained`, which returns early when the
        // data path is not chained — DNS failures are worth reporting in every mode.
        flushSuppressedUnansweredDNSQueries()
        // TUNNEL-OWNED trigger for the QA leak canary (#8): fires once per established chained session
        // regardless of app foreground state (a Connect-On-Demand / backgrounded establishment would
        // otherwise never fire it). Self-latching; a no-op unless armed. (Codex, PR #563.)
        fireChainedDNSLeakCanaryIfArmed()
        #endif
        // PRODUCTION self-heal (field 2026-08-24, reliability incident memory): this Focus poll is a
        // guaranteed ~60 s backstop that keeps running even when an UNPAIRED iOS sleep() has left the
        // chained driver suspended — its engine tick disarmed, so tx/rx/forwarding are flat, no
        // keepalive/handshake fires, and every outage detector is frozen (they live only inside the
        // quiesced tick). iOS does not guarantee a wake() for every sleep(). This poll RUNNING is
        // proof the process has resumed, so recover the driver if it is still suspended (idempotent —
        // a no-op otherwise). `handleOutboundBatch` covers the instant case on the user's first
        // packet; this bounds the worst case to one poll interval.
        resumeChainedTunnelIfSuspended()
        // PRODUCTION, not QA-gated (unlike the liveness debug line above): mirror the chained
        // driver's counters into `health` so the app's DNS-health surfaces show the chained
        // numbers while chained instead of the stale physical ones (Slice 3). dnsStateQueue-
        // confined, like every `health` mutation here; persists only when a value changed.
        mirrorChainedHealthCountersIfChanged()
        // Data-path byte window — sampled HERE (the focus tick), not in the mirror above, because a
        // ~60 s delta is only meaningful at this fixed cadence (Slice C). Surface-only telemetry.
        sampleChainedDataPathWindowOnTick()
        // ios-internal#526 attribution brackets. On device this 60 s tick shows a recurring
        // ~+7 MB / ~13 s phys_footprint transient, which contradicts this poll's own
        // "a cheap config-generation read per minute is negligible" rationale above. The
        // QA-only block that precedes this completes in ~2 ms (measured: `nrg-window`
        // follows `focus-poll-tick` by 1.3-2.1 ms), so the cost is one of the steps below.
        // Point events cannot separate them; these intervals can. QA-only, like every other
        // signpost here.
        #if DEBUG || LAVA_QA_TOOLS
        EnergySignpost.begin("focus-apply-diagnostics")
        #endif
        applyDiagnosticsControlIfNeeded(force: false)
        #if DEBUG || LAVA_QA_TOOLS
        EnergySignpost.end("focus-apply-diagnostics")
        #endif

        if diagnosticsPersistence.isDirty {
            #if DEBUG || LAVA_QA_TOOLS
            EnergySignpost.begin("focus-persist-diagnostics")
            #endif
            persistDiagnosticsIfNeeded(force: true)
            #if DEBUG || LAVA_QA_TOOLS
            EnergySignpost.end("focus-persist-diagnostics")
            #endif
        }

        let reloadInFlight = snapshotReloadCoordinator.assumeIsolated { $0.isReloadInFlight }
        guard !reloadInFlight else { return }
        #if DEBUG || LAVA_QA_TOOLS
        EnergySignpost.begin("focus-load-configuration")
        #endif
        let onDiskGeneration = loadConfiguration()?.configurationGeneration ?? lastObservedConfigurationGeneration
        #if DEBUG || LAVA_QA_TOOLS
        EnergySignpost.end("focus-load-configuration")
        #endif
        guard onDiskGeneration > lastObservedConfigurationGeneration else { return }
        // An EVENT, not an interval: requestSnapshotReload dispatches the reload rather than
        // performing it inline, so bracketing the call would time the hand-off, not the work.
        // Whether this fires at all is the diagnostic — if the generation never advances this
        // is silent, and #526's cost lies in the steps above instead of in a reload storm.
        #if DEBUG || LAVA_QA_TOOLS
        EnergySignpost.event("focus-reload-requested")
        #endif
        requestSnapshotReload(reason: "focus-config-poll", force: true)
    }
}
