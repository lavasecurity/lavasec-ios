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

/// The event boundary for a Focus diagnostic. Carries only ordering metadata; the record adds the
/// outcome and target filter identifier.
public struct FocusSwitchDiagnosticEvent: Equatable, Sendable {
    /// Wall-clock time shown in the redacted bug report.
    public let at: Date
    /// Clear generation observed when the event was captured. Unlike wall-clock time, this remains
    /// ordered when the device clock is corrected backwards.
    public let clearGeneration: Int

    package init(at: Date, clearGeneration: Int) {
        self.at = at
        self.clearGeneration = clearGeneration
    }
}

/// Carries a diagnostic event captured by the actor that reached a Focus-switch failure boundary.
/// The underlying error remains available to the caller for normal classification and UI handling.
///
/// The wrapper is immutable. `@unchecked Sendable` is required only because Swift cannot express
/// one-way ownership transfer for an `Error` existential: callers supply immutable/value errors,
/// and the receiving task alone inspects `underlying` after the producer throws this wrapper. No
/// call site retains and concurrently mutates an underlying reference error.
public struct FocusSwitchDiagnosticFailure: Error, @unchecked Sendable {
    /// The original failure used for ordinary cancellation, retry, and UI classification.
    public let underlying: Error
    /// Ordering metadata captured synchronously where `underlying` was produced.
    public let event: FocusSwitchDiagnosticEvent

    /// Creates a boundary failure without changing the underlying error's meaning.
    public init(underlying: Error, event: FocusSwitchDiagnosticEvent) {
        self.underlying = underlying
        self.event = event
    }
}

/// A privacy-safe record of the most recent Focus-driven switch ATTEMPT, for diagnosing the closed-app
/// path on internal TestFlight (LAV-100 Phase 4): Release builds strip the QA device log and there is no
/// device to pull from, so this single record — surfaced in the redacted bug report — tells whether the
/// extension's `perform()` ran at all and what the engine decided (committed / deferred / disallowed /
/// alreadyActive). Carries ONLY the outcome, the target filter id (a non-PII slug), and the decision
/// time — no domains, rules, or device-global data.
public struct FocusSwitchDiagnosticRecord: Codable, Equatable, Sendable {
    package let outcome: String
    package let targetFilterID: String
    /// The event time shown in the report. Headless records capture their clear generation before
    /// delayed consent-gated writes, so a delayed write can be classified correctly as pre-clear
    /// or post-clear even if the wall clock changes.
    package let at: Date
    /// Clear generation captured at the event boundary. Zero is the legacy value for records written
    /// before timestamped clears existed; such records are hidden once a clear generation advances.
    package let clearGeneration: Int
    /// Why the engine reached `outcome` — the specific gate/defer/commit branch, e.g. "committed",
    /// "deferred-no-warm-artifact", "deferred-catalog-moved", "deferred-superseded", "already-active",
    /// "disallowed-auth-to-edit". Surfaced in the redacted bug report so a closed-app switch is diagnosable
    /// on Release (no QA device log): it distinguishes e.g. "deferred because the target wasn't warm" from
    /// "deferred because a foreground write superseded it", etc.
    package let reason: String

    package init(
        outcome: String,
        targetFilterID: String,
        at: Date,
        reason: String = "",
        clearGeneration: Int = 0
    ) {
        self.outcome = outcome
        self.targetFilterID = targetFilterID
        self.at = at
        self.reason = reason
        self.clearGeneration = clearGeneration
    }

    private enum CodingKeys: String, CodingKey { case outcome, targetFilterID, at, reason, clearGeneration }

    // Custom decode so a record persisted by an OLDER build (no `reason` key) still decodes (reason: "")
    // instead of failing — keeps the diagnostic forward/backward compatible.
    /// Decodes a diagnostic record, defaulting a missing legacy reason to an empty string.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try c.decode(String.self, forKey: .outcome)
        targetFilterID = try c.decode(String.self, forKey: .targetFilterID)
        at = try c.decode(Date.self, forKey: .at)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        clearGeneration = try c.decodeIfPresent(Int.self, forKey: .clearGeneration) ?? 0
    }
}

/// Single-record store for the last Focus-switch attempt over the shared app-group defaults. Written by
/// the engine on every `performSwitch` (always-on, NOT QA-gated, so it exists in Release), read by the
/// bug-report builder.
public enum FocusSwitchDiagnostics {
    package static let defaultsKeyName = "lavasec.focus.lastSwitchDiagnostic"
    package static let clearedAtKeyName = "lavasec.focus.diagnosticsClearedAt"
    package static let clearGenerationKeyName = "lavasec.focus.diagnosticsClearGeneration"

