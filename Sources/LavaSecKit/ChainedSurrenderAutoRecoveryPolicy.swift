import Foundation

/// Bounds hands-free chained-surrender auto-recovery to a rolling time window.
///
/// Plan: lavasec-infra `plans/2026-08-18-chained-surrender-recovery.md` (Slice 2). A chained
/// tunnel that surrenders to DNS-only on a `budgetExhausted` blackout (a roam, a sleep/wake, a
/// dead zone) should come back on its own once the network is fine — but the recovery must NOT
/// re-create the flap loop the surrender exists to prevent: a persistently-dead chain on a
/// flapping path could otherwise recover → surrender → recover forever. This policy is the bound.
///
/// A ROLLING WINDOW rather than a lifetime cap, deliberately: a lifetime cap would penalise
/// *successful* recoveries (a device that legitimately roams a few times a day would exhaust it
/// and then never self-recover), whereas the window lets genuine roaming recover indefinitely —
/// windows apart — while a live flap of one dead path still exhausts the budget in a single
/// window and converges to "stay DNS-only until the user turns protection on" (which resets it).
public enum ChainedSurrenderAutoRecoveryPolicy {
    /// The most auto-recoveries permitted within ``windowSeconds``. Conservative: one roam or
    /// reconnect spends exactly one, so a handful of genuine transitions recover freely while a
    /// live flap exhausts the budget in one window. Tunable from a device re-pull.
    public static let maxRecoveriesPerWindow = 3

    /// The rolling window. ~30 min comfortably spans a flapping episode without permanently
    /// penalising a device that roams all day (its recoveries are windows apart).
    public static let windowSeconds: Double = 30 * 60

    /// Whether a hands-free auto-recovery may fire now, given the epochs of recent recoveries and
    /// the current wall clock, plus the window to PERSIST if it does (pruned to the window, with
    /// `nowEpoch` appended). When it may not, `prunedWindow` is the pruned window unchanged.
    ///
    /// Pure and clock-agnostic — `nowEpoch` is passed in because the store cannot see a wall
    /// clock. Only epochs clearly OLDER than the window (`nowEpoch - $0 >= windowSeconds`) prune;
    /// recent-past AND future epochs both COUNT toward the cap. Counting the future ones is the
    /// conservative choice under a backwards wall-clock jump: a rollback makes prior recoveries
    /// look "future", and pruning them would RESTORE the budget on every rollback (Codex, PR #569)
    /// — counting them means a rollback can only DELAY recovery, never manufacture it, and they
    /// age out on their own once wall time passes them by a window.
    public static func evaluate(
        recentEpochs: [Double], nowEpoch: Double
    ) -> (mayRecover: Bool, prunedWindow: [Double]) {
        let live = recentEpochs.filter { nowEpoch - $0 < windowSeconds }
        guard live.count < maxRecoveriesPerWindow else { return (false, live) }
        return (true, live + [nowEpoch])
    }
}
