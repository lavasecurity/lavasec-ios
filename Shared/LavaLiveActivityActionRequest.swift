import Foundation

enum LavaLiveActivityActionRequest: String, Codable, Sendable {
    case pauseFiveMinutes = "pause-5-minutes"
    case pauseTenMinutes = "pause-10-minutes"
    case pauseFifteenMinutes = "pause-15-minutes"
    // The Live Activity's single Pause button. Its length is the user-configured
    // value resolved from the shared app-group defaults at command time, so this
    // case has no fixed `pauseDuration`.
    case pauseConfigured = "pause-configured"
    case resume
    case reconnect

    var authenticationReason: String {
        switch self {
        case .pauseFiveMinutes, .pauseTenMinutes, .pauseFifteenMinutes, .pauseConfigured:
            "Pause Lava protection"
        case .resume:
            "Resume Lava protection"
        case .reconnect:
            "Restart Lava protection"
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
        case .pauseConfigured, .resume, .reconnect:
            nil
        }
    }
}
