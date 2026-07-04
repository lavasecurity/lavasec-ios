import Foundation

public struct ProtectionPauseState: Equatable, Sendable {
    public let sessionID: String
    public let pausedUntil: Date
    public let revision: Int

    public init(sessionID: String, pausedUntil: Date, revision: Int) {
        self.sessionID = sessionID
        self.pausedUntil = pausedUntil
        self.revision = revision
    }
}

public enum ProtectionPauseNoChangeReason: Equatable, Sendable {
    case noActivePause
    case duplicateCommand
}

public enum ProtectionPauseCommandStatus: Equatable, Sendable {
    case changed(ProtectionPauseState?)
    case unchanged(ProtectionPauseNoChangeReason)
    case rejected(ProtectionCommandRejection)
}

public struct ProtectionPauseCommandResult: Equatable, Sendable {
    public let revision: Int
    public let status: ProtectionPauseCommandStatus

    public init(revision: Int, status: ProtectionPauseCommandStatus) {
        self.revision = revision
        self.status = status
    }
}

// Result of a sanity-capped stored-pause read. `clampedCappedPause` is true when the read
// found an over-cap pausedUntil and clamped it to nil (discarding the keys) — the signal a
// caller needs to reconcile protection-ON even when it held no prior pause of its own, so a
// clamp with no cache transition still republishes the Live Activity (UX-2, Codex #208).
public struct ProtectionCappedPauseRead: Equatable, Sendable {
    public let state: ProtectionPauseState?
    public let clampedCappedPause: Bool

    public init(state: ProtectionPauseState?, clampedCappedPause: Bool) {
        self.state = state
        self.clampedCappedPause = clampedCappedPause
    }
}

public struct ProtectionPauseStore: Sendable {
    public enum Keys {
        public static let pausedUntil = "lavasec.protection.temporaryPauseUntil"
        public static let pausedSessionID = "lavasec.protection.temporaryPauseSessionID"
        public static let commandRevision = "lavasec.protection.commandRevision"
        public static let lastCommandID = "lavasec.protection.lastCommandID"
    }

    // A stored pausedUntil more than this far past `now` cannot be a pause the
    // user could have set: the longest selectable pause is
    // LiveActivityPausePreference.maximumMinutes. `slack` absorbs the seconds
    // between writing the pause and reading it back so a legitimately-just-set
    // maximum pause is never clipped. Beyond the ceiling the read path DISCARDS the
    // pause (clears the keys; protection ON) — a backward wall-clock step or a corrupt
    // days-ahead pausedUntil must fail CLOSED, not leave filtering off for hours.
    public static let pauseSanityCapSlack: TimeInterval = 2 * 60
    // Public so the tunnel's cached hot-path pause read can re-apply the SAME ceiling — its
    // 1s refresh gate can wedge past a backward clock step and serve a stale far-future
    // pausedUntil without ever re-reading this store (UX-2, Codex #208).
    public static let maxPauseDuration =
        LiveActivityPausePreference.duration(forMinutes: LiveActivityPausePreference.maximumMinutes)
        + pauseSanityCapSlack

    private let storage: any ProtectionKeyValueStorage
    private let lock: any ProtectionCriticalSectionLock
    private let clock: any ProtectionClock

    public init(
        storage: any ProtectionKeyValueStorage,
        lock: any ProtectionCriticalSectionLock,
        clock: any ProtectionClock = SystemProtectionClock()
    ) {
        self.storage = storage
        self.lock = lock
        self.clock = clock
    }

    public func currentPauseState() throws -> ProtectionPauseState? {
        try lock.withCriticalSection {
            currentPauseStateUnlocked()
        }
    }

    public func currentRevision() throws -> Int {
        try lock.withCriticalSection {
            currentRevisionUnlocked()
        }
    }

    // Session-bound stored pause INCLUDING one whose window has already elapsed.
    // Callers that own expiry (the tunnel's resume timer) must observe the
    // stored state to know there is something to clear; currentPauseState()
    // hides expired pauses by design.
    public func storedPauseState() throws -> ProtectionPauseState? {
        try storedPauseStateApplyingSanityCap().state
    }

