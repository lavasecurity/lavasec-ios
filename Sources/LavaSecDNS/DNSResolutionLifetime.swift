import Foundation
import LavaSecKit

/// One lookup's absolute deadline and originating-runtime admission gate, shared by every tier.
public struct DNSResolutionLifetime: Sendable {
    /// Includes queue wait and every resolver attempt in the same client budget.
    public let deadline: MonotonicDeadline
    private let isCurrent: @Sendable () -> Bool

    /// Captures a deadline and a live check of the runtime that accepted this lookup.
    public init(deadline: MonotonicDeadline, isCurrent: @escaping @Sendable () -> Bool) {
        self.deadline = deadline
        self.isCurrent = isCurrent
    }

    /// Whether the runtime that accepted the lookup still owns it, independent of timeout.
    public var runtimeIsCurrent: Bool { isCurrent() }

    /// Rechecked at queued launch and transport send seams; expiration never authorizes new I/O.
    public var isAdmitted: Bool { !deadline.hasExpired() && isCurrent() }
}