    /// Captures the event time and clear generation in one required cross-process critical section.
    ///
    /// `now` is evaluated only after the ordering lock is held. If the lock cannot be opened or
    /// acquired, this fails closed with `nil`; an unordered event must never become diagnostic
    /// evidence. This lock is terminal in the lock order: the body takes no other lock.
    /// - Parameters:
    ///   - defaults: Shared defaults containing the diagnostic clear generation.
    ///   - orderingLockURL: Dedicated terminal lock shared by every capture and generation clear.
    ///   - now: Clock evaluated only after the lock is held.
    public static func captureEvent(
        in defaults: UserDefaults,
        orderingLockURL: URL,
        now: @Sendable () -> Date = { Date() }
    ) -> FocusSwitchDiagnosticEvent? {
        FilterPublishLock.withRequiredExclusiveLock(at: orderingLockURL) {
            FocusSwitchDiagnosticEvent(
                at: now(), clearGeneration: currentClearGeneration(in: defaults))
        }
    }

    /// Records the last engine DECISION, whatever it was.
    ///
    /// `keepingLocalRecords` has no default for the reason it has none on the failure recorder:
    /// consent withdrawn must stop the write. Without it, turning Network Activity off clears
    /// this slot and the very next Focus edge writes it straight back.
    /// pinned: FocusSwitchDiagnosticsTests.testWithdrawnConsentStopsTheWriteRatherThanClearingAfterIt
    package static func record(
        _ record: FocusSwitchDiagnosticRecord, keepingLocalRecords: Bool, in defaults: UserDefaults
    ) {
        guard keepingLocalRecords else { return }
        write(record, forKey: defaultsKeyName, in: defaults)
    }

    /// Runs `body` with the user's standing consent, resolved ONCE and held for the duration.
    ///
    /// 🔴 ONE CHOKE POINT, BECAUSE THE ALTERNATIVE KEPT REGRESSING. Consent was resolved at three
    /// separate sites — the headless writer, the foreground failure write, and the bug-report read
    /// — and every one of them had to remember two things independently: fail CLOSED when consent
    /// cannot be established, and hold the settings path's lock across the check and the act.
    /// Review found the same two defects at site after site (Codex, PR #625), which is what a
    /// convention repeated three times buys. There is now one place to get it right.
    ///
    /// RESOLVED FROM THE PERSISTED CONFIGURATION, not an in-memory copy. The disk is what the
    /// OTHER process reads, and an in-memory value can be a placeholder: the app deliberately
    /// leaves a default `AppConfiguration` in memory when the real file is locked before first
    /// unlock, and that default says `keepNetworkActivity == true`.
    ///
    /// FAILS CLOSED. Unreadable, undecodable, absent — all resolve to NO consent. A default
    /// `AppConfiguration` carries `true`, so trusting it turns "we could not tell" into "consent
    /// granted", the one direction a consent gate must never fail.
    ///
    /// HOLDS THE LOCK ACROSS `body`, so a clear or a write cannot interleave with the settings
    /// path persisting the toggle. 🔴 NOT RE-ENTRANT — `flock` is per open-file-description, so
    /// `body` must not call anything that opens this same lock file.
    /// pinned: FocusSwitchDiagnosticsTests.testConsentFailsClosedWhenTheConfigurationCannotBeRead
    public static func withResolvedConsent<T>(
        configurationURL: URL, lockURL: URL, _ body: (Bool) -> T
    ) -> T {
        // 🔴 THIS LOCK ONLY. An earlier revision also took the FOCUS-SWITCH lock, to order a clear
        // against the engine's whole decide-then-record span. It was reverted: both clear callers
        // are `@MainActor` and synchronous, so a blocking `flock(LOCK_EX)` on a lock a Focus switch
        // holds across a COLD COMPILE froze the UI for seconds on "Clear all local logs" and the
        // Network Activity toggle (Kilo, PR #626).
        //
        // Timestamped clears close the residual without waiting for the focus-switch lock: a
        // decision made before a clear remains hidden even if its consent-gated write lands after
        // slot deletion. A decision made after the watermark remains visible.
        //
        // This lock is safe here: it is the configuration-write lock the settings path already
        // takes synchronously on the main thread today, held only for a file read or write.
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        if descriptor >= 0 {
            defer { close(descriptor) }
            if flock(descriptor, LOCK_EX) == 0 {
                defer { flock(descriptor, LOCK_UN) }
                return body(persistedConsent(at: configurationURL))
            }
        }
        // The lock is a serialization aid, not the consent decision: if it cannot be taken we
        // still resolve consent from disk and still fail closed. Degrading here matches the
        // engine's own lock, which also proceeds unlocked rather than dropping the work.
        return body(persistedConsent(at: configurationURL))
    }

