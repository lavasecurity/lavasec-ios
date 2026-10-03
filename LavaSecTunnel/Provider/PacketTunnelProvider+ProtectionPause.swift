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
    // MARK: - Temporary protection pause / resume

    func scheduleProtectionPauseResumeIfNeeded(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.scheduleProtectionPauseResumeIfNeeded(reason: reason)
            }
            return
        }

        cancelProtectionPauseResumeTimer()
        guard let until = currentTemporaryProtectionPauseUntil() else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: dnsStateQueue)
        timer.schedule(deadline: .now() + max(0, until.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in
            self?.resumeExpiredTemporaryProtectionPauseIfNeeded()
        }
        protectionPauseResumeTimer = timer
        timer.resume()
    }

    func cancelProtectionPauseResumeTimer() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.cancelProtectionPauseResumeTimer()
            }
            return
        }

        protectionPauseResumeTimer?.cancel()
        protectionPauseResumeTimer = nil
    }

    private func resumeExpiredTemporaryProtectionPauseIfNeeded() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.resumeExpiredTemporaryProtectionPauseIfNeeded()
            }
            return
        }

        guard let until = currentTemporaryProtectionPauseUntil() else {
            cancelProtectionPauseResumeTimer()
            return
        }

        guard Date() >= until else {
            scheduleProtectionPauseResumeIfNeeded(reason: "pause-not-expired")
            return
        }

        protectionPauseResumeTimer = nil
        try? protectionPauseStore.clearStoredPause()
        cacheTemporaryProtectionPauseUntil(nil)
        lastAppliedTemporaryProtectionPauseIsActive = false
        updateLiveActivitiesAfterTemporaryProtectionPauseExpired()
        postPauseEndedNotification()
        // No DNS runtime reset or snapshot reload on expiry: the loaded snapshot
        // is identity-unchanged, pause-era cache entries expire with the pause
        // window, and pending forwards re-check policy at completion.
    }

    private func updateLiveActivitiesAfterTemporaryProtectionPauseExpired() {
        Task {
            let defaults = LavaSecAppGroup.sharedDefaults
            let state = LavaActivityAttributes.ContentState(
                protectionState: .on,
                resumeDate: nil,
                pauseRequiresAuthentication: SecurityProtectedSurfaceStorage.isProtected(
                    .protectionPause,
                    defaults: defaults, projectionURL: LavaSecAppGroup.securityGateProjectionURL
                ),
                shieldStyle: GuardianShieldStyle(
                    rawValue: defaults.string(forKey: LavaSecAppGroup.customizationLavaGuardLookDefaultsKeyName) ?? ""
                ) ?? .original,
                pauseMinutes: LiveActivityPausePreference.minutes(
                    from: ProtectionUserDefaultsStorage(defaults: defaults)
                )
            )
            let content = ActivityContent(state: state, staleDate: nil)
            let activities = Activity<LavaActivityAttributes>.activities

            #if DEBUG || LAVA_QA_TOOLS
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "pause-expired-live-activity-update", details: [
                "count": String(activities.count)
            ])
            #endif

            for activity in activities {
                // Re-verify before EACH update, co-located with activity.update: this ON publish
                // runs in an unstructured, unversioned ActivityKit Task (unlike the command
                // service's revision-guarded path), and each prior `await` in this loop can suspend
                // long enough for a new pause to be written — so a single pre-loop check would let
                // a stale `.on` reach the REMAINING activities and strand the Dynamic Island on
                // while the store/tunnel are paused. Any active pause → stop; leave the Live
                // Activity to that pause's own update (Codex #208).
                guard (try? protectionPauseStore.currentPauseState()) == nil else {
                    return
                }
                await activity.update(content)
            }
        }
    }

    /// Post the "Pause ended — protection is back on" banner for a pause that EXPIRED on the tunnel's
    /// timer — the only process guaranteed alive when a pause ends with the app closed, which is exactly
    /// the moment the user has no other signal (the Live Activity flip reaches only users who enabled
    /// it). Closed/backgrounded only via the age-bounded foreground read; the category toggle
    /// (`protectionResumed`) + notification permission are enforced inside `LavaEventNotificationPoster`.
    /// Deliberately NOT called from `reconcileProtectionOnAfterVanishedTemporaryPause`: a vanished pause
    /// is a user-initiated resume (in-app / widget / Live Activity — the user watched the flip) or a
    /// defensive cap-discard, not an expiry. A fire-and-forget Task is safe HERE, unlike the App Intents
    /// poster's awaited post (Codex P2 lineage): the NE process is long-lived, so there is no
    /// perform()-return suspension race. The Task touches no dnsStateQueue-confined state — only the
    /// lock-protected pause store, mirroring the Live Activity republish task above (INV-QUEUE-1).
    private func postPauseEndedNotification() {
        Task {
            let defaults = LavaSecAppGroup.sharedDefaults
            guard !LavaAppForegroundPublication.isForegroundActive(in: defaults) else { return }
            let body = LavaEventNotificationPoster.pauseEndedBody(
                languageCode: LavaNotificationLanguage.pinnedCode(in: defaults)
            )
            // Re-verify the store right before the post, co-located with it — the same Codex #208
            // pattern the Live Activity republish above uses: this unstructured Task can suspend long
            // enough for the user to start a NEW pause from the widget/Live Activity, and "protection
            // is back on" must never land while filtering is paused again. Any active pause → drop the
            // banner; that pause's own expiry posts its own. (The residual await inside the poster is
            // the same accepted window as the LA loop's activity.update.)
            guard (try? protectionPauseStore.currentPauseState()) == nil else { return }
            await LavaEventNotificationPoster.post(
                category: .protectionResumed,
                requestIdentifier: LavaSecAppGroup.eventNotificationRequestIdentifierPrefix
                    + LavaNotificationCategory.protectionResumed.rawValue,
                title: "Lava",
                body: body,
                userInfo: [
                    LavaSecAppGroup.protectionNotificationRouteUserInfoKeyName:
                        LavaSecAppGroup.protectionNotificationGuardRouteValue
                ],
                defaults: defaults
            )
        }
    }

    func isTemporaryProtectionPauseActive(
        now: Date = Date(),
        synchronizesDefaults: Bool = true
    ) -> Bool {
        guard let pauseUntil = currentTemporaryProtectionPauseUntil(synchronizesDefaults: synchronizesDefaults) else {
            return false
        }

        // UX-2 (Codex #208): an over-cap pausedUntil on the DNS hot path is a stale cached
        // value from before a backward wall-clock step — the 1s refresh gate wedges because
        // `now - lastRefresh` stays negative (< the interval) until the clock catches up, so
        // the store is never re-read. FORCE a store refresh: storedPauseState() compare-and-
        // discards the over-cap keys, and the refresh's vanished-pause detection reconciles
        // protection to ON (clears the applied flag + republishes the Live Activity). Then this
        // query is not paused. Only hiding it here would (a) let the same value re-activate for
        // its final ~cap window once wall time catches up, and (b) leave the Dynamic Island on
        // paused while filtering is on. One-shot: the refresh caches nil, so subsequent queries
        // take the fast not-paused path.
        if pauseUntil.timeIntervalSince(now) > ProtectionPauseStore.maxPauseDuration {
            _ = refreshTemporaryProtectionPauseState(synchronizesDefaults: synchronizesDefaults, now: now)
            return false
        }

        return pauseUntil > now
    }

    private func currentTemporaryProtectionPauseUntil(synchronizesDefaults: Bool = true) -> Date? {
        // While the boot-deferred session begin is PENDING, any stored pause belongs to the
        // PREVIOUS (pre-reboot) session: the begin that would have cleared it — and begun the
        // fresh session that unbinds pausedSessionID — has not written yet, so the stale
        // pause's session pair still matches on disk. Honoring it once first unlock makes the
        // keys readable would forward DNS UNFILTERED for up to the pause's remainder
        // (DNSQueryDispatcher gives an active pause precedence over the snapshot) — a
        // fail-open on a freshly rebooted device (INV-DNS-1; Codex P2 round 4 on #377,
        // pinned: TunnelPreUnlockGuardSourceTests.testStalePauseIsMaskedWhileSessionBeginIsDeferred).
        // Masked as no-pause (fails toward filtering) until the flush's begin clears the
        // stale keys. A NEW pause command taken after unlock is NOT lost to this mask: its
        // own reload message flushes the pending begin and CARRIES the command across the
        // fresh session, re-issuing it for the remaining window (Codex P2 rounds 15 + 16
        // on #377 — an idle tunnel gets no other wake). Accepted residual: the carry is
        // best-effort, so a failed re-issue degrades to a one-command no-op — never a
        // fail-open.
        guard !hasPendingFreshProtectionVPNSessionBegin() else {
            return nil
        }
        let now = Date()
        if synchronizesDefaults {
            return refreshTemporaryProtectionPauseState(synchronizesDefaults: true, now: now)
        }

        let shouldRefresh = protectionPauseStateQueue.sync {
            let sinceLastRefresh = now.timeIntervalSince(lastProtectionPauseStateRefreshAt)
            // A NEGATIVE interval = the wall clock stepped BACKWARD since the last refresh. Force
            // a store read so storedPauseState() compare-and-discards a now-over-cap pausedUntil
            // EVEN WHEN THE CACHE IS nil (an intent-written pause the tunnel never learned via a
            // reload-protection-pause message) — otherwise the over-cap keys survive unread and
            // re-activate once the clock catches up to within the cap of that date, turning
            // filtering off for the final pause window (UX-2, Codex #208). One-shot: the refresh
            // sets lastProtectionPauseStateRefreshAt = now, so the next query sees no backward step.
            return sinceLastRefresh >= protectionPauseStateRefreshInterval || sinceLastRefresh < 0
        }
        if shouldRefresh {
            return refreshTemporaryProtectionPauseState(synchronizesDefaults: true, now: now)
        }

        return protectionPauseStateQueue.sync {
            cachedTemporaryProtectionPauseUntil
        }
    }

    func refreshTemporaryProtectionPauseState(
        synchronizesDefaults: Bool = true,
        now: Date = Date()
    ) -> Date? {
        // Read the store AND swap the cache under the SAME serialization point (Codex #208
        // post-merge): with the read outside this sync, two overlapping refreshes can interleave —
        // an older refresh reads a non-nil pausedUntil, a newer refresh caches nil + reconciles ON,
        // then the older refresh enters the sync and writes its STALE pause back into the cache, so
        // DNS treats protection as paused until the next refresh. Reading inside the sync means a
        // delayed refresh re-reads the CURRENT store when it finally acquires the queue, so a
        // vanished pause can never be re-cached.
        //
        // The swap also detects a pause that VANISHED — a cached pause the store no longer returns
        // because storedPauseState() compare-and-discarded an over-cap value (backward clock / corrupt
        // write) or another process cleared it. The transition (previous non-nil → now nil) is the
        // SINGLE-SHOT signal, so whichever refresh performs it reconciles the published state to ON.
        // Expired-but-in-window pauses are returned non-nil by the store, so they don't vanish here;
        // the resume timer still owns expiry.
        var pauseVanished = false
        var clampedCappedPause = false
        let pauseUntil: Date? = protectionPauseStateQueue.sync {
            let storedRead = readTemporaryProtectionPauseUntilFromDefaults(
                synchronizesDefaults: synchronizesDefaults
            )
            let previous = cachedTemporaryProtectionPauseUntil
            cachedTemporaryProtectionPauseUntil = storedRead.pauseUntil
            lastProtectionPauseStateRefreshAt = now
            pauseVanished = previous != nil && storedRead.pauseUntil == nil
            clampedCappedPause = storedRead.clampedCappedPause
            return storedRead.pauseUntil
        }
        // Reconcile ALSO when the store just CLAMPED an over-cap pause to nil, even if the cache
        // held no prior pause (previous == nil → no vanish transition). That is the case for a
        // pause written by the Live Activity intent that the tunnel never learned (the intent
        // publishes .paused via LavaProtectionCommandService but sends no reload message): the
        // store discard defuses the reactivation landmine, and this reconcile republishes ON so
        // ActivityKit doesn't stay paused while filtering is back on (Codex #208). Discarding the
        // keys makes it one-shot — the next read finds no keys and clamps nothing.
        if pauseVanished || clampedCappedPause {
            reconcileProtectionOnAfterVanishedTemporaryPause()
        }
        return pauseUntil
    }

    // Republish protection-ON after a pause vanished from the store (capped-discarded, or cleared
    // by another process) so the Dynamic Island doesn't stay on paused with a stale resume date
    // while filtering is back on (Codex #208). dnsStateQueue-confined for the applied flag; the
    // vanish transition in refreshTemporaryProtectionPauseState is the single-shot guard, so this
    // fires even for an intent-initiated pause the tunnel never marked applied (learned via the
    // refresh path, so lastApplied stays false while ActivityKit shows paused).
    private func reconcileProtectionOnAfterVanishedTemporaryPause() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.reconcileProtectionOnAfterVanishedTemporaryPause()
            }
            return
        }
        // Re-read the store on this dnsStateQueue hop: the reconcile was enqueued async, so a NEW
        // pause the user started in the meantime must not be clobbered by this now-stale
        // unconditional ON. If a current pause exists, leave it — its own .paused update stands,
        // and the normal apply path marks it applied (symmetric to the coordinator's .paused
        // re-verification, Codex #208).
        if (try? protectionPauseStore.currentPauseState()) != nil {
            return
        }
        lastAppliedTemporaryProtectionPauseIsActive = false
        updateLiveActivitiesAfterTemporaryProtectionPauseExpired()
    }

    private func cacheTemporaryProtectionPauseUntil(_ pauseUntil: Date?, refreshedAt: Date = Date()) {
        protectionPauseStateQueue.sync {
            cachedTemporaryProtectionPauseUntil = pauseUntil
            lastProtectionPauseStateRefreshAt = refreshedAt
        }
    }

    // synchronizesDefaults now only selects forced-refresh vs cached reads upstream;
    // cfprefsd already serves current app-group values cross-process, and flushing
    // here ran on the DNS hot path up to once per second. The store applies the
    // session binding (pauseSessionID == activeSessionID) and deliberately
    // returns expired pauses so the expiry timer can observe and clear them.
    private func readTemporaryProtectionPauseUntilFromDefaults(
        synchronizesDefaults: Bool
    ) -> (pauseUntil: Date?, clampedCappedPause: Bool) {
        guard let read = try? protectionPauseStore.storedPauseStateApplyingSanityCap() else {
            return (nil, false)
        }
        return (read.state?.pausedUntil, read.clampedCappedPause)
    }

    private func setPendingFreshProtectionVPNSessionReason(_ reason: String?) {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            pendingFreshProtectionVPNSessionReason = reason
            return
        }
        dnsStateQueue.sync { pendingFreshProtectionVPNSessionReason = reason }
    }

    private func takePendingFreshProtectionVPNSessionReason() -> String? {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            let reason = pendingFreshProtectionVPNSessionReason
            pendingFreshProtectionVPNSessionReason = nil
            return reason
        }
        return dnsStateQueue.sync {
            let reason = pendingFreshProtectionVPNSessionReason
            pendingFreshProtectionVPNSessionReason = nil
            return reason
        }
    }

    func hasPendingFreshProtectionVPNSessionBegin() -> Bool {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return pendingFreshProtectionVPNSessionReason != nil
        }
        return dnsStateQueue.sync { pendingFreshProtectionVPNSessionReason != nil }
    }

    // INV-PERSIST-1 canary: whether the app-group's CLASS-C protected content is readable
    // right now (first unlock happened). Probes the shared-defaults SUITE PLIST itself —
    // the very file the deferred suite writes protect — so the probe target IS the clobber
    // target and the absence semantics are exact: an absent plist means no suite content
    // exists to clobber (fresh install pre-onboarding; the begin's own pre-unlock create
    // fails harmlessly under try? and retries), while any configured install has one. The
    // probe must be a file that STAYS Class C: INV-PERSIST-2 re-classed the config to
    // Class-None precisely so a pre-unlock boot can read it, which disqualified it as an
    // unlock signal, and diagnostics.json can be legitimately absent long past install (a
    // user can disable counts + history before the tunnel ever persists diagnostics —
    // PR #378 review), which disqualified it too. cfprefsd keeps the suite plist at the
    // iOS default Class C, and class keys unlock atomically at first user authentication,
    // so its readability also signals for the diagnostics/ledger writers. Read as a plain
    // file probe (content readability), not through cfprefsd — a locked suite READ just
    // returns empty, which proves nothing; the plist path is the stable app-group
    // preferences layout (Library/Preferences/<group>.plist).
    // pinned: TunnelPreUnlockGuardSourceTests.testBootSuiteWritesAreDeferredUntilProtectedContentIsReadable
    func sharedProtectedContentIsReadable() -> Bool {
        Self.sharedProtectedContentIsReadableForObservabilityWriters()
    }

    // Static twin of the canary for the static observability writers (recordIncident /
    // sweepIncidentLedger), single-sourced so the two can never diverge on the probe. Same
    // semantics: probes the suite plist's CONTENT readability (metadata reads succeed
    // while locked; the ledger those writers guard shares the plist's Class C); an absent
    // plist counts as readable — no suite exists, so nothing protected to clobber.
    static func sharedProtectedContentIsReadableForObservabilityWriters() -> Bool {
        guard let suitePlistURL = LavaSecAppGroup.containerURL?
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent(LavaSecAppGroup.identifier + ".plist") else {
            return true
        }
        return !SharedStateFileReader.fileExistsButIsUnreadable(at: suitePlistURL)
    }

    // Flush the boot-deferred session begin once a readable config classification proved
    // the protected content readable. Also closes any dangling self-reconnect gap the
    // pre-unlock start skipped (its reads saw the locked suite as zeros and bailed without
    // writing). No pause-resume scheduling is needed here: the pre-unlock schedule read a
    // locked suite as "no pause" and armed nothing, and the begin below clears the stale
    // pre-reboot pause keys before any consumer re-reads them (the expiry poll only arms
    // when a pause was observed). `hasDecodableConfiguration` is the caller's
    // classification: true only for .loaded — it gates the recovery reload below, never
    // the suite/diagnostics duties.
    func flushDeferredFreshProtectionVPNSessionIfNeeded(hasDecodableConfiguration: Bool) {
        guard let reason = takePendingFreshProtectionVPNSessionReason() else {
            return
        }
        beginFreshProtectionVPNSession(reason: reason)
        Self.closeDanglingSelfReconnectGapIfNeeded()
        // RELOAD the diagnostics + depth stores from the now-readable files BEFORE anything
        // can persist: the boot loaded them as empty and serve-path markers dirtied that
        // emptiness (Codex P1 round 6 on #377). Ordering is airtight on the serialized
        // queue: the pending flag was taken above, this reload completes in the same
        // dnsStateQueue turn, and the diagnostics write closure (also on this queue, and
        // gated on the pending flag while it was set) can only run after the swap. The
        // uptime marker the boot stamped on the discarded empty store is re-marked against
        // the real one. GATED on the locked-boot flag: in the deferred-begin race (unlock
        // between startTunnel's begin canary and the boot loads — Codex P2 round 14) the
        // boot loaded these stores post-unlock, so they are REAL and dirtied by real serve
        // marks; reloading would discard those marks for nothing.
        if diagnosticsStoresReflectLockedBoot {
            loadDiagnosticsAndEventLogStores()
            if !diagnosticsStoresReflectLockedBoot {
                // The locked-boot window just ENDED — the reload above re-derived the
                // flag from a fresh canary probe and it flipped readable. This flush is
                // the ONLY place the transition may stamp: the loader's other caller
                // (loadInitialSharedState / startTunnel) runs off dnsStateQueue, where
                // a reused instance's stale flag would fire the stamp against the
                // queue-confined health persistence off-queue (INV-QUEUE-1) — and
                // resetHealth clobbers it there regardless (Codex review, #381). Unlock
                // is monotonic, so this fires exactly once per boot session; the stamp
                // itself is also idempotent. The boundary recorded is the LAST
                // OBSERVED-LOCKED instant, never the reload's own wall clock — the
                // reload runs one flush latency after the real unlock, and stamping
                // "now" would admit post-unlock decisions made in that gap as boot
                // evidence (Codex review, #381; the ?? Date() is defensively
                // unreachable: this transition requires the flag to have been true, and
                // every flag-set site stamps an observation). Force-persist: health
                // rides a 30 s debounce, and the lockedBoot* counters plus this stamp
                // are the QA release gate's only direct record of locked-window
                // filtering (incident plan Phase 4 follow-up, lavasec-infra
                // docs/engineering/reboot-first-unlock-qa-protocol.md "Path A") — an
                // early post-unlock jetsam must not lose them. One forced write per
                // boot session, never per query.
                // pinned: TunnelPreUnlockGuardSourceTests.testLockedBootWindowEndStampIsForcePersistedAtTheReadableReload
                health.markLockedBootWindowEnded(at: lastObservedLockedSharedContentAt ?? Date())
                markHealthUpdated()
                persistHealthIfNeeded(force: true)
            }
            markLocalProtectionUptimeStarted()
        }
        // Replace the fail-closed boot placeholder with an EXPLICIT forced reload rather
        // than relying on the Focus poll's generation watermark: a legacy config decodes
        // with configurationGeneration == 0, and the poll's `onDisk > lastObserved` gate
        // (0 > 0) would never fire for it — leaving fail-closed resident until an unrelated
        // config write (Codex P2 on #377). The pending-begin state makes this exactly
        // once-per-recovered-boot: a normal start defers nothing and never reaches here.
        // DEFERRED (never skipped) when a snapshot reload is already in flight: forcing from
        // here — this flush can run from refreshConfigurationIfNeeded(force:) INSIDE
        // loadSnapshotInBackground — would advance the reload generation and discard the
        // very snapshot that just recovered (Codex P2 round 3 on #377). But the in-flight
        // reload can also be the pre-unlock ABORT whose async clear has not yet run, and
        // that one adopts nothing — a plain skip would strand a generation-0 config on the
        // fail-closed boot placeholder (Codex P1 round 8). So the force is handed to
        // clearSnapshotReloadInFlight, which fires it after the in-flight reload fully
        // finishes: an aborting reload gets its recovery, and a productive one DISARMS the
        // handoff when it commits — the deferred force must never fire behind a successful
        // adoption, whose reset would drain live DNS queries (Codex P2 round 13).
        // GATED on the resident still being placeholder-class (identity nil): the
        // deferred-begin race boot (round 14) warm-resumed a REAL snapshot, and forcing a
        // reload behind it would reset the DNS runtime for a no-op — the same blip round 13
        // eliminated on the handoff path, here on the direct one. A fail-closed placeholder
        // (this recovery's actual target) always carries a nil identity.
        // ALSO gated on a DECODABLE config: from the .absentOrCorrupt flush there is
        // nothing real to load — the reload's fallback is currentAppConfiguration(), the
        // boot-time EMPTY placeholder, whose compile installs the permissive PASS-THROUGH
        // snapshot. That would actively downgrade block-all to allow-all on the strength
        // of a corrupt file (INV-DNS-1 fail-open; Codex P1 round 18 on #377). Stay
        // fail-closed instead: the app's reseed rewrite bumps the generation AND sends the
        // reload message, so recovery arrives through the normal channels once a decodable
        // config exists.
        if hasDecodableConfiguration, currentResidentSnapshotIdentity() == nil {
            let reloadAlreadyInFlight = snapshotReloadCoordinator.assumeIsolated { $0.isReloadInFlight }
            if reloadAlreadyInFlight {
                deferredRecoveryReloadPending = true
            } else {
                requestSnapshotReload(reason: "config-recovered-after-unlock", force: true)
            }
        }
    }

    func beginFreshProtectionVPNSession(reason: String) {
        // INV-PERSIST-1 (pinned: TunnelPreUnlockGuardSourceTests.testBootSuiteWritesAreDeferredUntilProtectedContentIsReadable):
        // writing into the shared suite while its backing plist is Data-Protection-locked (a
        // boot start before first unlock) risks cfprefsd re-materializing the plist with
        // ONLY these keys — dropping the language pin, notification prefs, pause/session
        // state, and customization (incident plan latent-2). Defer the begin until the
        // shared content is readable; the config-refresh success path flushes it. Suite
        // READS degrade safely meanwhile (a locked suite reads as no pause / no session).
        guard sharedProtectedContentIsReadable() else {
            // Fresh locked observation — every pre-unlock flush tick re-defers through
            // here, so this bounds the locked-boot evidence window on post-INV-PERSIST-2
            // boots (see lastObservedLockedSharedContentAt).
            lastObservedLockedSharedContentAt = Date()
            setPendingFreshProtectionVPNSessionReason(reason)
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "protection-session-begin-deferred", details: [
                "reason": reason
            ])
            return
        }
        let sessionID = (try? protectionSessionStore.beginFreshSession()) ?? ""
        try? protectionPauseStore.clearStoredPause()
        cacheTemporaryProtectionPauseUntil(nil)

        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "protection-session-begin", details: [
            "reason": reason,
            "sessionID": sessionID
        ])
        #endif
    }

    func endProtectionVPNSession(reason: String) {
        // Any boot-deferred begin dies with this lifecycle (readable or not): a post-stop
        // flush would otherwise begin a fresh session for a tunnel that is no longer
        // serving (Codex P2 round 2 on #377).
        setPendingFreshProtectionVPNSessionReason(nil)
        // INV-PERSIST-1: a stop/cleanup that runs before first unlock must not write the
        // locked suite either — same cfprefsd re-materialization hazard as the deferred
        // begin (pinned: TunnelPreUnlockGuardSourceTests.testStopCleanupSuiteWritesAreCanaryGated).
        // Skipping is safe: a locked suite already reads as no-session/no-pause, and the
        // NEXT start's (possibly deferred) begin performs these same clears once the
        // content is readable.
        guard sharedProtectedContentIsReadable() else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "protection-session-end-skipped-locked", details: [
                "reason": reason
            ])
            return
        }
        _ = try? protectionSessionStore.clearActiveSessionID()
        try? protectionPauseStore.clearStoredPause()
        cacheTemporaryProtectionPauseUntil(nil)

        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "protection-session-end", details: [
            "reason": reason
        ])
        #endif
    }

    var protectionPauseDefaults: UserDefaults {
        LavaSecAppGroup.sharedDefaults
    }
}
