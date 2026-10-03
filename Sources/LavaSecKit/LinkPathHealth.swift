import Foundation

/// The link/path health signal — the second ``ConnectivityHealthSignal``.
///
/// It reports whether the network path the tunnel rides is currently satisfied — the dimension the
/// DNS module surfaces only incidentally, through the policy's top-precedence `.networkUnavailable`.
/// Pulling it into its own signal lets the supervisor (Slice D) treat "the link is down" as a fact
/// distinct from "DNS is failing": a link outage is not a resolver problem, and its recovery (wait
/// for the path to return, not reconnect the resolver) differs.
///
/// The live signal is ``TunnelHealthSnapshot/networkPathIsSatisfied`` — the OS path monitor's view,
/// which applies to both DNS-only and chained modes. The chained `chainedLinkOutageCount` is a
/// CUMULATIVE counter, not a current state, so it is telemetry rather than a live verdict and is not
/// read here; a "flapping" refinement over a windowed delta of it would belong with the provider-held
/// baselines the data-path signal introduces, not in this pure current-state read.
///
/// The reason reuses ``ProtectionConnectivitySeverity/networkUnavailable``'s `diagnosticLabel` so the
/// link vocabulary cannot drift from the label the DNS path already emits for the same condition —
/// which is also what lets the supervisor dedupe the two when both report it.
public struct LinkPathHealth: ConnectivityHealthSignal {
    public let id: ConnectivityHealthSignalID = .linkPath

    public init() {}

    public func verdict(for inputs: ConnectivityHealthInputs, now: Date) -> HealthVerdict {
        // Mirror the DNS module's disconnected shortcut: while protection is off the link state is
        // moot, and the supervisor consults connectivity health only while connected.
        guard inputs.isConnected else { return .healthy }
        return inputs.health.networkPathIsSatisfied
            ? .healthy
            : .down(ProtectionConnectivitySeverity.networkUnavailable.diagnosticLabel)
    }
}
