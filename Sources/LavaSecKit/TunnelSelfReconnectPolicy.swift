import Foundation

/// Admits a tunnel restart for a sustained resolver wedge or an explicitly
/// evidenced Device DNS recapture requirement. Startup reads system DNS before
/// applying the tunnel's settings, so restarting can recover stale network DNS.
///
/// The tier recovery owner supplies the requirement; this policy admits the
/// shared process restart resource. It is deliberately conservative:
///   - an ordinary wedge requires `.needsReconnect`; a Device DNS requirement
///     comes from that tier's own evidence, which another tier's rescue cannot erase,
///   - only when protection is enabled *and* Connect-On-Demand is confirmed armed,
///     so the restart actually brings the tunnel back (otherwise self-cancelling
///     would just strand the user offline with no automatic recovery),
///   - rate-limited by a cooldown and a per-window cap so a network that simply
///     can't resolve can't drive a restart loop. The restart kills the extension
///     process, so the attempt history is persisted by the caller and passed back
///     in to survive across restarts.
public enum TunnelSelfReconnectPolicy {
    /// Minimum gap between self-reconnects, including restarts credited as productive.
    public static let cooldown: TimeInterval = 90
    /// Sliding window over which `maxAttemptsPerWindow` is counted.
    public static let attemptWindow: TimeInterval = 600
    /// Hard cap on self-reconnects within `attemptWindow`; once reached we stop
    /// restarting and leave the "reconnect needed" notification as the signal.
    public static let maxAttemptsPerWindow = 2
    /// Cap for a Device DNS recapture restart — a cold restart reads the network's
    /// resolver before tunnel settings mask system DNS. Slightly higher than the
    /// wedge cap: the +1 headroom absorbs one in-flight, not-yet-credited restart
    /// during a legitimate network-switch flurry. Confirmed recovery credits the
    /// attempt against this cap; the committed-restart marker retains the cooldown.
    /// An unrecovered resolver remains bounded at 3 restarts per window.
    public static let maxDeviceDNSRecaptureAttemptsPerWindow = 3

    /// Why a self-reconnect is being considered. Selects the per-window ceiling; the
    /// attempt *store* is shared across reasons (a self-reconnect is one scarce
    /// process-restart resource regardless of trigger — two budgets would let a
    /// flapping network double the real restart rate).
    public enum RestartReason: Equatable, Sendable {
        /// The sustained connectivity wedge (the original escalation).
        case wedge
        /// Device DNS requires fresh network resolver capture.
        case deviceDNSRecapture
    }

    /// The recovery owner's evidenced reason to request the shared restart resource.
    public enum RecoveryRequirement: Equatable, Sendable {
        /// Aggregate DNS health has established a sustained reconnect-worthy wedge.
        case sustainedWedge(ProtectionConnectivityAssessment)
        /// A Device DNS tier has established that its network resolver must be recaptured.
        /// The caller must enforce tier admission, egress, and current lifecycle evidence.
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

    /// Preserves aggregate-health admission for existing callers before applying shared restart limits.
    public static func decision(
        assessment: ProtectionConnectivityAssessment,
        protectionEnabled: Bool,
        onDemandEnabled: Bool,
        recentReconnectTimes: [Date],
        reason: RestartReason = .wedge,
        lastCommittedReconnectAt: Date? = nil,
        now: Date = Date()
    ) -> Decision {
        // Only the genuine wedge — not `.dnsSlow` (also `.reconnect`, but working)
        // and not an active device-DNS fallback (DNS is still flowing).
        guard assessment.severity == .needsReconnect,
              assessment.primaryAction == .reconnect
        else {
            return .noAction
        }

        let requirement: RecoveryRequirement = reason == .deviceDNSRecapture
            ? .deviceDNSRecapture
            : .sustainedWedge(assessment)
        return decision(
            requirement: requirement,
            protectionEnabled: protectionEnabled,
            onDemandEnabled: onDemandEnabled,
            recentReconnectTimes: recentReconnectTimes,
            lastCommittedReconnectAt: lastCommittedReconnectAt,
            now: now
        )
    }

    /// Admits an evidenced requirement after checking recovery intent and shared restart limits.
    /// `lastCommittedReconnectAt` retains cooldown after productive credit removes an attempt from the cap store.
    public static func decision(
        requirement: RecoveryRequirement,
        protectionEnabled: Bool,
        onDemandEnabled: Bool,
        recentReconnectTimes: [Date],
        lastCommittedReconnectAt: Date? = nil,
        now: Date = Date()
    ) -> Decision {
        let ceiling: Int
        switch requirement {
        case .sustainedWedge(let assessment):
            guard assessment.severity == .needsReconnect,
                  assessment.primaryAction == .reconnect
            else {
                return .noAction
            }
            ceiling = maxAttemptsPerWindow
        case .deviceDNSRecapture:
            // DNS tiers own their evidence (docs/architecture/dns-tiers.md). A
            // rescue by another tier says nothing about the failed Device DNS tier.
            ceiling = maxDeviceDNSRecaptureAttemptsPerWindow
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

        // Productive credit can remove an attempt from the cap store, but cannot
        // erase the time of the actual process restart. Normalize a future marker
        // the same way as persisted attempts so a clock regression fails closed.
        let committedAt = lastCommittedReconnectAt.map { min($0, now) }
        let latest = [recent.max(), committedAt].compactMap { $0 }.max()
        if let latest, now.timeIntervalSince(latest) < cooldown {
            return .throttled
        }

        if recent.count >= ceiling {
            return .throttled
        }

        return .reconnect
    }
}