    /// Resolves consent and runs an optional diagnostic write without waiting for a settings writer.
    /// Returns nil without invoking `body` if exclusion is unavailable. The consent check and write
    /// still share the settings lock; skipping diagnostics must never weaken the privacy boundary.
    public static func tryWithResolvedConsent<T>(
        configurationURL: URL, lockURL: URL, _ body: (Bool) -> T
    ) -> T? {
        FilterPublishLock.withTryExclusiveLock(at: lockURL) {
            body(persistedConsent(at: configurationURL))
        }
    }

    private static func persistedConsent(at configurationURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: configurationURL),
            let persisted = try? JSONDecoder().decode(AppConfiguration.self, from: data)
        else { return false }
        return persisted.keepNetworkActivity
    }

    /// The `outcome` a FOREGROUND reconcile apply records when its switch threw and rolled back.
    ///
    /// Distinct from every ``HeadlessFocusSwitchOutcome`` on purpose: those describe what the
    /// closed-app engine DECIDED, and this describes a decision that was taken and then failed to
    /// land.
    public static let foregroundReconcileFailedOutcome = "foreground-reconcile-failed"

    /// The FAILURE slot, separate from ``defaultsKeyName``.
    ///
    /// 🔴 TWO WRITERS SHARE THE OUTCOME SLOT, AND ONE OF THEM WRITES ON SUCCESS. The headless
    /// engine records EVERY decision — `.committed` and `.alreadyActive` included — with no
    /// condition, so a routine Focus switch overwrites whatever was there. Put a failure in that
    /// slot and the next success evicts the evidence, which on the observed device happens
    /// constantly: the kept marker retries on every foreground edge while the engine fires on
    /// every Focus edge. The record would be gone before the user filed a report.
    ///
    /// So failures get their own slot and the two never contend. `lastFocusSwitch` keeps meaning
    /// "the last thing that happened"; this one means "the last thing that went wrong", and
    /// neither can erase the other (MECE panel, PR #625).
    package static let failureKeyName = "lavasec.focus.lastSwitchFailure"

    /// Records a foreground reconcile apply that threw, so the failure survives into Release.
    ///
    /// 🔴 THE FAILURE THIS EXISTS FOR IS OTHERWISE INVISIBLE. `switchToFilter`'s catch rolls back
    /// and discards `error`; the only trace was `reconcile-apply-failed-kept-marker`, written by
    /// `logFocusSwitchEvent`, which is `#if DEBUG || LAVA_QA_TOOLS`. On a shipping build a Focus
    /// automation that never applies produces no log, no modal and no banner. Device 2026-08-29:
    /// 44 attempts across six builds and five days, zero successes, cause unknown because nothing
    /// recorded it.
    ///
    /// `keepingLocalRecords` HAS NO DEFAULT, deliberately. It is the user's standing consent to
    /// local record-keeping, and a defaulted parameter is how a writer silently stops honouring
    /// it. Withdrawing consent must stop the WRITES, not merely clear once — otherwise the next
    /// failure repopulates the slot and the clear was theatre.
    ///
    /// `reason` must be a STABLE, ENUMERATED key, never an interpolated error: this record is
    /// surfaced in the redacted bug report, and a free-text error can carry a path, a URL or a
    /// filter name. Opaque generated identifiers (`filter-<UUID>`) are permitted — they carry no
    /// user-authored text. Callers classify; see `AppViewModel.focusReconcileFailureReason(for:)`.
    /// pinned: FocusSwitchDiagnosticsTests.testAForegroundReconcileFailureIsRecordedForRelease
    /// pinned: FocusSwitchDiagnosticsTests.testWithdrawnConsentStopsTheWriteRatherThanClearingAfterIt
    public static func recordForegroundReconcileFailure(
        targetFilterID: String, reason: String, at: Date, clearGeneration: Int = 0,
        keepingLocalRecords: Bool,
        in defaults: UserDefaults
    ) {
        guard keepingLocalRecords else { return }
        let record = FocusSwitchDiagnosticRecord(
            outcome: foregroundReconcileFailedOutcome,
            targetFilterID: targetFilterID,
            at: at,
            reason: reason,
            clearGeneration: clearGeneration)
        // A delayed reconcile must not clobber an existing newer-generation diagnosis merely
        // because its MainActor catch resumed later. If the slot was emptied by a clear, the
        // read-side generation watermark hides this older write instead.
        if let existing = read(forKey: failureKeyName, in: defaults),
           existing.clearGeneration > record.clearGeneration {
            return
        }
        write(record, forKey: failureKeyName, in: defaults)
    }

    /// The last recorded FAILURE, when present. Surfaced in the redacted bug report.
    public static func lastFailure(in defaults: UserDefaults) -> FocusSwitchDiagnosticRecord? {
        visibleRecord(forKey: failureKeyName, in: defaults)
    }

    /// Erases every Focus diagnostic slot without changing the clear watermark or generation.
    ///
    /// Called wherever the user withdraws consent for local record-keeping — "Clear all local
    /// logs", and Network Activity turned off. Clears BOTH slots: a clear that left one behind
    /// would be worse than none, because the user has been told the records are gone. The
    /// generation-advancing ``clear(in:orderingLockURL:now:)`` variant is used when a synchronous
    /// clear must also suppress a pre-clear decision that is still waiting to write.
    /// pinned: FocusSwitchDiagnosticsTests.testClearErasesEverySlot
    public static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKeyName)
        defaults.removeObject(forKey: failureKeyName)
    }

    /// Records a synchronous clear cut-over and erases every Focus diagnostic slot.
    ///
    /// The cut-over is separate from physical deletion because a headless switch can already
    /// have decided before this call and then be delayed before its consent-gated write. Its
    /// captured generation remains older than the clear, so the read side continues to hide it if
    /// the writer re-adds the record after the slots are removed. A newer event captures the new
    /// generation and remains visible. The generation, rather than the wall clock, is the ordering
    /// authority, so a device clock correction cannot suppress post-clear diagnostics or make an
    /// earlier record visible again.
    /// pinned: FocusSwitchDiagnosticsTests.testAStaleDecisionWrittenAfterClearIsHiddenByTheWatermark
    /// The generation advance and both deletions share the terminal diagnostic-ordering lock with
    /// ``captureEvent(in:orderingLockURL:now:)``. If that lock is unavailable, deletion still runs
    /// unlocked: honoring the user's erase gesture is stronger than retaining ordering metadata.
    /// - Parameters:
    ///   - defaults: Shared defaults containing both diagnostic slots and clear metadata.
    ///   - orderingLockURL: Dedicated terminal lock, or `nil` when the container is unavailable.
    ///   - now: Clock used for the legacy timestamp watermark.
    public static func clear(
        in defaults: UserDefaults,
        orderingLockURL: URL?,
        now: @Sendable () -> Date = { Date() }
    ) {
        func advanceAndClear() {
            let nextGeneration = currentClearGeneration(in: defaults) &+ 1
            defaults.set(nextGeneration, forKey: clearGenerationKeyName)
            defaults.set(now().timeIntervalSinceReferenceDate, forKey: clearedAtKeyName)
            clear(in: defaults)
        }

        guard FilterPublishLock.withRequiredExclusiveLock(
            at: orderingLockURL, advanceAndClear
        ) != nil else {
            advanceAndClear()
            return
        }
    }

    private static func write(
        _ record: FocusSwitchDiagnosticRecord, forKey key: String, in defaults: UserDefaults
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    private static func read(
        forKey key: String, in defaults: UserDefaults
    ) -> FocusSwitchDiagnosticRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FocusSwitchDiagnosticRecord.self, from: data)
    }

    private static func clearWatermark(in defaults: UserDefaults) -> Date? {
        guard defaults.object(forKey: clearedAtKeyName) != nil else { return nil }
        return Date(timeIntervalSinceReferenceDate: defaults.double(forKey: clearedAtKeyName))
    }

    private static func currentClearGeneration(in defaults: UserDefaults) -> Int {
        defaults.integer(forKey: clearGenerationKeyName)
    }

    private static func visibleRecord(
        forKey key: String, in defaults: UserDefaults
    ) -> FocusSwitchDiagnosticRecord? {
        guard let record = read(forKey: key, in: defaults) else { return nil }
        let currentGeneration = currentClearGeneration(in: defaults)
        guard record.clearGeneration >= currentGeneration else { return nil }
        // New records are ordered by generation, not Date. This keeps them visible after a wall-clock
        // correction while the date remains useful for the bug report. Legacy records (generation 0)
        // are only visible before the first timestamped clear, and the date fallback preserves the
        // old behavior if a future migration ever leaves a zero-generation record behind.
        guard currentGeneration == 0 else { return record }
        guard let clearedAt = clearWatermark(in: defaults) else { return record }
        return record.at > clearedAt ? record : nil
    }

    /// Returns the last valid Focus-switch diagnostic record, when present.
    public static func last(in defaults: UserDefaults) -> FocusSwitchDiagnosticRecord? {
        visibleRecord(forKey: defaultsKeyName, in: defaults)
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