    // As storedPauseState(), but also reports whether it CLAMPED an over-cap pause to nil
    // (discarding the keys). A caller that reconciles on a cache TRANSITION alone would miss a
    // clamp that happened while it held no prior pause (an intent-written pause the tunnel never
    // learned via a reload message), stranding the Dynamic Island on paused while filtering is
    // back on — so the tunnel reconciles on this flag too (UX-2, Codex #208).
    public func storedPauseStateApplyingSanityCap() throws -> ProtectionCappedPauseRead {
        try lock.withCriticalSection {
            guard let activeSessionID = activeSessionIDUnlocked(),
                  let pausedSessionID = storage.string(forKey: Keys.pausedSessionID),
                  pausedSessionID == activeSessionID,
                  let pausedUntil = storage.date(forKey: Keys.pausedUntil)
            else {
                return ProtectionCappedPauseRead(state: nil, clampedCappedPause: false)
            }
            if exceedsPauseSanityCap(pausedUntil) {
                discardCappedPauseKeysUnlocked(pausedUntil: pausedUntil, sessionID: pausedSessionID)
                return ProtectionCappedPauseRead(state: nil, clampedCappedPause: true)
            }

            return ProtectionCappedPauseRead(
                state: ProtectionPauseState(
                    sessionID: activeSessionID,
                    pausedUntil: pausedUntil,
                    revision: currentRevisionUnlocked()
                ),
                clampedCappedPause: false
            )
        }
    }

    // Clears stored pause keys without minting a command revision: expiry and
    // session-boundary cleanup are observations, not user commands, and must
    // not invalidate newer Live Activity updates.
    public func clearStoredPause() throws {
        try lock.withCriticalSection {
            clearStoredPauseKeysUnlocked()
        }
    }

    @discardableResult
    public func pause(
        for duration: TimeInterval,
        requestedSessionID: String,
        commandID: String? = nil
    ) throws -> ProtectionPauseCommandResult {
        try lock.withCriticalSection {
            guard let activeSessionID = activeSessionIDUnlocked() else {
                return ProtectionPauseCommandResult(
                    revision: currentRevisionUnlocked(),
                    status: .rejected(.noActiveSession)
                )
            }

            guard activeSessionID == requestedSessionID else {
                return ProtectionPauseCommandResult(
                    revision: currentRevisionUnlocked(),
                    status: .rejected(.staleSession(activeSessionID: activeSessionID))
                )
            }

            if isDuplicateCommand(commandID) {
                return ProtectionPauseCommandResult(
                    revision: currentRevisionUnlocked(),
                    status: .unchanged(.duplicateCommand)
                )
            }

            let revision = nextRevisionUnlocked()
            let pausedUntil = clock.now.addingTimeInterval(duration)
            storage.set(pausedUntil, forKey: Keys.pausedUntil)
            storage.set(activeSessionID, forKey: Keys.pausedSessionID)
            storeLastCommandID(commandID)
            let state = ProtectionPauseState(
                sessionID: activeSessionID,
                pausedUntil: pausedUntil,
                revision: revision
            )
            return ProtectionPauseCommandResult(revision: revision, status: .changed(state))
        }
    }

    @discardableResult
    public func resume(requestedSessionID: String, commandID: String? = nil) throws -> ProtectionPauseCommandResult {
        try lock.withCriticalSection {
            if isDuplicateCommand(commandID) {
                return ProtectionPauseCommandResult(
                    revision: currentRevisionUnlocked(),
                    status: .unchanged(.duplicateCommand)
                )
            }

            guard hasStoredPauseStateUnlocked() else {
                return ProtectionPauseCommandResult(
                    revision: currentRevisionUnlocked(),
                    status: .unchanged(.noActivePause)
                )
            }

            if let activeSessionID = activeSessionIDUnlocked(),
               activeSessionID != requestedSessionID {
                return ProtectionPauseCommandResult(
                    revision: currentRevisionUnlocked(),
                    status: .rejected(.staleSession(activeSessionID: activeSessionID))
                )
            }

            let revision = nextRevisionUnlocked()
            storage.removeObject(forKey: Keys.pausedUntil)
            storage.removeObject(forKey: Keys.pausedSessionID)
            storeLastCommandID(commandID)
            return ProtectionPauseCommandResult(revision: revision, status: .changed(nil))
        }
    }

