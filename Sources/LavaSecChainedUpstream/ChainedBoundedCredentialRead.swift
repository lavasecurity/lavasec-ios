import Foundation

/// Bounds the one blocking read the session build performs on the engine queue.
///
/// `ChainedSessionSource`'s no-blocking contract "rests on prose" for the credential read,
/// and the prose stopped being enough the moment a real Keychain store filled the closure:
/// `SecItemCopyMatching` can block on the security daemon, the attempt watchdog fires on
/// the SAME serial engine queue, and its deadline is the outage deadline itself — so a
/// wedged securityd would hold the claimed default route blackholed past the budget the
/// watchdog exists to enforce (Codex, PR #508).
///
/// The resolution keeps every existing contract: the read stays fresh-per-attempt (no
/// cached key material — `testCredentialsAreReadPerAttemptRatherThanHeldByTheFactory`'s
/// rule), the build stays synchronous (C1's authorize-and-arm shape is untouched), and the
/// engine queue now waits AT MOST ``defaultTimeoutMilliseconds`` — chosen well under
/// `ChainedReconnectPolicy.minimumUsefulAttemptSeconds` — instead of waiting on securityd's
/// health. A timeout throws `ChainedSessionBuildFailure.credentialsUnavailable`, the
/// transient lane: the attempt spends a rung and the ladder retries, which is exactly what
/// a briefly-unanswerable store should cost. A read that completes AFTER the timeout is
/// scrubbed and discarded — its attempt already failed, and key material must not outlive
/// the box that has no consumer for it.
public enum ChainedBoundedCredentialRead {
    /// Two seconds: three orders of magnitude above a healthy securityd round-trip, and
    /// well under the 7 s `minimumUsefulAttemptSeconds` floor — so the worst-case watchdog
    /// deferral this wait can cause never eats an attempt the policy considered useful.
    public static let defaultTimeoutMilliseconds = 2_000

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var delivered: Result<ChainedSessionCredentials, Error>?
        private var abandoned = false

        /// The reader's side: hand over the result, or learn nobody is waiting.
        /// Returns `false` when the wait already timed out — the caller must scrub.
        func deliver(_ result: Result<ChainedSessionCredentials, Error>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !abandoned else { return false }
            delivered = result
            return true
        }

        /// The waiter's side: take the result, or mark the box abandoned so a late
        /// delivery knows to scrub.
        func takeOrAbandon() -> Result<ChainedSessionCredentials, Error>? {
            lock.lock()
            defer { lock.unlock() }
            if let delivered { return delivered }
            abandoned = true
            return nil
        }
    }

    /// Runs `read` off the caller's queue and waits at most the bound.
    ///
    /// Called on the engine queue by the factory's `readCredentials` closure; the read
    /// itself runs on a global queue so the engine queue's wait — and therefore the
    /// watchdog's worst-case deferral — is the BOUND, never the read.
    /// pinned: ChainedBoundedCredentialReadTests.testAWedgedReadTimesOutIntoTheTransientLane
    /// pinned: ChainedBoundedCredentialReadTests.testALateReadIsScrubbedAndDiscarded
    public static func perform(
        timeoutMilliseconds: Int = ChainedBoundedCredentialRead.defaultTimeoutMilliseconds,
        read: @escaping @Sendable () throws -> ChainedSessionCredentials
    ) throws -> ChainedSessionCredentials {
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try read() }
            if !box.deliver(result) {
                // Nobody is waiting: this attempt already failed on the timeout. The key
                // material produced here has no consumer and must not linger.
                if case .success(let credentials) = result {
                    credentials.scrubSecrets()
                }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .milliseconds(max(1, timeoutMilliseconds)))
        guard let result = box.takeOrAbandon() else {
            throw ChainedSessionBuildFailure.credentialsUnavailable
        }
        return try result.get()
    }
}
