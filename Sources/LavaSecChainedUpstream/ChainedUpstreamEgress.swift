import Foundation

/// The kind of link an interface is, mirrored from `NWInterface.InterfaceType`.
///
/// Mirrored rather than imported so the decision is testable without `Network` and without a
/// tunnel process. The provider maps `NWInterface.InterfaceType` onto this and decides nothing
/// of its own — the same split `TunnelRoutePlan` uses for routes.
public enum ChainedUpstreamLinkKind: String, Equatable, Sendable, CaseIterable {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    /// Everything else, which on this platform is where **virtual interfaces live** — `utun`
    /// among them. That is why this case is refused rather than treated as unknown-but-maybe.
    case other
}

/// One interface, identified rather than merely categorized.
///
/// The IDENTITY matters as much as the kind. A socket is bound to an interface, not to a
/// category, so "still Wi-Fi" says nothing about whether the binding survived, and the caller
/// needs to be told WHICH interface to bind to rather than which sort.
///
/// It says nothing about whether a socket may be KEPT. An earlier version of this comment
/// claimed a metadata-only path update "must not tear down a working socket", which the final
/// policy contradicts — it rebuilds on every path change, because survival is not observable.
/// See ``ChainedUpstreamSocketLifecycle``.
public struct ChainedUpstreamInterface: Equatable, Sendable {
    /// The system's name for it, `en0` and friends.
    public let name: String
    /// What kind of link it is.
    public let kind: ChainedUpstreamLinkKind
    public init(name: String, kind: ChainedUpstreamLinkKind) {
        self.name = name
        self.kind = kind
    }
}

/// An interface a socket may actually be bound to.
///
/// A separate type because `ChainedUpstreamEgress.bind` used to carry a raw
/// `ChainedUpstreamInterface`, so the loop guard lived only in the factory: any caller could
/// write `.bind(ChainedUpstreamInterface(name: "utun4", kind: .other))` and hand the socket
/// the tunnel itself. That is the recurring defect in this feature — validating in a factory
/// validates the factory, not the type — and here the illegal value is the encapsulation loop.
///
/// Both terms are enforced, because either alone is insufficient. The KIND must be physical,
/// and the NAME must not be one of the virtual prefixes: an interface can report `.wifi` while
/// being named `utun4` if the system's classification is ever wrong or spoofed, and the name
/// is what the caller passes to the socket.
/// pinned: ChainedUpstreamEgressTests.testABindableInterfaceCannotNameAVirtualOne
public struct ChainedBindableInterface: Equatable, Sendable {
    public let interface: ChainedUpstreamInterface
    public var name: String { interface.name }
    public var kind: ChainedUpstreamLinkKind { interface.kind }

    /// Virtual-interface name prefixes. `utun` is the tunnel's own family — binding there is
    /// the loop — and the rest are the other kernel-provided virtual links.
    static let virtualNamePrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "lo"]

    public init?(_ interface: ChainedUpstreamInterface) {
        guard ChainedUpstreamEgressPolicy.physicalLinkKinds.contains(interface.kind) else {
            return nil
        }
        let name = interface.name.lowercased()
        guard !Self.virtualNamePrefixes.contains(where: name.hasPrefix) else { return nil }
        self.interface = interface
    }
}

/// Where the upstream socket is allowed to send.
public enum ChainedUpstreamEgress: Equatable, Sendable {
    /// Bind the socket to this interface. The socket must be *required* to use it, not merely
    /// prefer it — a preference is satisfied by the tunnel, which is the loop this type exists
    /// to prevent. That requirement is enforced by the code that opens the socket, in S8; the
    /// value cannot carry it, and saying so here is the whole of the pairing.
    case bind(ChainedBindableInterface)
    /// Do not open a socket. Chaining cannot start, so the tunnel resolves DNS-only.
    case refuse(ChainedUpstreamEgressPolicy.Refusal)
}

