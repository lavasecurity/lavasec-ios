import ActivityKit
import Foundation
import LavaSecCore

enum GuardianShieldStyle: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case original
    case fireOpal = "emberObsidian"
    case purpleObsidian
    case obsidian
    case cherryQuartz = "strawberryObsidian"
    case emerald
    case kiwiCreme

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

        init(
            protectionState: ProtectionState,
            resumeDate: Date?,
            pauseRequiresAuthentication: Bool,
            shieldStyle: GuardianShieldStyle
        ) {
            self.protectionState = protectionState
            self.resumeDate = resumeDate
            self.pauseRequiresAuthentication = pauseRequiresAuthentication
            self.shieldStyle = shieldStyle
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            protectionState = try container.decode(ProtectionState.self, forKey: .protectionState)
            resumeDate = try container.decodeIfPresent(Date.self, forKey: .resumeDate)
            pauseRequiresAuthentication = try container.decode(Bool.self, forKey: .pauseRequiresAuthentication)
            shieldStyle = try container.decodeIfPresent(GuardianShieldStyle.self, forKey: .shieldStyle) ?? .original
        }
    }

    enum ProtectionState: String, Codable, Hashable, Sendable {
        case on
        case paused
        case reconnecting
        case needsReconnect
        case networkUnavailable

        var guardianState: GuardianMascotState {
            switch self {
            case .on:
                .awake
            case .paused:
                .paused
            case .reconnecting, .networkUnavailable:
                .retrying
            case .needsReconnect:
                .concerned
            }
        }


        var expandedTitle: String {
            switch self {
            case .on:
                "Lava Security is On"
            case .paused:
                "Lava Security is Paused"
            case .reconnecting:
                "Lava Security is reconnecting"
            case .needsReconnect:
                "Lava Security needs to reconnect"
            case .networkUnavailable:
                "Waiting for network"
            }
        }
    }
}
