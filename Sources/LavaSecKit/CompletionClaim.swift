import Foundation

/// Shared, thread-safe permission to settle one completion, including through copied wrappers.
/// pinned: CompletionClaimTests.testConcurrentExpiryAndCompletionHaveOneWinner
public final class CompletionClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Creates an unclaimed completion.
    public init() {}

    /// Returns true only for the first caller. Invoke callbacks after this method returns.
    public func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
