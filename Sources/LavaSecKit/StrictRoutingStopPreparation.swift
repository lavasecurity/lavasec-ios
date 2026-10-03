/// Verifies the saved profile is disarmed before an explicitly requested strict-VPN stop.
/// The caller must own the protection lifecycle mutation fence. This is not used by
/// automatic reconnects, which must retain strict routing while protection is requested.
@MainActor
public enum StrictRoutingStopPreparation {
    /// Persisted state read back after saving, rather than the mutated in-memory profile.
    public struct SavedState: Equatable, Sendable {
        /// Whether the saved profile can restart on traffic.
        public let onDemandEnabled: Bool
        /// Whether the saved profile still captures all eligible traffic; nil means unreadable.
        public let includesAllNetworks: Bool?

        /// Creates the result of an actual preferences reload.
        public init(onDemandEnabled: Bool, includesAllNetworks: Bool?) {
            self.onDemandEnabled = onDemandEnabled
            self.includesAllNetworks = includesAllNetworks
        }
    }

    /// A save callback alone did not prove that the strict profile was released.
    public enum VerificationError: Error, Equatable, Sendable {
        /// The saved protocol could not be read, so its strict-routing state is unknown.
        case unreadableProtocol
        /// The reloaded profile can still reconnect or still requests strict routing.
        case profileStillArmed
    }

    /// Clears strict routing and on-demand in one save, then verifies both from preferences.
    /// Errors propagate to the existing bounded retry/profile-removal stop recovery path.
    public static func perform(
        clearAndSave: @MainActor () async throws -> Void,
        reloadAndRead: @MainActor () async throws -> SavedState
    ) async throws {
        try await clearAndSave()
        let saved = try await reloadAndRead()
        guard let includesAllNetworks = saved.includesAllNetworks else {
            throw VerificationError.unreadableProtocol
        }
        guard !saved.onDemandEnabled, !includesAllNetworks else {
            throw VerificationError.profileStillArmed
        }
    }
}
