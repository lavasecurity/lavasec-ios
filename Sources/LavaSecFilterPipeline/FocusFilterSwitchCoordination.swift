import Foundation
import LavaSecKit

/// Cross-process coordination for the Focus-driven headless filter switch (LAV-100 Phase 3).
///
/// The headless warm-switch path (a `SetFocusFilterIntent` waking the app in the background) and
/// the foreground app must agree on TWO pieces of shared state without ever clobbering the
/// single-owner `app-configuration.json` (the LAV-90 invariant). The pure stores here own the key
/// layout + encode/decode so the app, the headless switch service, and their unit tests can never
/// drift on strings or semantics — they take a `UserDefaults` (the shared app-group suite in
/// production, a throwaway suite in tests) and an explicit `now` so they stay deterministic.
///
/// Two pieces:
///  • `PendingFilterSwitchStore` — the durable record of "a Focus switch to filter X was requested".
///    This is the feature's CORRECTNESS guarantee: the headless immediate-commit is a best-effort
///    fast path, and this marker ensures the foreground eventually applies the switch even when the
///    immediate commit was skipped (app active / no warm artifact), aborted, or out-raced by a
///    foreground write.
/// (The headless path is STATE-AGNOSTIC as of 2026-06-29 — it no longer tracks app foreground state; the
/// cross-process write lock + generation fence make a concurrent foreground write safe, so it commits
/// regardless of app state. The pending-switch marker remains the correctness guarantee.)

/// A pending Focus-driven filter switch, recorded by the headless path and reconciled by the
/// foreground. `requestedAt` lets a newer request supersede an unreconciled earlier one and lets the
/// foreground compare-and-clear only the exact request it reconciled.
public struct PendingFilterSwitchRequest: Codable, Equatable, Sendable {
    /// Identifier of the filter requested by Focus.
    public let targetFilterID: String
    /// Time the Focus request was recorded.
    public let requestedAt: Date

    package init(targetFilterID: String, requestedAt: Date) {
        self.targetFilterID = targetFilterID
        self.requestedAt = requestedAt
    }
}

/// Single-key store for the pending Focus switch over the shared app-group defaults.
public enum PendingFilterSwitchStore {
    package static let defaultsKeyName = "lavasec.focus.pendingFilterSwitch"
    /// Timestamp of the last FOREGROUND-initiated filter switch. `switchToFilter` stamps the instant it
    /// was INITIATED (captured at entry, before its async prepare), not when it completed — so a slow cold
    /// switch can't backdate-clear a Focus request that fired while it was preparing. The foreground
    /// reconcile drops a pending Focus request whose `requestedAt` is at-or-before this, so a deliberate
    /// manual switch INITIATED after the Focus request always wins — a stale marker never reverts the
    /// user's newer explicit choice.
    package static let lastForegroundSwitchAtDefaultsKeyName = "lavasec.focus.lastForegroundSwitchAt"

