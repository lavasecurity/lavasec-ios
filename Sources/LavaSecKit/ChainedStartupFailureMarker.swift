import Darwin
import Foundation

/// Cross-process marker for a chained tunnel start that was refused.
///
/// A provider can be started by iOS Connect-On-Demand while the containing app is suspended, so
/// the provider's NSError is not a reliable state store. Production callers use a small, atomic
/// App Group control-plane file written before a failed completion/cancel and read by the app on
/// its next status observation. It keeps the saved chaining preference intact, but makes the live
/// protection state available to both processes. Durably confirmed recoverable surrender preserves
/// filtered DNS-only recovery; other confirmed reasons authorize terminal reconciliation. The provider's
/// ``ChainedStartupContract`` remains the start gate. UserDefaults is an in-memory test adapter.
public enum ChainedStartupFailureMarker {
    /// Shared-defaults key carrying the safe, non-sensitive refusal classification.
    public static let defaultsKey = "lavasec.protection.chainedStartupFailureReason"
    /// Monotonic retry revision written beside the refusal. A provider captures
    /// this revision at start; a retired provider cannot recreate its marker
    /// after an explicit retry advances it.
    public static let generationDefaultsKey = "lavasec.protection.chainedStartupFailureGeneration"
    /// Test-adapter equivalent of the production file's explicit-retry handoff bit.
    private static let explicitRetryRequestedDefaultsKey =
        "lavasec.protection.chainedStartupFailureExplicitRetryRequested"

    /// The marker state that belongs to one explicit-retry revision.
    public struct State: Equatable, Sendable {
        /// The refusal classification, or `nil` when no failure is pending.
        public let reason: String?
        /// The explicit-retry revision this state belongs to. Zero is a fresh install or the
        /// legacy marker shape.
        public let generation: UInt64
        /// A widget/intent may request an explicit retry without having the tunnel's
        /// Keychain entitlement. The provider consumes this bit before it latches the
        /// chained data path, so a Live Activity restart repairs the same suppression as
        /// an in-app Guard start.
        public let explicitRetryRequested: Bool

        /// Memberwise initializer. `explicitRetryRequested` defaults to `false` so decoding a
        /// marker written before the handoff bit existed yields a clean, non-requesting state.
        public init(
            reason: String?,
            generation: UInt64,
            explicitRetryRequested: Bool = false
        ) {
            self.reason = reason
            self.generation = generation
            self.explicitRetryRequested = explicitRetryRequested
        }
    }

    /// Failures reading or atomically replacing the production marker file. An unreadable marker
    /// is never treated as absent: the provider fails closed until the file can be read again.
    public enum StorageError: Error, Equatable, Sendable {
        case corrupt
        case unreadable(String)
        case protectionClassFailed
    }

    private struct PersistedState: Codable, Sendable {
        let reason: String?
        let generation: UInt64
        let explicitRetryRequested: Bool

        private enum CodingKeys: String, CodingKey {
            case reason
            case generation
            case explicitRetryRequested
        }

        init(reason: String?, generation: UInt64, explicitRetryRequested: Bool) {
            self.reason = reason
            self.generation = generation
            self.explicitRetryRequested = explicitRetryRequested
        }

