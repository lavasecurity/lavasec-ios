import Foundation
import Network

/// Builds the `NWParameters` for the upstream UDP socket, with the interface binding that
/// keeps encapsulated traffic out of our own tunnel.
///
/// ## The loop this prevents
///
/// Under `INV-CHAIN-1` the tunnel claims `0.0.0.0/0`, which includes the peer's address. An
/// unbound socket therefore routes its own encapsulated datagrams back into the tunnel that
/// produced them: the packet loop reads them, encapsulates them again, and sends them into the
/// tunnel again. Not a slow leak — an immediate loop that consumes the CPU and the memory
/// budget of a process living under a ~50 MB jetsam ceiling (`INV-MEM-1`), and takes the user's
/// connectivity with it.
///
/// ## Required, and there is no "preferred" to choose instead
///
/// `ChainedUpstreamEgress.bind` states the obligation the value type cannot carry: the socket
/// must be *required* to use the interface, "not merely prefer it — a preference is satisfied
/// by the tunnel, which is the loop this type exists to prevent". `NWParameters` has no
/// preference spelling at all — no `preferredInterface`, no `preferredInterfaceType` — so the
/// preference that comment warns about is not an API one could pick by mistake. It is the
/// DEFAULT: parameters with no interface requirement route by the system's own choice, and
/// under a `0.0.0.0/0` claim that choice can be our tunnel. The mistake to guard against is
/// leaving the requirement unset, not setting the wrong kind of one.
/// pinned: ChainedUpstreamChannelParametersTests.testTheInterfaceRequirementIsSetRatherThanLeftDefault
///
/// ## `.other` is Network's "no requirement", not a virtual-interface type
///
/// This is the trap in this file, and it is asymmetric. A fresh `NWParameters.udp` reports
/// `requiredInterfaceType == .other`, which is how Network spells "unconstrained" in a
/// non-optional field. In the PROHIBITED list the same case names the actual type — the one
/// `utun` reports, which is why `ChainedUpstreamLinkKind.other` is refused outright.
///
/// So `.other` must never be used as a sentinel meaning "unsatisfiable" in the required slot.
/// The first version of this file did exactly that — mapping non-physical kinds to `.other` on
/// the reasoning that a prohibited type would make the parameters unusable — and it would have
/// produced parameters with NO interface requirement: the permissive answer, silently, in the
/// function written to prevent it. The mapping is optional now, and an unmappable kind refuses
/// to produce parameters rather than producing loose ones.
/// pinned: ChainedUpstreamChannelParametersTests.testTheDefaultRequirementIsOtherSoItCannotMeanUnsatisfiable
///
/// ## The type is not the identity, and only the identity closes the loop
///
/// `requiredInterfaceType` narrows the socket to a CATEGORY. Two physical interfaces of the
/// same category defeat that on their own — a Mac with Wi-Fi and a USB-Ethernet dongle, an
/// iPhone with Wi-Fi and a Wi-Fi-backed hotspot link — and so does the disappearance of the
/// selected interface while another of its kind survives, because the requirement is still
/// satisfied by the one we did not choose. `ChainedUpstreamInterface` already says the identity
/// is what matters ("a socket is bound to an interface, not to a category"), and the policy
/// selects one named interface; installing only its type discards the selection and keeps the
/// half of it that cannot prevent the loop.
///
/// So `requiredInterface` — the live `NWInterface`, strictly stronger than the type — is
/// installed here too, and the parameters are refused when no live interface matches the
/// selection. Refusing is the whole point: the alternative to identity-binding is type-only
/// binding, and under a `0.0.0.0/0` claim the interface that type accidentally satisfies can be
/// the tunnel's own peer path. A degraded binding is the encapsulation loop, not a slower one.
/// pinned: ChainedUpstreamChannelParametersTests.testParametersAreRefusedWhenNoLiveInterfaceMatchesTheSelection
///
/// ## What is testable here, and what is not
///
/// `NWInterface` has no initialiser — it exists only inside a live `NWPath` — so the POSITIVE
/// case cannot be constructed offline and its test degrades to a skip on a host with no
/// physical interface. The REFUSAL is fully deterministic without a network, and it is the
/// branch that carries the safety property, so that is the one that is pinned. The identity
/// slot also has an honest `nil` default, unlike the type slot above, so "unset" is
/// unambiguous here and needs no sentinel reasoning.
/// pinned: ChainedUpstreamChannelParametersTests.testTheIdentitySlotHasAnHonestUnsetDefault
public enum ChainedUpstreamChannelParameters {
    /// Parameters for a UDP socket bound to the one live interface `binding` names, or `nil`
    /// when the binding cannot be constrained or nothing live matches it.
    ///
    /// - Parameters:
    ///   - binding: the interface the egress policy selected. Its type already guarantees a
    ///     physical link — `ChainedBindableInterface` refuses virtual kinds and virtual name
    ///     prefixes — so a `nil` from the type mapping means something bypassed that
    ///     initialiser.
    ///   - liveInterfaces: the interfaces a STARTED path monitor currently reports. Passed in
    ///     rather than read here because this type is a pure value builder and the read is
    ///     neither pure nor instant; `ChainedUpstreamLivePath` owns it.
    /// - Returns: `nil` in every case where the socket could not be pinned to the selected
    ///   interface. The caller must refuse to open a socket rather than open one that is
    ///   merely type-constrained.
    public static func make(
        for binding: ChainedBindableInterface, among liveInterfaces: [NWInterface]
    ) -> NWParameters? {
        guard let parameters = typeConstrained(for: binding),
              let requiredType = interfaceType(for: binding.kind),
              let live = liveInterface(named: binding.name, of: requiredType, among: liveInterfaces)
        else { return nil }
        parameters.requiredInterface = live
        return parameters
    }