    /// Record (overwriting any prior unreconciled request — the newest Focus change wins). Returns whether
    /// the marker was durably written: a `false` return means the encode failed (theoretically impossible
    /// for this Codable, but the headless path treats it as fail-closed rather than committing without the
    /// correctness guarantee in place — review #2).
    ///
    /// `lockURL` (LAV-100 Phase 4): the App Intents extension records from a SEPARATE process, so this
    /// runs under the shared marker flock to serialize against the foreground's `clearIfMatches` — closing
    /// the cross-process record-vs-clear TOCTOU. `nil` degrades to in-process-only (tests).
    @discardableResult
    package static func record(_ request: PendingFilterSwitchRequest, in defaults: UserDefaults, lockURL: URL? = nil) -> Bool {
        FilterPublishLock.withExclusiveLock(at: lockURL) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(request) else { return false }
            defaults.set(data, forKey: defaultsKeyName)
            return true
        }
    }

    /// Compare-and-record: overwrite the marker ONLY while it still equals `expecting` — the record
    /// half of the replay protocol (`BackgroundPendingSwitchDrain`). A REPLAY re-records the request
    /// it read, but a NEWER Focus/Shortcut intent may have overwritten the slot while the replay was
    /// serialized behind the focus flock; an unconditional overwrite there would erase the user's
    /// newest automation with a re-stamped old one (the lost-update Codex flagged on the lavasec-ios
    /// public promotion of PR #410). One flock spans the compare and the write, so an intent's
    /// `record` can only land strictly before (→ mismatch → false, newer marker preserved) or
    /// strictly after (→ its overwrite legitimately wins as the newest intent). Fresh intents keep
    /// using `record` — newest-wins overwrite is correct for them.
    /// pinned: FocusFilterSwitchCoordinationTests.testRecordIfMatchesRefusesWhenMarkerChanged
    @discardableResult
    package static func recordIfMatches(
        _ request: PendingFilterSwitchRequest,
        expecting: PendingFilterSwitchRequest,
        in defaults: UserDefaults,
        lockURL: URL? = nil
    ) -> Bool {
        FilterPublishLock.withExclusiveLock(at: lockURL) {
            guard current(in: defaults) == expecting else { return false }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(request) else { return false }
            defaults.set(data, forKey: defaultsKeyName)
            return true
        }
    }

    /// Returns the pending Focus request, or `nil` when no valid record exists.
    public static func current(in defaults: UserDefaults) -> PendingFilterSwitchRequest? {
        guard let data = defaults.data(forKey: defaultsKeyName) else { return nil }
        return try? JSONDecoder().decode(PendingFilterSwitchRequest.self, from: data)
    }

    /// Compare-and-clear: remove the marker ONLY if it is still the exact request the caller
    /// reconciled. A newer request recorded after the caller read `current()` is therefore never
    /// dropped — the next reconcile applies it. Returns whether the clear happened.
    ///
    /// Serialization (closes the read-vs-removeObject TOCTOU): this method is fully SYNCHRONOUS (no `await`
    /// between the `current()` check and `removeObject`). Through Phase 3 that sufficed because every mutator
    /// ran on the app's single @MainActor (App Intents executed in the app process). LAV-100 Phase 4 adds the
    /// App Intents EXTENSION as a second `record`-ing process, so the @MainActor argument no longer spans
    /// both — `record` and `clearIfMatches` now take the shared marker flock (`lockURL`) so the extension's
    /// record can't land between this clear's compare and remove (which would silently drop the new request).
    /// A newer request can only land strictly before the compare (→ no match → not removed) or strictly after
    /// the remove (→ preserved). The tunnel process only READS config/artifacts, never this key. `nil`
    /// `lockURL` degrades to in-process-only (tests).
    @discardableResult
    public static func clearIfMatches(_ request: PendingFilterSwitchRequest, in defaults: UserDefaults, lockURL: URL? = nil) -> Bool {
        FilterPublishLock.withExclusiveLock(at: lockURL) {
            guard current(in: defaults) == request else { return false }
            defaults.removeObject(forKey: defaultsKeyName)
            return true
        }
    }

    /// Stamp the time of a foreground-initiated switch (call from `switchToFilter`'s commit).
    public static func recordForegroundSwitch(at now: Date, in defaults: UserDefaults) {
        defaults.set(now.timeIntervalSinceReferenceDate, forKey: lastForegroundSwitchAtDefaultsKeyName)
    }

    /// The manual-vs-automation precedence rule, in ONE place so the two marker drains — the
    /// foreground reconcile (`AppViewModel.applyPendingFilterSwitchOnce`) and the background BGTask
    /// drain (`BackgroundPendingSwitchDrain`) — can never drift on it: a request is superseded when a
    /// manual switch was INITIATED at-or-after it. `<=` on purpose: an exact tie favors the MANUAL
    /// switch (the user's explicit action outranks the automation), and that is the safe direction —
    /// a wrongly-dropped automation marker is re-recorded by the next Focus/Shortcut edge, whereas a
    /// wrongly-KEPT one would silently revert the user (founder review P2-3 lineage, LAV-100).
    /// pinned: FocusFilterSwitchCoordinationTests.testSupersessionPredicateFavorsManualSwitchOnTies
    public static func isSupersededByForegroundSwitch(
        _ request: PendingFilterSwitchRequest,
        in defaults: UserDefaults
    ) -> Bool {
        guard let lastForegroundSwitchAt = lastForegroundSwitch(in: defaults) else { return false }
        return request.requestedAt <= lastForegroundSwitchAt
    }

    /// The last foreground-initiated switch time, or nil if none recorded. Presence-checked (not a 0.0
    /// sentinel) so the reference date itself reads back correctly.
    public static func lastForegroundSwitch(in defaults: UserDefaults) -> Date? {
        guard defaults.object(forKey: lastForegroundSwitchAtDefaultsKeyName) != nil else { return nil }
        return Date(timeIntervalSinceReferenceDate: defaults.double(forKey: lastForegroundSwitchAtDefaultsKeyName))
    }
}

