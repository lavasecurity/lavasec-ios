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
    // MARK: - Startup shared state & bootstrap snapshot

    func loadInitialSharedState() -> Bool {
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadInitialSharedState-begin")
        #if DEBUG || LAVA_QA_TOOLS
        // Snapshot the leak-canary nonce armed at THIS launch, BEFORE any handshake, so only a session
        // from a post-arm connect fires it. A nonce armed mid-session differs from this and waits for
        // the next startTunnel — the canary can never fire before the capture begins (Codex, PR #563).
        leakCanaryEligibleNonce = LavaSecAppGroup.sharedDefaults.string(
            forKey: LavaSecAppGroup.leakCanaryArmedNonceKey)
        // Reset the fire-once latch too: NetworkExtension reuses this provider across starts, but a
        // freshly-built ChainedOutageDriver restarts sessionGeneration at 1 — a stale latch of 1 from a
        // prior lifecycle would block the ENTIRE new session. 0 is the "never fired" sentinel
        // (generations start at 1, like chainedHandshakeLatchGeneration's reset). (Codex, PR #563.)
        chainedLeakCanaryFiredForGeneration = 0
        #endif

        // INV-PERSIST-1: classify the config read so existing-but-unreadable (Data
        // Protection on a boot start before first unlock) never collapses into the empty
        // default the pass-through branch below treats as "user has no filters". The empty
        // placeholder is still installed in memory (resolver wiring reads it), but the
        // bootstrap fails CLOSED on the flag and the refresh marker stays nil so the 30 s
        // refresh keeps retrying until the real config is readable.
        let configurationIsUnreadable: Bool
        let configuration: AppConfiguration
        switch loadConfigurationClassified() {
        case .loaded(let loaded):
            configurationIsUnreadable = false
            configuration = loaded
        case .absentOrCorrupt:
            configurationIsUnreadable = false
            configuration = AppConfiguration()
        case .unreadable:
            configurationIsUnreadable = true
            configuration = AppConfiguration()
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "config-unreadable-at-start", details: [
                "consequence": "fail-closed bootstrap + refresh retry until first unlock"
            ])
        }
        let launchFollowsRecentSelfReconnect = Self.launchFollowsRecentSelfReconnect(now: Date())
        setAppConfiguration(configuration)
        latchDataPathMode(for: configuration, configurationIsUnreadable: configurationIsUnreadable)
        // Queue-confine the refresh bookkeeping like setAppConfiguration above and every
        // other access via refreshConfigurationIfNeeded: a prior-lifecycle detached snapshot
        // load can still be inside loadSnapshotInBackground and touch these same markers on
        // dnsStateQueue while this off-queue start runs, so route the writes through the queue
        // (loadInitialSharedState is called from startTunnel, never on dnsStateQueue, so .sync
        // cannot deadlock).
        // INV-PERSIST-1 retry keeper: file METADATA is readable while content is locked, so
        // stamping the real mtime after a FAILED load would make refreshConfigurationIfNeeded's
        // unchanged-mtime gate suppress every retry — the fail-closed placeholder would then
        // outlive first unlock until the app's next config write (the sticky half of the
        // incident plan's latent-1). A nil marker compares as "changed" on every refresh
        // tick, so the tunnel keeps retrying until the post-unlock load succeeds.
        // A PENDING deferred begin also keeps the marker nil: first unlock can land between
        // startTunnel's begin canary and this read, making the config readable here while
        // the begin is already deferred — and on a warm resume the snapshot reload no-ops
        // before any forced refresh, so the cadence tick this marker un-gates is the only
        // path left to flushDeferredFreshProtectionVPNSessionIfNeeded (Codex P2 round 14
        // on #377). The cost is one redundant config re-load on that tick.
        // pinned: TunnelPreUnlockGuardSourceTests.testUnreadableConfigLeavesRefreshMarkerNilSoRetriesContinue
        let configurationModifiedAt = (configurationIsUnreadable || hasPendingFreshProtectionVPNSessionBegin())
            ? nil
            : modificationDate(for: configurationURL)
        dnsStateQueue.sync {
            lastConfigurationModifiedAt = configurationModifiedAt
            lastConfigurationRefreshAt = Date()
            filteringUnavailableNoticeStartedAt = nil
            protectionNotificationDelivery = ProtectionNotificationDeliveryState()
        }
        // Release any prior-lifecycle resident BEFORE the synchronous bootstrap decode. On a
        // same-instance restart / setTunnelNetworkSettings-failure retry (NOT a fresh process),
        // self.snapshot still holds the previous resident; decoding a fresh up-to-cap (1M-rule)
        // snapshot while a near-budget old one is retained would stack into the 2x-resident peak
        // the reload path explicitly avoids (freedResidentBeforeDecode) and could jetsam the
        // extension. Dropping our reference lets the old tables free before the decode; a lingering
        // prior-lifecycle task keeps its own captured reference, so this is not a use-after-free.
        // readPackets has not started, so nothing serves queries against this transient placeholder.
        snapshotQueue.sync {
            snapshot = FilterSnapshot(blockRules: DomainRuleSet())
            protectionPolicySnapshot = snapshot
            residentSnapshotIdentity = nil
            residentSnapshotHasEnabledFilters = false
            residentFailClosedDueToUnavailableSnapshot = false
        }
        // The loosening baseline belongs to the session whose resident we just released, and
        // NetworkExtension reuses this provider instance across starts (see the note above), so
        // without this a same-instance restart would compare its first adoption against the
        // PREVIOUS session's ruleset. A stale baseline both invents nudges at startup and, if the
        // old session was looser, suppresses the first real one (PR #645).
        //
        // This is only the RESET half. The bootstrap below re-seeds it from the resident it
        // installs whenever that resident is a real ruleset — see the note there for why leaving it
        // nil silently disabled the nudge on the fast-resume path.
        dnsStateQueue.sync { lastAdoptedRuleCounts = nil }
        // This restart ENDS the previous fail-closed window, so its brokered-hostname budget
        // ends with it. Paired here rather than only at the commit site because a
        // same-instance restart never reaches that site.
        resetBrokeredBootstrapHostnamesFromAnyQueue()

        // Compute the bootstrap install off-queue (bootstrapResidentSnapshotFromDisk does disk
        // reads that don't touch snapshotQueue), then publish all resident state in ONE
        // snapshotQueue critical section below.
        let bootstrapSnapshot: any FilterRuntimeSnapshot
        let bootstrapIdentity: PreparedFilterSnapshotIdentity?
        let bootstrapHasEnabledFilters: Bool
        let shouldBeginTransientBootstrapDNSWait: Bool
        if configurationIsUnreadable {
            // INV-PERSIST-1 × INV-DNS-1 (pinned: TunnelPreUnlockGuardSourceTests.testUnreadableConfigBootstrapsFailClosedNeverPassThrough):
            // an unreadable config is NOT "no filters" — the user's real config (and its
            // enabled lists) is intact behind Data Protection, so serve fail-closed until
            // the refresh retry adopts it after first unlock. The empty pass-through branch
            // below stays reserved for a config that genuinely READS as empty. Last-known-
            // good is not an option here: with no readable config there is nothing to
            // config-exact-match against (INV-DNS-3). Like the transient bootstrap window
            // below, this is deliberately NOT ledgered at entry (INV-OBS-1) — it fires on
            // every pre-unlock boot start and resolves within one refresh of unlock; a
            // served fail-closed query records via the serve path as usual.
            bootstrapSnapshot = FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)
            bootstrapIdentity = nil
            bootstrapHasEnabledFilters = false
            shouldBeginTransientBootstrapDNSWait = false
        } else if configuration.enabledBlocklistIDs.isEmpty {
            bootstrapSnapshot = configuration.filterSnapshot()
            bootstrapIdentity = nil
            bootstrapHasEnabledFilters = false
            shouldBeginTransientBootstrapDNSWait = false
        } else if let resumed = bootstrapResidentSnapshotFromDisk(configuration: configuration) {
            // Fast-resume from the user's own on-disk artifact so a cold start (notably a
            // self-reconnect that kills + relaunches the process) does NOT serve a block-all
            // FailClosedRuntimeSnapshot window while the async load decodes — the transient
            // false-positives behind LAV-92/93. Wrap + set the identity exactly like the async
            // commit. For a STRICT resume the immediately-following loadSnapshotInBackground
            // hits the no-op reload gate and SKIPS the redundant multi-MB decode (and its
            // 2x-resident peak); for a LAST-KNOWN-GOOD resume (UR-48 Phase 2a) the stale-hash
            // identity can never satisfy that gate, so the fresh compile still runs and
            // replaces the stale rules within seconds — LKG here only covers the window.
            bootstrapSnapshot = ResolverAdjustedRuntimeSnapshot(
                base: resumed.snapshot,
                resolver: configuration.resolverPreset
            )
            bootstrapIdentity = resumed.identity
            bootstrapHasEnabledFilters = true
            shouldBeginTransientBootstrapDNSWait = false
        } else {
            // No serviceable in-budget on-disk artifact, or it exceeds the synchronous-decode
            // cap → fail closed (NEVER fail open). The async loadSnapshotInBackground resumes
            // from disk / recompiles and commits the real snapshot. For a RECENT self-reconnect
            // launch, DNS requests in this window are queued briefly below instead of receiving
            // synthetic blocked answers; ordinary cold starts keep the existing immediate
            // fail-closed behavior. Queued DNS is not forwarded while the snapshot is unavailable:
            // it is replayed through the filter only after a current-lifecycle snapshot commits,
            // otherwise it receives SERVFAIL. This bootstrap fail-closed is TRANSIENT — the
            // unavailable marker stays false (below) so it does not suppress a later
            // self-reconnect the way a genuine unavailability does.
            // Security boundary: the self-reconnect wait holds at most 64 DNS requests for <=4s
            // after a recent self-reconnect credit. Timeout, overflow, stale lifecycle, or failed
            // snapshot completion all return SERVFAIL instead of forwarding around the filter.
            bootstrapSnapshot = FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)
            bootstrapIdentity = nil
            bootstrapHasEnabledFilters = false
            shouldBeginTransientBootstrapDNSWait = launchFollowsRecentSelfReconnect
            // Deliberately NOT ledgered at ENTRY (INV-OBS-1): this window is transient by design —
            // the async loadSnapshotInBackground commits a real snapshot within ~seconds, and the
            // marker stays false below. It is taken on EVERY start for the over-sync-cap /
            // stale-artifact cohort, so an unconditional record here would flood the 50-record
            // ring with routine startups — the exact INV-OBS-1 misleading-true failure the ledger
            // exists to prevent. Coverage instead splits on user visibility (Codex follow-up):
            // a window that actually SERVES a fail-closed query records once from the serve
            // path (recordDiagnostic — durable past the next resetHealth), a quiet window
            // leaves no record, and if the async load also fails closed (over-budget /
            // unbuildable) it records its own transition-gated failClosedEntered.
        }
        // Publish under snapshotQueue. startTunnel can RESTART the same provider instance while a
        // detached snapshot load from the PRIOR lifecycle is still inside loadCompiledSnapshot
        // (stop/cleanup invalidates the reload generation but neither cancels nor awaits that
        // task), and it reads these queue-guarded markers via currentResidentSnapshotIdentity()/
        // currentResidentSnapshotHasEnabledFilters(). So confine the writes to snapshotQueue like
        // every other access (loadInitialSharedState is called from startTunnel, never on
        // snapshotQueue, so .sync cannot deadlock). The bootstrap also FULLY OWNS all three
        // markers, resetting them in EVERY branch: a startTunnel retry after a
        // setTunnelNetworkSettings failure (whose cleanup clears neither) must not let a stale
        // "healthy filtering resident" marker survive into a fail-closed bootstrap and trick the
        // async keep-resident/no-op decisions.
        snapshotQueue.sync {
            snapshot = bootstrapSnapshot
            protectionPolicySnapshot = bootstrapSnapshot
            residentSnapshotIdentity = bootstrapIdentity
            residentSnapshotHasEnabledFilters = bootstrapHasEnabledFilters
            residentFailClosedDueToUnavailableSnapshot = false
        }
        // SEED THE LOOSENING BASELINE FROM WHAT WE JUST INSTALLED, or this PR's fix does not fire
        // on the commonest cold start.
        //
        // The reset above drops the PREVIOUS session's counts, which is right. Leaving it at `nil`
        // is not, because a bootstrap can install a REAL resident: the strict fast-resume branch
        // above installs the user's own on-disk artifact and stamps its identity — and its own
        // comment says what follows, that `loadSnapshotInBackground` then "hits the no-op reload
        // gate and SKIPS the redundant multi-MB decode". That no-op path returns before the commit,
        // so `recordAdoptedRuleCounts` is never called, and the baseline stays `nil` while a real
        // ruleset is being served. The first later Extra → Balanced or allowlist change then
        // compares against `nil`, reads as "first adoption of a session", posts no nudge — and
        // leaves the reporter's apps stuck exactly as they were (Codex review, PR #645).
        //
        // `blocksEveryLookup` is the right condition, not "is there an identity". A fail-closed
        // bootstrap must stay `nil`: recovery from it is a loosening whatever the counts say, and
        // the commit path already detects that from the resident it replaces. Every other bootstrap
        // — fast-resume, and the empty-configuration pass-through — is a real ruleset the user is
        // being served right now, and that is what a later adoption must be compared against.
        // pinned: FilterLooseningReapplySourceTests.testStartupSeedsTheBaselineFromARealBootstrapResident
        if !bootstrapSnapshot.blocksEveryLookup {
            let bootstrapCounts = FilterLooseningReapplyPolicy.RuleCounts(snapshot: bootstrapSnapshot)
            dnsStateQueue.sync { lastAdoptedRuleCounts = bootstrapCounts }
        }

        // NetworkExtension can spend most of the bounded wait installing settings before DNS
        // packets can arrive. Clear stale wait state here, but start the timer only after
        // setTunnelNetworkSettings succeeds and the async snapshot load/read loop are about
        // to begin.
        cancelTransientBootstrapDNSWait(reason: "loadInitialSharedState")

        loadDiagnosticsAndEventLogStores()
        // A prune performed during load (resetForCurrentDayIfNeeded once the fine-grained
        // retention window has elapsed) sets the store's pending-prune flag but not the
        // persistence controller's dirty flag, so persist when EITHER is set — otherwise an
        // idle start leaves >7-day domain-history events in the app-group JSON until the next
        // DNS event dirties diagnostics, breaking the on-disk retention guarantee.
        let prunedDuringLoad = diagnostics.consumePendingFineGrainedPrunePersist()
        if prunedDuringLoad || diagnosticsPersistence.isDirty {
            persistDiagnosticsIfNeeded(force: true)
        }

        // Startup-side ledger retention sweep (arm/confirm, never single-clock
        // destructive): the on-disk 7-day window must hold even for a device with few
        // incident writes, and tunnel starts are the reliable recurring hook. Like
        // recordIncident, observability-only — nothing reads a result.
        Self.sweepIncidentLedger()

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadInitialSharedState-ready", details: [
            "bootstrapBlockRuleCount": "\(snapshot.blockRuleCount)",
            "bootstrapAllowRuleCount": "\(snapshot.allowRuleCount)"
        ])
        return shouldBeginTransientBootstrapDNSWait
    }
}
