import Foundation
import UserNotifications

/// User-facing local-notification categories, each surfaced as its own toggle in
/// Customization → Notifications. The toggles live in the shared app-group defaults so EVERY process
/// that can post — the app, the App Intents extension (Focus switches), and the Network Extension
/// tunnel (connectivity) — reads the same on/off switch.
///
/// `connectivity` deliberately gates the PRE-EXISTING reconnect/DNS notifications
/// (`ProtectionConnectivityNotificationPolicy`); the other three are simple event notifications posted
/// through `LavaEventNotificationPoster` (no cooldown/supersession policy — they are discrete events).
///
/// LAV-100 follow-up: the notification BODY strings are English for now, matching the existing
/// connectivity notifications (also English-only). Localizing all notification copy across the 10
/// locales — including the extension's bundle — is a separate pass.
public enum LavaNotificationCategory: String, CaseIterable, Sendable {
    /// "Switched to <Filter>" — a Focus auto-switch changed the active filter. Posted ONLY when the app
    /// is closed/backgrounded (the foreground app shows the change in-UI, so a banner would be redundant).
    case filterChanged = "filter-changed"
    /// "Couldn't switch to <Filter>" — a Focus switch was refused (e.g. auth-to-edit on, target gone).
    case filterCouldNotApply = "filter-could-not-apply"
    /// Gates the existing connectivity/reconnect notifications (DNS not resolving, network unavailable, …).
    case connectivity = "connectivity"

    /// App-group defaults key for this category's enabled flag.
    public var enabledDefaultsKey: String { "lavasec.notifications.enabled.\(rawValue)" }
}

/// Cross-process read/write of the per-category notification toggles over the shared app-group
/// defaults. DEFAULT ON: a fresh install opts into every category (the user opts out per-category in
/// Customization → Notifications). Pure value access — no `AppViewModel`, callable from any process.
public enum LavaNotificationPreferences {
    /// Whether `category` is enabled. Absent key ⇒ `true` (default-on).
    public static func isEnabled(_ category: LavaNotificationCategory, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: category.enabledDefaultsKey) as? Bool ?? true
    }

    public static func setEnabled(_ enabled: Bool, for category: LavaNotificationCategory, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: category.enabledDefaultsKey)
    }
}

/// Posts a SIMPLE event notification (filter switched / couldn't apply / paused-resumed) — gated by the
/// category toggle and the existing notification permission, de-duped by request identifier. Distinct
/// from the connectivity poster (`ProtectionConnectivityNotificationPolicy` + the app/tunnel controllers),
/// which keeps its freshness/cooldown/supersession policy; these are discrete one-shot events.
///
/// Permission is CHECKED but never REQUESTED here: a background poster (extension/tunnel) must not raise a
/// system permission prompt out of context. The app's contextual flow (onboarding / enabling a toggle)
/// owns the request. Takes the `UserDefaults`, the `UNUserNotificationCenter`, and the route `userInfo` +
/// request identifier explicitly so this stays in LavaSecCore without depending on the app-group constants.
public enum LavaEventNotificationPoster {
    /// Localized body for a Focus filter-switch outcome — "Switched to <name>" / "Couldn't switch to <name>".
    /// Localized against THIS package's catalog (`Bundle.module`) so it resolves in the App Intents extension
    /// (and tunnel), whose bundles don't contain the app's string catalog. `filterName` is the user's filter
    /// name (not localized); the placeholder position is per-locale.
    public static func filterSwitchBody(committed: Bool, filterName: String) -> String {
        let key: String.LocalizationValue = committed ? "notif.body.switchedTo" : "notif.body.couldNotSwitchTo"
        return String(format: String(localized: key, bundle: .module), filterName)
    }

    /// Add (or replace, by identifier) a passive event notification IF `category` is enabled and
    /// notifications are authorized. No-op otherwise. Returns whether a request was actually added.
    @discardableResult
    public static func post(
        category: LavaNotificationCategory,
        requestIdentifier: String,
        title: String,
        body: String,
        userInfo: [String: String],
        defaults: UserDefaults,
        center: UNUserNotificationCenter = .current()
    ) async -> Bool {
        guard LavaNotificationPreferences.isEnabled(category, in: defaults) else { return false }

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined, .denied:
            // Never request from a background event post; the app's contextual flow owns the prompt.
            return false
        @unknown default:
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .passive
        content.userInfo = userInfo

        let request = UNNotificationRequest(identifier: requestIdentifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
