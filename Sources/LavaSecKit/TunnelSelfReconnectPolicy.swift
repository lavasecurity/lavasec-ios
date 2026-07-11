import Foundation

/// Decides whether the tunnel should restart *itself* to recover from a wedged
/// resolver — the case where DNS stays broken after a network handoff because the
/// device-DNS resolver addresses captured while the tunnel is active are stale
/// (a full restart re-captures them, since startup reads system DNS before
/// applying the tunnel's own DNS settings).
///
/// This is the last-resort escalation after the in-place recovery (connection
/// teardown, settle re-probe, device-DNS fallback) has failed to restore DNS.
/// It is deliberately conservative:
///   - only when the connectivity assessment is `.needsReconnect` (a sustained,
///     restart-worthy failure — never for mere slowness or an active fallback),
///   - only when protection is enabled *and* Connect-On-Demand is confirmed armed,
///     so the restart actually brings the tunnel back (otherwise self-cancelling
///     would just strand the user offline with no automatic recovery),
///   - rate-limited by a cooldown and a per-window cap so a network that simply
///     can't resolve can't drive a restart loop. The restart kills the extension
///     process, so the attempt history is persisted by the caller and passed back
///     in to survive across restarts.
public enum TunnelSelfReconnectPolicy {
    /// Minimum gap between self-reconnects.
    public static let cooldown: TimeInterval = 90
    /// Sliding window over which `maxAttemptsPerWindow` is counted.
    public static let attemptWindow: TimeInterval = 600
    /// Hard cap on self-reconnects within `attemptWindow`; once reached we stop
    /// restarting and leave the "reconnect needed" notification as the signal.
    public static let maxAttemptsPerWindow = 2
    /// Cap for the device-DNS *recapture* restart (Track 4) — the no-fallback
    /// resolver-changing handoff where a cold restart is the ONLY thing that
    /// re-captures the new network's resolver (Phase 0). Slightly higher than the
    /// wedge cap: the +1 headroom absorbs one in-flight, not-yet-credited restart
    /// during a legitimate network-switch flurry (a productive restart is credited
    /// back on the next launch's confirmed recovery, so genuine switching nets ~0),
    /// while still bounding a genuinely-dead resolver at 3 restarts/window before
    /// falling back to the in-place wedge-recovery probe (anti restart-loop).
    public static let maxDeviceDNSRecaptureAttemptsPerWindow = 3

    /// Why a self-reconnect is being considered. Selects the per-window ceiling; the
    /// attempt *store* is shared across reasons (a self-reconnect is one scarce
    /// process-restart resource regardless of trigger — two budgets would let a
    /// flapping network double the real restart rate).
    public enum RestartReason: Equatable, Sendable {
        /// The sustained connectivity wedge (the original escalation).
        case wedge
        /// Device-DNS capture-retry exhaustion on a no-fallback config (Track 4).
        case deviceDNSRecapture
    }

    /// The outcome of evaluating whether a tunnel self-reconnect may proceed.
    public enum Decision: Equatable, Sendable {
        /// Restart now (and record `now` in the persisted attempt history).
        case reconnect
        /// Reconnect-worthy, but suppressed by the cooldown/cap — notify only.
        case throttled
        /// Not a self-reconnect situation.
        case noAction
    }

    /// Attempt timestamps trimmed to the active window — the value the caller
    /// should persist (so the window doesn't grow without bound).
    public static func prunedAttemptTimes(_ times: [Date], now: Date = Date()) -> [Date] {
        // A backward wall-clock jump can make persisted attempts look future-dated.
        // Clamp them to `now` rather than dropping them: discarding would erase the
        // attempt history and let the cooldown/cap be bypassed, reopening the
        // restart loop the window exists to prevent.
        times
            .map { min($0, now) }
            .filter { now.timeIntervalSince($0) < attemptWindow }
    }

    /// Chooses a reconnect outcome after checking severity, on-demand recovery, cooldown, and window limits.
    public static func decision(
        assessment: ProtectionConnectivityAssessment,
        protectionEnabled: Bool,
        onDemandEnabled: Bool,
        recentReconnectTimes: [Date],
        reason: RestartReason = .wedge,
        now: Date = Date()
    ) -> Decision {
        // Only the genuine wedge — not `.dnsSlow` (also `.reconnect`, but working)
        // and not an active device-DNS fallback (DNS is still flowing).
        guard assessment.severity == .needsReconnect,
              assessment.primaryAction == .reconnect
        else {
            return .noAction
        }

        // A self-cancel only recovers if Connect-On-Demand is actually armed to
        // bring the tunnel back. Protection being marked enabled is necessary but
        // not sufficient: the app persists `protectionEnabled = true` even when
        // arming on-demand fails (a transient `saveToPreferences` error), so we
        // additionally require a confirmed on-demand signal. Without it, restarting
        // would strand the user offline with no automatic recovery.
        guard protectionEnabled, onDemandEnabled else {
            return .noAction
        }

        let recent = prunedAttemptTimes(recentReconnectTimes, now: now)

        if let mostRecent = recent.max(), now.timeIntervalSince(mostRecent) < cooldown {
            return .throttled
        }

        let ceiling = reason == .deviceDNSRecapture
            ? maxDeviceDNSRecaptureAttemptsPerWindow
            : maxAttemptsPerWindow
        if recent.count >= ceiling {
            return .throttled
        }

        return .reconnect
    }
}
