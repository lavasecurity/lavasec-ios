import Foundation

public enum GuardFlowStepStatus: String, Equatable, Sendable {
    case healthy
    case inactive
    case issue

    /// The status a connector bar shows for the link between the step above it
    /// and the step below it:
    /// - `issue` (red) if either neighbor has an issue — a failing step turns
    ///   the bars on both sides red.
    /// - `inactive` (grey) only when BOTH neighbors are inactive — e.g. the
    ///   whole pipeline is off, so the link carries nothing.
    /// - `healthy` (green) otherwise — a single inactive step is a passthrough
    ///   that still carries traffic, so its bars stay green.
    public static func linkStatus(_ lhs: GuardFlowStepStatus, _ rhs: GuardFlowStepStatus) -> GuardFlowStepStatus {
        if lhs == .issue || rhs == .issue {
            return .issue
        }

        if lhs == .inactive && rhs == .inactive {
            return .inactive
        }

        return .healthy
    }
}

// The DNS step detail keeps the resolver name and the transport annotation as
// separate components so the UI can truncate a long (custom) name while the
// transport stays visible: "lfidjnsiskdokd… (DoT)" instead of losing the
// annotation to tail truncation.
public struct GuardFlowDNSDetail: Equatable, Sendable {
    public let name: String
    public let transportAnnotation: String?

    public init(name: String, transportAnnotation: String? = nil) {
        self.name = name
        self.transportAnnotation = transportAnnotation
    }

    public var displayText: String {
        guard let transportAnnotation else {
            return name
        }

        return "\(name) (\(transportAnnotation))"
    }
}

public enum GuardStepHealthPolicy {
    public static func dnsStatus(
        isProtectionActive: Bool,
        configuredResolver: DNSResolverPreset,
        health: TunnelHealthSnapshot,
        connectivitySeverity: ProtectionConnectivitySeverity
    ) -> GuardFlowStepStatus {
        guard isProtectionActive else {
            return .inactive
        }

        switch connectivitySeverity {
        case .dnsSlow, .needsReconnect, .networkUnavailable:
            return .issue
        case .usingDeviceDNSFallback:
            return .inactive
        case .healthy, .recovering:
            break
        }

        if configuredResolver.transport == .deviceDNS {
            return .inactive
        }

        return .healthy
    }

    public static func dnsDetail(
        configuredResolver: DNSResolverPreset,
        health: TunnelHealthSnapshot,
        connectivitySeverity: ProtectionConnectivitySeverity
    ) -> String {
        dnsDetailComponents(
            configuredResolver: configuredResolver,
            health: health,
            connectivitySeverity: connectivitySeverity
        ).displayText
    }

    public static func dnsDetailComponents(
        configuredResolver: DNSResolverPreset,
        health: TunnelHealthSnapshot,
        connectivitySeverity: ProtectionConnectivitySeverity
    ) -> GuardFlowDNSDetail {
        switch connectivitySeverity {
        case .usingDeviceDNSFallback:
            return GuardFlowDNSDetail(name: "Device DNS fallback")
        case .dnsSlow, .needsReconnect, .networkUnavailable, .healthy, .recovering:
            break
        }

        return configuredResolver.guardFlowDNSDetailComponents(
            dohHTTPVersion: observedDoHHTTPVersion(configuredResolver: configuredResolver, health: health)
        )
    }

    // DoH3 is best-effort per connection: the annotation is claimed only from
    // an observation that belongs to the CONFIGURED resolver, so a stale
    // sample from a previous resolver or transport never over-claims.
    private static func observedDoHHTTPVersion(
        configuredResolver: DNSResolverPreset,
        health: TunnelHealthSnapshot
    ) -> String? {
        guard let observedAddress = health.lastResolverAddress,
              configuredResolver.dohEndpoints.contains(where: { $0.cacheIdentifier == observedAddress })
        else {
            return nil
        }

        return health.lastDoHHTTPVersion
    }

    public static func filterStatus(
        isProtectionActive: Bool,
        filtersConfigured: Bool,
        hasFilterIssue: Bool,
        filterSnapshotUsable: Bool,
        filterSnapshotLoadComplete: Bool = true
    ) -> GuardFlowStepStatus {
        guard isProtectionActive else {
            return .inactive
        }

        if hasFilterIssue {
            return .issue
        }

        guard filtersConfigured else {
            return .inactive
        }

        guard filterSnapshotLoadComplete else {
            return .healthy
        }

        return filterSnapshotUsable ? .healthy : .issue
    }
}
