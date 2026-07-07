import Foundation

public enum ProtectionActionKind: String, CaseIterable, Equatable, Sendable {
    case turnOn
    case turnOff
    case toggle
    case reconnect
    case refreshLists
    case pause
    case resume
    case installProfile
    case adminQAProfile
}

// Single-flight gate for protection actions: concurrent taps, Live Activity
// commands, scheduled resumes, and QA flows cannot interleave lifecycle work.
// Entry points claim a kind before starting (synchronously, so a second tap is
// rejected before any await); the owner releases when its flow finishes.
// UI in-flight state is derived via onInFlightChange rather than written ad hoc.
@MainActor
public final class ProtectionActionOrchestrator {
    public private(set) var inFlightAction: ProtectionActionKind?

    private let onInFlightChange: @MainActor (ProtectionActionKind?) -> Void

    public init(onInFlightChange: @escaping @MainActor (ProtectionActionKind?) -> Void = { _ in }) {
        self.onInFlightChange = onInFlightChange
    }

    public var isActionInFlight: Bool {
        inFlightAction != nil
    }

    @discardableResult
    public func claim(_ kind: ProtectionActionKind) -> Bool {
        guard inFlightAction == nil else {
            return false
        }

        inFlightAction = kind
        onInFlightChange(kind)
        return true
    }

    // Releases only when the in-flight action matches: a stale release from an
    // abandoned flow cannot end a newer action's claim.
    public func release(_ kind: ProtectionActionKind) {
        guard inFlightAction == kind else {
            return
        }

        inFlightAction = nil
        onInFlightChange(nil)
    }

    // Convenience for fully-async flows; returns false when another action
    // already holds the claim and the operation was skipped.
    @discardableResult
    public func run(_ kind: ProtectionActionKind, operation: () async -> Void) async -> Bool {
        guard claim(kind) else {
            return false
        }

        defer {
            release(kind)
        }
        await operation()
        return true
    }
}
