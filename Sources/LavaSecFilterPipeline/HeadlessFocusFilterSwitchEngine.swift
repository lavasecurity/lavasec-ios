import Foundation
import LavaSecKit

/// Outcome of a headless Focus-driven filter switch. Relocated from `AppViewModel` (LAV-100 Phase 4)
/// so the App Intents extension can report it without the app target.
public enum HeadlessFocusSwitchOutcome: String, Equatable, Sendable {
    /// The requested filter was committed and published.
    case committed
    /// The request was recorded for later foreground reconciliation.
    case deferred
    /// The requested filter was already active.
    case alreadyActive
    /// The request was refused by a fail-closed guard.
    case disallowed
}

/// Lock-protected mutable cell shared only by the publish callback and its awaiting caller.
private final class FocusSwitchDiagnosticEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var event: FocusSwitchDiagnosticEvent?

    func store(_ event: FocusSwitchDiagnosticEvent) {
        lock.lock()
        self.event = event
        lock.unlock()
    }

    func load() -> FocusSwitchDiagnosticEvent? {
        lock.lock()
        defer { lock.unlock() }
        return event
    }
}

/// Records the pair actually written at the publication boundary, including on a later flip error.
/// The awaiting caller uses its generation to fence a rollback against concurrent newer writers.
private final class FocusSwitchCommittedStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: (configuration: AppConfiguration, library: FilterLibrary)?

    func store(_ value: (configuration: AppConfiguration, library: FilterLibrary)) {
        lock.lock()
        state = value
        lock.unlock()
    }

    func load() -> (configuration: AppConfiguration, library: FilterLibrary)? {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

/// Immutable callback context. `UserDefaults` is documented thread-safe but lacks a Sendable
/// conformance; every access is additionally ordered by the dedicated cross-process lock.
private final class FocusSwitchDiagnosticEventCapture: @unchecked Sendable {
    private let defaults: UserDefaults
    private let orderingLockURL: URL
    private let now: @Sendable () -> Date

    init(
        now: @escaping @Sendable () -> Date,
        defaults: UserDefaults,
        orderingLockURL: URL
    ) {
        self.now = now
        self.defaults = defaults
        self.orderingLockURL = orderingLockURL
    }

    func capture() -> FocusSwitchDiagnosticEvent? {
        FocusSwitchDiagnostics.captureEvent(
            in: defaults, orderingLockURL: orderingLockURL, now: now)
    }
}

/// The pure, extension-safe engine for a Focus-driven warm filter switch.
///
/// This is the relocation of `AppViewModel.performHeadlessFocusFilterSwitch` out of the app target so a
/// `SetFocusFilterIntent` running in the App Intents EXTENSION (the only place an intent runs while the
/// app is closed — WWDC22 §10121) can drive the same switch. It operates on `(configuration, library)`
/// value copies loaded from the App Group container — there is no `AppViewModel`, no `@Published` state,
/// no NetworkExtension. The throwaway headless model's in-memory assignments were already
/// write-only-then-discarded, so plain value locals are behavior-identical; a resident foreground app
/// re-syncs its own in-memory state via the durable pending-switch marker.
///
/// Load-bearing semantics: fail-closed gate (NOT auth-to-edit; the Plus paywall was dropped, so all tiers
/// may switch), the reseed/config-fallback/frozen guards, the durable marker recorded FIRST, warm-only
/// commit (the headless path never cold-compiles), the in-lock catalog-basis veto, and the marker LEFT for
/// the foreground reconcile to clear. The commit is STATE-AGNOSTIC — it no longer defers on a coarse
/// foreground-active flag; the Phase-4 cross-process write lock + generation fence make a concurrent
/// foreground write safe (the loser aborts), so a closed-app switch lands promptly regardless of app state.
/// The commit funnels through the same single writer (`SharedFilterStatePersistence`) + the same artifact
/// publish (`FilterSnapshotPreparationService.persistArtifacts`) the foreground uses, so the two contexts
/// can never drift on write-ordering or generation semantics.
public enum HeadlessFocusFilterSwitchEngine {
    /// Everything the engine needs, supplied by the caller (app or extension) so the App Group
    /// identifier + NetworkExtension stay out of LavaSecCore. Not `Sendable`: it is used entirely on the
    /// calling task; only individual `Sendable` values cross into detached tasks / the publish actor.
    public struct Environment {
        internal let containerURL: URL
        internal let configurationURL: URL
        internal let filterLibraryURL: URL
        internal let catalogCacheURL: URL
        internal let backgroundWarmIndexURL: URL
        internal let publishLockURL: URL
        internal let focusSwitchLockURL: URL
        /// Cross-process CAS lock for the shared (config, library) pair write (LAV-100 Phase 4 P4c).
        internal let configurationWriteLockURL: URL
        /// Cross-process lock for the pending-switch MARKER record/clear (LAV-100 Phase 4).
        internal let pendingMarkerLockURL: URL
        /// Terminal cross-process order for diagnostic event capture versus generation clear.
        internal let focusDiagnosticOrderingLockURL: URL
        internal let snapshotFilename: String
        internal let compactSnapshotFilename: String
        internal let defaults: UserDefaults
        internal let catalogSyncFreshnessInterval: TimeInterval
        /// Clock, injectable for tests.
        internal let now: @Sendable () -> Date
        /// Clock for Release-visible diagnostic event timestamps. Kept separate from `now` because
        /// replay uses `now` for the original pending-marker identity.
        internal let diagnosticNow: @Sendable () -> Date
        /// Test seam invoked after a warm lookup or final catalog validation has captured its diagnostic
        /// event, but before the enclosing async caller resumes.
        internal let onHeadlessValidationCompleted: @Sendable () -> Void
        /// Test seam invoked after a successful publish but before the async commit call returns to
        /// its caller.
        internal let onHeadlessCommitCompleted: @Sendable () -> Void
        /// Post a Darwin notification by name. Production: `DarwinProtectionSignalNotifier().postNotification`.
        /// Used for both the tunnel-reload signal (after a commit) and the foreground reconcile nudge.
        internal let postSignal: @Sendable (String) -> Void
        /// Privacy-safe device-debug logging (no-op in Release).
        internal let log: @Sendable (_ event: String, _ details: [String: String]) -> Void
        /// REPLAY-ONLY marker identity (lavasec-ios public review of the PR #410 promotion), default
        /// nil. When set, BOTH marker records in `runLocked` become compare-and-record
        /// (`PendingFilterSwitchStore.recordIfMatches`, expecting this value): a replay must never
        /// overwrite a marker that no longer equals the request it is replaying — a NEWER intent
        /// recorded while the replay was flock-blocked would otherwise be erased by a re-stamped old
        /// one (lost update). A mismatch on the MAIN record path aborts the replay fail-closed
        /// (`disallowed-replay-marker-changed`); the newer marker survives for the next drain pass.
        /// Fresh intents leave this nil — newest-wins overwrite is their correct semantics.
        internal let replayExpectedMarker: PendingFilterSwitchRequest?
        /// REPLAY-ONLY in-lock supersession veto (Codex PR #410 P1), default nil. Evaluated INSIDE the
        /// held publish lock immediately before the pointer flip, AFTER the generation fence: returning
        /// true aborts the commit with a clean rollback to the pre-switch selection. Only the background
        /// drain's replay passes it (re-checking `PendingFilterSwitchStore.isSupersededByForegroundSwitch`
        /// at the last possible moment, closing the pre-check→commit window in which a manual switch can
        /// COMPLETE); fresh intents must leave it nil — a new Focus/Shortcut edge legitimately switches
        /// away from a just-manually-switched filter (newest wins by timestamps).
        internal let replaySupersededVeto: (@Sendable () -> Bool)?
        /// Post a user-facing notification for a switch OUTCOME — `committed == true` ⇒ "Switched to
        /// <name>"; `committed == false` ⇒ "Couldn't switch to <name>" (a refused switch, e.g. auth-to-edit).
        /// The closure (provided by `FocusSwitchEnvironment`) gates on the caller's category toggle +
        /// closed/backgrounded-only + permission, then posts; the Shortcuts/automation caller's closure
        /// additionally DROPS `committed == false` (its thrown error is that caller's failure feedback —
        /// see `FocusSwitchEnvironment.OutcomeFeedback`). Default no-op (tests / the in-app caller, which
        /// has nothing to notify — the user sees the switch in-UI). Takes the resolved emoji + name display label (the
        /// engine has the library) so the closure needs no library access. Stored names and diagnostics
        /// remain unchanged; identity artwork belongs only to user-facing feedback.
        internal let notifySwitchOutcome: @Sendable (_ committed: Bool, _ filterName: String) async -> Void

        /// Creates an environment from the shared files, locks, defaults, and callback seams.
        /// - Parameter focusDiagnosticOrderingLockURL: Dedicated terminal lock shared by diagnostic
        ///   event capture and generation-advancing clears.
        public init(
            containerURL: URL,
            configurationURL: URL,
            filterLibraryURL: URL,
            catalogCacheURL: URL,
            backgroundWarmIndexURL: URL,
            publishLockURL: URL,
            focusSwitchLockURL: URL,
            configurationWriteLockURL: URL,
            pendingMarkerLockURL: URL,
            focusDiagnosticOrderingLockURL: URL,
            snapshotFilename: String,
            compactSnapshotFilename: String,
            defaults: UserDefaults,
            catalogSyncFreshnessInterval: TimeInterval,
            now: @escaping @Sendable () -> Date = { Date() },
            diagnosticNow: @escaping @Sendable () -> Date = { Date() },
            onHeadlessValidationCompleted: @escaping @Sendable () -> Void = {},
            onHeadlessCommitCompleted: @escaping @Sendable () -> Void = {},
            postSignal: @escaping @Sendable (String) -> Void = { DarwinProtectionSignalNotifier().postNotification(named: $0) },
            log: @escaping @Sendable (_ event: String, _ details: [String: String]) -> Void = { _, _ in },
            notifySwitchOutcome: @escaping @Sendable (_ committed: Bool, _ filterName: String) async -> Void = { _, _ in },
            replaySupersededVeto: (@Sendable () -> Bool)? = nil,
            replayExpectedMarker: PendingFilterSwitchRequest? = nil
        ) {
            self.containerURL = containerURL
            self.configurationURL = configurationURL
            self.filterLibraryURL = filterLibraryURL
            self.catalogCacheURL = catalogCacheURL
            self.backgroundWarmIndexURL = backgroundWarmIndexURL
            self.publishLockURL = publishLockURL
            self.focusSwitchLockURL = focusSwitchLockURL
            self.configurationWriteLockURL = configurationWriteLockURL
            self.pendingMarkerLockURL = pendingMarkerLockURL
            self.focusDiagnosticOrderingLockURL = focusDiagnosticOrderingLockURL
            self.snapshotFilename = snapshotFilename
            self.compactSnapshotFilename = compactSnapshotFilename
            self.defaults = defaults
            self.catalogSyncFreshnessInterval = catalogSyncFreshnessInterval
            self.now = now
            self.diagnosticNow = diagnosticNow
            self.onHeadlessValidationCompleted = onHeadlessValidationCompleted
            self.onHeadlessCommitCompleted = onHeadlessCommitCompleted
            self.postSignal = postSignal
            self.log = log
            self.notifySwitchOutcome = notifySwitchOutcome
            self.replaySupersededVeto = replaySupersededVeto
            self.replayExpectedMarker = replayExpectedMarker
        }
    }

    /// The single marker-record funnel for BOTH `runLocked` record sites: an unconditional
    /// newest-wins `record` for fresh intents, a compare-and-record (`recordIfMatches`, expecting the
    /// replayed request) when `env.replayExpectedMarker` is set — so a replay can never erase a newer
    /// intent's marker. See `Environment.replayExpectedMarker`.
    @discardableResult
    private static func recordMarker(_ request: PendingFilterSwitchRequest, env: Environment) -> Bool {
        if let expected = env.replayExpectedMarker {
            return PendingFilterSwitchStore.recordIfMatches(
                request, expecting: expected, in: env.defaults, lockURL: env.pendingMarkerLockURL
            )
        }
        return PendingFilterSwitchStore.record(request, in: env.defaults, lockURL: env.pendingMarkerLockURL)
    }

    /// Thrown by the in-lock `commitBeforeFlip` to VETO the pointer flip when a concurrent background
    /// catalog refresh moved the cached catalog past the warm artifact's basis between the off-lock
    /// revalidation and the flip. Distinct type so the commit's catch treats it as a CLEAN DEFER (the
    /// foreground reconcile cold-compiles against the new catalog), not a commit wedge (Codex round-16).
    private struct CatalogMovedError: Error {}

    /// A newer manual switch vetoed a replay before it could write any state (PR #410).
    private struct ReplaySupersededError: Error {}

    /// Another writer advanced the loaded configuration generation before this commit.
    private struct SupersededError: Error {}

    /// No side state was committed. Preserve the boundary's reason for local diagnostics.
    private enum PublicationDeferredError: Error {
        case incomplete, cancelled, contended, superseded

        var diagnosticReason: String {
            switch self {
            case .incomplete: "deferred-publication-incomplete"
            case .cancelled: "deferred-publication-cancelled"
            case .contended: "deferred-publication-contended"
            case .superseded: "deferred-publication-superseded"
            }
        }
    }

    /// The engine's decision: the public outcome plus the SPECIFIC branch reason (e.g.
    /// "deferred-no-warm-artifact", "committed", "disallowed-auth-to-edit"). The reason is recorded into the
    /// Release-visible `FocusSwitchDiagnostics` so a closed-app switch is diagnosable without the QA log.
    private struct SwitchDecision {
        let outcome: HeadlessFocusSwitchOutcome
        let reason: String
        /// Captured when the engine decides, before any outcome notification or consent-gated write.
        let diagnosticEvent: FocusSwitchDiagnosticEvent?
        init(
            _ outcome: HeadlessFocusSwitchOutcome,
            _ reason: String,
            diagnosticEvent: FocusSwitchDiagnosticEvent?
        ) {
            self.outcome = outcome
            self.reason = reason
            self.diagnosticEvent = diagnosticEvent
        }
    }

    private static func makeDecision(
        _ outcome: HeadlessFocusSwitchOutcome, _ reason: String, env: Environment
    ) -> SwitchDecision {
        SwitchDecision(
            outcome,
            reason,
            diagnosticEvent: FocusSwitchDiagnostics.captureEvent(
                in: env.defaults,
                orderingLockURL: env.focusDiagnosticOrderingLockURL,
                now: env.diagnosticNow))
    }

    private static func makeDecision(
        _ outcome: HeadlessFocusSwitchOutcome,
        _ reason: String,
        diagnosticEvent: FocusSwitchDiagnosticEvent?
    ) -> SwitchDecision {
        SwitchDecision(outcome, reason, diagnosticEvent: diagnosticEvent)
    }

    /// Serialized headless Focus-switch entry. Concurrent invocations (two intents firing) are serialized
    /// by a dedicated app-group flock; the pending-switch marker + the publish lock already make any
    /// interleave safe, so the lock degrades OPEN if unavailable.
    @discardableResult
    public static func performSwitch(toFilterID id: String, env: Environment) async -> HeadlessFocusSwitchOutcome {
        env.log("focus-switch-begin", ["filterID": id])
        let decision = await withCrossProcessLock(at: env.focusSwitchLockURL) { () async -> SwitchDecision in
            let decision = await runLocked(toFilterID: id, env: env)
            // Record the diagnostic INSIDE the focus-switch lock so the LAST engine decision is also the last
            // diagnostic write: two concurrent intents serialize on the flock, so whichever runs last (and is
            // therefore authoritative on disk) is also the last to record. A trailing UNLOCKED write could
            // otherwise be descheduled and let an earlier-decided outcome overwrite the authoritative one
            // (panel P3). Always-on (NOT QA-gated, so it survives in Release): a privacy-safe record of this
            // attempt's outcome AND the specific branch reason, surfaced in the redacted bug report so the
            // closed-app path is diagnosable on internal TestFlight without a device or the QA device log.
            //
            // GATED ON STANDING CONSENT. The user's "keep local records" choice must stop the WRITE,
            // not just be followed by a clear — otherwise turning Network Activity off erases this
            // slot and the very next Focus edge writes it straight back (MECE panel, PR #625). The
            // 🔴 THE CONSENT CHECK AND THE WRITE ARE ONE CRITICAL SECTION, under the SAME
            // cross-process lock the settings path uses to persist the toggle. Read and write used
            // to be separate: the settings process could persist `keepNetworkActivity == false`
            // and clear the slots in between, and this write then put a record back that the user
            // had just withdrawn consent for. An earlier revision of this comment called that an
            // accepted residual — it is not, because the lock to close it was already in hand
            // (Codex, PR #625).
            //
            // 🔴 THE CONFIGURATION IS DECODED INSIDE THE RESOLVER, NOT VIA `loadState`. `flock`
            // is per open-file-description, so a helper that opens this same lock file would block
            // this process against itself — which is why the resolver decodes rather than
            // delegating. (This comment said "inline" while the decode lived here; it moved into
            // `withResolvedConsent` and the comment did not follow — Kilo, PR #626.)
            //
            // 🔴 AND IT FAILS CLOSED. An unreadable or undecodable configuration must read as
            // consent WITHHELD: a default `AppConfiguration()` carries `keepNetworkActivity ==
            // true`, so trusting it turns "we could not tell" into "consent granted", the one
            // direction a consent gate must never fail. This file already refuses to COMMIT a
            // switch on that signal; a diagnostic write deserves no weaker rule.
            // pinned: HeadlessFocusFilterSwitchEngineTests.testAnUnreadableConfigurationWritesNoDiagnostic
            // A deferred intent must not wait behind the same configuration writer just to
            // record its outcome. Under contention omit this optional record, never the marker.
            _ = FocusSwitchDiagnostics.tryWithResolvedConsent(
                configurationURL: env.configurationURL,
                lockURL: env.configurationWriteLockURL
            ) { consented in
                if let diagnosticEvent = decision.diagnosticEvent {
                    FocusSwitchDiagnostics.record(
                        FocusSwitchDiagnosticRecord(
                            outcome: decision.outcome.rawValue,
                            targetFilterID: id,
                            at: diagnosticEvent.at,
                            reason: decision.reason,
                            clearGeneration: diagnosticEvent.clearGeneration),
                        keepingLocalRecords: consented,
                        in: env.defaults
                    )
                }
            }
            return decision
        }
        env.log("focus-switch-finished", ["filterID": id, "outcome": decision.outcome.rawValue, "reason": decision.reason])
        return decision.outcome
    }

    // NOTE (panel P1, LAV-100 Phase 4 round 5): there is deliberately NO "cancel on Focus-off" entry point.
    // `SetFocusFilterIntent.perform()` runs with a nil filter on deactivation but carries NO Focus identity,
    // so the off-edge cannot tell WHICH Focus turned off. A single shared marker slot holds only the NEWEST
    // Focus intent, so blindly clearing it on any Focus-off could drop a DIFFERENT, still-active Focus's
    // just-recorded switch (a lost update). A filter is a sticky choice (another Focus or a manual tap is what
    // changes it next), and the foreground reconcile already drops genuinely-stale markers via its
    // lastForegroundSwitch supersession + already-active/target-gone guards; a deferred switch re-applying is
    // the tolerated, self-healing direction. So the intent's nil edge is a pure no-op.

    // MARK: - Core

    private static func runLocked(toFilterID id: String, env: Environment) async -> SwitchDecision {
        let defaults = env.defaults
        let now = env.now()

        // Load (configuration, library, didReseed) from the App Group container — the engine's own
        // working copies (no AppViewModel). A missing/corrupt/migration-needed library reseeds defaults
        // and reports didReseed; the gate below refuses in that case.
        let loaded = loadState(env: env)
        var configuration = loaded.configuration
        let library0 = loaded.library

        // Security boundary, fail-closed: Focus auto-switch is available to ALL tiers (the Plus paywall was
        // dropped — founder 2026-06-29), but it is OFF whenever filter editing requires authentication (an
        // unattended switch would otherwise bypass that gate). A gated-out request is NOT recorded — it must
        // not happen now or on a later reconcile.
        guard !SecurityProtectedSurfaceStorage.isProtected(.filterEditing, defaults: defaults,
            projectionURL: SecurityProtectedSurfaceStorage.projectionURL(containerURL: env.containerURL)) else {
            // The switch is refused while filter editing is auth-locked — tell the user the auto-switch
            // they expected did NOT happen (only when we can name the target; an unknown id is an edge we
            // stay silent on). The closure gates on the toggle + closed/backgrounded + permission; the
            // Shortcuts/automation caller's closure drops this refusal (its thrown error is that caller's
            // failure feedback — see FocusSwitchEnvironment.OutcomeFeedback).
            let decision = makeDecision(.disallowed, "disallowed-auth-to-edit", env: env)
            if let target = library0.filter(id: id) {
                await env.notifySwitchOutcome(false,
                    FilterIdentityPolicy.displayName(name: target.name, emoji: target.emoji))
            }
            return decision
        }

        // A reseeded/migrated load mirrored Balanced into `configuration` WITHOUT persisting (the
        // foreground migration hasn't landed), OR the device-global config file failed to load (a default
        // AppConfiguration would clobber the user's real settings). Committing here — or recording a marker
        // for a target id derived from the reseeded library — would let default rules/settings be written
        // over the user's real state at a winning generation. Refuse so the foreground applies the real
        // switch after its migration commits; a later Focus edge re-fires against the migrated library.
        guard !loaded.didReseed else {
            return makeDecision(.disallowed, "disallowed-config-fallback-or-reseed", env: env)
        }

        var library = library0

        // Target must exist + be switchable (not over the tier's filter cap).
        guard library.filter(id: id) != nil,
              !library.isFrozen(filterID: id, maxFilters: configuration.limits.maxFilters) else {
            return makeDecision(.disallowed, "disallowed-target-unavailable", env: env)
        }

        // Already-active: the newest Focus intent's target is what's already on disk. RECORD it anyway
        // (overwriting any OLDER pending request to a different filter) so the foreground reconcile can't
        // switch AWAY from the now-desired filter, then nudge the foreground. Best-effort record (the
        // desired filter is already active, so a missing self-heal marker can't produce a wrong state).
        // Funneled through recordMarker: a REPLAY's best-effort record is compare-and-record, so it
        // silently yields to a newer intent's marker instead of erasing it.
        guard id != library.activeFilterID else {
            let decision = makeDecision(.alreadyActive, "already-active", env: env)
            recordMarker(PendingFilterSwitchRequest(targetFilterID: id, requestedAt: now), env: env)
            env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
            return decision
        }

        // Record the durable marker FIRST — the correctness guarantee for everything below. If the write
        // fails (theoretically impossible for this Codable), FAIL CLOSED. For a REPLAY the funnel is
        // compare-and-record: a false return here also means the marker no longer equals the replayed
        // request — a NEWER intent won the slot while this replay was flock-blocked — so the replay
        // aborts fail-closed and the newer marker survives for the next drain pass (distinct reason,
        // Release-diagnosable).
        let request = PendingFilterSwitchRequest(targetFilterID: id, requestedAt: now)
        guard recordMarker(request, env: env) else {
            let decision = makeDecision(
                .disallowed,
                env.replayExpectedMarker != nil ? "disallowed-replay-marker-changed" : "disallowed-record-failed",
                env: env
            )
            env.log("record-failed-fail-closed", ["filterID": id])
            return decision
        }

        // STATE-AGNOSTIC commit (founder 2026-06-29): the engine no longer defers on a coarse
        // "app foreground-active" flag — that 5-minute window was a Phase-3 coordination from before the
        // cross-process CAS existed and produced a dead zone where a closed-app switch only applied on next
        // foreground. The Phase-4 cross-process write lock + generation fence (SharedFilterStatePersistence,
        // taken by BOTH the foreground publishers AND this commit) now make a concurrent foreground write
        // safe: the loser aborts cleanly rather than clobbering. So we always attempt the warm commit
        // regardless of app state; the marker + foreground reconcile + lastForegroundSwitch settle
        // manual-vs-Focus precedence to the time-correct (newer-wins) result.

        // Plan the transition up front so the warm artifact is validated against the TARGET's mirrored
        // configuration (the config its token was compiled against), NOT the current active config.
        guard let target = library.filter(id: id),
              let plan = FilterSwitchPlan.make(toFilterID: id, configuration: configuration, library: library) else {
            let decision = makeDecision(.deferred, "deferred-plan-unavailable", env: env)
            env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
            return decision
        }

        // Warm-only immediate commit. No valid warm artifact ⇒ defer (the foreground cold-compiles on
        // next activation; the headless path never cold-compiles in an App Intent's short window).
        let warmIndex = loadWarmIndex(env: env)
        let diagnosticCapture = FocusSwitchDiagnosticEventCapture(
            now: env.diagnosticNow,
            defaults: env.defaults,
            orderingLockURL: env.focusDiagnosticOrderingLockURL)
        let validationCompleted = env.onHeadlessValidationCompleted
        let warmLookupEvent = FocusSwitchDiagnosticEventBox()
        guard let reusable = await WarmFilterSnapshotLoader.reusableSnapshotForSwitch(
            target: target,
            configuration: plan.configuration,
            containerURL: env.containerURL,
            cacheURL: env.catalogCacheURL,
            freshnessMaxAge: env.catalogSyncFreshnessInterval,
            backgroundWarmIndex: warmIndex,
            onCompleted: {
                if let event = diagnosticCapture.capture() {
                    warmLookupEvent.store(event)
                }
                validationCompleted()
            }
        ) else {
            let decision = makeDecision(
                .deferred,
                "deferred-no-warm-artifact",
                diagnosticEvent: warmLookupEvent.load() ?? diagnosticCapture.capture())
            env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
            return decision
        }

        // Final catalog re-validation before the flip: a BACKGROUND catalog refresh could have committed
        // a new latest.json since the warm load. On a move, DEFER (the foreground cold-compiles against the
        // new catalog).
        let catalogValidationEvent = FocusSwitchDiagnosticEventBox()
        let catalogStillReusable = await WarmFilterSnapshotLoader.stillReusableAgainstCachedCatalog(
            reusable.preparedSnapshot,
            configuration: plan.configuration,
            cacheURL: env.catalogCacheURL,
            freshnessMaxAge: env.catalogSyncFreshnessInterval,
            onCompleted: {
                if let event = diagnosticCapture.capture() {
                    catalogValidationEvent.store(event)
                }
                validationCompleted()
            }
        )
        guard catalogStillReusable else {
            let decision = makeDecision(
                .deferred,
                "deferred-catalog-moved",
                diagnosticEvent: catalogValidationEvent.load() ?? diagnosticCapture.capture())
            env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
            return decision
        }

        // Snapshot the pre-switch state so a partial commit can be rolled back to a CONSISTENT on-disk
        // selection (mirrors the foreground switch's failure rollback).
        let previousConfiguration = configuration
        let previousLibrary = library
        let commitAttemptEvent = diagnosticCapture.capture()
        do {
            // Stage the rules first, then commit the pair and pointer in one synchronous locked
            // section. No selection change is visible while staging or waiting for the publish actor.
            // Take both halves from the same plan so their filter-scoped fields match.
            configuration = plan.configuration
            library = plan.library

            // In-lock catalog-basis veto (Codex round-16): the off-lock revalidation can pass against the
            // OLD latest.json and then a background catalog refresh can win the publish lock — committing a
            // newer catalog + flipping its pointer — before THIS path reaches the flip. Re-run the SAME
            // basis check INSIDE the held publish lock, immediately before the flip; throwing aborts before
            // any state change. Capture the Sendable inputs as locals — the closure runs off the main actor.
            let basisCacheURL = env.catalogCacheURL
            let basisMaxAge = env.catalogSyncFreshnessInterval
            let basisSnapshot = reusable.preparedSnapshot
            let basisConfiguration = plan.configuration
            let replayVeto = env.replaySupersededVeto
            let committedEvent = try await commit(
                preparedSnapshot: reusable.preparedSnapshot,
                configuration: &configuration,
                library: &library,
                warmIndex: warmIndex,
                env: env,
                commitBeforeFlip: { @Sendable in
                    // REPLAY-ONLY supersession veto (Codex PR #410 P1), after the generation fence:
                    // a manual switch that COMPLETED between a replay's off-lock pre-check and this
                    // flip left its stamp visible by now — abort before writing so the drain never
                    // commits an old automation over the user's just-persisted manual selection.
                    // (A manual switch completing AFTER our config load is caught by the generation
                    // fence instead.) nil for fresh intents — see Environment.replaySupersededVeto.
                    if replayVeto?() == true {
                        throw ReplaySupersededError()
                    }
                    guard BlocklistCatalogSynchronizer.hasFreshCachedCatalog(in: basisCacheURL, maxAge: basisMaxAge),
                          let cachedCatalog = try? BlocklistCatalogSynchronizer(cacheDirectoryURL: basisCacheURL).loadCachedCatalogMetadata(),
                          basisSnapshot.canReuseForProtectionStartup(configuration: basisConfiguration, cachedCatalog: cachedCatalog)
                    else {
                        throw CatalogMovedError()
                    }
                }
            )
            // The extension can't push to the always-on tunnel (sendProviderMessage is app-only, and a
            // tunnel-side Darwin observer is unreliable when idle — see P4d), so the tunnel POLLS the
            // configuration generation and adopts this committed switch on its next tick. LEAVE the marker
            // for the foreground reconcile to clear so a still-resident foreground re-syncs its stale
            // in-memory state to the committed target.
            //
            // NUDGE the foreground even on a COMMITTED switch (Codex P1, state-agnostic switch): now that the
            // commit can land WHILE the app is foreground-active, a resident AppViewModel would otherwise stay
            // on the old filter (in-memory + UI) until its next scene transition — and any foreground edit
            // before that could persist its stale library/config over this committed switch. The app-direction
            // Darwin signal wakes its reconcile promptly to adopt the committed target and clear the marker.
            // (Under Phase 3 commits were inactive-only, so the next foreground activation reconciled; the
            // state-agnostic path needs the explicit wake.)
            let decision = makeDecision(.committed, "committed", diagnosticEvent: committedEvent)
            env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
            // Tell the user the headless switch landed — "Switched to <name>" — but only when the app is
            // closed/backgrounded (the closure's gate); a foreground app shows the change in-UI, so a banner
            // would be redundant. This is the mitigation for iOS's suspended-app extension-launch latency: a
            // late background switch still surfaces. Gated inside on permission + the shared
            // filterChanged toggle (both the Focus extension and the Shortcuts/automation intent post
            // committed switches under that one category — founder 2026-07-12).
            await env.notifySwitchOutcome(true,
                FilterIdentityPolicy.displayName(name: target.name, emoji: target.emoji))
            return decision
        } catch {
            let diagnosticFailure = error as? FocusSwitchDiagnosticFailure
            let commitError = diagnosticFailure?.underlying ?? error
            let failureEvent = diagnosticFailure?.event ?? commitAttemptEvent
            if commitError is ReplaySupersededError || commitError is CatalogMovedError ||
                commitError is PublicationDeferredError || commitError is CancellationError {
                // Every veto/abort happens before the pair write. Keep the previous selection
                // byte-for-byte, and leave the durable marker for a later warm/foreground retry.
                let reason: String
                switch commitError {
                case is ReplaySupersededError: reason = "deferred-replay-superseded-inlock"
                case is CatalogMovedError: reason = "deferred-catalog-moved-inlock"
                case let deferred as PublicationDeferredError: reason = deferred.diagnosticReason
                default: reason = PublicationDeferredError.cancelled.diagnosticReason
                }
                let decision = makeDecision(.deferred, reason, diagnosticEvent: failureEvent)
                env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
                return decision
            }
            if commitError is SupersededError ||
                commitError is SharedFilterStatePersistence.StaleBaseGenerationError {
                // CLEAN DEFER without rollback: the newer on-disk writer is authoritative.
                let decision = makeDecision(
                    .deferred, "deferred-superseded", diagnosticEvent: failureEvent)
                env.log("headless-commit-deferred-superseded", ["filterID": id])
                env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
                return decision
            }
            // The config+library MAY have been written BEFORE the artifact pointer flip, so a throw can leave
            // disk SELECTING the target while the pointer still names the previous artifact. Roll the on-disk
            // config+library back so the selection is consistent with the un-flipped pointer; the kept marker
            // drives the foreground reconcile retry. FENCE the rollback against our own write:
            // `configuration.configurationGeneration` holds the loaded base if the write itself threw (nothing
            // landed), or the generation we wrote if the flip threw — either way a foreground writer that
            // advanced past it wins and the rollback is skipped rather than clobbering the user's update.
            let decision = makeDecision(
                .deferred, "deferred-commit-failed", diagnosticEvent: failureEvent)
            let fencedGeneration = configuration.configurationGeneration
            configuration = previousConfiguration
            library = previousLibrary
            do {
                try writeConfigurationOnly(configuration: &configuration, library: &library, expectedBaseGeneration: fencedGeneration, env: env)
                env.log("headless-commit-failed-rolled-back", ["filterID": id, "error": "\(commitError)"])
            } catch is SharedFilterStatePersistence.StaleBaseGenerationError {
                // A newer writer advanced past our write between the failure and the rollback — leave the newer
                // on-disk state (rolling back would clobber it). Same posture as the superseded clean-defer arm.
                env.log("headless-commit-rollback-skipped-superseded", ["filterID": id])
            } catch let rollbackError {
                env.log("headless-commit-rollback-failed", [
                    "filterID": id,
                    "commitError": "\(commitError)",
                    "rollbackError": "\(rollbackError)"
                ])
            }
            return decision
        }
    }

    // MARK: - Commit

    /// Stages rules before advancing the selection. The paired write and pointer flip then execute
    /// synchronously under configuration → publication locks, without an actor suspension between them.
    /// Issue #719: an App Intent must not advance selection and then wait behind another publisher.
    /// pinned: HeadlessFocusFilterSwitchEngineTests.testContendedPublicationDefersWithoutAdvancingTheSavedSelection
    private static func commit(
        preparedSnapshot: PreparedFilterSnapshot,
        configuration: inout AppConfiguration,
        library: inout FilterLibrary,
        warmIndex: BackgroundWarmIndex,
        env: Environment,
        commitBeforeFlip: @escaping @Sendable () throws -> Void
    ) async throws -> FocusSwitchDiagnosticEvent? {
        let diagnosticCapture = FocusSwitchDiagnosticEventCapture(
            now: env.diagnosticNow,
            defaults: env.defaults,
            orderingLockURL: env.focusDiagnosticOrderingLockURL)
        let committedState = FocusSwitchCommittedStateBox()
        // A pointer write can fail after a successful pair write. Preserve that exact generation
        // for the caller's existing rollback fence; a newer writer must still win.
        defer {
            if let written = committedState.load() {
                configuration = written.configuration
                library = written.library
            }
        }
        do {
            guard preparedSnapshot.summary.coversEnabledBlocklists(in: configuration) else {
                throw PublicationDeferredError.incomplete
            }
            library.syncActiveFilter(from: configuration)
            let token = FilterArtifactStore.versionedToken(for: preparedSnapshot)
            library.mutateFilter(id: library.activeFilterID) { $0.lastCompiledToken = token }

            let plannedConfiguration = configuration
            let plannedLibrary = library
            let configurationURL = env.configurationURL
            let libraryURL = env.filterLibraryURL
            let loadedGeneration = configuration.configurationGeneration
            let service = FilterSnapshotPreparationService(cacheDirectoryURL: env.catalogCacheURL)
            let completedEvent = FocusSwitchDiagnosticEventBox()
            let outcome = try await service.persistArtifacts(
                preparedSnapshot,
                containerURL: env.containerURL,
                snapshotFilename: env.snapshotFilename,
                compactSnapshotFilename: env.compactSnapshotFilename,
                publishLockURL: env.publishLockURL,
                configurationWriteLockURL: env.configurationWriteLockURL,
                lockMode: .tryOrAbort,
                commitBeforeFlip: {
                    // Prefer the newer-writer veto over the catalog/replay checks. All checks run
                    // before the pair changes, under both locks, after artifact staging has finished.
                    guard SharedFilterStatePersistence.onDiskConfigurationGeneration(at: configurationURL) <= loadedGeneration else {
                        throw SupersededError()
                    }
                    try commitBeforeFlip()
                    let written = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
                        configuration: plannedConfiguration,
                        library: plannedLibrary,
                        configurationURL: configurationURL,
                        filterLibraryURL: libraryURL,
                        // Already held by persistArtifacts. Reacquiring this flock would deadlock.
                        crossProcessLockURL: nil,
                        rejectsAdvancedBeyond: loadedGeneration
                    )
                    committedState.store(written)
                },
                onPublished: {
                    if let event = diagnosticCapture.capture() { completedEvent.store(event) }
                },
                diagnosticFailureEvent: { diagnosticCapture.capture() },
                additionalRetainedTokens: library.retainedWarmArtifactTokens(
                    maxFilters: configuration.limits.maxFilters,
                    backgroundWarmIndex: warmIndex
                )
            )
            switch outcome {
            case .published: break
            case .abortedCancelled: throw PublicationDeferredError.cancelled
            case .abortedContended: throw PublicationDeferredError.contended
            case .abortedSuperseded: throw PublicationDeferredError.superseded
            }
            env.onHeadlessCommitCompleted()
            return completedEvent.load()
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let diagnosticFailure as FocusSwitchDiagnosticFailure {
            throw diagnosticFailure
        } catch {
            guard let event = diagnosticCapture.capture() else { throw error }
            throw FocusSwitchDiagnosticFailure(underlying: error, event: event)
        }
    }

    /// Mirror of `AppViewModel.persistConfigurationOnly(schedulesAutomaticBackup: false)`: bump the
    /// generation + write the config+library pair via the single shared writer, no artifact flip. Used to
    /// roll the on-disk selection back to the previous filter after a vetoed/failed commit.
    ///
    /// `expectedBaseGeneration` fences the rollback against our own write: publication has released its
    /// locks before the error reaches this caller, so another writer may have advanced the generation.
    /// Passing the generation this commit wrote means the rollback reverts only
    /// if nobody advanced past it; otherwise it aborts (`StaleBaseGenerationError`) and leaves the newer
    /// state, rather than re-bumping the generation and clobbering the user's update.
    private static func writeConfigurationOnly(
        configuration: inout AppConfiguration,
        library: inout FilterLibrary,
        expectedBaseGeneration: Int?,
        env: Environment
    ) throws {
        library.syncActiveFilter(from: configuration)
        let written = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: configuration,
            library: library,
            configurationURL: env.configurationURL,
            filterLibraryURL: env.filterLibraryURL,
            crossProcessLockURL: env.configurationWriteLockURL,
            rejectsAdvancedBeyond: expectedBaseGeneration
        )
        configuration = written.configuration
        library = written.library
    }

    // MARK: - Load

    /// Read `(configuration, library, didReseed)` from the App Group container, mirroring
    /// `AppViewModel.loadPersistedConfiguration` + `loadOrMigrateFilterLibrary` for the HEADLESS (read-only)
    /// case: accept only an invariant-valid, current-schema library that did not lose a two-file write
    /// race, mirroring the active filter's four fields into `configuration`; otherwise reseed the three
    /// defaults and report `didReseed` (the gate then refuses, since the headless path never persists a
    /// migration).
    private static func loadState(env: Environment) -> (configuration: AppConfiguration, library: FilterLibrary, didReseed: Bool) {
        var configuration = AppConfiguration()
        var configurationLoaded = false
        if let data = try? Data(contentsOf: env.configurationURL),
           let persisted = try? JSONDecoder().decode(AppConfiguration.self, from: data) {
            configuration = persisted
            configurationLoaded = true
        }

        // FAIL CLOSED if the device-global configuration didn't load: a default `AppConfiguration()` carries
        // DEFAULT resolver/protection/entitlement/logging settings, and committing a switch from it would
        // overwrite the user's real config with defaults. (Before the Plus gate was dropped, a default config
        // had `isPaid == false` and the Plus check caught this implicitly; now we refuse explicitly.) Treat a
        // config-load failure exactly like an unusable library — reseed + `didReseed`, which the gate refuses
        // (Codex). Only proceed on the happy path when BOTH files loaded cleanly.
        if configurationLoaded,
           let data = try? Data(contentsOf: env.filterLibraryURL),
           let persisted = try? JSONDecoder().decode(FilterLibrary.self, from: data) {
            let normalized = persisted.normalized()
            if normalized.isValid,
               normalized.schemaVersion >= FilterLibrary.currentSchemaVersion,
               !normalized.lostWriteRace(againstConfigurationGeneration: configuration.configurationGeneration) {
                mirrorActiveFilter(of: normalized, into: &configuration)
                return (configuration, normalized, false)
            }
        }

        let library = FilterLibrary.seededDefaults(active: .balanced)
        mirrorActiveFilter(of: library, into: &configuration)
        return (configuration, library, true)
    }

    /// Regenerate `configuration`'s four filter-scoped fields from the library's active filter (the
    /// library is the source of truth; the device-global fields are left untouched). Mirror of
    /// `AppViewModel.mirrorActiveFilterIntoConfiguration`.
    private static func mirrorActiveFilter(of library: FilterLibrary, into configuration: inout AppConfiguration) {
        let active = library.activeFilter
        configuration.enabledBlocklistIDs = active.enabledBlocklistIDs
        configuration.customBlocklists = active.customBlocklists
        configuration.blockedDomains = active.blockedDomains
        configuration.allowedDomains = active.allowedDomains
    }

    private static func loadWarmIndex(env: Environment) -> BackgroundWarmIndex {
        BackgroundWarmIndexStore(fileURL: env.backgroundWarmIndexURL).load()
    }

    // MARK: - Lock

    /// Serialize concurrent headless Focus switches with a dedicated app-group flock. Degrade-OPEN if the
    /// lock file is unavailable (same posture as `LavaProtectionCommandService`). The flock is bound to the
    /// open file description, so it stays held across the `await` body and is released on close.
    /// Holds a cross-process advisory lock for the duration of `body`.
    ///
    /// 🔴 NOT RE-ENTRANT. `flock` is per open-file-description, so taking the SAME lock again
    /// inside `body` — via a helper that opens the file itself, such as `loadState` or
    /// `writeConfigurationAndLibrary` — blocks this process against itself. Anything that needs
    /// state while holding a lock must read it inline.
    private static func withCrossProcessLock<T>(
        at lockURL: URL,
        _ body: () async -> T
    ) async -> T {
        // O_CREAT only (never createFile, which would replace the inode and orphan the lock).
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return await body() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return await body() }
        defer { flock(descriptor, LOCK_UN) }
        return await body()
    }
}
