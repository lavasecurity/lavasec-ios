import Foundation

/// Coalesces concurrent biometric-authentication attempts onto a single in-flight evaluation.
///
/// The app's `.appSettings` surface is reachable from two independently-debounced handles — the Guard
/// long-press row selection (`guardianSelectionTask`) and the picker sheet's toggle / unlock links
/// (`appSettingsActionTask`). On the un-authenticated Guard long-press entry neither has a prior-turn
/// authentication to short-circuit, so without coalescing a *simultaneous* selection + toggle tap fans
/// out TWO `LAContext.evaluatePolicy` prompts — a Face ID prompt stacked on another (fan-out A;
/// Codex/OCR review on lavasec-ios#69). Each debounce handle only prevents a re-tap of its OWN surface.
///
/// This gate closes the cross-handle window at the source: a caller that arrives while an evaluation is
/// already in flight shares its result only within the same authorization scope. A newer turn waits
/// for the old OS prompt to finish before starting its own evaluation. It mirrors
/// the passcode-request coalescing in `SecurityController.requestPasscode` (which shares one presented
/// passcode sheet across waiters) so the biometric path is symmetric with it.
///
/// `@MainActor`-isolated: every caller (`SecurityController`) already runs on the main actor, so the
/// check-and-arm and the drain each occur without an interleaving suspension — no double-arm, no lost
/// waiter. It does NOT add cancellation to `evaluatePolicy` (which is not cancellation-aware); it only
/// ensures at most one prompt is outstanding.
///
/// - Note: This is a UI anti-fan-out gate, not a cryptographic boundary — see `INV-LOCK-1` on
///   `SecurityController.evaluateBiometrics`. Coalescing behaviour is pinned by
///   `BiometricAuthenticationCoalescerTests.testConcurrentAttemptsShareOneEvaluation`.
@MainActor
public final class BiometricAuthenticationCoalescer {
    /// The evaluation shared by every caller that arrives during a single prompt's lifetime, or `nil`
    /// when no prompt is outstanding. `Task<Bool, Never>` because `evaluatePolicy` reports a plain
    /// success `Bool` and never throws to the caller.
    private struct Evaluation {
        let id: UInt64
        let scope: UInt64?
        let task: Task<Bool, Never>
    }
    private var inFlight: Evaluation?
    private var nextID: UInt64 = 0

    /// Creates a coalescer with no evaluation in flight.
    public init() {}

    /// Serializes OS evaluations while sharing results only within one current authorization scope.
    /// Revoked callers receive false; their results cannot authorize a replacement turn.
    ///
    /// - Parameters:
    ///   - scope: View-authentication turn, or nil for the distinct foreground App Unlock owner.
    ///   - isCurrent: Whether this caller still owns its turn. Revoked callers cannot reuse results
    ///     or start replacement prompts after the OS finishes an earlier evaluation.
    ///   - evaluate: Performs one OS evaluation. Different turns serialize without sharing results.
    /// - Returns: The evaluation result only while this caller still owns its authorization scope.
    public func authenticate(
        scope: UInt64? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        _ evaluate: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        while let current = inFlight {
            let result = await current.task.value
            guard isCurrent() else { return false }
            if current.scope == scope { return result }
            // A newer owner waits for the old OS prompt to end. Its completion may resume this
            // caller before the original owner, so cleanup must be owned by the evaluation ID.
            if inFlight?.id == current.id { inFlight = nil }
        }
        guard isCurrent() else { return false }
        nextID += 1
        let id = nextID
        let task = Task { @MainActor in
            guard isCurrent() else { return false }
            return await evaluate()
        }
        inFlight = Evaluation(id: id, scope: scope, task: task)
        let result = await task.value
        if inFlight?.id == id { inFlight = nil }
        return isCurrent() && result
    }
}
