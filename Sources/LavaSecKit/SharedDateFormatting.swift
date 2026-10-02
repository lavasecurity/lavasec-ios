import Foundation

/// Shared, cached date formatters. `ISO8601DateFormatter` is expensive to
/// allocate; its default configuration is thread-safe for `.string(from:)`.
public enum SharedDateFormatting {
    /// Default-configured ISO 8601 formatter (`.withInternetDateTime`).
    /// Use for emitting log/diagnostic timestamps. Do NOT mutate `formatOptions`.
    nonisolated(unsafe) public static let iso8601 = ISO8601DateFormatter()

    /// Same, plus milliseconds. Separate instance rather than an option flip on ``iso8601``,
    /// which is shared by every other emit site and documented as immutable.
    nonisolated(unsafe) public static let iso8601WithMilliseconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

}
