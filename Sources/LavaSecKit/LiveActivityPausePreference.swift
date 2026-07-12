import Foundation

/// User-configurable length of the Live Activity "Pause for N min" action.
///
/// Owns the valid range, the default, the shared app-group key, and the clamping
/// so the three readers — Settings (the app), the widget button label, and the
/// pause intent — can never drift on the number. The value is persisted in the
/// app-group defaults because the widget and the intent run outside the app.
public enum LiveActivityPausePreference {
    public static let defaultMinutes = 5
    public static let minimumMinutes = 1
    public static let maximumMinutes = 30
    public static let minutesRange = minimumMinutes...maximumMinutes
    /// The app-group defaults key persisting the selected pause duration.
    public static let defaultsKeyName = "lavasec.customization.liveActivityPauseMinutes"
    /// Compatibility alias for existing consumers of the public package product.
    public static let defaultsKey = defaultsKeyName

    public static func clamp(_ minutes: Int) -> Int {
        min(maximumMinutes, max(minimumMinutes, minutes))
    }

    /// The stored length in minutes, falling back to `defaultMinutes` when unset
    /// (UserDefaults returns 0 for an absent integer key) and always clamped to
    /// the valid range so a stale or out-of-range write can never widen the
    /// off-protection window.
    public static func minutes(from storage: any ProtectionKeyValueStorage) -> Int {
        let stored = storage.integer(forKey: defaultsKeyName)
        guard stored != 0 else {
            return defaultMinutes
        }
        return clamp(stored)
    }

    public static func setMinutes(_ minutes: Int, in storage: any ProtectionKeyValueStorage) {
        storage.set(clamp(minutes), forKey: defaultsKeyName)
    }

    public static func duration(forMinutes minutes: Int) -> TimeInterval {
        TimeInterval(clamp(minutes) * 60)
    }
}
