import Foundation

/// The Guard module's single semantic projection. Text and concrete colors are resolved by the
/// host, while panel material and status tint follow the same service status. A current,
/// deferred Device DNS repair may offer reconnect without changing that service claim.
public struct GuardStatusPresentation: Equatable, Sendable {
    public enum Headline: Equatable, Sendable { case status(ProtectionStatus), needsAttention }
    public let headline: Headline

    public enum PrimaryAction: String, Sendable { case turnOn, turnOff, reconnect, resume }
    public enum ActionTone: String, Sendable { case affirmative, quiet, recovery }

    public private(set) var materialIntent: GuardMaterialIntent
    public private(set) var tintRole: ProtectionTintRole
    public private(set) var mascotState: GuardianMascotState
    public private(set) var primaryAction: PrimaryAction
    public private(set) var actionTone: ActionTone
    public private(set) var allowsPause: Bool

    /// Projects service health and an optional, already-qualified explicit Device DNS repair.
    public init(status: ProtectionStatus, hasErrorNotice: Bool = false,
                offersDeviceDNSRecapture: Bool = false) {
        // Operational errors must replace a normal headline together with its colors.
        headline = hasErrorNotice && status != .chainingFailed ? .needsAttention : .status(status)
        switch status {
        case .off, .notInstalled:
            (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                (.rest, .inactive, .sleeping, .turnOn, .affirmative, false)
        case .turningOn, .establishing:
            (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                (.unresolved, .transitioning, .waking, .turnOff, .quiet, false)
        case .turningOff:
            (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                (.stopping, .transitioning, .sleeping, .turnOff, .quiet, false)
        case .paused:
            (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                (.paused, .paused, .paused, .resume, .affirmative, false)
        case .reconnecting, .vpnRecovering:
            (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                (.recovery, .transitioning, .retrying, .turnOff, .recovery, false)
        case .vpnUnconfirmed:
            (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                (.unknown, .attention, .concerned, .turnOff, .recovery, false)
        // Setup is valid but forwarding is not yet observed. This is verification,
        // not a recovery request: retain a neutral panel and a quiet stop action.
        case .tunnelReady:
            (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                (.unknown, .transitioning, .waking, .turnOff, .quiet, false)
        case .chainingFailed:
            (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                (.recovery, .attention, .concerned, .reconnect, .recovery, false)
        case .unavailable:
            (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                (.unknown, .transitioning, .retrying, .turnOff, .recovery, false)
        case .connected(let severity):
            switch severity {
            case .healthy:
                (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                    (.affirmed, .protected, .awake, .turnOff, .quiet, true)
            case .recovering:
                (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                    (.recovery, .transitioning, .retrying, .turnOff, .recovery, true)
            case .usingDeviceDNSFallback, .usingEncryptedFallback:
                (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                    (.recovery, .attention, .concerned, .turnOff, .recovery, true)
            case .dnsSlow, .needsReconnect:
                (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                    (.recovery, .attention, .concerned, .reconnect, .recovery, false)
            case .networkUnavailable:
                (materialIntent, tintRole, mascotState, primaryAction, actionTone, allowsPause) =
                    (.recovery, .inactive, .retrying, .turnOff, .recovery, false)
            }
        }
        // A deferred Device tier can need an explicit repair while other tiers keep the
        // whole connection healthy. Keep its observed health and material; only the action
        // offers the recapture the current tier and route context admit.
        if offersDeviceDNSRecapture, case .connected = status {
            primaryAction = .reconnect
            actionTone = .recovery
        }
        // An operational failure can arrive before the lifecycle sample catches up. Keep the
        // action truthful to the observed status, but never paint an error over a green panel.
        if hasErrorNotice {
            materialIntent = .unknown
            tintRole = .attention
            mascotState = .concerned
            actionTone = .recovery
            allowsPause = false
        }
    }
}

/// Material intent projected from authoritative service state. An operational error may
/// remove affirmation; configuration and copy can never establish protection.
public enum GuardMaterialIntent: String, Sendable {
    case rest, affirmed, unresolved, stopping, recovery, paused, unknown

    public init(status: ProtectionStatus) {
        self = GuardStatusPresentation(status: status).materialIntent
    }

    public func surface(previous: GuardMaterialSurface? = nil) -> GuardMaterialSurface {
        switch self {
        case .rest: return .rest
        case .affirmed: return .affirmed
        case .stopping: return previous ?? .neutral
        case .unresolved: return previous == .rest || previous == nil ? .rest : .neutral
        case .recovery, .paused, .unknown: return .neutral
        }
    }

    public func duration(from previous: GuardMaterialSurface, to next: GuardMaterialSurface) -> Double {
        guard previous != next else { return 0 }
        switch (previous, next) {
        case (.rest, .affirmed): return 0.5
        case (.neutral, .affirmed): return 0.5
        case (_, .rest): return 0.55
        case (.affirmed, .neutral): return self == .paused ? 0.4 : self == .unknown ? 0.3 : 0.24
        default: return 0.24
        }
    }
}

public enum GuardMaterialSurface: String, Sendable { case rest, affirmed, neutral }
