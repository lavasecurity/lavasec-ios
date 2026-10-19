/// Once-only completion and cancellation for a system dialog. This owns only
/// callback identity; native callers independently validate existing read grants.
public struct ScopedSystemAlertLifetime: Sendable {
    /// A component's dialog request, independent of later visits or dialogs.
    public struct Ticket: Hashable, Sendable {
        public let ownerID: String
        public let requestID: String
        public init(ownerID: String, requestID: String) { self.ownerID = ownerID; self.requestID = requestID }
    }
    public private(set) var current: Ticket?
    private var retired = Set<Ticket>()
    public init() {}

    /// Check before replacing another dialog: a delayed retired request cannot
    /// dismiss its successor merely by asking for presentation again.
    public func mayBegin(_ ticket: Ticket) -> Bool { current != ticket && !retired.contains(ticket) }

    /// A cleanup may arrive before its suspended presentation request. Retired
    /// request identities never regain admission during this native runtime.
    public mutating func begin(_ ticket: Ticket) -> Bool {
        guard current == nil, mayBegin(ticket) else { return false }
        current = ticket
        return true
    }
    /// Claims a current result once. Repeated or superseded UIKit callbacks do nothing.
    public mutating func finish(_ ticket: Ticket) -> Bool {
        guard current == ticket else { return false }
        current = nil; retired.insert(ticket)
        return true
    }
    /// Retires even an unpresented request without cancelling another owner.
    @discardableResult public mutating func cancel(_ ticket: Ticket) -> Bool {
        retired.insert(ticket)
        guard current == ticket else { return false }
        current = nil
        return true
    }
}
