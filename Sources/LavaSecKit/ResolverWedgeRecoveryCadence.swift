import Foundation

/// Escalating re-probe cadence for a same-network resolver wedge — the LAV-92 "fast guide".
///
/// When DNS is failed-closed the user is offline *now*, so the tunnel re-probes the primary
/// (after clearing the resolver backoff penalty box) until it recovers. That recovery loop used
/// to re-arm on a flat 30s interval: a brief upstream blip — the common case, e.g. a network
/// handover or a transient DoH hiccup — then took up to 30s to recover even though the primary
/// was reachable again within a second or two (a real rc12 capture showed a ~33s outage whose
/// fresh DoH connect, once finally attempted, succeeded in 478ms).
///
/// This escalates from a tight first re-probe and doubles up to the original ceiling, so a short
/// outage recovers in ~2–6s while a sustained one still backs off to the gentle steady-state
/// cadence — one re-probe per interval, never per query, so it never reintroduces the
/// dead-resolver hammering the backoff exists to prevent. At the cap it is identical to the old
/// flat behaviour, so steady-state and the (deliberately conservative) heavier self-reconnect
/// throttle are untouched.
///
/// `attempt` is the zero-based count of consecutive re-probes within one wedge *episode*; it
/// resets the moment the wedge clears (recovery or lifecycle reset cancels the probe).
public struct ResolverWedgeRecoveryCadence: Sendable {
    /// Delay before the first re-probe of an episode.
    public let firstInterval: TimeInterval
    /// Ceiling the doubling backs off to (the legacy flat interval).
    public let maxInterval: TimeInterval

    /// Creates a doubling cadence with nonnegative intervals, clamping the first delay to the ceiling.
    public init(firstInterval: TimeInterval = 2, maxInterval: TimeInterval = 30) {
        // A non-positive or inverted configuration would defeat the cap; clamp so the cadence
        // is always a non-decreasing ramp from a positive first interval up to the ceiling.
        let safeMax = max(maxInterval, 0)
        self.firstInterval = min(max(firstInterval, 0), safeMax)
        self.maxInterval = safeMax
    }

    /// Delay before the wedge-recovery probe at `attempt` (0 = first probe of the episode):
    /// `firstInterval * 2^attempt`, capped at `maxInterval`.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let clampedAttempt = max(0, attempt)
        guard clampedAttempt > 0 else {
            return min(firstInterval, maxInterval)
        }
        // Cap the shift so a pathologically long wedge can't overflow; once the doubled value
        // reaches `maxInterval` the result is pinned there regardless.
        let shift = min(clampedAttempt, 16)
        let scaled = firstInterval * TimeInterval(1 << shift)
        return min(scaled, maxInterval)
    }
}
