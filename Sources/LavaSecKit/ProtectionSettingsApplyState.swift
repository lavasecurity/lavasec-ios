import Foundation

/// Debounces saved settings while keeping tunnel restarts single-flight and bound to
/// the explicit Guard intent that accepted the change. Time is monotonic and supplied
/// by the owner so rapid input and lifecycle interleaving can be tested without sleeps.
public struct ProtectionSettingsApplyState: Equatable, Sendable {
    /// Identity of one accepted settings change and its original protection intent.
    public struct Ticket: Equatable, Sendable {
        fileprivate let sequence: UInt64
        fileprivate let intentRevision: UInt64
        fileprivate let externalRestartGeneration: ProtectionExternalRestartGenerationSnapshot
    }

    /// Quiet interval after the latest successful change, in seconds.
    public static let settleInterval: TimeInterval = 0.5
    /// Latest change still waiting for its quiet interval and the lifecycle gate.
    public private(set) var pending: Ticket?
    /// Restart that currently owns the lifecycle; newer input never cancels it.
    public private(set) var applying: Ticket?
    /// Earliest monotonic time at which the pending change may start.
    public private(set) var deadline: TimeInterval?
    private var sequence: UInt64 = 0

    /// Creates an idle coordinator.
    public init() {}

    /// Records a successful commit. Changes while Guard is off remain stored only.
    /// The temporary disconnect inside this owner's restart still accepts newer input.
    public mutating func recordChange(
        now: TimeInterval, intent: ProtectionRestoreIntentState,
        externalRestartGeneration: ProtectionExternalRestartGenerationSnapshot, hasRunningProtection: Bool
    ) {
        guard intent.isEnabled, hasRunningProtection || applying != nil else {
            cancelPending()
            return
        }
        sequence &+= 1
        pending = Ticket(sequence: sequence, intentRevision: intent.revision,
                         externalRestartGeneration: externalRestartGeneration)
        deadline = now + Self.settleInterval
    }

    /// Claims the settled latest change once the app's other lifecycle work is idle.
    public mutating func beginIfReady(
        now: TimeInterval, intent: ProtectionRestoreIntentState,
        externalRestartGeneration: ProtectionExternalRestartGenerationSnapshot, lifecycleIsAvailable: Bool
    ) -> Ticket? {
        discardSuperseded(intent: intent, externalRestartGeneration: externalRestartGeneration)
        guard applying == nil, lifecycleIsAvailable,
              let pending, let deadline, now >= deadline else { return nil }
        self.pending = nil
        self.deadline = nil
        applying = pending
        return pending
    }

    /// Revalidates a running operation after suspension without mistaking later settings
    /// input for a new Guard intent. An accepted OFF or explicit restart invalidates it.
    public func mayContinue(
        _ ticket: Ticket, intent: ProtectionRestoreIntentState,
        externalRestartGeneration: ProtectionExternalRestartGenerationSnapshot
    ) -> Bool {
        applying == ticket && intent.isEnabled && intent.revision == ticket.intentRevision
            && externalRestartGeneration == ticket.externalRestartGeneration
    }

    /// Releases only the matching restart, preserving changes accepted during it.
    public mutating func finish(_ ticket: Ticket) {
        guard applying == ticket else { return }
        applying = nil
    }

    /// Drops queued work captured before a newer explicit lifecycle choice.
    public mutating func discardSuperseded(
        intent: ProtectionRestoreIntentState,
        externalRestartGeneration: ProtectionExternalRestartGenerationSnapshot
    ) {
        if let pending, !intent.isEnabled || pending.intentRevision != intent.revision
            || pending.externalRestartGeneration != externalRestartGeneration {
            cancelPending()
        }
    }

    /// Removes pending work without releasing a lifecycle operation still in progress.
    public mutating func cancelPending() {
        pending = nil
        deadline = nil
    }
}
