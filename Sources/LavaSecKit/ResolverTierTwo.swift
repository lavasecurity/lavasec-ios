import Foundation

/// What T2 is for one configuration: the fallback the user selected, whatever kind it is.
/// Selection is normalized at the configuration boundary to preserve legacy preferences.
public enum ResolverTierTwo: Equatable, Sendable {
    /// The user declined a fallback. The ladder ends at T1 and refuses (`INV-DNS-1`).
    ///
    /// Also the answer for a probe that must measure T1 alone: `allowsQueryFallback` false means
    /// no tier below the one being measured, or the probe reports the ladder's health as the
    /// resolver's.
    case none
    /// The device's own resolvers — whatever DHCP handed it.
    ///
    /// The network answers the lookup, which is what the user asked for by leaving "Fallback to
    /// Device DNS" on. There is no rule against it: `INV-CHAIN-5` is scoped to a latched chained
    /// session and derived from the chaining toggle, and says nothing here.
    case deviceDNS
    /// A resolver the user picked, on the transport they picked.
    case resolver(DNSResolverPreset)

    /// Whether T2 is a resolver the user named, rather than the device's own or nothing.
    public var isResolver: Bool { resolverPreset != nil }

    /// The resolver filling T2, when one does.
    public var resolverPreset: DNSResolverPreset? {
        guard case .resolver(let preset) = self else { return nil }
        return preset
    }

    /// Resolves T2 from the selection and the runtime facts that can make a chosen tier
    /// unreachable.
    ///
    /// - Parameters:
    ///   - primaryTransport: the selected primary transport, used to interpret legacy
    ///     fallback preferences and prevent a duplicate Device DNS rung.
    ///   - usesExplicitDNSTiers: accepts an alternative beneath any primary when the user
    ///     saved the ordered tier editor; false preserves legacy dormant preferences.
    ///   - effectiveTransport: the transport the plan will actually run. It differs from the
    ///     selection while the device-DNS fallback MODE is active, and a device rung beneath a
    ///     primary that is already device DNS would be the same resolver twice.
    ///   - hasDeviceDNSAddresses: whether any device resolver was captured. A device rung with
    ///     nothing to ask is not a rung.
    ///   - allowsQueryFallback: false for the smoke probe, which must measure T1 alone.
    public static func resolve(
        primaryTransport: DNSResolverTransport,
        effectiveTransport: DNSResolverTransport,
        fallbackToDeviceDNS: Bool,
        usesEncryptedDeviceDNSFallback: Bool,
        usesExplicitDNSTiers: Bool = false,
        encryptedFallbackResolver: DNSResolverPreset,
        allowsQueryFallback: Bool,
        hasDeviceDNSAddresses: Bool
    ) -> ResolverTierTwo {
        guard allowsQueryFallback else { return .none }
        if usesEncryptedDeviceDNSFallback && (usesExplicitDNSTiers || primaryTransport == .deviceDNS) {
            return .resolver(encryptedFallbackResolver)
        }
        guard primaryTransport != .deviceDNS else { return .none }
        guard fallbackToDeviceDNS, effectiveTransport != .deviceDNS, hasDeviceDNSAddresses
        else { return .none }
        return .deviceDNS
    }
}
