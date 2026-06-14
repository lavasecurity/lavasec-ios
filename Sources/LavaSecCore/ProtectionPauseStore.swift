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

public struct ProtectionPauseStore: Sendable {
    public enum Keys {
        public static let pausedUntil = "lavasec.protection.temporaryPauseUntil"
        public static let pausedSessionID = "lavasec.protection.temporaryPauseSessionID"
        public static let commandRevision = "lavasec.protection.commandRevision"
        public static let lastCommandID = "lavasec.protection.lastCommandID"
    }

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
        try lock.withCriticalSection {
            guard let activeSessionID = activeSessionIDUnlocked(),
                  let pausedSessionID = storage.string(forKey: Keys.pausedSessionID),
                  pausedSessionID == activeSessionID,
                  let pausedUntil = storage.date(forKey: Keys.pausedUntil)
            else {
                return nil
            }

            return ProtectionPauseState(
                sessionID: activeSessionID,
                pausedUntil: pausedUntil,
                revision: currentRevisionUnlocked()
            )
        }
    }

    // Clears stored pause keys without minting a command revision: expiry and
    // session-boundary cleanup are observations, not user commands, and must
    // not invalidate newer Live Activity updates.
    public func clearStoredPause() throws {
        try lock.withCriticalSection {
            storage.removeObject(forKey: Keys.pausedUntil)
            storage.removeObject(forKey: Keys.pausedSessionID)
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

        return ProtectionPauseState(
            sessionID: activeSessionID,
            pausedUntil: pausedUntil,
            revision: currentRevisionUnlocked()
        )
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
