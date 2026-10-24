import Foundation

/// Background concealment follows explicit protection choices, independently of read authorization.
public enum SecurityPrivacyPolicy {
    /// Permits only the already painted, revealed draft of the same visit to
    /// remain visible without read authority. This grants no editing or reads.
    public static func canRetainAcceptedPrivateDraftDisplay(
        hasAcceptedRevealedDisplay: Bool,
        ownerIsCurrent: Bool,
        backgroundCoverRequired: Bool
    ) -> Bool {
        hasAcceptedRevealedDisplay && ownerIsCurrent && !backgroundCoverRequired
    }

    /// Keeps an explicitly concealed draft hidden; revealed drafts follow the inactive window policy.
    public static func requiresPrivateDraftCover(
        isRevealed: Bool,
        applicationIsActive: Bool,
        backgroundCoverRequired: Bool
    ) -> Bool {
        !isRevealed || (!applicationIsActive && backgroundCoverRequired)
    }

    /// Only Open Lava App opts into the global cover. Scoped action gates and
    /// temporary credential/data failures cannot turn a confirmed OFF into ON.
    /// An unreadable choice at cold launch stays conservative until classified.
    public static func requiresBackgroundCover(appUnlockIsSelected: Bool?) -> Bool {
        appUnlockIsSelected != false
    }
}
