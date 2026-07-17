import Foundation
import LavaSecKit

// MARK: - Background pending-switch drain (LAV-100 follow-up)
//
// Drains a deferred Focus/Automation filter switch WHILE LAVA STAYS CLOSED, from the app-process
// catalog-refresh BGTask — the missing half of the original Phase-3 design ("a foreground/BGTask
// warm-and-apply … on the next app foreground OR REFRESH CYCLE"; only the foreground half shipped).
// Until this existed, a `.deferred` switch waited for the next app open: the tunnel poll adopts only
// COMMITTED generation bumps, and neither the tunnel (INV-MEM-1, no compiles in the NE process) nor
// an App Intent's short window can cold-compile (lavasec-infra
// `plans/2026-07-16-deferred-automation-switch-background-warm-and-apply-plan.md`, founder 2026-07-16).
//
// The drain is deliberately a THIN twin of the foreground reconcile's moot-marker handling plus a
// re-drive of the SAME shared engine — it adds no switch logic of its own. Warm-only by design, and
// honest about coverage: it closes the main pocket (an ALREADY-COMPILED target whose catalog basis is
// unchanged — the sync's verified-unchanged freshness re-stamp exists precisely so this reuse passes)
// and, on a published refresh cycle, targets the sidecar warm pass just recompiled. A NEVER-compiled
// or disk-pressure-evicted target still re-defers here every cycle (the warm pass does not run on
// "bg-unchanged" cycles, and this drain never cold-compiles in the BGTask's budgeted window) and
// waits for the next foreground — the plan's optional Phase 2 (bounded background cold-compile) is
// the future fix for that remainder. A re-defer simply leaves the durable marker for the next
// cycle/foreground: the same tolerated, self-healing deferral the Focus path already carries.

/// Drains the durable pending Focus/Automation switch marker from the background (app-process
/// BGTask), so a deferred automation switch applies without the user opening Lava.
///
/// Mirrors the foreground reconcile's semantics for MOOT markers (auth gate closed / superseded by
/// a newer manual switch ⇒ compare-and-clear under the shared marker flock) and otherwise re-drives
/// `HeadlessFocusFilterSwitchEngine.performSwitch` — the single gated switch boundary — leaving the
/// marker in place on every engine outcome exactly as the App Intents extension does, so the
/// foreground reconcile's re-sync/clear protocol is unchanged.
public enum BackgroundPendingSwitchDrain {
    /// What the drain did with the marker, for logging/tests. The engine outcome is carried on
    /// `.drove` so callers can log it without re-reading diagnostics.
    public enum Outcome: Equatable, Sendable {
        /// No pending marker existed; nothing to do.
        case noMarker
        /// Filter editing is auth-protected: an unattended switch must not happen now or on a later
        /// reconcile (the same invariant the foreground reconcile enforces), so the marker was
        /// cleared without driving the engine.
        case clearedAuthGateClosed
        /// A manual switch initiated at-or-after the marker's request superseded it; cleared
        /// without driving the engine.
        case clearedSuperseded
        /// The surrounding task was cancelled (BGTask expired) before the engine was driven; the
        /// marker survives untouched for the next cycle/foreground.
        case cancelled
        /// The engine was driven; the marker is LEFT for the foreground reconcile protocol.
        case drove(HeadlessFocusSwitchOutcome)
    }