/// What a change in the world means for a socket that is already open.
///
/// There is deliberately no `keep`. Four attempts were made to decide when a socket survives a
/// path change — on link kind, on interface name, on local address, and finally by asking the
/// transport for a Boolean — and the last one failed for the same reason as the first three,
/// just one layer down: for the silent same-interface roam this exists to handle, the
/// transport cannot produce a truthful `false` either. The interface index is still `en0` and
/// no socket error is emitted; datagrams simply stop arriving. So a caller could only answer
/// `true` from the same insufficient observations that were wrong here, or answer `nil`
/// always, which made `keep` unreachable. An unanswerable question is worse than no question.
///
/// Rebuilding unconditionally is affordable because a socket rebuild is NOT a handshake.
/// `Tunn` is constructed from keys and an index alone (`wireguard-core/src/lib.rs`); it holds
/// no socket and no endpoint, so the session survives its transport. A new source port is the
/// ordinary WireGuard roaming case, which the peer resolves by re-anchoring the endpoint on
/// the next authenticated datagram. The cost of a needless rebuild is one UDP socket.
/// pinned: ChainedUpstreamEgressTests.testAPathChangeAlwaysRebuildsBecauseSurvivalIsNotObservable
public enum ChainedUpstreamSocketLifecycle: Equatable, Sendable {
    /// Tear down and open a new one. A bound socket outlives neither its interface nor its
    /// peer address.
    case rebuild
    /// Close it and do not reopen. The session is over.
    case close
}

/// Events that can invalidate an open upstream socket.
public enum ChainedUpstreamSocketEvent: Equatable, Sendable, CaseIterable {
    /// The system reported a path update.
    ///
    /// Carries nothing, because nothing it could carry would be trustworthy. See
    /// ``ChainedUpstreamSocketLifecycle`` for the four attempts at deciding survival and why
    /// the last one — asking the transport for a Boolean — failed for the same reason as the
    /// three inferences it replaced.
    case pathChanged
    /// The endpoint resolved to a different address, after a roam re-resolve.
    case peerAddressChanged
    /// The chained session ended for any reason.
    case sessionEnded
}

/// Decides where the upstream socket egresses, and when it must be rebuilt.
///
/// Plan: lavasec-infra `plans/backlog/2026-07-27-vpn-upstream-phase-3-data-path-plan.md` (S3),
/// implementing D5's "loop avoidance by interface binding, no `excludedRoutes` games".
///
/// ## The failure this prevents is a loop, not a leak
///
/// Chained mode claims `0.0.0.0/0`. An unbound socket therefore matches the tunnel's own
/// default route, so a datagram the engine just encapsulated is handed back to the tunnel to
/// be encapsulated again. That is not a slow path or a wasted copy — it is an unbounded
/// recursion between the packet loop and the socket, and it consumes CPU and the bounded
/// queues until the extension is killed.
///
/// The fix is binding the socket to the physical interface, which is why the required-interface
/// constraint is the whole point of this type rather than an optimization. `excludedRoutes` is
/// the alternative and is deliberately not used: it asks the routing table to carve a hole for
/// an address that moves, and it silently stops working the moment the peer's address changes.
///
/// ## Refusing is a working outcome, BEFORE the tunnel is established
///
/// A refusal at start-up resolves DNS-only per `INV-CHAIN-1` — filtered, working internet —
/// rather than a tunnel that claims the default route and cannot forward.
///
/// After establishment the same refusal means something worse, and this type cannot express
/// it. Chained mode has already claimed `0.0.0.0/0`, so a rebuild whose re-derived egress
/// refuses leaves the route claimed with no socket to serve it — a blackhole, not a fallback.
/// Recovering needs the tunnel restarted into DNS-only, which is a decision above this policy:
/// `ChainedReconnectPolicy.Surrender` is where it lives, and S8 is what connects them. Naming
/// the gap because an unnamed one reads as handled.
public enum ChainedUpstreamEgressPolicy {
    /// Why no socket may be opened.
    public enum Refusal: String, Equatable, Sendable {
        /// The only path available is a virtual interface. Binding to it would send the
        /// engine's own output back into the tunnel that produced it.
        case onlyVirtualInterfaceAvailable
        /// The only path available is loopback, which cannot reach a peer at all.
        case onlyLoopbackAvailable
        /// The system reports no interface. There is nothing to bind to and nothing to reach.
        case noPathAvailable
    }

