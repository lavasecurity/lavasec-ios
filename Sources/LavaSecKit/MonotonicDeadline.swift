import Foundation

/// An absolute work deadline that advances through device sleep and ignores wall-clock changes.
public struct MonotonicDeadline: Equatable, Sendable {
    /// The continuous-clock instant at which work expires.
    public let instant: ContinuousClock.Instant

    /// Creates a deadline after a finite, nonnegative interval in seconds.
    public init(after seconds: TimeInterval, now: ContinuousClock.Instant = ContinuousClock().now) {
        precondition(seconds.isFinite && seconds >= 0)
        instant = now.advanced(by: .seconds(seconds))
    }

    /// Whether the whole budget has elapsed, including time spent waiting for admission.
    public func hasExpired(now: ContinuousClock.Instant = ContinuousClock().now) -> Bool {
        now >= instant
    }

    /// Remaining seconds for an operating-system timeout; expired deadlines return zero.
    public func remainingSeconds(now: ContinuousClock.Instant = ContinuousClock().now) -> TimeInterval {
        let remaining = now.duration(to: instant).components
        return max(0, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
    }
}
