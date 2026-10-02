import Foundation

/// The two lifecycle directions that compete for the shared protection lease.
public enum ProtectionLifecycleLeaseOwner: String, Equatable, Sendable {
    /// Background restoration of an explicitly enabled protection configuration.
    case automaticRestore
    /// A direct Restart command accepted from the Live Activity or Dynamic Island.
    case explicitRestart
}

/// A compare-and-set lease that excludes cross-process protection lifecycle work.
///
/// The expiry is crash recovery, not the normal release path. Owners renew while their async work
/// remains live and release by token so an expired owner can never clear a newer claim.
public struct ProtectionLifecycleLease: Equatable, Sendable {
    /// Unpredictable compare-and-set identity for this exact owner instance.
    public let token: String
    /// Direction of lifecycle work holding the lease.
    public let owner: ProtectionLifecycleLeaseOwner
    /// Crash-recovery deadline; live asynchronous owners renew before it passes.
    public let expiresAt: Date

    /// Creates the immutable identity returned by an atomic lease claim.
    public init(token: String, owner: ProtectionLifecycleLeaseOwner, expiresAt: Date) {
        self.token = token
        self.owner = owner
        self.expiresAt = expiresAt
    }
}

/// A strict snapshot of the durable generation rotated by every accepted direct restart.
///
/// The wrapper is intentionally distinct from `String?`: `nil` is a legitimate initial generation,
/// while failure to read the shared state must throw rather than masquerade as that initial value.
public struct ProtectionExternalRestartGenerationSnapshot: Equatable, Sendable {
    /// Durable generation value, including `nil` before the first accepted direct Restart.
    public let value: String?

    /// Wraps a successfully read generation so it cannot be confused with a failed read.
    public init(value: String?) {
        self.value = value
    }
}

/// Persistent, lock-agnostic lifecycle coordination shared by the app and App Intent process.
///
/// Callers provide the same cross-process critical-section lock around the same App Group storage.
/// An accepted explicit restart rotates `externalRestartGeneration`; an automatic restore must
/// compare the generation it captured before its first suspension in the same critical section
/// that installs its lease. That closes both restart-before-restore and restore-before-restart.
public struct ProtectionLifecycleLeaseStore: Sendable {
    /// Stable persisted field names shared by file-backed and test storage adapters.
    public enum Keys {
        /// Persisted lease-owner field.
        public static let owner = "lavasec.protection.lifecycleLeaseOwner"
        /// Persisted compare-and-set token field.
        public static let token = "lavasec.protection.lifecycleLeaseToken"
        /// Persisted crash-recovery deadline field.
        public static let expiresAt = "lavasec.protection.lifecycleLeaseExpiresAt"
        /// Persisted generation rotated by every accepted explicit Restart.
        public static let externalRestartGeneration = "lavasec.protection.externalRestartGeneration"
    }

    private let storage: any ProtectionKeyValueStorage
    private let lock: any ProtectionCriticalSectionLock
    private let clock: any ProtectionClock
    private let makeToken: @Sendable () -> String

    /// Creates a store over caller-supplied persistence and critical-section primitives.
    public init(
        storage: any ProtectionKeyValueStorage,
        lock: any ProtectionCriticalSectionLock,
        clock: any ProtectionClock = SystemProtectionClock(),
        makeToken: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.storage = storage
        self.lock = lock
        self.clock = clock
        self.makeToken = makeToken
    }

    /// Reads the durable generation rotated by the latest accepted explicit Restart.
    public func currentExternalRestartGeneration() throws -> String? {
        try lock.withCriticalSection {
            storage.string(forKey: Keys.externalRestartGeneration)
        }
    }

    /// Strictly captures the external-Restart generation, preserving legitimate initial `nil`.
    public func captureExternalRestartGeneration() throws -> ProtectionExternalRestartGenerationSnapshot {
        try lock.withCriticalSection {
            ProtectionExternalRestartGenerationSnapshot(
                value: storage.string(forKey: Keys.externalRestartGeneration)
            )
        }
    }

    /// Returns whether shared state still matches an earlier strict generation capture.
    public func matchesExternalRestartGeneration(
        _ snapshot: ProtectionExternalRestartGenerationSnapshot
    ) throws -> Bool {
        try lock.withCriticalSection {
            storage.string(forKey: Keys.externalRestartGeneration) == snapshot.value
        }
    }

