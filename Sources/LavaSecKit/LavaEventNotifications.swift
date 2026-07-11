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
/// All notification copy (these event bodies AND the connectivity titles/messages) is localized across the
/// 10 supported locales via THIS package's catalog (`Bundle.module`), so it resolves even in the App Intents
/// extension and NE tunnel bundles. The language is pinned via `LavaNotificationLanguage` so those extension
/// processes — which do NOT inherit the app's iOS per-app language override — still render in the SAME
/// language as the app UI rather than falling back to the system language.
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

    /// Persists whether a notification category is enabled in the supplied shared defaults store.
    public static func setEnabled(_ enabled: Bool, for category: LavaNotificationCategory, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: category.enabledDefaultsKey)
    }
}

/// Cross-process pin of the language the app's UI is CURRENTLY resolved to, so notifications posted by the
/// App Intents extension (Focus filter switches) and the NE tunnel (connectivity) — separate processes that
/// do NOT inherit the app's iOS per-app language override — render in the SAME language as the app UI rather
/// than falling back to the system language.
///
/// The app publishes its resolved localization into the shared app-group defaults on every foreground; each
/// poster reads it back and localizes against the matching `.lproj` of `Bundle.module`. When the pin is
/// absent (e.g. before the app's first foreground), the posters fall back to the ambient `Bundle.module`
/// resolution — which is already correct inside the app process, so only the extension/tunnel need the pin.
public enum LavaNotificationLanguage {
    /// App-group defaults key holding the app's resolved LavaSecCore localization code (e.g. `"zh-Hans"`).
    public static let defaultsKey = "lavasec.notifications.appLanguageCode"

    /// The LavaSecCore localization the app is CURRENTLY resolving to. Computed against `Bundle.module`'s own
    /// localizations so it is always one this package can actually load; when read from the app process it
    /// honors an iOS per-app language override the extension/tunnel can't see. `nil` only if the bundle
    /// somehow reports no localization.
    public static func currentAppLocalization() -> String? {
        Bundle.module.preferredLocalizations.first
    }

    /// Publish `code` (typically `currentAppLocalization()`) so the extension/tunnel posters can read it.
    /// A `nil`/empty code clears the pin (posters fall back to ambient resolution).
    public static func publish(_ code: String?, to defaults: UserDefaults) {
        if let code, !code.isEmpty {
            defaults.set(code, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    /// The pinned localization code, or `nil` when unset/empty.
    public static func pinnedCode(in defaults: UserDefaults) -> String? {
        guard let code = defaults.string(forKey: defaultsKey), !code.isEmpty else { return nil }
        return code
    }
}

/// Localizes a notification key against a SPECIFIC `.lproj` of `Bundle.module` (the pinned language) rather
/// than the ambient process resolution. Internal glue shared by the event poster and the connectivity policy
/// so the two never drift on how they honor `LavaNotificationLanguage`.
enum LavaNotificationLocalizer {
    /// Localize `key` for `languageCode` by reading THAT locale's `Localizable.strings` out of `Bundle.module`
    /// directly, falling back to the ambient `Bundle.module` resolution when the code is `nil`, its `.lproj` is
    /// absent, or the key is missing there.
    ///
    /// Reading the `.strings` file directly (rather than `path(forResource:ofType:"lproj")` +
    /// `Bundle.localizedString`) is deliberate: Foundation's resource-localization lookup applies the process's
    /// preferred-language matching and will refuse a non-preferred `.lproj` (observed with `zh-Hans`), which is
    /// exactly the ambient resolution we're trying to override. The catalog ships plain per-locale `.strings`
    /// (not a compiled `.xcstrings`), so a direct read resolves in both SwiftPM and Xcode builds.
    static func string(_ key: String, languageCode: String?) -> String {
        if let languageCode, let value = stringFromLProj(key, languageCode: languageCode) {
            return value
        }
        return Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    }

    /// The value for `key` in the pinned locale's `Localizable.strings`, or `nil` if the locale or key is
    /// absent. Locates the file by literal path (bundle subdirectory lookup, then the resource root) so no
    /// locale matching is applied — the whole point is to select a specific locale, not the preferred one.
    ///
    /// The `.lproj` directory name comes from `Bundle.module.localizations` (the identifiers the built bundle
    /// actually contains), matched case-insensitively against `languageCode`, rather than interpolating the
    /// pinned code verbatim: a region-qualified code like `zh-Hans`/`pt-BR` can be cased differently in the
    /// generated resource bundle than what `currentAppLocalization()` publishes, and a verbatim literal path
    /// would then miss on a case-sensitive volume and silently fall back to the ambient (system) locale — the
    /// exact mismatch this exists to prevent.
    private static func stringFromLProj(_ key: String, languageCode: String) -> String? {
        guard let localization = resolvedLocalization(for: languageCode) else { return nil }
        let lproj = "\(localization).lproj"
        let url = Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: lproj)
            ?? Bundle.module.resourceURL?.appendingPathComponent("\(lproj)/Localizable.strings")
        guard let url,
              let table = NSDictionary(contentsOf: url) as? [String: String]
        else {
            return nil
        }
        return table[key]
    }

    /// The bundle's own localization identifier best matching `languageCode` — an exact hit first, then a
    /// case-insensitive match — so the `.lproj` path is always grounded in a directory that actually exists.
    /// `nil` when the bundle carries no such localization.
    private static func resolvedLocalization(for languageCode: String) -> String? {
        let available = Bundle.module.localizations
        if let exact = available.first(where: { $0 == languageCode }) {
            return exact
        }
        return available.first(where: { $0.caseInsensitiveCompare(languageCode) == .orderedSame })
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
    ///
    /// `languageCode` pins the language to the app's UI language (`LavaNotificationLanguage`) so the extension
    /// renders in the same language as the app rather than the system language; `nil` uses ambient resolution.
    public static func filterSwitchBody(committed: Bool, filterName: String, languageCode: String? = nil) -> String {
        let key = committed ? "notif.body.switchedTo" : "notif.body.couldNotSwitchTo"
        return String(format: LavaNotificationLocalizer.string(key, languageCode: languageCode), filterName)
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
            // Never request authorization from a background event post — the app's contextual foreground
            // flow (onboarding) owns the prompt. This keeps the poster safe to call from the App Intents
            // extension / tunnel and resilient to Apple tightening background-extension notification policy
            // (Kilo #29): we only ADD a request when already authorized/provisional/ephemeral, never prompt.
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
