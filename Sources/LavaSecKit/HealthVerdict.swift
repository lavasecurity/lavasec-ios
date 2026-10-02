import Foundation

/// The verdict a single ``ConnectivityHealthSignal`` returns for one observation window.
///
/// Three levels, deliberately coarser than the seven-way ``ProtectionConnectivitySeverity`` the
/// DNS module recasts. A supervisor that composes several signals (DNS resolution, link, data path)
/// needs one common currency to combine, and the finer distinction is not lost: ``reason`` carries
/// the source severity's own locale-independent `diagnosticLabel`, so a consumer that needs the
/// original (e.g. the reconnect-vs-turn-off action a bare level cannot express) can reconstruct it.
///
/// ``reason`` is `nil` iff `.healthy` — a healthy signal has nothing to explain — and is never
/// user-facing copy. Per the core's module conventions, presentation is a per-OS concern; this type
/// stays free of English strings by reusing the diagnostic labels the notification/UI layers already
/// key on rather than inventing a parallel vocabulary.
public struct HealthVerdict: Equatable, Sendable {
    public enum Level: String, Sendable, Equatable, CaseIterable {
        case healthy
        case degraded
        case down
    }

    public let level: Level
    /// A locale-independent diagnostic label (e.g. ``ProtectionConnectivitySeverity/diagnosticLabel``),
    /// never user-facing copy. `nil` iff ``level`` is `.healthy`.
    public let reason: String?

    private init(level: Level, reason: String?) {
        self.level = level
        self.reason = reason
    }

    /// The signal sees the tunnel carrying traffic as expected.
    public static let healthy = HealthVerdict(level: .healthy, reason: nil)

    /// The tunnel is still carrying traffic but the signal sees a degraded condition (a fallback in
    /// use, slow answers, a not-yet-escalated failure). `reason` names the condition.
    public static func degraded(_ reason: String) -> HealthVerdict {
        HealthVerdict(level: .degraded, reason: reason)
    }

    /// The signal sees the tunnel not carrying traffic (no network path, or a failure sustained past
    /// its threshold). `reason` names the condition.
    public static func down(_ reason: String) -> HealthVerdict {
        HealthVerdict(level: .down, reason: reason)
    }
}
