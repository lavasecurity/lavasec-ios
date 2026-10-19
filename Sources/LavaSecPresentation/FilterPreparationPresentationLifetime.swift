import Foundation

/// Fences renderer acknowledgments and spoken results to the native preparation
/// attempt. Recreating an RN surface does not create another operation or result.
public struct FilterPreparationPresentationLifetime: Equatable, Sendable {
    /// The current native attempt, independently of any containing modal route.
    public private(set) var id: UUID?
    /// Whether the current attempt's confirmed success has actually been shown.
    public private(set) var successWasPresented = false
    private var announcedOutcomes = Set<String>()
    /// A missing or failed renderer never owns an unbounded native hold.
    public static let completionFallbackDelay: TimeInterval = 8
    /// Enough time for the staged quarter, final fill and checkmark hold.
    public static let renderedSuccessGrace: TimeInterval = 2
    public private(set) var terminalDeadline: TimeInterval?
    private var terminalOutcome: String?
    private var renderedSuccessWasNoted = false

    /// Creates an empty presentation lifetime.
    public init() {}

    /// Starts a new attempt and revokes all callbacks from the previous renderer.
    @discardableResult public mutating func begin() -> UUID {
        let next = UUID()
        id = next
        successWasPresented = false
        announcedOutcomes.removeAll()
        terminalDeadline = nil; terminalOutcome = nil; renderedSuccessWasNoted = false
        return next
    }

    /// Accepts only a confirmed success belonging to the current attempt.
    public mutating func acknowledgeSuccess(id: UUID, confirmed: Bool) -> Bool {
        guard self.id == id, confirmed else { return false }
        successWasPresented = true
        return true
    }

    /// Native truth starts one monotonic deadline; repeated publications do not
    /// postpone it. The caller supplies uptime for deterministic tests.
    @discardableResult public mutating func beginTerminal(id: UUID, outcome: String, now: TimeInterval) -> Bool {
        guard self.id == id, terminalOutcome != outcome else { return false }
        terminalOutcome = outcome
        terminalDeadline = now + Self.completionFallbackDelay
        renderedSuccessWasNoted = false
        return true
    }

    /// One meaningful late mount receives its complete visual timeline. Repeated
    /// remounts cannot renew the hold indefinitely; the extension is bounded.
    public mutating func noteRenderedSuccess(id: UUID, now: TimeInterval) -> Bool {
        guard self.id == id, terminalOutcome == "success", let deadline = terminalDeadline,
              now < deadline, !renderedSuccessWasNoted else { return false }
        renderedSuccessWasNoted = true
        terminalDeadline = max(deadline, now + Self.renderedSuccessGrace)
        return true
    }

    /// Deadline expiry never establishes success; native terminal truth is required.
    public func shouldUseTerminalFallback(id: UUID, now: TimeInterval) -> Bool {
        self.id == id && terminalDeadline.map { now >= $0 } == true
    }

    /// Claims an announcement once, including after a renderer remount.
    public mutating func claimAnnouncement(id: UUID, outcome: String) -> Bool {
        guard self.id == id else { return false }
        return announcedOutcomes.insert(outcome).inserted
    }
}
