import Foundation

package enum LocalLogTimestampFormatter {
    package static func string(from timestamp: Date) -> String {
        string(from: timestamp, uses24HourClock: systemUses24HourClock())
    }

    package static func string(from timestamp: Date, uses24HourClock: Bool) -> String {
        "\(dateString(from: timestamp)), \(timeString(from: timestamp, uses24HourClock: uses24HourClock))"
    }

    private static func systemUses24HourClock(locale: Locale = .autoupdatingCurrent) -> Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        return format.contains("H") || format.contains("k")
    }

    private static func dateString(from timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: timestamp)
    }

    private static func timeString(from timestamp: Date, uses24HourClock: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = uses24HourClock ? "HH:mm" : "h:mm a"
        return formatter.string(from: timestamp)
    }
}
