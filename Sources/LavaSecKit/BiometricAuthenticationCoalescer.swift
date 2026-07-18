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
/// already in flight awaits that SAME evaluation's result instead of starting another prompt. It mirrors
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
    private var inFlight: Task<Bool, Never>?

    /// Creates a coalescer with no evaluation in flight.
    public init() {}

    /// Runs `evaluate` (which performs exactly one biometric prompt) only when no evaluation is already
    /// in flight; callers that arrive mid-flight share the running evaluation's result rather than
    /// raising a second prompt. Once the shared evaluation completes, the next call starts fresh.
    ///
    /// - Parameter evaluate: Performs a single biometric evaluation and returns whether it succeeded.
    ///   It is invoked at most once per outstanding prompt — a coalesced caller never invokes it.
    /// - Returns: The shared evaluation's result (`true` on success).
    public func authenticate(_ evaluate: @escaping @MainActor () async -> Bool) async -> Bool {
        if let inFlight {
            return await inFlight.value
        }

        let evaluation = Task { @MainActor in
            await evaluate()
        }
        inFlight = evaluation
        defer { inFlight = nil }
        return await evaluation.value
    }
}
