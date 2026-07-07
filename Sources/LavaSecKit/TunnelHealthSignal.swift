import Foundation

/// Cross-process channel used to nudge the foreground app when the tunnel's
/// connectivity-relevant health changes, so the Dynamic Island / Live Activity
/// can reflect transient reconnect states promptly (UR-6: Dynamic Island lag
/// during retry/reconnect).
///
/// The health *data* still travels over the reliable provider-message channel
/// (the `flush-tunnel-health` message plus the shared health file); this Darwin
/// notification is only a lightweight wake-up that tells the app fresh health is
/// worth pulling. The NE extension cannot rely on Darwin observers — its run
/// loop is dormant, which is why the app→tunnel Darwin path was retired in
/// favor of provider messages — but a foreground app receives them reliably, so
/// the tunnel→app direction used here is sound.
public enum TunnelHealthSignal {
    public static let darwinNotificationName = "com.lavasec.protection.tunnel-health-changed"
}

/// Posts Darwin notifications via `CFNotificationCenterGetDarwinNotifyCenter`.
/// Conforms to `ProtectionSignalNotifier` so it can stand in anywhere a notifier
/// is expected. Posting is thread-safe.
public struct DarwinProtectionSignalNotifier: ProtectionSignalNotifier {
    public init() {}

    public func postNotification(named name: String) {
        #if canImport(Darwin)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
        #endif
    }
}
