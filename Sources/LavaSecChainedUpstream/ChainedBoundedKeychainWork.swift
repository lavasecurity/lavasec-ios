import Foundation

/// Bounds a Keychain round-trip that a latency-critical path performs.
///
/// The generalisation of the lesson `ChainedBoundedCredentialRead` learned: bounding ONE
/// store read does not bound the path, because every sibling `SecItemCopyMatching` /
/// `SecItemUpdate` on the same code path can block on the same wedged security daemon.
/// Three such siblings sit on paths whose whole purpose is to be prompt (Codex, PR #508):
/// the construction downgrade — which must reach the DNS-only relatch and let `startTunnel`
/// install fail-safe settings — and the surrender persist, which must not delay the restart
/// that ends a blackhole.
///
/// Throwing on timeout is what makes this composable: both callers already treat a throw as
/// "carry on with the safe action" (`ChainedSurrenderRecovery` restarts anyway; the
/// downgrade logs and relatches), so a wedged store degrades to exactly the behaviour those
/// paths already define for a store that refuses.
public enum ChainedBoundedKeychainWork {
    /// Two seconds, the same bound and the same reasoning as the credential read: far above
    /// a healthy round-trip, far below any deadline these paths participate in.
    public static let defaultTimeoutMilliseconds =
        ChainedBoundedCredentialRead.defaultTimeoutMilliseconds

    /// The store did not answer inside the bound. The caller proceeds with its safe action.
    public struct TimedOut: Error, Equatable {}

    /// Runs `work` off the caller's queue and waits at most the bound.
    ///
    /// A late completion cannot be cancelled — `SecItem*` has no cancellation — so the
    /// closure is handed `isStillWanted` and MUST consult it immediately before any
    /// mutation. "A late write is still the write they wanted" was wrong, and Codex
    /// (PR #508) falsified it: the caller has already moved on, so a late settle can clear
    /// a marker the NEXT lifecycle just wrote, and a late surrender can restore a
    /// suppression the user just Reset — resurrecting exactly the states the single-record
    /// shape exists to make unrepresentable.
    ///
    /// The fence is a check, not a transaction: `SecItem` offers no compare-and-swap, so a
    /// timeout landing between the check and the write is still possible. The store performs
    /// this check inside its lifecycle transaction, immediately before the guarded write, so
    /// another lifecycle-record mutation cannot interleave in that final window. Reads are
    /// unfenced deliberately: a late read mutates nothing.
    /// pinned: ChainedBoundedKeychainWorkTests.testAWedgedStoreTimesOutInsteadOfBlockingTheCaller
    /// pinned: ChainedBoundedKeychainWorkTests.testTheWorksOwnErrorTravelsUnchanged
    /// pinned: ChainedBoundedKeychainWorkTests.testATimedOutWorkIsToldToStandDownBeforeItWrites
    public static func perform(
        timeoutMilliseconds: Int = ChainedBoundedKeychainWork.defaultTimeoutMilliseconds,
        work: @escaping @Sendable (_ isStillWanted: @Sendable () -> Bool) throws -> Void
    ) throws {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.store(Result { try work({ !box.isAbandoned }) })
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .milliseconds(max(1, timeoutMilliseconds)))
        guard let result = box.takeOrAbandon() else { throw TimedOut() }
        try result.get()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?
        private var abandoned = false

        /// The waiter gave up: every later mutation must stand down.
        var isAbandoned: Bool {
            lock.lock()
            defer { lock.unlock() }
            return abandoned
        }

        func store(_ value: Result<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            result = value
        }

        /// Takes the result, or marks the box abandoned so a still-running closure's
        /// `isStillWanted` answers false before it writes.
        func takeOrAbandon() -> Result<Void, Error>? {
            lock.lock()
            defer { lock.unlock() }
            if let result { return result }
            abandoned = true
            return nil
        }
    }
}
