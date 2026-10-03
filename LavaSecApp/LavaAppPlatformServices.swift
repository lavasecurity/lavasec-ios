import Foundation
import LavaSecKit

/// App-side notification effects. The delivery policy and cross-process history stay
/// native; presentation callers request evaluation rather than owning notification state.
@MainActor
protocol ProtectionNotificationPresenting: AnyObject {
    func scheduleIfNeeded(
        assessment: ProtectionConnectivityAssessment,
        health: TunnelHealthSnapshot,
        now: Date
    )
    func requestAuthorization() async -> Bool
}

extension ProtectionNotificationPresenting {
    func scheduleIfNeeded(assessment: ProtectionConnectivityAssessment, health: TunnelHealthSnapshot) {
        scheduleIfNeeded(assessment: assessment, health: health, now: Date())
    }
}

/// The first app composition boundary for native presentation effects. Construction is
/// side-effect free: observation/authorization remains at the existing lifecycle sites.
/// A headless model can use the same factory without starting foreground effects.
///
/// This deliberately contains only migrated dependencies, not the mutable app hub.
/// See infra's mobile UI plan, slice 1B; feature and durable service ownership follow
/// separately so this extraction cannot change their transaction or initialization order.
@MainActor
struct LavaAppPlatformServices {
    let protectionNotifications: any ProtectionNotificationPresenting
    let ambientProtection: any AmbientProtectionPresenter

    static func live() -> Self {
        Self(
            protectionNotifications: ProtectionUserNotificationController(),
            ambientProtection: LavaLiveActivityController()
        )
    }
}
