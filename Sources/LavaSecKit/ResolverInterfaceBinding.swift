import Foundation

/// Which interface a resolver socket is allowed to leave from.
///
/// ## Why this exists
///
/// Every socket resolver in the app egresses wherever the routing table sends it, which is the
/// physical interface. That is correct in DNS-only mode and is the leak in chained mode: the
/// user routed their traffic through an upstream precisely so their local network could not see
/// it, and their DNS would keep going out around the tunnel, to the same observer, naming every
/// site they visit.
///
/// It was believed until 2026-07-29 that nothing could be done about this for TCP, because a
/// retry needs a TCP endpoint and the tunnel has none. That was wrong. A socket bound to
/// ``NEPacketTunnelProvider``'s `virtualInterface` has its packets delivered to the provider's
/// own `packetFlow`, with the tunnel's address as their source — measured on device, both
/// transports, with the unbound control legs producing nothing. So the kernel is the endpoint
/// and the tunnel carries the result.
///
/// ## Why a type and not an optional index
///
/// `UInt32?` would make "forgot to bind" and "deliberately unbound" the same value, and they
/// are the two ends of a privacy decision. Spelling them as distinct cases means a call site
/// has to state which one it means, and a reviewer can see it. This is the technique
/// `ChainedResolverEgress` uses for the same class of mistake.
///
/// The binding is a REQUIREMENT, not a preference: ``mustBindBeforeConnect`` is what the socket
/// layer fails closed on. A chained socket that could not be bound must not fall back to the
/// physical interface, because that fallback is indistinguishable from the leak. The same holds
/// for ``boundToPhysical``: once the DNS capture floor claims a destination's route
/// (``DNSCaptureFloor``), an unbound socket to it follows the routing table back INTO the tunnel
/// and is refused by a peer that does not carry it, so a failed physical pin must fail the query
/// rather than silently re-enter.
public enum ResolverInterfaceBinding: Equatable, Sendable {
    /// The routing table chooses. DNS-only mode, and every path that has no tunnel to prefer.
    case systemChosen
    /// The socket must be bound to this interface index before `connect(2)`, and its creation
    /// must fail if it cannot be. Chained mode, where the index is the provider's
    /// `virtualInterface.index`.
    case boundToTunnel(interfaceIndex: UInt32)
    /// The socket must be bound to the PHYSICAL interface the device is currently routing over,
    /// and its creation must fail if it cannot be. F2's scoped answer: the DNS capture floor
    /// claimed this destination's route, so `.systemChosen` would re-enter the tunnel, and the
    /// upstream's own `AllowedIPs` do NOT already carry it — so the physical path is the only
    /// road the query may take. The index is the live primary interface index from the monitored
    /// `NWPath`, never guessed.
    case boundToPhysical(interfaceIndex: UInt32)

    /// The index a socket must be pinned to, or nil when the routing table decides.
    ///
    /// The tunnel and physical cases both pin, deliberately: which interface is a separate
    /// question from whether there is a pin at all, and a caller that cannot tell them apart
    /// only needs the index.
    public var requiredInterfaceIndex: UInt32? {
        switch self {
        case .systemChosen:
            return nil
        case .boundToTunnel(let interfaceIndex):
            return interfaceIndex
        case .boundToPhysical(let interfaceIndex):
            return interfaceIndex
        }
    }

    /// Whether failing to apply the binding must fail the socket.
    ///
    /// The whole point of the type. `IP_BOUND_IF` failing on a chained socket means the query
    /// is about to leave on the physical interface — the exact outcome chained mode exists to
    /// prevent — so the socket is refused and the query fails closed per `INV-DNS-1`.
    /// pinned: ResolverInterfaceBindingTests.testAChainedBindingIsARequirementAndNotAPreference
    public var mustBindBeforeConnect: Bool {
        requiredInterfaceIndex != nil
    }

    /// Stable identifier for device logs. Never user copy, and never the index — an interface
    /// index is a device-local number with no privacy weight, but it is also noise in a field
    /// log that already records the mode.
    public var logValue: String {
        switch self {
        case .systemChosen:
            return "resolver-socket-system-chosen"
        case .boundToTunnel:
            return "resolver-socket-bound-to-tunnel"
        case .boundToPhysical:
            return "resolver-socket-bound-to-physical"
        }
    }
}