    private func currentPauseStateUnlocked() -> ProtectionPauseState? {
        guard let activeSessionID = activeSessionIDUnlocked(),
              let pausedSessionID = storage.string(forKey: Keys.pausedSessionID),
              pausedSessionID == activeSessionID,
              let pausedUntil = storage.date(forKey: Keys.pausedUntil),
              pausedUntil > clock.now
        else {
            return nil
        }
        if exceedsPauseSanityCap(pausedUntil) {
            discardCappedPauseKeysUnlocked(pausedUntil: pausedUntil, sessionID: pausedSessionID)
            return nil
        }

        return ProtectionPauseState(
            sessionID: activeSessionID,
            pausedUntil: pausedUntil,
            revision: currentRevisionUnlocked()
        )
    }

    // True when pausedUntil is further ahead than any user-settable pause could
    // reach — the signature of a backward clock step or a corrupt far-future
    // write.
    private func exceedsPauseSanityCap(_ pausedUntil: Date) -> Bool {
        pausedUntil.timeIntervalSince(clock.now) > Self.maxPauseDuration
    }

    // DISCARD, don't just hide, a capped pausedUntil (Codex #208): if the invalid keys
    // survived, the same value would re-enable the pause once `clock.now` moves or is
    // corrected to within the ceiling of that date. Clearing is an observation, not a user
    // command, so it mints no revision (same contract as clearStoredPause).
    //
    // COMPARE-AND-CLEAR (Codex #208): the read paths hold only this in-process `lock`, NOT
    // the cross-process command file lock, so `LavaProtectionCommandService.pause` in another
    // process may write a fresh valid pause between the `storage.date` read above and here.
    // Removing the keys unconditionally would silently delete it. Only clear if the stored
    // values STILL match the capped pair we read — a newer pause has a different (near-future)
    // pausedUntil, so it is left intact.
    //
    // RESIDUAL (accepted, fail-safe): the compare and the removes are not atomic w.r.t. the
    // cross-process writer, so a fresh pause written in the tiny window between them is dropped.
    // This is the SAME race class the tunnel's existing unlocked clears (expiry, session
    // begin/end via clearStoredPause) already carry — not one this cap introduces — and its
    // outcome is fail-safe: a dropped pause means protection stays ON (the user simply re-taps),
    // never off. Closing it would require serializing every reader against the command file
    // lock; on the tunnel DNS hot path a BLOCKING cross-process lock reintroduces the CON-1
    // stall class, so a full fix belongs in a separate change that makes ALL pause mutations
    // non-blocking cross-process (try-lock, drop-on-contention), not bolted onto this read cap.
    private func discardCappedPauseKeysUnlocked(pausedUntil: Date, sessionID: String) {
        guard storage.date(forKey: Keys.pausedUntil) == pausedUntil,
              storage.string(forKey: Keys.pausedSessionID) == sessionID
        else {
            return
        }
        clearStoredPauseKeysUnlocked()
    }

    private func clearStoredPauseKeysUnlocked() {
        storage.removeObject(forKey: Keys.pausedUntil)
        storage.removeObject(forKey: Keys.pausedSessionID)
    }

    private func hasStoredPauseStateUnlocked() -> Bool {
        storage.date(forKey: Keys.pausedUntil) != nil
            || storage.string(forKey: Keys.pausedSessionID) != nil
    }

    private func activeSessionIDUnlocked() -> String? {
        guard let sessionID = storage.string(forKey: ProtectionSessionStore.Keys.activeSessionID),
              !sessionID.isEmpty
        else {
            return nil
        }
        return sessionID
    }

    private func currentRevisionUnlocked() -> Int {
        storage.integer(forKey: Keys.commandRevision)
    }

    private func nextRevisionUnlocked() -> Int {
        let revision = currentRevisionUnlocked() + 1
        storage.set(revision, forKey: Keys.commandRevision)
        return revision
    }

    private func isDuplicateCommand(_ commandID: String?) -> Bool {
        guard let commandID = normalizedCommandID(commandID),
              let lastCommandID = storage.string(forKey: Keys.lastCommandID)
        else {
            return false
        }

        return commandID == lastCommandID
    }

    private func storeLastCommandID(_ commandID: String?) {
        guard let commandID = normalizedCommandID(commandID) else {
            return
        }

        storage.set(commandID, forKey: Keys.lastCommandID)
    }

    private func normalizedCommandID(_ commandID: String?) -> String? {
        guard let commandID = commandID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !commandID.isEmpty
        else {
            return nil
        }

        return commandID
    }
}