    /// Returns the current live lease, clearing an expired or malformed persisted record.
    public func currentLease() throws -> ProtectionLifecycleLease? {
        try lock.withCriticalSection {
            currentLiveLeaseUnlocked()
        }
    }

    /// Returns whether the caller still owns the live lease identified by this token.
    /// Expiry is intentionally read from storage because renewal extends it without mutating the
    /// original value held by the async owner.
    public func isOwned(_ lease: ProtectionLifecycleLease) throws -> Bool {
        try lock.withCriticalSection {
            guard let current = currentLiveLeaseUnlocked() else {
                return false
            }
            return current.owner == lease.owner && current.token == lease.token
        }
    }

    /// Atomically validates the request's external generation and installs an automatic-restore
    /// lease. A restart accepted after capture either owns the live lease or changed the generation;
    /// either condition rejects this claim.
    public func claimAutomaticRestore(
        expectedExternalRestartGeneration: String?,
        leaseDuration: TimeInterval
    ) throws -> ProtectionLifecycleLease? {
        precondition(leaseDuration > 0)
        return try lock.withCriticalSection {
            guard storage.string(forKey: Keys.externalRestartGeneration)
                    == expectedExternalRestartGeneration,
                  currentLiveLeaseUnlocked() == nil
            else {
                return nil
            }

            return installLeaseUnlocked(owner: .automaticRestore, duration: leaseDuration)
        }
    }

    /// Installs an explicit-restart lease and rotates the durable generation as one atomic claim.
    /// A rejected claim leaves the generation untouched because no restart was accepted.
    public func claimExplicitRestart(leaseDuration: TimeInterval) throws -> ProtectionLifecycleLease? {
        precondition(leaseDuration > 0)
        return try lock.withCriticalSection {
            guard currentLiveLeaseUnlocked() == nil else {
                return nil
            }

            let lease = installLeaseUnlocked(owner: .explicitRestart, duration: leaseDuration)
            storage.set(lease.token, forKey: Keys.externalRestartGeneration)
            return lease
        }
    }

    /// Extends a still-live owned lease. Once expired or replaced, a stale owner cannot revive it.
    @discardableResult
    public func renew(_ lease: ProtectionLifecycleLease, leaseDuration: TimeInterval) throws -> Bool {
        precondition(leaseDuration > 0)
        return try lock.withCriticalSection {
            guard let current = currentLiveLeaseUnlocked(),
                  current.owner == lease.owner,
                  current.token == lease.token
            else {
                return false
            }

            storage.set(clock.now.addingTimeInterval(leaseDuration), forKey: Keys.expiresAt)
            return true
        }
    }

    /// Releases only the exact owner/token pair. The expiry is deliberately not compared because
    /// normal cleanup may run just after the deadline, before another owner has claimed the slot.
    @discardableResult
    public func release(_ lease: ProtectionLifecycleLease) throws -> Bool {
        try lock.withCriticalSection {
            guard storage.string(forKey: Keys.owner) == lease.owner.rawValue,
                  storage.string(forKey: Keys.token) == lease.token
            else {
                return false
            }

            clearLeaseUnlocked()
            return true
        }
    }

    private func installLeaseUnlocked(
        owner: ProtectionLifecycleLeaseOwner,
        duration: TimeInterval
    ) -> ProtectionLifecycleLease {
        let lease = ProtectionLifecycleLease(
            token: makeToken(),
            owner: owner,
            expiresAt: clock.now.addingTimeInterval(duration)
        )
        storage.set(lease.owner.rawValue, forKey: Keys.owner)
        storage.set(lease.token, forKey: Keys.token)
        storage.set(lease.expiresAt, forKey: Keys.expiresAt)
        return lease
    }

    private func currentLiveLeaseUnlocked() -> ProtectionLifecycleLease? {
        guard let ownerRaw = storage.string(forKey: Keys.owner),
              let owner = ProtectionLifecycleLeaseOwner(rawValue: ownerRaw),
              let token = storage.string(forKey: Keys.token),
              !token.isEmpty,
              let expiresAt = storage.date(forKey: Keys.expiresAt),
              expiresAt > clock.now
        else {
            clearLeaseUnlocked()
            return nil
        }

        return ProtectionLifecycleLease(token: token, owner: owner, expiresAt: expiresAt)
    }

    private func clearLeaseUnlocked() {
        storage.removeObject(forKey: Keys.owner)
        storage.removeObject(forKey: Keys.token)
        storage.removeObject(forKey: Keys.expiresAt)
    }
}