    /// Runs one drain pass against the shared container described by `env`.
    ///
    /// CORRECTNESS-CRITICAL REPLAY IDENTITY: the engine records the marker with
    /// `requestedAt = env.now()` on both its record paths (`HeadlessFocusFilterSwitchEngine.runLocked`),
    /// which is right for a FRESH intent but would let a REPLAY forge freshness: a drain-time
    /// re-record stamped "now" would out-rank a manual switch whose supersession stamp lands only on
    /// success (`switchToFilter` stamps its INITIATION instant after `persistSharedState` succeeds), so
    /// a days-old automation could resurrect over — and on the next reconcile revert — the user's
    /// explicit later choice. The drain therefore drives the engine with `now` overridden to the
    /// ORIGINAL `request.requestedAt`: the replay keeps its true temporal identity, and any manual
    /// switch initiated after the original automation still wins everywhere the `<=` precedence rule
    /// runs. (Side effect, accepted: a replay's `FocusSwitchDiagnostics` record carries the ORIGINAL
    /// request time in `at` — it identifies the request being replayed, and the reason string still
    /// names the branch taken.) Manual precedence is enforced at THREE points: the supersession
    /// pre-check below (cheap, before any engine work), the engine's IN-LOCK `replaySupersededVeto`
    /// (re-evaluated under the publish lock immediately before the flip — catches a manual switch
    /// that COMPLETED after the pre-check, rolling back to the manual selection), and the engine's
    /// generation fence (catches one completing after the engine's config load). `clearIfMatches`
    /// (exact-request compare under the shared marker flock) guarantees a NEWER request recorded
    /// concurrently by an intent is never dropped by this pass.
    ///
    /// NEWER-INTENT PROTECTION (the compare-and-record seam; lavasec-ios public review of the PR #410
    /// promotion): the replay env also carries `replayExpectedMarker = request`, which turns BOTH of
    /// the engine's marker records into compare-and-record (`recordIfMatches`). A NEWER Focus/Shortcut
    /// intent that wins the slot while this replay is flock-blocked therefore survives: the replay's
    /// main-path record mismatches and aborts fail-closed (`disallowed-replay-marker-changed`), and
    /// its already-active best-effort record silently yields — the newest automation is never erased
    /// by a re-stamped old one.
    /// pinned: BackgroundPendingSwitchDrainTests.testSupersededMarkerIsClearedWithoutDrivingEngine
    /// pinned: BackgroundPendingSwitchDrainTests.testNewerMarkerRedefersOnWarmMissAndPreservesOriginalRequestedAt
    @discardableResult
    public static func drain(env: HeadlessFocusFilterSwitchEngine.Environment) async -> Outcome {
        let defaults = env.defaults
        guard let request = PendingFilterSwitchStore.current(in: defaults) else { return .noMarker }

        // Same fail-closed SECURITY gate the foreground reconcile re-checks (and the engine
        // enforces): filter editing auth-protected ⇒ the unattended request is moot, and it must
        // not apply on a later pass either — clear it. (The engine would refuse this switch too;
        // clearing here matches `applyPendingFilterSwitchOnce`'s gate-closed branch so the two
        // drains can't drift on the invariant.)
        guard !SecurityProtectedSurfaceStorage.isProtected(.filterEditing, defaults: defaults) else {
            PendingFilterSwitchStore.clearIfMatches(request, in: defaults, lockURL: env.pendingMarkerLockURL)
            return .clearedAuthGateClosed
        }

        // Supersession: the SHARED precedence predicate (one tie rule for both drains). Must precede
        // performSwitch — see the doc comment's replay-identity rationale.
        if PendingFilterSwitchStore.isSupersededByForegroundSwitch(request, in: defaults) {
            PendingFilterSwitchStore.clearIfMatches(request, in: defaults, lockURL: env.pendingMarkerLockURL)
            return .clearedSuperseded
        }

        // Last cancellation gate before the commit-capable engine runs: an expired BGTask should not
        // START a publish (mirrors the catalog publish's pre-stage cancellation guard). A cancellation
        // that lands AFTER this point does not abort the engine mid-commit — that residual is the
        // same accepted class as the App Intents extension being terminated mid-commit: fail-closed,
        // rollback-fenced, and healed marker-independently on the next cold launch by
        // `reconcileTunnelSnapshotAfterLaunch` (see the engine's commit rationale and
        // `AppViewModel.applyPendingFilterSwitchOnce`'s re-notify note).
        guard !Task.isCancelled else { return .cancelled }

        // Re-drive the shared engine: warm commit when the just-refreshed cache/warm pass covers
        // the target, clean re-defer otherwise. Target-gone/frozen and reseed refusals surface as
        // `.disallowed` and deliberately LEAVE the marker — the foreground reconcile owns those
        // clears (it can distinguish the reasons; this headless pass cannot), and a lingering moot
        // marker is inert until then. The marker is likewise LEFT on commit so a still-resident
        // suspended foreground re-syncs its in-memory state — the extension's exact protocol.
        //
        // The replay env carries TWO protections (Codex PR #410 P1 pair): `now` = the ORIGINAL
        // requestedAt (replay identity — see the doc comment) and the in-lock supersession veto,
        // re-evaluated by the engine UNDER THE PUBLISH LOCK immediately before the flip. The veto
        // closes the remaining window the pre-check can't see: a manual switch that COMPLETES
        // between the pre-check and the engine's config load would otherwise be switched away from
        // by this replay (and the reconcile would only clear the marker, never restore the manual
        // choice); at flip time its stamp is visible, the veto fires, and the engine's rollback
        // restores the manual selection. A manual switch completing after the engine's load is
        // caught by the generation fence instead — the window is fully closed.
        // UserDefaults is documented thread-safe but not Sendable, and the veto runs on the publish
        // actor inside the engine's in-lock closure — carry the SAME instance across in an explicitly
        // unchecked box (the BGTaskBox pattern) so the veto reads the store the pre-check read; a
        // fresh suite lookup here would break the test harness's throwaway suites.
        let vetoDefaults = UncheckedSendableDefaults(defaults: defaults)
        let replayEnv = env.forReplay(
            now: { request.requestedAt },
            supersededVeto: { PendingFilterSwitchStore.isSupersededByForegroundSwitch(request, in: vetoDefaults.defaults) },
            expectedMarker: request
        )
        return .drove(await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: request.targetFilterID, env: replayEnv))
    }

    /// `UserDefaults` is thread-safe by documentation but carries no `Sendable` conformance; this box
    /// makes that judgement explicit at the one place the drain sends an instance across tasks.
    private struct UncheckedSendableDefaults: @unchecked Sendable {
        let defaults: UserDefaults
    }
}