    /// Link kinds that can carry traffic off the device.
    ///
    /// An allowlist, not a denylist of `other` and `loopback`. A future platform interface
    /// kind lands in `other` and must be refused by default: the cost of wrongly refusing an
    /// exotic-but-real link is DNS-only, which works, while the cost of wrongly accepting a
    /// virtual one is the loop above.
    /// pinned: ChainedUpstreamEgressTests.testOnlyPhysicalLinksAreEverBoundTo
    public static let physicalLinkKinds: Set<ChainedUpstreamLinkKind> = [
        .wifi, .cellular, .wiredEthernet,
    ]

    /// Chooses the interface the upstream socket binds to.
    ///
    /// - Parameter usedInterface: the interface the path actually uses, or `nil` if there is
    ///   none. Only that one is considered, so there is no list and nothing to mis-order. An
    ///   earlier version took the available kinds and treated their order as a preference,
    ///   which could bind to cellular while the system-selected route was Wi-Fi — metered
    ///   usage the user did not ask for, or a failure under cellular restrictions.
    public static func egress(usedInterface: ChainedUpstreamInterface?) -> ChainedUpstreamEgress {
        guard let used = usedInterface else { return .refuse(.noPathAvailable) }

        guard physicalLinkKinds.contains(used.kind) else {
            // Which refusal is chosen matters only for the log. The virtual case is named
            // separately because it is the state where a naive implementation loops: the
            // tunnel has claimed everything and is now the only path the system reports.
            return .refuse(
                used.kind == .other ? .onlyVirtualInterfaceAvailable : .onlyLoopbackAvailable)
        }
        // Constructed, not asserted. If the validated type refuses what the kind check above
        // accepted, the disagreement is a bug in this policy — but the safe answer is still to
        // refuse, because the alternative is handing the socket an interface the type says is
        // not bindable.
        guard let bindable = ChainedBindableInterface(used) else {
            return .refuse(.onlyVirtualInterfaceAvailable)
        }
        return .bind(bindable)
    }

    /// Decides what an event means for a socket that is already open.
    ///
    /// - Parameters:
    ///   - event: what happened.
    ///   - boundTo: the interface the open socket is bound to.
    public static func lifecycle(
        after event: ChainedUpstreamSocketEvent,
        boundTo: ChainedUpstreamInterface
    ) -> ChainedUpstreamSocketLifecycle {
        switch event {
        case .sessionEnded:
            return .close
        case .peerAddressChanged:
            // A connected datagram socket carries its destination. Reusing it for a different
            // peer sends to the old one.
            return .rebuild
        case .pathChanged:
            // The asymmetry that settles it. Keeping a socket across a real move fails
            // SILENTLY — the stale binding does not error, so datagrams go nowhere and the
            // peer reads as unresponsive rather than the socket reading as broken, which
            // spends the whole outage budget diagnosing the wrong thing. Rebuilding when
            // nothing moved costs one UDP socket, because the session is not carried by the
            // socket: `Tunn` holds keys and an index, not an endpoint, so no handshake is
            // restarted and the peer re-anchors on the next authenticated datagram.
            //
            // A silent failure against a cheap redundant one is not a close call, and it is
            // the same judgement the rest of this feature makes — `INV-DNS-1` prefers a
            // working refusal to a state that looks fine and is not.
            return .rebuild
        }
    }
}

extension ChainedUpstreamEgress {
    /// Whether a socket may be opened at all.
    public var permitsSocket: Bool {
        switch self {
        case .bind:
            return true
        case .refuse:
            return false
        }
    }

    /// Stable identifier for device logs. Never user copy.
    public var logValue: String {
        switch self {
        case .bind(let interface):
            // The KIND, not the name: an interface name is a small fingerprint of the user's
            // network and a device log travels in a bug report.
            return "egress-\(interface.kind.rawValue)"
        case .refuse(let reason):
            return "egress-refused-\(reason.rawValue)"
        }
    }
}
