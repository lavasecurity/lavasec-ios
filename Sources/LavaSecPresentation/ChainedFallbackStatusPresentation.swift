import LavaSecKit

extension ChainedFallbackStatus {
    /// One configuration-redacted message for the compact Settings status panel.
    public var compactMessage: String {
        switch self {
        case .unavailableInFullTunnel: "Allowed DNS lookups use your WireGuard VPN"
        case .readyUnused: "Fallback DNS is ready if needed"
        case .working: "Fallback DNS has handled lookups"
        case .off: "DNS fallback is off"
        case .awaitingSession: "DNS fallback status is not available yet"
        case .pendingDisable: "DNS fallback will turn off after reconnecting"
        case .awaitingRestart: "DNS fallback changes are waiting for reconnect"
        case .notForwarded: "Fallback DNS is not answering"
        case .answeringWithoutResolving: "Fallback DNS is not resolving lookups"
        case .noneUsable: "DNS fallback is unavailable with these settings"
        }
    }

    /// Success tint is earned by actual resolution evidence, never readiness alone.
    public var isCompactSuccess: Bool {
        if case .working = self { return true }
        return false
    }
}