extension HeadlessFocusFilterSwitchEngine.Environment {
    /// A copy of this environment configured for a REPLAY: `now` overridden to the original request
    /// time (replay identity), the in-lock supersession veto installed, and the expected marker set
    /// so the engine's records become compare-and-record (see `BackgroundPendingSwitchDrain.drain`).
    /// Lives here, not in the engine file, so the pin-locked engine source gains only the additive
    /// seams; all other fields are carried over verbatim.
    func forReplay(
        now: @escaping @Sendable () -> Date,
        supersededVeto: @escaping @Sendable () -> Bool,
        expectedMarker: PendingFilterSwitchRequest
    ) -> Self {
        HeadlessFocusFilterSwitchEngine.Environment(
            containerURL: containerURL,
            configurationURL: configurationURL,
            filterLibraryURL: filterLibraryURL,
            catalogCacheURL: catalogCacheURL,
            backgroundWarmIndexURL: backgroundWarmIndexURL,
            publishLockURL: publishLockURL,
            focusSwitchLockURL: focusSwitchLockURL,
            configurationWriteLockURL: configurationWriteLockURL,
            pendingMarkerLockURL: pendingMarkerLockURL,
            snapshotFilename: snapshotFilename,
            compactSnapshotFilename: compactSnapshotFilename,
            defaults: defaults,
            catalogSyncFreshnessInterval: catalogSyncFreshnessInterval,
            now: now,
            postSignal: postSignal,
            log: log,
            notifySwitchOutcome: notifySwitchOutcome,
            replaySupersededVeto: supersededVeto,
            replayExpectedMarker: expectedMarker
        )
    }
}
