import Foundation

/// A short-lived, single-use confirmation bound to the rendered Live Activity.
public struct LiveActivityPauseConfirmation: Codable, Hashable, Sendable {
    /// Identity carried by the rendered Confirm intent; a stale button cannot consume a new request.
    public let token: String
    /// Beginning of the confirmation window, also rejecting a backwards clock jump.
    public let issuedAt: Date
    /// The confirmation expires at this instant, including the exact boundary.
    public let expiresAt: Date

    /// The confirmation window. Named so the app process can schedule the revert against
    /// the same value the deadline is built from, instead of repeating the literal.
    public static let window: TimeInterval = 5

    /// Creates a five-second confirmation window.
    public init(now: Date, token: String = UUID().uuidString) {
        self.token = token
        issuedAt = now
        expiresAt = now.addingTimeInterval(Self.window)
    }

    /// Checks the rendered token and deadline without granting permission to pause by itself.
    public func accepts(token: String, now: Date) -> Bool {
        self.token == token && now >= issuedAt && now < expiresAt
    }
}

/// Process-local permission gate. Re-arming replaces old permission; consumption is single-use.
public struct LiveActivityPauseConfirmationGate: Sendable {
    private var pending: (activityID: String, confirmation: LiveActivityPauseConfirmation)?

    /// Starts with no permission; process restarts never restore a pending confirmation.
    public init() {}

    /// Replaces any prior activity or token with a fresh five-second window.
    public mutating func arm(activityID: String, now: Date) -> LiveActivityPauseConfirmation {
        let confirmation = LiveActivityPauseConfirmation(now: now)
        pending = (activityID, confirmation)
        return confirmation
    }

    /// Consumes only matching unexpired permission, before the caller performs asynchronous work.
    public mutating func consume(activityID: String, token: String, now: Date) -> Bool {
        guard let pending, pending.activityID == activityID,
              pending.confirmation.accepts(token: token, now: now) else { return false }
        self.pending = nil
        return true
    }
}
