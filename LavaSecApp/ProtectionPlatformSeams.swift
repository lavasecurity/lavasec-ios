import ActivityKit
import Foundation
import UIKit

/// Quarantines the two rewrite-class iOS-only features behind protocols so the view
/// model depends on the seam, not the framework. Each has an Android-native stance
/// (see the design-system plan's "Android Stance & Structural Ports").

/// App-icon personalization (iOS alternate icons). Android: themed icons / launcher
/// shortcut / skip — conforms with a platform-native implementation.
@MainActor
protocol IconPersonalizing {
    var supportsAppIconPersonalization: Bool { get }
    var currentAppIconName: String? { get }
    func setAppIcon(_ iconName: String?) async throws
}

@MainActor
struct UIKitIconPersonalizer: IconPersonalizing {
    var supportsAppIconPersonalization: Bool { UIApplication.shared.supportsAlternateIcons }
    var currentAppIconName: String? { UIApplication.shared.alternateIconName }
    func setAppIcon(_ iconName: String?) async throws {
        try await UIApplication.shared.setAlternateIconName(iconName)
    }
}

/// Ambient protection presence. The iOS conformance is `LavaLiveActivityController`
/// (ActivityKit Live Activities / Dynamic Island); Android conforms with the
/// VpnService foreground-service notification (+ optional Quick Settings tile).
@MainActor
protocol AmbientProtectionPresenter: AnyObject, Sendable {
    var canOfferLiveActivities: Bool { get }
    func startObservingAuthorizationChanges(onChange: @escaping @MainActor (Bool) -> Void)
    func stopObservingAuthorizationChanges()
    func reconcile(
        usesLiveActivities: Bool,
        protectionState: LavaActivityAttributes.ProtectionState?,
        resumeDate: Date?,
        shieldStyle: GuardianShieldStyle,
        pauseRequiresAuthentication: Bool
    ) async
}
