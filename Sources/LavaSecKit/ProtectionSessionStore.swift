import Foundation

public enum ProtectionCommandRejection: Equatable, Sendable {
    case noActiveSession
    case staleSession(activeSessionID: String?)
}

public enum ProtectionSessionMutation: Equatable, Sendable {
    case changed(activeSessionID: String?)
    case unchanged(activeSessionID: String?)
    case rejected(ProtectionCommandRejection)
}

public struct ProtectionSessionStore: Sendable {
    public enum Keys {
        public static let activeSessionID = "lavasec.protection.activeSessionID"
    }

    private let storage: any ProtectionKeyValueStorage
    private let lock: any ProtectionCriticalSectionLock

    public init(
        storage: any ProtectionKeyValueStorage,
        lock: any ProtectionCriticalSectionLock
    ) {
        self.storage = storage
        self.lock = lock
    }

    public func activeSessionID() throws -> String? {
        try lock.withCriticalSection {
            activeSessionIDUnlocked()
        }
    }

    public func isActive(sessionID: String) throws -> Bool {
        try lock.withCriticalSection {
            activeSessionIDUnlocked() == sessionID
        }
    }

    @discardableResult
    public func setActiveSessionID(_ sessionID: String) throws -> ProtectionSessionMutation {
        try lock.withCriticalSection {
            let normalizedSessionID = normalized(sessionID)
            let currentSessionID = activeSessionIDUnlocked()

            guard currentSessionID != normalizedSessionID else {
                return .unchanged(activeSessionID: currentSessionID)
            }

            guard let normalizedSessionID else {
                return .unchanged(activeSessionID: currentSessionID)
            }

            storage.set(normalizedSessionID, forKey: Keys.activeSessionID)
            return .changed(activeSessionID: normalizedSessionID)
        }
    }

    @discardableResult
    public func clearActiveSessionID(matching sessionID: String) throws -> ProtectionSessionMutation {
        try lock.withCriticalSection {
            guard let currentSessionID = activeSessionIDUnlocked() else {
                return .rejected(.noActiveSession)
            }

            guard currentSessionID == sessionID else {
                return .rejected(.staleSession(activeSessionID: currentSessionID))
            }

            storage.removeObject(forKey: Keys.activeSessionID)
            return .changed(activeSessionID: nil)
        }
    }

    // Unconditional clear for session owners (the tunnel on stop, the app on
    // user-initiated turn-off): the owner ends whatever session exists.
    @discardableResult
    public func clearActiveSessionID() throws -> ProtectionSessionMutation {
        try lock.withCriticalSection {
            guard activeSessionIDUnlocked() != nil else {
                return .unchanged(activeSessionID: nil)
            }

            storage.removeObject(forKey: Keys.activeSessionID)
            return .changed(activeSessionID: nil)
        }
    }

    // Mints a fresh session id, becoming the active session owner.
    @discardableResult
    public func beginFreshSession(id sessionID: String = UUID().uuidString) throws -> String {
        try lock.withCriticalSection {
            storage.set(sessionID, forKey: Keys.activeSessionID)
            return sessionID
        }
    }

    // Returns the existing session id, or mints one when absent — the app uses
    // this when a pause command may arrive before the first explicit session.
    public func ensureActiveSessionID() throws -> String {
        try lock.withCriticalSection {
            if let sessionID = activeSessionIDUnlocked() {
                return sessionID
            }

            let sessionID = UUID().uuidString
            storage.set(sessionID, forKey: Keys.activeSessionID)
            return sessionID
        }
    }

    private func activeSessionIDUnlocked() -> String? {
        normalized(storage.string(forKey: Keys.activeSessionID))
    }

    private func normalized(_ sessionID: String?) -> String? {
        guard let sessionID, !sessionID.isEmpty else {
            return nil
        }
        return sessionID
    }
}
