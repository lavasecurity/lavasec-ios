import Foundation

/// The DNS-resolution health signal — the first ``ConnectivityHealthSignal``, and the whole of the
/// scaffold slice.
///
/// It DELEGATES to the unchanged ``ProtectionConnectivityPolicy/assessment(isConnected:health:now:)``
/// — the single source of truth for DNS-health severity — and translates that seven-way severity into
/// the coarser three-level ``HealthVerdict``. It re-implements NONE of the precedence
/// (network-path > restart-worthy failure > device-DNS fallback > encrypted fallback > slow >
/// recovering floor), so it cannot drift from the live policy: that is what makes introducing it a
/// provable no-op. Nothing consults it yet — the composing supervisor arrives in a later slice.
///
/// The verdict's ``HealthVerdict/reason`` is the severity's own `diagnosticLabel`, so a consumer can
/// recover the exact severity — in particular the `.reconnect`-vs-`.turnOff` distinction the
/// three-level collapse would otherwise lose. `.networkUnavailable` is mapped here as part of the
/// whole DNS severity; the link dimension is pulled into its own signal in a later slice.
///
/// When the tunnel is disconnected the delegated policy returns `.healthy` (there is nothing to
/// surface while protection is off), and this module mirrors that for no-op fidelity. A disconnected
/// tunnel is not literally "carrying traffic", but the value is a don't-care: the supervisor
/// evaluates connectivity health only while connected, so it never surfaces this verdict.
public struct DNSResolutionHealth: ConnectivityHealthSignal {
    public let id: ConnectivityHealthSignalID = .dnsResolution

    public init() {}

    public func verdict(for inputs: ConnectivityHealthInputs, now: Date) -> HealthVerdict {
        let severity = ProtectionConnectivityPolicy.assessment(
            isConnected: inputs.isConnected,
            health: inputs.health,
            now: now
        ).severity

        switch severity {
        case .healthy:
            return .healthy
        case .recovering, .usingDeviceDNSFallback, .usingEncryptedFallback, .dnsSlow:
            return .degraded(severity.diagnosticLabel)
        case .networkUnavailable, .needsReconnect:
            return .down(severity.diagnosticLabel)
        }
    }
}
