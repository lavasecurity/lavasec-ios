import Foundation

/// Background concealment follows explicit protection choices, independently of read authorization.
public enum SecurityPrivacyPolicy {
    /// Keeps an explicitly concealed draft hidden; revealed drafts follow the inactive window policy.
    public static func requiresPrivateDraftCover(
        isRevealed: Bool,
        applicationIsActive: Bool,
        backgroundCoverRequired: Bool
    ) -> Bool {
        !isRevealed || (!applicationIsActive && backgroundCoverRequired)
    }

    /// Keeps uncertain security state covered; a configured credential alone does not opt in.
    /// Protected-data loss revokes access, not the confirmed display choice. Keep its
    /// argument label for callers that evaluate access and concealment together.
    public static func requiresBackgroundCover(
        authenticationAvailability: SecurityAuthenticationAvailability,
        protectedSurfaces: Set<SecurityProtectedSurface>,
        gatesAreAvailable: Bool,
        protectedDataIsAvailable _: Bool
    ) -> Bool {
        guard gatesAreAvailable,
              authenticationAvailability != .unavailable else { return true }
        return authenticationAvailability == .available && !protectedSurfaces.isEmpty
    }
}
