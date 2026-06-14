import Foundation

public enum LavaTunnelConfigurationIdentity {
    public static let currentDisplayName = "Lava Security"
    public static let legacyDisplayNames: Set<String> = ["Lava Sec"]

    public static func matches(
        displayName: String?,
        providerBundleIdentifier: String?,
        expectedProviderBundleIdentifier: String
    ) -> Bool {
        guard providerBundleIdentifier == expectedProviderBundleIdentifier,
              let displayName
        else {
            return false
        }

        return displayNamePriority(displayName) < unknownDisplayNamePriority
    }

    public static func displayNamePriority(_ displayName: String?) -> Int {
        guard let displayName else {
            return unknownDisplayNamePriority
        }

        if displayName == currentDisplayName {
            return 0
        }

        if legacyDisplayNames.contains(displayName) {
            return 1
        }

        return unknownDisplayNamePriority
    }

    private static let unknownDisplayNamePriority = 2
}