        /// The marker file predates the explicit-retry handoff bit. Missing that key is
        /// therefore a clean, non-requesting state rather than a corrupt file.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
            generation = try container.decode(UInt64.self, forKey: .generation)
            explicitRetryRequested = try container.decodeIfPresent(
                Bool.self, forKey: .explicitRetryRequested) ?? false
        }
    }

    /// Reads the marker and its revision. Callers that coordinate a cross-process
    /// write should use the `lockURL` overload below.
    public static func state(in defaults: UserDefaults) -> State {
        State(
            reason: reason(in: defaults),
            generation: currentGeneration(in: defaults),
            explicitRetryRequested: defaults.bool(forKey: explicitRetryRequestedDefaultsKey))
    }

    /// Reads the marker under the shared lifecycle lock. An unavailable lock is
    /// surfaced rather than guessed through: starting a chained tunnel without
    /// knowing whether it is terminal is not safe.
    public static func state(
        in defaults: UserDefaults,
        lockURL: URL?
    ) throws -> State {
        try withExclusiveAccess(at: lockURL) {
            state(in: defaults)
        }
    }

    /// Reads the atomically persisted production marker. An absent file is a clean, generation-0
    /// state; once written, the file remains present even when the reason is cleared so the retry
    /// revision cannot silently reset across a process restart.
    public static func state(
        from storageURL: URL,
        lockURL: URL?
    ) throws -> State {
        try withExclusiveAccess(at: lockURL) {
            try stateFromFile(at: storageURL)
        }
    }

    /// Returns the explicit-retry revision, with zero representing the legacy
    /// marker shape or a fresh install.
    public static func currentGeneration(in defaults: UserDefaults) -> UInt64 {
        guard let number = defaults.object(forKey: generationDefaultsKey) as? NSNumber else {
            return 0
        }
        let value = number.int64Value
        return value >= 0 ? UInt64(value) : 0
    }

    /// Advances the explicit retry revision and removes the old terminal marker.
    /// The caller must invoke this under `withExclusiveAccess` when another
    /// process can be recording a marker.
    @discardableResult
    public static func beginExplicitRetry(in defaults: UserDefaults) -> UInt64 {
        let current = currentGeneration(in: defaults)
        let next = current == UInt64.max ? 0 : current + 1
        defaults.set(Int(next), forKey: generationDefaultsKey)
        defaults.removeObject(forKey: defaultsKey)
        defaults.set(true, forKey: explicitRetryRequestedDefaultsKey)
        return next
    }

    /// Locked convenience for the app's explicit Guard boundaries.
    @discardableResult
    public static func beginExplicitRetry(
        in defaults: UserDefaults,
        lockURL: URL?
    ) throws -> UInt64 {
        try withExclusiveAccess(at: lockURL) {
            beginExplicitRetry(in: defaults)
        }
    }

    /// Advances the production marker revision and atomically clears its terminal reason.
    @discardableResult
    public static func beginExplicitRetry(
        storageURL: URL,
        lockURL: URL?
    ) throws -> UInt64 {
        try withExclusiveAccess(at: lockURL) {
            do {
                let current = try stateFromFile(at: storageURL)
                let next = nextGeneration(after: current.generation)
                try writeFile(
                    State(reason: nil, generation: next, explicitRetryRequested: true),
                    to: storageURL)
                return next
            } catch StorageError.corrupt {
                // A user-initiated retry is also the recovery boundary for a torn or
                // hand-edited marker. We do not know the retired provider's generation in
                // this case, so a fresh non-zero nonce fences every stale writer instead of
                // allowing a corrupt file to make the retry impossible forever.
                let freshGeneration = freshRecoveryGeneration()
                try writeFile(
                    State(
                        reason: nil,
                        generation: freshGeneration,
                        explicitRetryRequested: true),
                    to: storageURL)
                return freshGeneration
            }
        }
    }

    /// Consumes the provider-side half of an explicit retry. The Keychain suppression is
    /// reset first by the provider; this compare-and-set then clears the handoff bit so a
    /// later automatic start cannot repeat the reset indefinitely.
    @discardableResult
    public static func consumeExplicitRetryRequest(
        generation: UInt64,
        storageURL: URL,
        lockURL: URL?
    ) throws -> Bool {
        try withExclusiveAccess(at: lockURL) {
            let current = try stateFromFile(at: storageURL)
            guard current.generation == generation, current.explicitRetryRequested else {
                return false
            }
            try writeFile(
                State(
                    reason: current.reason,
                    generation: current.generation,
                    explicitRetryRequested: false),
                to: storageURL)
            return true
        }
    }

    /// Records the latest refusal. Empty values are normalized so presence is unambiguous.
    public static func record(reason: String, in defaults: UserDefaults) {
        _ = record(
            reason: reason,
            generation: currentGeneration(in: defaults),
            in: defaults)
    }

    /// Records a refusal only if it still belongs to the provider's captured
    /// retry revision. This is the compare-and-set half of the stale-provider
    /// fence; callers use the locked overload in production.
    @discardableResult
    public static func record(
        reason: String,
        generation: UInt64,
        in defaults: UserDefaults
    ) -> Bool {
        guard currentGeneration(in: defaults) == generation else {
            return false
        }
        let value = reason.isEmpty ? "unknown" : reason
        defaults.set(value, forKey: defaultsKey)
        defaults.set(Int(generation), forKey: generationDefaultsKey)
        defaults.removeObject(forKey: explicitRetryRequestedDefaultsKey)
        return true
    }

    /// Locked convenience for provider-side refusal publication.
    @discardableResult
    public static func record(
        reason: String,
        generation: UInt64,
        in defaults: UserDefaults,
        lockURL: URL?
    ) throws -> Bool {
        try withExclusiveAccess(at: lockURL) {
            record(reason: reason, generation: generation, in: defaults)
        }
    }

    /// Atomically records a production refusal only if the provider still owns the captured
    /// retry revision. The compare-and-set and replacement happen under the marker-only lock.
    ///
    /// A corrupt file is REPAIRED here rather than refused, which is the opposite of
    /// ``clear(generation:storageURL:lockURL:)``. The asymmetry is deliberate and is about which
    /// way each operation fails: refusing to publish leaves no terminal gate at all, so an armed
    /// Connect-On-Demand profile relaunches a provider that fails, forever — the exact loop this
    /// type exists to stop, and unrecoverable while the containing app is suspended. Refusing to
    /// clear merely keeps a gate that an explicit retry or a proven start will lift. A corrupt file
    /// also carries no revision, so no fence can be honoured and someone has to win; a later
    /// explicit retry supersedes this write with a fresh random generation.
    /// pinned: ChainedStartupFailureMarkerTests.testATerminalRefusalRepairsACorruptMarker
    @discardableResult
    public static func record(
        reason: String,
        generation: UInt64,
        storageURL: URL,
        lockURL: URL?
    ) throws -> Bool {
        try withExclusiveAccess(at: lockURL) {
            let current: State
            do {
                current = try stateFromFile(at: storageURL)
            } catch StorageError.corrupt {
                try writeFile(
                    State(
                        reason: normalizedReason(reason),
                        generation: generation,
                        explicitRetryRequested: false),
                    to: storageURL)
                return true
            }
            guard current.generation == generation else {
                return false
            }
            try writeFile(
                State(
                    reason: normalizedReason(reason),
                    generation: generation,
                    explicitRetryRequested: false),
                to: storageURL)
            return true
        }
    }

    /// Removes the terminal marker at an explicit recovery boundary or after a successful start.
    public static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: explicitRetryRequestedDefaultsKey)
    }

    /// Clears a marker only when the caller still owns the revision it captured
    /// at start. A late success from an old provider therefore cannot erase a
    /// newer lifecycle's terminal marker.
    @discardableResult
    public static func clear(
        generation: UInt64,
        in defaults: UserDefaults
    ) -> Bool {
        guard currentGeneration(in: defaults) == generation else {
            return false
        }
        clear(in: defaults)
        return true
    }

    /// Locked convenience for provider-side success publication.
    @discardableResult
    public static func clear(
        generation: UInt64,
        in defaults: UserDefaults,
        lockURL: URL?
    ) throws -> Bool {
        try withExclusiveAccess(at: lockURL) {
            clear(generation: generation, in: defaults)
        }
    }

    /// Atomically clears a production refusal only if the provider still owns the captured
    /// retry revision. A late success from an old provider therefore cannot erase a newer marker.
    @discardableResult
    public static func clear(
        generation: UInt64,
        storageURL: URL,
        lockURL: URL?
    ) throws -> Bool {
        try withExclusiveAccess(at: lockURL) {
            let current = try stateFromFile(at: storageURL)
            guard current.generation == generation else {
                return false
            }
            try writeFile(
                State(reason: nil, generation: generation, explicitRetryRequested: false),
                to: storageURL)
            return true
        }
    }

    /// Runs one marker read/compare-and-set transition under the marker's own
    /// bounded file lock. This lock is deliberately distinct from the chained
    /// lifecycle-evidence lock: a timed-out Keychain worker can remain inside
    /// that lock after the caller has moved on, but the terminal automatic-start
    /// gate must still be durable before the provider cancels.
    ///
    /// The optional URL keeps unsigned host tests and local builds functional,
    /// while installed app/tunnel targets always pass their App Group lock.
    public static func withExclusiveAccess<T>(
        at lockURL: URL?,
        _ operation: () throws -> T
    ) throws -> T {
        guard let lockURL else {
            return try operation()
        }
        return try ChainedStartupFailureMarkerFileLock.withExclusiveAccess(
            at: lockURL,
            operation)
    }

    /// Returns the persisted marker state, classifying a missing file as clean and every other
    /// read/decode failure as unavailable. This is intentionally a fresh file read on every
    /// operation; unlike UserDefaults, the provider and app cannot carry stale process-local state.
    private static func stateFromFile(at storageURL: URL) throws -> State {
        switch SharedStateFileReader.read(PersistedState.self, from: storageURL) {
        case let .loaded(persisted):
            return State(
                reason: normalizedReason(persisted.reason ?? ""),
                generation: persisted.generation,
                explicitRetryRequested: persisted.explicitRetryRequested)
        case .absent:
            return State(reason: nil, generation: 0)
        case .corrupt:
            throw StorageError.corrupt
        case let .unreadable(description):
            throw StorageError.unreadable(description)
        }
    }

    /// Replaces the complete marker tuple atomically and stamps it as a Class-None control-plane
    /// file on iOS. The atomic replacement is the crash barrier between surrender and cancellation.
    private static func writeFile(_ state: State, to storageURL: URL) throws {
        let data = try JSONEncoder().encode(
            PersistedState(
                reason: state.reason,
                generation: state.generation,
                explicitRetryRequested: state.explicitRetryRequested))
        try data.write(
            to: storageURL,
            options: SharedStateFileProtection.atomicControlPlaneWritingOptions)
        guard SharedStateFileProtection.applyControlPlaneProtection(at: storageURL) else {
            throw StorageError.protectionClassFailed
        }
    }

    private static func normalizedReason(_ reason: String) -> String? {
        reason.isEmpty ? nil : reason
    }

    private static func nextGeneration(after generation: UInt64) -> UInt64 {
        generation == UInt64.max ? 0 : generation + 1
    }

    private static func freshRecoveryGeneration() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        return UInt64.random(in: 1...UInt64.max, using: &generator)
    }

    /// Returns the refusal classification when a terminal failure is pending.
    public static func reason(in defaults: UserDefaults) -> String? {
        guard let value = defaults.string(forKey: defaultsKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Whether any refusal is recorded, including a recoverable surrender.
    public static func isMarked(in defaults: UserDefaults) -> Bool {
        reason(in: defaults) != nil
    }

    /// Returns the production marker reason. An unavailable marker is deliberately not a
    /// terminal reason: callers that need to distinguish a transient read failure should use
    /// ``observation(from:lockURL:)``. The separate ``isMarked(storageURL:lockURL:)`` API remains
    /// fail-closed for automatic restore decisions.
    public static func reason(from storageURL: URL, lockURL: URL?) -> String? {
        do {
            return try state(from: storageURL, lockURL: lockURL).reason
        } catch {
            return nil
        }
    }

    /// Classifies one production marker read without turning a transient lock/file failure
    /// into a destructive terminal OFF transition.
    public enum Observation: Equatable, Sendable {
        case clear
        case marked(String, generation: UInt64)
        case unavailable

        /// A confirmed reason that requires explicit recovery; transient reads and surrenders
        /// a network change can repair never authorize a destructive OFF transition.
        public var terminalReason: String? {
            guard case let .marked(reason, _) = self,
                !ChainedSurrenderReason.markerReasonIsRecoverableSurrender(reason),
                !ChainedStartupFailureMarker.markerReasonIsRetryable(reason)
            else { return nil }
            return reason
        }
    }

    /// Refusal reasons a later start can clear without user action: the device was locked or
    /// the upstream secret was not yet readable. The spellings mirror
    /// ``TunnelDataPathLatch/Refusal/logValue``; the consistency test keeps the two in step.
    /// pinned: ChainedStartupFailureMarkerTests.testRetryableRefusalReasonsNeverAuthorizeTerminalReconciliation
    public static func markerReasonIsRetryable(_ reason: String) -> Bool {
        switch reason {
        case TunnelDataPathLatch.Refusal.configurationUnreadable.logValue,
             TunnelDataPathLatch.Refusal.deviceStateUnavailable.logValue:
            return true
        default:
            return false
        }
    }

    /// Reads the production marker as a three-way ``Observation``.
    ///
    /// Prefer this over ``reason(from:lockURL:)`` and ``isMarked(storageURL:lockURL:)`` wherever a
    /// caller is about to take a destructive action: those two collapse a transient lock/read
    /// failure into "clean" and "marked" respectively, while a terminal OFF reconciliation must
    /// only ever run against a confirmed ``marked`` reason.
    public static func observation(
        from storageURL: URL,
        lockURL: URL?
    ) -> Observation {
        do {
            let state = try state(from: storageURL, lockURL: lockURL)
            if let reason = state.reason {
                return .marked(reason, generation: state.generation)
            }
            return .clear
        } catch {
            return .unavailable
        }
    }

    /// Whether a production marker is present. An unreadable marker is treated as present so an
    /// app-side restore cannot race a provider that is unable to establish its terminal state.
    public static func isMarked(storageURL: URL, lockURL: URL?) -> Bool {
        do {
            return try state(from: storageURL, lockURL: lockURL).reason != nil
        } catch {
            return true
        }
    }
}

/// A marker-only bounded lock domain.
///
/// This cannot share ``ChainedLifecycleEvidenceFileLock``'s process lock: the
/// surrender path intentionally abandons a timed-out Keychain worker, and that
/// worker may still hold the lifecycle-evidence lock while the provider must
/// publish this terminal gate. A separate lock file and process-local mutex let
/// the marker transition complete without waiting for the uninterruptible
/// Keychain call, while still serializing marker revisions across app/tunnel
/// processes.
private enum ChainedStartupFailureMarkerFileLock {
    private static let inProcessLock = NSLock()
    private static let lockWaitSeconds: TimeInterval = 0.25
    private static let retryDelayMicroseconds: useconds_t = 5_000

    static func withExclusiveAccess<T>(
        at lockURL: URL,
        _ operation: () throws -> T
    ) throws -> T {
        guard inProcessLock.lock(before: Date(timeIntervalSinceNow: lockWaitSeconds)) else {
            throw ChainedDeviceStateStoreFailure.coordinationBusy
        }
        defer { inProcessLock.unlock() }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw ChainedDeviceStateStoreFailure.coordinationOpenFailed(errno)
        }
        defer { close(descriptor) }

        guard SharedStateFileProtection.applyControlPlaneProtection(at: lockURL) else {
            throw ChainedDeviceStateStoreFailure.coordinationProtectionFailed
        }

        let deadline = Date(timeIntervalSinceNow: lockWaitSeconds)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let errorCode = errno
            guard errorCode == EWOULDBLOCK || errorCode == EAGAIN else {
                throw ChainedDeviceStateStoreFailure.coordinationLockFailed(errorCode)
            }
            guard Date() < deadline else {
                throw ChainedDeviceStateStoreFailure.coordinationBusy
            }
            usleep(retryDelayMicroseconds)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
