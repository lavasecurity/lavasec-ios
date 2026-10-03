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
    // MARK: - Diagnostics & upstream health recording

    /// Records the final filtering outcome. Forwarded queries wait for answer-alias inspection;
    /// immediate blocks record at dispatch. `isReplayOfARecordedDecision` suppresses duplicate
    /// user counts only; current fail-closed and locked-boot evidence is always recorded.
    func recordDiagnostic(
        domain: String,
        decision: FilterDecision,
        failClosedReason: String? = nil,
        isReplayOfARecordedDecision: Bool = false
    ) {
        // Stamp the event at the DECISION moment, not when this queued block later runs. A clear
        // can advance the SQLite clear floor in between, so a queued pre-clear decision stamped
        // with a post-clear `Date()` would sit at `ts >= floor` and survive the clear/prune in
        // the depth store even though the JSON buffer is wiped — reappearing in Domain History
        // (PR #327 review). Using the decision time keeps the depth store on the same side of the
        // floor as the buffer.
        let decisionTime = Date()
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.refreshConfigurationIfNeeded()
            // Fail-closed serves stay OUT of user-facing filtering counts and Domain History
            // (record below drops them — #164 honesty rule), but they must leave a durable
            // observability trace: without one, a past fail-closed window is indistinguishable
            // from "no incident" in a field report. Health counters carry no user-count
            // semantics, so trace here — BEFORE the diagnostics-preferences gate, which must
            // not silence it. The reason was captured atomically with the decision under
            // snapshotQueue (a reload can commit a real snapshot before this deferred block
            // runs, so a late marker read could mislabel the window that actually served).
            if decision.reason == .protectionUnavailable {
                let resolvedReason = failClosedReason ?? "transient-protection-unavailable"
                // Force-persist the FIRST trace of a fail-closed window class (and a
                // reason-class change): health writes are debounced 30 s and the app-side
                // sample can skip a provider flush inside that window, so a report filed
                // right after the outage would still read a health file with no trace —
                // the exact gap this trace closes. Subsequent same-window queries ride
                // the debounce (one forced write per window class, not per query).
                let isFirstTraceOfWindowClass = self.health.failClosedServedQueryCount == 0
                    || self.health.lastFailClosedReason != resolvedReason
                self.health.failClosedServedQueryCount += 1
                let blockedAt = Date()
                self.health.lastFailClosedAt = blockedAt
                self.health.lastFailClosedReason = resolvedReason
                if resolvedReason == "snapshot-unavailable" {
                    self.recordUnavailableFilteringForNotification(now: blockedAt)
                }
                self.markHealthUpdated()
                if isFirstTraceOfWindowClass {
                    self.persistHealthIfNeeded(force: true)
                    self.scheduleProtectionNotificationIfNeeded()
                    // INV-OBS-1 refinement (Codex): the transient bootstrap window is NOT
                    // ledgered at entry — quiet routine starts must stay silent — but a
                    // window that actually SERVED a query is a user-visible outage whose
                    // only other trace (the health counters above) is session-scoped:
                    // resetHealth() on the next start wipes it, so a late-filed report
                    // after a restart would again read "no incident". Ledger the FIRST
                    // transient serve per window class (at most one record per tunnel
                    // start — never per query, so the 50-record ring cannot flood). The
                    // persistent classes ride their own transition-gated commit-site
                    // records; recording their serves too would double-enter one window.
                    if resolvedReason == "transient-protection-unavailable" {
                        Self.recordIncident(.failClosedEntered, reason: resolvedReason)
                    }
                }
            }
            // Locked-boot filtering evidence (incident plan Phase 4 follow-up; the QA
            // release gate's "Path A" — lavasec-infra
            // docs/engineering/reboot-first-unlock-qa-protocol.md): while the shared
            // stores still reflect a locked boot, bucket every decision into the health
            // snapshot's lockedBoot* counters. Health is Class-None (INV-PERSIST-2) and
            // never reloaded mid-session, so this is the ONE record of locked-window
            // filtering that survives to a post-unlock export — the Class-C privacy
            // stores defer or drop theirs (and the reload below discards their in-memory
            // locked-window bookkeeping). Deliberately BEFORE the diagnostics-preferences
            // gate — this is observability evidence, not a user-facing count, the same
            // posture as the fail-closed trace above — and counters-only, no domain
            // (privacy audit). Membership is TWO-BRANCH, because neither the flag nor a
            // frozen timestamp alone is exact (Codex review, #381, three rounds):
            //  • flag set + a FRESH canary probe observing locked NOW ⇒ the decision is
            //    certainly pre-unlock — admit exactly, and the probe doubles as a fresh
            //    locked observation. The flag alone over-admits: it clears only at the
            //    throttled readable reload, so it stays set for up to one refresh interval
            //    of post-unlock traffic. The probe costs one stat, paid ONLY inside the
            //    bounded locked-boot window — never the steady-state hot path.
            //  • otherwise ⇒ conservative boundary: admit only decisions predating the
            //    last observed-locked instant (frozen into the window-end stamp once the
            //    reload runs). Recovers pre-unlock stragglers whose blocks dequeue after
            //    the reload; drops the ambiguous (observation, unlock] sliver — the gate
            //    may under-report and rerun, never fabricate.
            // Rides the 30 s health debounce while the window is open (the window-end
            // stamp force-persists once at unlock); fallback-admitted stragglers force
            // their own persist below.
            // pinned: TunnelPreUnlockGuardSourceTests.testLockedBootServesAreBucketedIntoClassNoneHealthEvidence
            if self.diagnosticsStoresReflectLockedBoot, !self.sharedProtectedContentIsReadable() {
                self.lastObservedLockedSharedContentAt = Date()
                self.health.recordLockedBootServe(action: decision.action, reason: decision.reason)
                self.markHealthUpdated()
            } else if self.health.lockedBootWindowCovers(decisionAt: decisionTime, lastObservedLockedAt: self.lastObservedLockedSharedContentAt) {
                self.health.recordLockedBootServe(action: decision.action, reason: decision.reason)
                self.markHealthUpdated()
                // A straggler admitted past the certainly-locked branch lands at or after
                // the unlock boundary — the window stamp's forced write may already be
                // done, so force again or a jetsam/stop inside the 30 s debounce persists
                // the stamp but loses the count: exactly the sparse evidence the fallback
                // exists to preserve (Codex review, #381). Bounded by the handful of
                // unlock-boundary blocks, never steady-state: later decisions fail the
                // boundary comparison and never reach here.
                self.persistHealthIfNeeded(force: true)
            }
            // Everything above is observability evidence and runs for a replay too (see the
            // parameter's note). Everything below is the user-facing record, which this
            // query has already had.
            guard !isReplayOfARecordedDecision else {
                return
            }

            let configuration = self.currentAppConfiguration()
            guard configuration.keepFilteringCounts || configuration.keepDomainDiagnostics else {
                return
            }

            let rolledOver = self.diagnostics.resetForCurrentDayIfNeeded()
            let recordMutated = self.diagnostics.record(
                domain: domain,
                decision: decision,
                keepFilteringCounts: configuration.keepFilteringCounts,
                keepDomainHistory: configuration.keepDomainDiagnostics
            )
            // Mirror the JSON events buffer's population into the SQLite depth store: same gate
            // (`keepDomainDiagnostics`) and same exclusion of fail-closed blocks (which are not
            // curated matches and aren't shown in Domain History). Paused-allows are included,
            // exactly as they are in the events buffer. Fire-and-forget so `dnsStateQueue` never
            // blocks on sqlite, best-effort so a log failure can't affect filtering (INV-DNS-1).
            if configuration.keepDomainDiagnostics, decision.reason != .protectionUnavailable {
                self.dnsEventLog?.appendBestEffort(domain: domain, decision: decision, timestamp: decisionTime)
            }
            // Suppressed fail-closed queries leave the store unchanged (record drops them from
            // history + counts), so don't re-dirty/re-persist the same diagnostics file ~every
            // 30s during a fail-closed outage. Still persist when the day rolled over or expired
            // history was pruned — consume the prune flag so it doesn't dangle for the load path.
            let prunePending = self.diagnostics.consumePendingFineGrainedPrunePersist()
            if rolledOver || recordMutated || prunePending {
                self.markDiagnosticsUpdated()
            }
        }
    }

    /// Records, at most once per session per `(ruleKind, action)` pair, that a query reaching the
    /// filter was covered by one of the user's own manual `blockedDomains`/`allowedDomains`.
    ///
    /// The direct answer to "I added a domain and it still loads": if the user's added name is
    /// queried and reaches the filter, this event names the rule kind and the decision WITHOUT the
    /// name (the queried domain never enters the log). Membership scans rule sets normalized once
    /// per configuration (`ManualDomainRuleSet`), so it is a per-query suffix scan, not a
    /// per-query normalization. Bounded to at most FOUR logged pairs per session (2 rule kinds x
    /// 2 actions); once all are logged the helper short-circuits before scanning any rule, so it is
    /// never a per-query log. Silence means the query did not reach the filter — the
    /// unclaimed-resolver / DoH escape — or no rule covers the name; the escape reading is only
    /// sound until a pair has been logged, because the dedup then suppresses every later match of
    /// that pair. Runs OFF `dnsStateQueue` (the packet read loop's callback queue and the
    /// wake-replay queue) against the lock-guarded `manualRuleDiagnosticState`, whose snapshot
    /// `adoptAppConfiguration` publishes ON that queue — the lock, not the queue, is what
    /// synchronizes the two.
    func recordManualRuleDecisionIfNeeded(normalizedDomain: String, decision: FilterDecision) {
        // The fail-closed guard lives in the pure matcher: `coverage` returns nil for
        // `.protectionUnavailable`, so a covered name during a fail-closed window cannot log a
        // manual-rule block it did not cause and cannot consume a dedup slot.
        // pinned: ManualDomainRuleDiagnosticSourceTests.testFailClosedDecisionCannotLogAManualRuleMatch
        // ONE lock-guarded read, deliberately off `dnsStateQueue`: this helper runs on the packet
        // read loop's callback queue and the wake-replay queue, while `adoptAppConfiguration`
        // publishes on `dnsStateQueue`. A plain strong-reference read here was an unsynchronized
        // cross-thread access — a data race, not merely a torn-value concern — so the snapshot and
        // the logged-key count come out of the SAME lock critical section. The critical section is
        // a pointer read plus a `Set.count`, so the per-query path still takes no `dnsStateQueue`
        // hop (`INV-QUEUE-1`).
        // pinned: ManualDomainRuleDiagnosticSourceTests.testTheOffQueueReadPathReadsTheGuardedState
        let (snapshot, loggedKeyCount) = manualRuleDiagnosticState.withLock {
            ($0.snapshot, $0.loggedKeys.count)
        }
        // Cheap cap short-circuit BEFORE the rule scan: once all 2x2 pairs are logged the helper
        // owes nothing more, so a covered query must not scan either normalized rule set or enqueue
        // a no-op dedup hop (Kilo round 3, PR #745).
        // pinned: ManualDomainRuleDiagnosticSourceTests.testTheCoveredQueryShortCircuitsOnceEveryPairIsLogged
        guard loggedKeyCount < ManualDomainRuleMatch.loggedPairCount else {
            return
        }
        guard let snapshot else {
            return
        }
        guard let ruleKind = ManualDomainRuleMatch.coverage(
            normalizedDomain: normalizedDomain,
            for: decision,
            blockedRules: snapshot.blocked,
            allowedRules: snapshot.allowed
        ) else {
            return
        }
        let actionValue = decision.action == .block ? "block" : "allow"
        let key = "\(ruleKind.rawValue):\(actionValue)"
        // THE DEDUP SET IS SESSION STATE AND ITS MUTATION IS SERIALIZED. The coverage read above
        // is off-queue; the once-per-match insert+log hops onto `dnsStateQueue`, and the insert
        // itself runs under the same lock the read took, so neither a concurrent
        // `handleDNSRequest` nor a second covered query can race the `Set`. The insert re-checks
        // the cap under the lock because the read above is a snapshot, not a reservation.
        // pinned: ManualDomainRuleDiagnosticSourceTests.testTheDedupMutationIsSerializedUnderTheGuardedState
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }
            let didInsert = self.manualRuleDiagnosticState.withLock { state -> Bool in
                guard state.loggedKeys.count < ManualDomainRuleMatch.loggedPairCount else {
                    return false
                }
                return state.loggedKeys.insert(key).inserted
            }
            guard didInsert else {
                return
            }
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "manual-rule-decision", details: [
                "manualRuleKind": ruleKind.rawValue,
                "manualRuleAction": actionValue
            ])
        }
    }

    func markLocalProtectionUptimeStarted() {
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard self.currentAppConfiguration().keepFilteringCounts else {
                return
            }

            self.diagnostics.startLocalProtectionUptime()
            self.markDiagnosticsUpdated()
            self.persistDiagnosticsIfNeeded(force: true)
        }
    }

    func refreshConfigurationIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastConfigurationRefreshAt) >= configurationRefreshInterval else {
            return
        }

        lastConfigurationRefreshAt = now
        let modifiedAt = modificationDate(for: configurationURL)
        guard force || modifiedAt != lastConfigurationModifiedAt else {
            return
        }

        switch loadConfigurationClassified() {
        case .loaded(let configuration):
            setAppConfiguration(configuration)
            // INV-PERSIST-1: a readable classification reaches the flush from the
            // serve-path cadence (recordDiagnostic, ≤ one configurationRefreshInterval)
            // and the app's reload message — NOT only the snapshot-adoption path — so a
            // readable config whose reload exits without adopting (over-budget,
            // unbuildable artifact) still flushes on the next cadence tick (Codex P2
            // round 12 on #377). Post-INV-PERSIST-2 a successful CONFIG load no longer
            // proves first unlock (the config is Class-None and reads fine pre-unlock);
            // the flush's begin re-checks the suite-plist canary and re-defers while
            // Class C is still locked.
            flushDeferredFreshProtectionVPNSessionIfNeeded(hasDecodableConfiguration: true)
            // Stamp the mtime marker only once nothing is deferred: post-INV-PERSIST-2 a
            // PRE-unlock tick can classify .loaded, and stamping there — with the begin
            // just re-deferred by its canary — would wall the flush off behind the
            // unchanged-mtime gate until an unrelated config write (the round-14 marker
            // principle, applied at the refresh site; PR #378 review). A pre-unlock boot
            // therefore re-reads the config each tick until the begin lands — bounded by
            // first unlock, and the same cost the nil boot marker already accepts.
            if !hasPendingFreshProtectionVPNSessionBegin() {
                lastConfigurationModifiedAt = modifiedAt
            }
        case .absentOrCorrupt:
            // READABLE content that fails to decode (or an absent file) proves first unlock
            // just as well — the deferred begin must flush HERE too, or a config that turns
            // out corrupt behind a locked boot strands the pending begin (pause mask,
            // locked-boot diagnostics flag, fail-closed placeholder) forever, because this
            // branch repeats on every tick (Codex P2 round 17 on #377). Deliberately no
            // config adoption, no mtime stamp, and NO recovery reload (the false below):
            // the nil marker keeps re-classifying each tick, so the app's reseed rewrite
            // flips the next tick to .loaded — the same recovery corrupt configs get on a
            // normal boot. The flush is take-once, so the repeat ticks after it are no-ops.
            flushDeferredFreshProtectionVPNSessionIfNeeded(hasDecodableConfiguration: false)
        case .unreadable:
            // Still locked — the nil marker keeps this retrying every tick until unlock.
            // Fresh locked observation (pre-INV-PERSIST-2-migration boots, where the config
            // itself is still Class C — post-migration ticks classify .loaded and observe
            // locked via the begin's re-defer instead): bounds the locked-boot evidence
            // window (see lastObservedLockedSharedContentAt). GATED on the locked-boot flag
            // plus a fresh suite-canary probe: post-migration the config is Class-None, so
            // a transient I/O error ALSO classifies .unreadable here — on a never-locked
            // session an ungated stamp would seed the covers boundary and admit ordinary
            // traffic as locked-boot evidence (Codex review, #381). The probe's stat is
            // paid only on the rare unreadable tick, never steady-state.
            if diagnosticsStoresReflectLockedBoot, !sharedProtectedContentIsReadable() {
                lastObservedLockedSharedContentAt = Date()
            }
        }
    }

    // The resolver/network-settings-relevant projection of the configuration.
    // A reload whose projection is unchanged must not reset the DNS runtime or
    // reapply tunnel network settings (which the user sees as a reconnect) —
    // diagnostics toggles and paid status are deliberately excluded.
    static func resolverNetworkIdentity(_ configuration: AppConfiguration) -> String {
        [
            configuration.resolverPresetID,
            configuration.configuredPrimaryDNSResolverTier.rawValue,
            configuration.customResolverAddress ?? "",
            configuration.customResolverSecondaryAddress ?? "",
            configuration.fallbackToDeviceDNS ? "1" : "0",
            // The encrypted Device-DNS fallback resolver is part of the resolver
            // runtime too: changing it (e.g. saving a hostname-based Custom DoH/DoT/DoQ
            // alternative while running) must count as a resolver change so the reload
            // re-warms its bootstrap hostname, rather than leaving it un-warmed until a
            // later packet resets the runtime — by which point Device DNS may be wedged.
            configuration.usesEncryptedDeviceDNSFallback ? "1" : "0",
            configuration.usesExplicitDNSTiers ? "1" : "0",
            configuration.fallbackResolverPresetID,
            configuration.fallbackCustomResolverAddress ?? "",
            configuration.fallbackCustomResolverSecondaryAddress ?? ""
        ].joined(separator: "|")
    }

    func recordCacheHit() {
        health.cacheHitCount += 1
        markHealthCountersUpdated()
    }

    func recordCacheMiss() {
        health.cacheMissCount += 1
        markHealthCountersUpdated()
    }

    func recordCoalescedQuery() {
        health.coalescedQueryCount += 1
        markHealthCountersUpdated()
    }

    func recordUpstreamResult(_ result: DNSResolutionResult, clientDeadlineExpired: Bool = false) {
        // Backoff is fenced per-attempt inside updateResolverBackoff (task #56): a stale old-path rung
        // is dropped there, a new-path rung of the same ladder is kept. Health evidence still flows for
        // the whole result — a chained timeout is already routed to the outage supervisor, not the
        // physical reconnect coordinator, below.
        updateResolverBackoff(from: result.attempts)
        let now = Date()
        let tierEvidence = clientDeadlineExpired
            ? result.tierEvidence.map { $0.recordingClientDeadlineExpired() } : result.tierEvidence
        recordResolverTierEvidence(tierEvidence, at: now)
        health.networkKind = currentNetworkKind()
        // While chained, this resolution was carried through the tunnel to the conf's own
        // resolver, so its health is the outage supervisor's, not the physical-DNS reconnect
        // coordinator's — and whether the physical coordinator consumes this evidence is the
        // same ownership question the reconnect actor and the egress suspension ask, so it is
        // answered by the one authority instead of re-read here (`dnsHealthAuthority`, which the
        // reconnect gate and `ChainedResolverEgressPolicy` also consult). Without it, a chained
        // resolution's fail-closed `.backedOff`/timeout crosses the physical reconnect threshold
        // and the app shows a false "reconnect" while DNS works (device-verified, chimmy
        // 2026-08-14). Read on `dnsStateQueue`, where this completion already runs.
        let completion = ResolverHealthOrganicUpstreamCompletion(
            occurredAt: now,
            result: result,
            chainedDataPathLatched: !dnsHealthAuthority().organicEvidenceFeedsPhysicalReconnect,
            clientDeadlineExpired: clientDeadlineExpired
        )
        applyResolverHealthEvent(.organicUpstreamCompleted(completion))
    }

    // MARK: - Canonical tier evidence and repair dispatch

    func currentResolverTierPathEpoch() -> Int {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return resolverBackoffPathEpoch
        }
        return dnsStateQueue.sync { resolverBackoffPathEpoch }
    }

    func resetResolverTierEvidence() {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        resolverTierRecoveryRetry?.cancel()
        resolverTierRecoveryRetry = nil
        resolverTierHealth = ResolverTierHealth()
        latestResolverTierEvidence.removeAll(keepingCapacity: true)
        resolverTierContextIdentity = nil
        resolverTierSnapshotIdentity = UUID().uuidString
        lastResolverTierRecoveryLogSignature = nil
        health.dnsTierHealth = []
    }

    // Mode-insensitive configured identity: a temporary T2 promotion is service by the same
    // ladder, not a new selection. The private cache key never enters logs or pane snapshots.
    func currentResolverTierContextIdentity() -> String {
        let configured = currentResolverRuntimeConfiguration(ignoresDeviceDNSFallbackMode: true)
        return "\(tunnelLifecycleGeneration)|\(tunnelDataPathLatchEpoch)|\(resolverBackoffPathEpoch)|\(configured.cacheIdentifier)"
    }

    // A single ordering source for send admission and observed replies, independent of wall
    // clock changes. The transports enter through the same queue-specific re-entrancy seam.
    func nextResolverTierObservationSequence() -> UInt64 {
        let advance: () -> UInt64 = {
            self.resolverTierObservationSequence += 1
            return self.resolverTierObservationSequence
        }
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true { return advance() }
        return dnsStateQueue.sync(execute: advance)
    }

    // Observe a sealed raw Device reply before a slower lower rung can delay its delivery.
    // This only retires silence; counters and client-service credit stay with final evidence.
    func recordResolverTierReply(
        _ evidence: ResolverTierEvidence, lifetime: DNSResolutionLifetime? = nil,
        contextIdentity: String? = nil, runtimeGeneration: Int? = nil
    ) -> ResolverTierEvidence {
        let observe: () -> ResolverTierEvidence = {
            guard self.tunnelLifecycleIsActive, self.resolverTierEvidenceIsCurrent(evidence),
                  lifetime?.runtimeIsCurrent ?? true,
                  contextIdentity.map({ self.currentResolverTierContextIdentity() == $0 }) ?? true,
                  runtimeGeneration.map({ self.resolverRuntimeGeneration == $0 }) ?? true,
                  evidence.resolverKind == .device,
                  evidence.outcome == .served || evidence.outcome == .answered else { return evidence }
            let selections = self.currentAppConfiguration().dnsResolutionSelections
            let selectionIndex = evidence.tier == .tierOne ? 0 : 1
            guard evidence.tier != .tierZero, selections.indices.contains(selectionIndex),
                  selections[selectionIndex].isEnabled,
                  selections[selectionIndex].resolver?.transport == .deviceDNS,
                  !evidence.resolverAddresses.isEmpty,
                  evidence.resolverAddresses.allSatisfy({ self.deviceDNSResolverAddresses.contains($0) })
            else { return evidence }
            let context = self.currentResolverTierContextIdentity()
            if self.resolverTierContextIdentity != context {
                self.resetResolverTierEvidence()
                self.resolverTierContextIdentity = context
            }
            let sequence = evidence.replySequence ?? self.nextResolverTierObservationSequence()
            let wasChecking = self.resolverTierHealth.deviceDNSConfirmationNeeded(for: evidence.tier)
                || self.resolverTierHealth.deviceDNSRecaptureIsConfirmed(for: evidence.tier)
            self.resolverTierHealth.observeDeviceDNSReply(for: evidence.tier, observationSequence: sequence)
            if !DNSResolverTier.allCases.contains(where: {
                self.resolverTierHealth.deviceDNSConfirmationNeeded(for: $0)
                    || self.resolverTierHealth.deviceDNSRecaptureIsConfirmed(for: $0)
            }) {
                self.resolverTierRecoveryRetry?.cancel()
                self.resolverTierRecoveryRetry = nil
            }
            let retired = wasChecking && !self.resolverTierHealth.deviceDNSConfirmationNeeded(for: evidence.tier)
                && !self.resolverTierHealth.deviceDNSRecaptureIsConfirmed(for: evidence.tier)
            if retired {
                let incident = self.resolverTierConfirmation?.tier == evidence.tier
                    ? self.resolverTierConfirmation?.sequence ?? sequence : sequence
                self.logDeviceDNSTierConfirmation(evidence: evidence, decision: "retired-by-reply", sequence: incident)
                self.projectResolverTierHealth()
            }
            return evidence.recordingReply(observationSequence: sequence)
        }
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true { return observe() }
        return dnsStateQueue.sync(execute: observe)
    }

    func recordResolverTierEvidence(_ observations: [ResolverTierEvidence], at now: Date) {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        guard tunnelLifecycleIsActive else { return }
        let context = currentResolverTierContextIdentity()
        if resolverTierContextIdentity != context {
            resetResolverTierEvidence()
            resolverTierContextIdentity = context
        }
        for evidence in observations {
            guard resolverTierEvidenceIsCurrent(evidence) else { continue }
            let observationSequence = nextResolverTierObservationSequence()
            let action = resolverTierHealth.apply(evidence, at: now, observationSequence: observationSequence)
            let delayedDeviceReply = evidence.resolverKind == .device
                && (evidence.outcome == .served || evidence.outcome == .answered)
                && (resolverTierHealth.deviceDNSConfirmationNeeded(for: evidence.tier)
                    || resolverTierHealth.deviceDNSRecaptureIsConfirmed(for: evidence.tier))
            if evidence.outcome != .notAttempted && !delayedDeviceReply {
                latestResolverTierEvidence[evidence.tier] = evidence
            }
            switch action {
            case .none:
                if evidence.outcome == .failure, evidence.resolverKind == .device {
                    if resolverTierHealth.deviceDNSConfirmationNeeded(for: evidence.tier) {
                        scheduleDeviceDNSTierConfirmation(evidence: evidence, now: now)
                    }
                }
                if evidence.outcome == .served, evidence.resolverKind == .device {
                    creditProductiveSelfReconnectIfPending(now: now, recoveredDeviceDNS: true)
                }
            case .upstreamSession:
                // T0 is already observed by the chained driver's tunnel-DNS executor. Its
                // session retry/surrender ladder remains the single upstream recovery owner.
                break
            case .retryFixedEndpoint:
                // recordUpstreamResult applied per-endpoint backoff before this dispatch. Its
                // bounded recovery launch reopens suppressed endpoints on subsequent lookups.
                // A fixed endpoint failure never creates a device-address recapture grant.
                if dnsHealthAuthority().physicalInterfaceHealthProbesMayRun {
                    scheduleResolverWedgeRecoveryProbeIfNeeded()
                }
            case .recaptureDeviceDNS:
                evaluateDeviceDNSTierRecapture(
                    evidence: evidence, observationSequence: observationSequence, now: now)
            }
        }
        // A source-matched reply by THIS Device tier retires its no-response opportunity.
        // Resolver-declared errors remain separate rejection evidence, never stale-address proof.
        // Other tiers' replies cannot clear it; the retry callback consults the stored Device evidence.
        if !latestResolverTierEvidence.values.contains(where: {
            $0.resolverKind == .device && $0.outcome == .failure
        }) {
            resolverTierRecoveryRetry?.cancel()
            resolverTierRecoveryRetry = nil
        }
        projectResolverTierHealth()
    }

    func resolverTierEvidenceIsCurrent(_ evidence: ResolverTierEvidence) -> Bool {
        guard evidence.originatingLifecycle == tunnelLifecycleGeneration else { return false }
        if currentTunnelDataPathMode().isChainedUpstream {
            guard evidence.originatingLatchEpoch == tunnelDataPathLatchEpoch else { return false }
        } else if evidence.originatingLatchEpoch != nil {
            return false
        }
        // No-wire refusals remain useful counters but cannot authorize repair. Actual evidence
        // must have the epoch stamped at launch/send, never read back at completion (INV-DNS-4).
        return evidence.outcome == .notAttempted || evidence.pathEpoch == resolverBackoffPathEpoch
    }

    func projectResolverTierHealth() {
        let previousRepairKey = resolverTierRepairSignalKey()
        health.dnsTierHealth = resolverTierHealth.snapshots.map { snapshot in
            var projected = snapshot
            projected.configurationIdentity = resolverTierSnapshotIdentity
            return projected
        }
        markHealthCountersUpdated()
        if previousRepairKey != resolverTierRepairSignalKey() {
            // Persist before the app nudge so a deferred tier repair becomes actionable on
            // its first foreground read. Counter-only churn keeps the debounced writer.
            persistHealthIfNeeded(force: true)
            signalAppIfConnectivityStateChanged()
        }
    }

    private func resolverTierRepairSignalKey() -> String {
        health.dnsTierHealth.map {
            "\($0.tier.rawValue)|\($0.recoveryKind.rawValue)|\($0.recoveryStatus.rawValue)"
        }.joined(separator: ";")
    }

    private func updateResolverBackoff(from attempts: [ResolverAttempt], now: Date = Date()) {
        // task #56 (Codex, #565): drop any attempt whose tunnelled path-epoch is stale before it reaches
        // the ledger. A rung sent on the OLD physical path before a surviving-carry roam must not
        // re-stamp the backoff the roam just cleared, but a LATER rung of the same failover ladder sent
        // on the NEW path MUST still back off the resolver that timed out there — so this fences
        // PER-ATTEMPT, not per-resolution. `pathEpoch == nil` marks a non-tunnelled attempt (DNS-only /
        // DoH / DoT), which is never epoch-fenced (its runtime-generation gate covers a reset). The
        // current epoch is dnsStateQueue-confined, and this runs on that queue (completeForward ->
        // recordUpstreamResult -> here).
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        let currentEpoch = resolverBackoffPathEpoch
        let currentPathAttempts = attempts.filter {
            $0.pathEpoch == nil || $0.pathEpoch == currentEpoch
        }
        guard !currentPathAttempts.isEmpty else { return }
        resolverBackoffStateQueue.sync {
            resolverBackoffPolicy.record(
                currentPathAttempts.map {
                    ResolverBackoffPolicy.Attempt(
                        address: $0.address,
                        outcome: ResolverBackoffPolicy.AttemptOutcome($0.outcome)
                    )
                },
                now: now
            )
        }
    }

    func markHealthUpdated() {
        refreshHealthEnvelope()
        signalAppIfConnectivityStateChanged()
        healthPersistence.markDirty()
    }

    func markResolverHealthProjectionUpdated() {
        refreshHealthEnvelope()
        healthPersistence.markDirty()
    }

    private func refreshHealthEnvelope() {
        health.updatedAt = Date()
        health.networkKind = currentNetworkKind()
    }

    /// The per-query counter bumps (`recordCacheHit` / `recordCacheMiss` /
    /// `recordCoalescedQuery`) update only stats fields the connectivity
    /// assessment never reads (`cacheHitCount` / `cacheMissCount` /
    /// `coalescedQueryCount`), so they must NOT re-run the full
    /// `ProtectionConnectivityPolicy` cascade. Doing so on every served query
    /// was pure steady-state CPU work that always produced the same severity
    /// (the Darwin nudge is deduped by key anyway, so the post was already a
    /// no-op there). Connectivity-relevant mutations keep going through
    /// `markHealthUpdated`, while resolver-health projections use
    /// `markResolverHealthProjectionUpdated` plus their ordered signal effect.
    /// Both paths still reassess and signal when required. dnsStateQueue-confined.
    func markHealthCountersUpdated() {
        refreshHealthEnvelope()
        healthPersistence.markDirty()
    }

    /// Posts the tunnel-health Darwin nudge when the connectivity-relevant state
    /// (the assessment that drives the Dynamic Island's reconnecting / network
    /// lost / needs-reconnect glyphs) changes. Deduped so routine health churn
    /// that does not change the derived state stays quiet. dnsStateQueue-confined,
    /// like the `health` it reads (UR-6).
    func signalAppIfConnectivityStateChanged(now: Date = Date()) {
        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )
        let connectivitySignalKeyValue = "\(assessment.severity.diagnosticLabel)|\(String(describing: assessment.primaryAction))|\(resolverTierRepairSignalKey())"
        guard connectivitySignalKeyValue != lastSignaledConnectivityKey else {
            return
        }

        lastSignaledConnectivityKey = connectivitySignalKeyValue
        connectivitySignalNotifier.postNotification(named: TunnelHealthSignal.darwinNotificationName)
    }

    func persistHealthIfNeeded(force: Bool = false) {
        healthPersistence.flush(force: force)
    }
}
