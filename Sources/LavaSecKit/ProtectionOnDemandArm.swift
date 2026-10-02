import Foundation

/// Bounded saved-profile repair for a live connection whose recovery rule is not confirmed.
public enum ProtectionOnDemandArm {
    /// Privacy-safe rule shape used to verify universal recovery without retaining match values.
    public struct RuleSnapshot: Equatable, Sendable {
        /// Whether the platform rule performs Connect.
        public let isConnectRule: Bool
        /// Whether the rule applies to every interface.
        public let matchesAnyInterface: Bool
        /// Whether any probe, SSID, search-domain, or DNS-server condition is present.
        public let hasConditions: Bool

        /// Creates a rule shape without storing network identifiers or URLs.
        public init(isConnectRule: Bool, matchesAnyInterface: Bool, hasConditions: Bool) {
            self.isConnectRule = isConnectRule
            self.matchesAnyInterface = matchesAnyInterface
            self.hasConditions = hasConditions
        }
    }

    /// Requires exactly one unconditional any-interface Connect rule. Earlier Ignore/Disconnect
    /// rules or a conditional Connect cannot prove recovery after reboot on an arbitrary network.
    public static func hasUniversalConnectRule(_ rules: [RuleSnapshot]) -> Bool {
        guard rules.count == 1, let rule = rules.first else { return false }
        return rule.isConnectRule && rule.matchesAnyInterface && !rule.hasConditions
    }

    /// Authoritative state loaded for one repair attempt.
    public struct State: Equatable, Sendable {
        /// Whether the current saved manager still has a connected tunnel.
        public let isConnected: Bool
        /// Whether the saved any-interface connect rule is enabled and confirmed.
        public let isArmed: Bool

        /// Creates an authoritative saved-profile observation.
        public init(isConnected: Bool, isArmed: Bool) {
            self.isConnected = isConnected
            self.isArmed = isArmed
        }
    }

    /// Failures that must never be interpreted as a confirmed recovery rule.
    public enum Failure: Error, Equatable, Sendable {
        /// A newer intent, connection, external restart, or cancellation owns the profile.
        case ownershipLost
        /// The saved profile did not contain the requested enabled connect rule.
        case verificationFailed
    }

    // pinned: ProtectionOnDemandArmTests.testForegroundRepairWaitsForPendingArmBeforeLoadingAndPublishingItsSnapshot
    /// Loads and synchronously admits one foreground recovery snapshot while excluding profile
    /// mutations. Read and publication share the arm's existing fence; a saved-disabled snapshot
    /// cannot replace the manager being saved/reloaded by an in-flight arm (INV-PERSIST-3).
    /// Ownership is checked while waiting and after the read. Admission may legitimately create a
    /// new observation epoch, so it is not followed by a check against the old ownership token.
    @MainActor
    public static func refreshForForegroundRepair<Snapshot>(
        lockFileURL: URL,
        validateOwnership: @escaping @MainActor () -> Bool,
        readState: @escaping @MainActor () async throws -> Snapshot,
        applyState: @escaping @MainActor (Snapshot) -> Void
    ) async throws {
        try await ProtectionLifecycleMutationFence.withExclusiveMutation(
            lockFileURL: lockFileURL,
            waitUntilAvailable: true,
            validateWaiting: { !Task.isCancelled && validateOwnership() }
        ) {
            try Task.checkCancellation()
            guard validateOwnership() else { throw ProtectionLifecycleMutationFenceError.ownershipLost }
            let state = try await readState()
            try Task.checkCancellation()
            guard validateOwnership() else { throw ProtectionLifecycleMutationFenceError.ownershipLost }
            applyState(state)
        }
    }

    /// Repairs at most `maximumAttempts` times, validating ownership across every suspension.
    /// `saveAndVerify` must verify the saved rule before returning; the caller keeps the complete
    /// transaction inside its lifecycle mutation fence. Every retry reloads current saved state.
    @MainActor
    public static func perform(
        maximumAttempts: Int = 3,
        validateOwnership: () -> Bool,
        readState: () async throws -> State,
        saveAndVerify: () async throws -> Void,
        waitBeforeRetry: () async throws -> Void,
        recordAttempt: (Int, String) -> Void = { _, _ in }
    ) async throws -> Bool {
        func validate() throws {
            try Task.checkCancellation()
            guard validateOwnership() else { throw Failure.ownershipLost }
        }
        for attempt in 1...max(1, maximumAttempts) {
            try validate()
            recordAttempt(attempt, "requested")
            do {
                let state = try await readState()
                try validate()
                guard state.isConnected else {
                    recordAttempt(attempt, "disconnected")
                    return false
                }
                if state.isArmed {
                    recordAttempt(attempt, "already-armed")
                    return true
                }
                try await saveAndVerify()
                try validate()
                recordAttempt(attempt, "verified")
                return true
            } catch {
                // OFF may advance the local intent while a platform callback ignores cancellation.
                // Validate before any retry delay, and again before the next load/save. A successor
                // must never inherit this repair's retry budget (INV-PERSIST-3).
                // pinned: ProtectionOnDemandArmTests.testNewerOffDuringRetryPreventsTheNextProfileLoadOrSave
                try validate()
                recordAttempt(attempt, "failed")
                if error is CancellationError || error as? Failure == .ownershipLost {
                    throw error
                }
                guard attempt < maximumAttempts else { throw error }
                try await waitBeforeRetry()
            }
        }
        return false
    }
}
