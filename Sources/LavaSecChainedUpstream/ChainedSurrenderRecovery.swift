/// The order of a surrender's two effects, held as a testable property rather than a comment.
///
/// C4's crash window: the suppression must be durable BEFORE the restart begins, or a crash
/// between the two wakes into a latch that still selects chained — and the blackhole the
/// surrender just ended comes back wearing a fresh session. And a persist FAILURE must not
/// block the restart: a suppression that could not persist is still honoured for this
/// lifecycle by the driver's own `hasSurrendered` latch, while refusing to restart leaves
/// the claimed default route with no data path — the state C4 exists to end.
/// `ChainedDeviceEligibilityStore.recordChainedSurrender` argues both halves from the
/// store's side; this type is the caller's side, small enough to prove.
public enum ChainedSurrenderRecovery {
    public enum PersistOutcome: Equatable, Sendable {
        case persisted
        /// The restart still ran; the payload is a log detail, never user copy.
        case persistFailed(String)
    }

    /// Persists FIRST, restarts ALWAYS.
    ///
    /// Runs wherever the surrender sink runs — the engine queue — so neither closure may
    /// touch `dnsStateQueue`; the persist is a Keychain write and the restart an NE call,
    /// both queue-free.
    /// pinned: ChainedSurrenderRecoveryTests.testTheSuppressionIsDurableBeforeTheRestartBegins
    /// pinned: ChainedSurrenderRecoveryTests.testAFailedPersistStillRestarts
    @discardableResult
    public static func perform(
        persistSuppression: () throws -> Void,
        restartIntoDNSOnly: () -> Void
    ) -> PersistOutcome {
        let outcome: PersistOutcome
        do {
            try persistSuppression()
            outcome = .persisted
        } catch {
            outcome = .persistFailed(String(describing: error))
        }
        restartIntoDNSOnly()
        return outcome
    }
}
