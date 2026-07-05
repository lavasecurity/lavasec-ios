import Foundation

public enum ProtectionLifecycleStatus: Equatable, Sendable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
}

public enum ProtectionLifecyclePolicy {
    public static func isProtectionEnabled(_ status: ProtectionLifecycleStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting:
            true
        case .invalid, .disconnected, .disconnecting:
            false
        }
    }

    public static func isStopPending(_ status: ProtectionLifecycleStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting, .disconnecting:
            true
        case .invalid, .disconnected:
            false
        }
    }

    public static func isStartPending(_ status: ProtectionLifecycleStatus) -> Bool {
        switch status {
        case .connecting, .reasserting:
            true
        case .invalid, .disconnected, .connected, .disconnecting:
            false
        }
    }

    public static func isUptimeActive(_ status: ProtectionLifecycleStatus) -> Bool {
        switch status {
        case .connected, .reasserting:
            true
        case .invalid, .disconnected, .connecting, .disconnecting:
            false
        }
    }

    /// Whether protection is DOWN right now but Connect-On-Demand is confirmed armed, so iOS will
    /// bring the tunnel back on its own as soon as a network path is available again (e.g. after
    /// signal returns from an elevator/tunnel).
    ///
    /// The NEVPNStatus is `.disconnected` in BOTH the "user turned it off" case and the
    /// "temporarily dropped but still armed to auto-reconnect" case — the status alone can't tell
    /// them apart. The confirmed-on-demand bit (written only after `saveToPreferences` confirms the
    /// arming, and cleared before an intentional turn-off disables on-demand) is what disambiguates:
    /// `.disconnected` + armed ⇒ a self-reconnect is pending, NOT a fully-off state. Callers use this
    /// to render a "Reconnecting" affordance instead of the fully-off "Turn On" surface, which would
    /// otherwise wrongly read as "protection is off" while iOS is merely waiting for the network.
    ///
    /// Only `.disconnected` qualifies: `.connecting`/`.reasserting` are already surfaced as transitioning,
    /// `.connected` is up, `.disconnecting` is a turn-off in progress, and `.invalid` means the profile
    /// isn't loaded at all (nothing armed to reconnect).
    public static func isAwaitingOnDemandReconnect(
        status: ProtectionLifecycleStatus,
        onDemandConfirmedEnabled: Bool
    ) -> Bool {
        guard onDemandConfirmedEnabled else { return false }
        switch status {
        case .disconnected:
            return true
        case .invalid, .connecting, .connected, .reasserting, .disconnecting:
            return false
        }
    }

    public static func shouldDisablePrimaryAction(
        status: ProtectionLifecycleStatus,
        isConfiguring: Bool
    ) -> Bool {
        isConfiguring
    }

    public static func shouldDisableProtectionForToggle(_ status: ProtectionLifecycleStatus) -> Bool {
        isProtectionEnabled(status)
    }
}