// NOTE: `AppForegroundActivityState` (the cross-process foreground-active hint + its 5-minute stale window)
// was REMOVED 2026-06-29. The headless switch is now STATE-AGNOSTIC — it no longer defers on app foreground
// state; the Phase-4 cross-process write lock + generation fence make a concurrent foreground write safe, so
// a closed-app switch commits promptly regardless of app state (no 5-minute dead zone). See
// HeadlessFocusFilterSwitchEngine.runLocked.

/// A privacy-safe record of the most recent Focus-driven switch ATTEMPT, for diagnosing the closed-app
/// path on internal TestFlight (LAV-100 Phase 4): Release builds strip the QA device log and there is no
/// device to pull from, so this single record — surfaced in the redacted bug report — tells whether the
/// extension's `perform()` ran at all and what the engine decided (committed / deferred / disallowed /
/// alreadyActive). Carries ONLY the outcome, the target filter id (a non-PII slug), and the time — no
/// domains, rules, or device-global data.
public struct FocusSwitchDiagnosticRecord: Codable, Equatable, Sendable {
    package let outcome: String
    package let targetFilterID: String
    package let at: Date
    /// Why the engine reached `outcome` — the specific gate/defer/commit branch, e.g. "committed",
    /// "deferred-no-warm-artifact", "deferred-catalog-moved", "deferred-superseded", "already-active",
    /// "disallowed-auth-to-edit". Surfaced in the redacted bug report so a closed-app switch is diagnosable
    /// on Release (no QA device log): it distinguishes e.g. "deferred because the target wasn't warm" from
    /// "deferred because a foreground write superseded it", etc.
    package let reason: String

    package init(outcome: String, targetFilterID: String, at: Date, reason: String = "") {
        self.outcome = outcome
        self.targetFilterID = targetFilterID
        self.at = at
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case outcome, targetFilterID, at, reason }

    // Custom decode so a record persisted by an OLDER build (no `reason` key) still decodes (reason: "")
    // instead of failing — keeps the diagnostic forward/backward compatible.
    /// Decodes a diagnostic record, defaulting a missing legacy reason to an empty string.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try c.decode(String.self, forKey: .outcome)
        targetFilterID = try c.decode(String.self, forKey: .targetFilterID)
        at = try c.decode(Date.self, forKey: .at)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

/// Single-record store for the last Focus-switch attempt over the shared app-group defaults. Written by
/// the engine on every `performSwitch` (always-on, NOT QA-gated, so it exists in Release), read by the
/// bug-report builder.
public enum FocusSwitchDiagnostics {
    package static let defaultsKeyName = "lavasec.focus.lastSwitchDiagnostic"

    package static func record(_ record: FocusSwitchDiagnosticRecord, in defaults: UserDefaults) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        defaults.set(data, forKey: defaultsKeyName)
    }

    /// Returns the last valid Focus-switch diagnostic record, when present.
    public static func last(in defaults: UserDefaults) -> FocusSwitchDiagnosticRecord? {
        guard let data = defaults.data(forKey: defaultsKeyName) else { return nil }
        return try? JSONDecoder().decode(FocusSwitchDiagnosticRecord.self, from: data)
    }
}

/// Lightweight Darwin (cross-process) wake the headless path posts after recording a deferred
/// switch, so a foreground app reconciles the pending marker promptly instead of waiting for its
/// next scene-phase transition. App-only delivery (the NE extension's run loop is dormant), which is
/// exactly the direction used here — headless intent → foreground app — so it is sound.
public enum FocusFilterSwitchSignal {
    /// Posted by the headless path after RECORDING a deferred switch, so a resident foreground app
    /// reconciles the pending marker promptly. App-direction delivery (foreground reconcile) — reliable
    /// because the foreground app's run loop services Darwin notifications while it is active.
    ///
    /// NOTE: there is intentionally NO extension→tunnel Darwin signal. The always-on tunnel adopts a
    /// Focus-committed config change by POLLING the configuration generation (LAV-100 Phase 4 P4d): a
    /// tunnel-side Darwin observer was proven unreliable in the NE extension (0 callbacks across 14 device
    /// probe runs), so the poll — not a Darwin push — is the closed-app reload path.
    public static let darwinNotificationName = "com.lavasec.focus.pending-switch-recorded"
}
