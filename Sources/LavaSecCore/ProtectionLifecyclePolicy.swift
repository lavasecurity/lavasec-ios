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
