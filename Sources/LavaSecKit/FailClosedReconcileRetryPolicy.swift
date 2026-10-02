import Foundation

/// When to re-attempt the launch snapshot reconcile after it failed.
///
/// WHY A RETRY EXISTS AT ALL. `reconcileTunnelSnapshotAfterLaunch` runs ONCE per process. If it
/// fails while the tunnel is serving block-all, the device stays in a total DNS outage until the
/// user happens to toggle protection — nothing else re-attempts the repair.
///
/// WHY IT IS TIMED RATHER THAN IMMEDIATE. The repair depends on the tunnel's bootstrap broker,
/// which is admitted only once the tunnel has COMMITTED its fail-closed state — and on a cold
/// launch the app's reconcile runs before that. Measured on device (S9):
///
///     05:14:38  data-path-latched
///     05:14:39  app reconcile -> cannotFindHost -> broker  => refused "not-fail-closed"
///     05:14:50  loadSnapshot-missing  (fail-closed committed HERE, 11s later)
///
/// So the first attempt is racing a state that does not exist yet. The first delay is chosen to
/// clear that settle with margin rather than to be quick; being early is exactly the failure.
///
/// A pure policy so the schedule is unit-testable — the caller that owns the timer is not.
public enum FailClosedReconcileRetryPolicy {
    /// Backoff schedule, in seconds, indexed by attempt number (0 = first RETRY, not the
    /// original attempt).
    ///
    /// 20s clears the observed ~11s settle with margin. The later steps cover a slow or
    /// repeatedly-superseded snapshot load without turning a genuinely unfixable
    /// configuration into an indefinite retry loop — that case is already reported to the
    /// user, and a device that cannot repair itself should stop spending radio on trying.
    public static let retryDelaysSeconds: [TimeInterval] = [20, 60, 180]

    /// Seconds to wait before `attempt`, or `nil` when the ladder is exhausted.
    public static func delaySeconds(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < retryDelaysSeconds.count else { return nil }
        return retryDelaysSeconds[attempt]
    }

    /// Total attempts this policy will schedule after the initial failure.
    public static var maximumRetryCount: Int { retryDelaysSeconds.count }

    /// Whether a retry is worth scheduling.
    ///
    /// `protectionIsEnabled` is the load-bearing term: with protection off the tunnel serves
    /// nothing, the app's own resolver works, and the ordinary catalog refresh will repair the
    /// artifact on its usual schedule. Retrying then would be pure background work.
    public static func shouldScheduleRetry(
        attempt: Int,
        protectionIsEnabled: Bool
    ) -> Bool {
        guard protectionIsEnabled else { return false }
        return delaySeconds(forAttempt: attempt) != nil
    }
}