    /// The type-only half, which is NOT safe to hand to a socket on its own.
    ///
    /// Internal, and internal deliberately: these are the parameters the identity constraint
    /// exists to strengthen, so the only caller allowed to use them is `make` above, which
    /// completes them or throws them away. Split out because everything it sets is assertable
    /// from a value a test can read, while the identity is not.
    static func typeConstrained(for binding: ChainedBindableInterface) -> NWParameters? {
        guard let requiredType = interfaceType(for: binding.kind) else { return nil }
        let parameters = NWParameters.udp
        // `.other` here names the virtual-interface type, which is where `utun` lives — the
        // opposite meaning it carries in the required slot above.
        parameters.prohibitedInterfaceTypes = [.other]
        parameters.requiredInterfaceType = requiredType
        // A proxy would carry our datagrams somewhere we did not choose, on a path the
        // interface requirement does not describe.
        parameters.preferNoProxies = true
        return parameters
    }

    /// The live interface the selection names, matched on NAME and TYPE together.
    ///
    /// The type is re-checked rather than assumed because the two constraints are installed
    /// into the same parameter set: a live `en0` reporting `.wifi` against a selection that
    /// said `en0`/`wiredEthernet` would produce parameters no interface can satisfy, and
    /// unsatisfiable parameters fail the way this file least wants — silently, as a connection
    /// that never establishes and sends that never complete, which the outage driver reads as
    /// an unresponsive peer for the whole budget. Disagreement means the selection was made
    /// against a path that has since changed, so refusing and rebuilding is the honest answer.
    ///
    /// A name can legitimately appear more than once in `availableInterfaces` (measured: `en0`
    /// twice, from distinct path elements). Those entries carry the same index and type and
    /// compare equal, so the first match is not a choice between candidates.
    static func liveInterface(
        named name: String, of type: NWInterface.InterfaceType, among candidates: [NWInterface]
    ) -> NWInterface? {
        candidates.first { $0.name == name && $0.type == type }
    }

    /// Maps the policy's link kind onto Network's interface type, or `nil` when there is no
    /// type that constrains it.
    ///
    /// `nil` rather than `.other` for the non-physical kinds — see the type's note. Returning a
    /// value that Network reads as "unconstrained" would be the permissive answer wearing the
    /// costume of a strict one.
    static func interfaceType(for kind: ChainedUpstreamLinkKind) -> NWInterface.InterfaceType? {
        switch kind {
        case .wifi: return .wifi
        case .cellular: return .cellular
        case .wiredEthernet: return .wiredEthernet
        case .loopback, .other: return nil
        }
    }
}

extension ChainedUpstreamLinkKind {
    /// Maps Network's interface type onto the policy's link kind — the provider-side half of
    /// the mirror, owned here beside its reverse (`interfaceType(for:)`) so the provider can
    /// map "and decide nothing of its own" (the enum's doc) without growing a switch that
    /// drifts from this file's.
    ///
    /// Total, unlike the reverse map: every `NWInterface.InterfaceType` lands somewhere, and
    /// anything unrecognized — including cases a future SDK adds — lands on `.other`, which
    /// the egress policy REFUSES. Fail closed is the only safe answer for a link kind nobody
    /// has reasoned about; binding to it would put the tunnel's egress on an interface class
    /// this module has never seen.
    /// pinned: ChainedUpstreamLinkKindMappingTests.testEveryInterfaceTypeLandsOnItsMirroredKind
    public init(mirroring type: NWInterface.InterfaceType) {
        switch type {
        case .wifi: self = .wifi
        case .cellular: self = .cellular
        case .wiredEthernet: self = .wiredEthernet
        case .loopback: self = .loopback
        case .other: self = .other
        @unknown default: self = .other
        }
    }
}
