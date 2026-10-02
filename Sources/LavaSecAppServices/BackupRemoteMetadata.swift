import Foundation

/// Server-confirmed backup presence, with an optional upload-specific timestamp.
public struct BackupRemoteMetadata: Decodable, Equatable, Sendable {
    /// The record owner, used to reject a response belonging to another account.
    public let userID: String
    /// Nil for legacy rows whose upload time cannot be established.
    public let uploadedAt: Date?

    private enum CodingKeys: String, CodingKey { case userID = "user_id", uploadedAt = "uploaded_at" }

    /// Decodes fractional and whole-second Postgres timestamps without inventing dates.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decode(String.self, forKey: .userID)
        let value = try container.decodeIfPresent(String.self, forKey: .uploadedAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = value.flatMap(formatter.date(from:))
        formatter.formatOptions = [.withInternetDateTime]
        uploadedAt = fractional ?? value.flatMap(formatter.date(from:))
    }
}

/// Five-minute trailing debounce. The token fences stale jobs even after cancellation.
public struct AutomaticBackupSchedule: Sendable {
    /// The required idle interval before an automatic upload attempt.
    public static let delay: TimeInterval = 5 * 60
    /// Current scheduling generation.
    public private(set) var generation: UInt64 = 0
    /// Deadline of the latest settings change, or nil when cancelled.
    public private(set) var deadline: Date?
    /// Creates an idle schedule.
    public init() {}
    /// Replaces a previous deadline and returns this change's ownership token.
    @discardableResult public mutating func changed(at date: Date) -> UInt64 {
        generation &+= 1
        deadline = date.addingTimeInterval(Self.delay)
        return generation
    }
    /// Cancels every previously issued job.
    public mutating func cancel() { generation &+= 1; deadline = nil }
    /// True only for the latest job once its full trailing interval has elapsed.
    public func canRun(token: UInt64, at date: Date) -> Bool {
        token == generation && deadline.map { date >= $0 } == true
    }
}
