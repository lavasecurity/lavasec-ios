import Foundation

enum LavaLiveActivityActionRequest: String, Codable, Sendable {
    case pauseFiveMinutes = "pause-5-minutes"
    case pauseTenMinutes = "pause-10-minutes"
    case pauseFifteenMinutes = "pause-15-minutes"
    case resume
    case reconnect

    var authenticationReason: String {
        switch self {
        case .pauseFiveMinutes, .pauseTenMinutes, .pauseFifteenMinutes:
            "Pause Lava protection"
        case .resume:
            "Resume Lava protection"
        case .reconnect:
            "Reconnect Lava protection"
        }
    }

    var pauseDuration: TimeInterval? {
        switch self {
        case .pauseFiveMinutes:
            5 * 60
        case .pauseTenMinutes:
            10 * 60
        case .pauseFifteenMinutes:
            15 * 60
        case .resume, .reconnect:
            nil
        }
    }
}
