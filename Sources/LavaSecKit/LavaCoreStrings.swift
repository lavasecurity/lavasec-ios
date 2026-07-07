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
}
