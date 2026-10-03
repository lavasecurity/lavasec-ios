import ActivityKit
import Foundation
import LavaSecKit

enum GuardianShieldStyle: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case original
    case fireOpal = "emberObsidian"
    case purpleObsidian
    case obsidian
    case cherryQuartz = "strawberryObsidian"
    case emerald
    case kiwiCreme
    case aquamarine

    var id: Self {
        self
    }

    var displayName: String {
        switch self {
        case .original:
            "Original"
        case .fireOpal:
            "Fire Opal"
        case .purpleObsidian:
            "Amethyst"
        case .obsidian:
            "Obsidian"
        case .cherryQuartz:
            "Cherry Quartz"
        case .emerald:
            "Emerald"
        case .kiwiCreme:
            "Kiwi Crème"
        case .aquamarine:
            "Aquamarine"
        }
    }

    /// Alternate app icons are simple seed artwork; iOS owns Dark/Tinted rendering from the user's Home Screen icon appearance.
    var alternateAppIconName: String? {
        switch self {
        case .original:
            nil
        case .fireOpal:
            "AppIconFireOpal"
        case .purpleObsidian:
            "AppIconAmethyst"
        case .obsidian:
            "AppIconObsidian"
        case .cherryQuartz:
            "AppIconCherryQuartz"
        case .emerald:
            "AppIconEmerald"
        case .kiwiCreme:
            "AppIconKiwiCreme"
        case .aquamarine:
            "AppIconAquamarine"
        }
    }
}

struct LavaActivityAttributes: ActivityAttributes {
    var activityName = "Lava Security"

    struct ContentState: Codable, Hashable, Sendable {
        var protectionState: ProtectionState
        var resumeDate: Date?
        var pauseRequiresAuthentication: Bool
        var shieldStyle: GuardianShieldStyle
        // Drives the "Pause for N min" expanded-view button label. Travels with
        // the activity content so changing the length in Settings relabels the
        // live button on the next reconcile.
        var pauseConfirmation: LiveActivityPauseConfirmation?
        var pauseMinutes: Int

        init(
            protectionState: ProtectionState,
            resumeDate: Date?,
            pauseRequiresAuthentication: Bool,
            shieldStyle: GuardianShieldStyle,
            pauseMinutes: Int = LiveActivityPausePreference.defaultMinutes
        ) {
            self.protectionState = protectionState
            self.resumeDate = resumeDate
            self.pauseRequiresAuthentication = pauseRequiresAuthentication
            self.shieldStyle = shieldStyle
            self.pauseMinutes = pauseMinutes
            pauseConfirmation = nil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // An activity that an older build encoded with a now-removed
            // connectivity state (reconnecting / needsReconnect / networkUnavailable)
            // must still decode after an update rather than fail outright — Lava is
            // fail-closed, so resolving any unknown state to `.on` is the honest,
            // non-destructive fallback until the next reconcile republishes.
            protectionState = (try? container.decode(ProtectionState.self, forKey: .protectionState)) ?? .on
            resumeDate = try container.decodeIfPresent(Date.self, forKey: .resumeDate)
            pauseRequiresAuthentication = try container.decode(Bool.self, forKey: .pauseRequiresAuthentication)
            shieldStyle = try container.decodeIfPresent(GuardianShieldStyle.self, forKey: .shieldStyle) ?? .original
            pauseConfirmation = try container.decodeIfPresent(LiveActivityPauseConfirmation.self, forKey: .pauseConfirmation)
            pauseMinutes = try container.decodeIfPresent(Int.self, forKey: .pauseMinutes)
                ?? LiveActivityPausePreference.defaultMinutes
        }
    }

    // The Dynamic Island surfaces only what it can keep honest while the app is
    // suspended: whether protection is engaged (`on`) or the user paused it
    // (`paused`). Ambient connectivity status is deliberately not modeled — it
    // can't be kept fresh on a push-only surface, and Lava is fail-closed, so a
    // reconnect wobble never exposes traffic. Recovery is offered as an always-
    // available Restart action instead of a reactive (and stale-prone) alarm.
    //
    // `restarting` is the one transient exception, and a deliberate one: it is set
    // and cleared entirely within a single user-initiated Restart command that runs
    // in a live (tap-woken) app process — action feedback we control end to end, not
    // ambient status. It carries a short staleDate so a killed background window
    // can't strand it.
    enum ProtectionState: String, Codable, Hashable, Sendable {
        case on
        case paused
        case restarting

        var guardianState: GuardianMascotState {
            switch self {
            case .on:
                .awake
            case .paused:
                .paused
            case .restarting:
                .retrying
            }
        }

        var expandedTitle: String {
            switch self {
            case .on:
                "Lava Security is On"
            case .paused:
                "Lava Security is Paused"
            case .restarting:
                "Restarting…"
            }
        }
    }
}

extension LavaActivityAttributes.ContentState {
    // Both transient states carry their self-resolve deadline in `resumeDate`, and
    // the expanded views advance on a 1-second TimelineView, so the Dynamic Island
    // resolves them on its OWN clock without a fresh push from the app:
    //  - paused → on at the resume time,
    //  - restarting → on at the restart deadline (so a restart killed mid-flight,
    //    before the app could restore state, can't strand the island on
    //    "Restarting…"; on-demand brings the tunnel back, and the next app wake
    //    reconciles the true state).
    func effectiveProtectionState(now: Date) -> LavaActivityAttributes.ProtectionState {
        switch protectionState {
        case .paused, .restarting:
            guard let resumeDate, resumeDate <= now else {
                return protectionState
            }
            return .on
        case .on:
            return .on
        }
    }
}
