import Foundation

/// Localized string lookup against LavaSecCore's own resource bundle
/// (`Bundle.module`, the per-locale `*.lproj/Localizable.strings`). This lets app
/// extensions that link LavaSecCore — notably the Live Activity widget, which has
/// no catalog of its own — share the same translations instead of shipping
/// hardcoded English. Same mechanism the notification bodies already use.
public enum LavaCoreStrings {
    /// Look up `key` in LavaSecCore's localization table for the current locale.
    public static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: .module)
    }

    /// Look up `key` as a format string and substitute `arguments`, using the
    /// current locale for number formatting.
    public static func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key), locale: .autoupdatingCurrent, arguments: arguments)
    }

    /// Look up `key` in the `.lproj` for `languageCode` — the shared
    /// `LavaNotificationLanguage` pin — falling back to the ambient process resolution
    /// when the code is nil/unknown or the key is missing. Routes through the same
    /// direct-`.strings` read the notification posters use (`LavaNotificationLocalizer`):
    /// Foundation's bundle lookup applies the PROCESS's preferred-language matching and
    /// refuses a non-preferred `.lproj`, so an out-of-process renderer (the Live Activity
    /// widget) would stay stuck in the system language regardless of the app's per-app
    /// override — the exact stuck-English activity from the 2026-07-14 incident
    /// (plan Phase 3, lavasec-infra
    /// `plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`).
    public static func localized(_ key: String, languageCode: String?) -> String {
        LavaNotificationLocalizer.string(key, languageCode: languageCode)
    }

    /// Format variant of ``localized(_:languageCode:)``: resolves the template in the
    /// pinned language, then substitutes `arguments` with the current locale's number
    /// formatting (digits follow the device region, words follow the pin — matching the
    /// notification posters' behavior).
    public static func localizedFormat(_ key: String, languageCode: String?, _ arguments: CVarArg...) -> String {
        String(format: localized(key, languageCode: languageCode), locale: .autoupdatingCurrent, arguments: arguments)
    }
}
