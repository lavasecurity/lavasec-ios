import Foundation

/// Configuration failures the app can explain before asking iOS to start a tunnel.
/// Unknown storage is never interpreted as absence or permission to turn chaining off.
public enum ChainedConfigurationIssue: String, Error, Equatable, Sendable {
    /// No committed configuration exists.
    case missingConfiguration
    /// A configuration exists but its device-bound private key is gone.
    case missingPrivateKey
    /// The configuration or its key cannot currently be read consistently.
    case unavailable

    /// User-facing recovery copy, localized by the presenting process.
    public var message: String {
        switch self {
        case .missingConfiguration:
            return "Add a WireGuard configuration in VPN chaining, or turn chaining off."
        case .missingPrivateKey:
            return "Your WireGuard key is missing. Load the configuration again, or turn chaining off."
        case .unavailable:
            return "Your WireGuard configuration couldn't be read. Try again after unlocking your device."
        }
    }
}

/// Setup disclosure and routing are separate choices. The provider retains its full
/// readiness check; this admission rule prevents the empty-configuration UI dead end.
public enum ChainedSetupPolicy {
    /// Editing can repair a failed startup. Only account/hardware restrictions and
    /// unknown device state prevent replacement; neither requires a saved key first.
    public static func canEditConfiguration(_ inputs: ChainedSurfaceInputs) -> Bool {
        inputs.hasEntitlement && !inputs.deviceStateIsUnreadable
            && inputs.ineligibility != .notEntitled && inputs.ineligibility != .insufficientMemory
    }

    /// Resolves only configuration availability, independently of the stored ON/OFF choice.
    public static func configurationIssue(_ inputs: ChainedSurfaceInputs) -> ChainedConfigurationIssue? {
        if inputs.storeIsUnreadable { return .unavailable }
        if !inputs.hasStoredConfiguration { return .missingConfiguration }
        if inputs.storedConfigurationIsMissingKey { return .missingPrivateKey }
        return nil
    }

    /// Whether a new explicit ON request is admissible. OFF never needs this permission.
    public static func canEnable(setupEnabled: Bool, inputs: ChainedSurfaceInputs) -> Bool {
        guard setupEnabled, configurationIssue(inputs) == nil else { return false }
        var requested = inputs
        requested.preferenceEnabled = true
        // Surrender is retried at the explicit Guard-start boundary. It does not make
        // an otherwise usable configuration impossible to select again.
        requested.isSurrenderSuppressed = false
        // The explicit Guard start clears this retryable breaker. Blocking configuration
        // repair or selection on it would recreate the very dead end setup is meant to fix.
        if requested.ineligibility == .startupCrashLoop { requested.ineligibility = nil }
        return ChainedOperationalState.resolve(requested) == .ready
    }
}
