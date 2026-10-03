import Darwin
import Foundation
import LavaSecKit

/// A numeric address the packet loop can send to without any lookup.
///
/// Construction validates with `inet_pton` and rejects everything else, for the same reason
/// `ResolverEndpoint` does in `LavaSecDNS`: an address that still needs resolving cannot be
/// used to bootstrap resolution. Here the consequence is sharper than a wasted round trip —
/// see ``ChainedEndpointResolutionPlan``.
public struct ChainedEndpointAddress: Equatable, Sendable {
    /// The numeric literal, exactly as validated.
    public let literal: String
    /// UDP port of the peer.
    public let port: UInt16
    /// Which family `literal` belongs to. The tunnel needs this to pick a socket.
    public let isIPv6: Bool

    /// Parses `literal` as an IPv4 or IPv6 address. Fails for hostnames and for anything
    /// `inet_pton` refuses.
    public init?(literal: String, port: UInt16) {
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            self.literal = literal
            self.port = port
            self.isIPv6 = false
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, literal, &v6) == 1 {
            self.literal = literal
            self.port = port
            self.isIPv6 = true
            return
        }
        return nil
    }
}

/// A resolver this bootstrap may dial.
///
/// Separate from ``ChainedEndpointAddress`` because the two carry different invariants and
/// only one of them is about a peer. An endpoint address is whatever port the user configured;
/// a resolver is numeric AND on port 53, always.
///
/// Typing the endpoint payload closed the hostname forgery but left the port open: a caller
/// could still build `ChainedEndpointAddress(literal: "1.1.1.1", port: 51820)` and hand it over
/// as a resolver, and an S3 transport would then send every DNS query to a non-DNS port and
/// time out — a bootstrap that fails slowly instead of one that fails at all. There is no port
/// to pass here, so that is unwritable rather than merely asserted against.
/// pinned: ChainedEndpointResolutionTests.testAResolverCannotBeBuiltOnANonDNSPort
public struct ChainedResolverAddress: Equatable, Sendable {
    /// The numeric address, exactly as validated.
    public let literal: String
    /// Which family `literal` belongs to.
    public let isIPv6: Bool
    /// The one port a resolver is ever dialed on.
    ///
    /// Lives here rather than on the policy so the constant sits with the type that guarantees
    /// it. An earlier version put it on the policy and then wrote `53` inline twice in this
    /// struct, which is exactly the drift the constant was created to prevent.
    public static let dnsPort: UInt16 = 53

    /// Always ``dnsPort``. Exposed so a transport reads it rather than writing its own.
    public var port: UInt16 { Self.dnsPort }

    /// Parses `literal` as an IPv4 or IPv6 address. Fails for hostnames, and for the tunnel's
    /// own DNS listener.
    ///
    /// The listener rejection is HERE, not only in `plan`. Both this initializer and the
    /// `queryDirectly` case are public, so a caller could otherwise write
    /// `ChainedResolverAddress(literal: TunnelRoutePlan.dnsServerAddress)!` and embed it in a
    /// plan directly, walking straight past the filter — and the transport would then query
    /// the tunnel whose upstream it is bootstrapping. That is the third time this shape has
    /// appeared in this stack: validating in a factory and calling the TYPE safe.
    /// pinned: ChainedEndpointResolutionTests.testTheTunnelListenerCannotBeBuiltAsAResolver
    public init?(literal: String) {
        guard literal != TunnelRoutePlan.dnsServerAddress else { return nil }
        // Structural unusability belongs here too, for the same reason the listener does:
        // both this initializer and the plan's payload are reachable, so a rule enforced only
        // in `plan` is a rule a hand-built value walks past. Loopback, unspecified,
        // link-local and NAT64 all wedge a query on an address that cannot answer.
        guard DeviceDNSFallbackPolicy.isUsableResolverAddress(literal) else { return nil }
        guard let address = ChainedEndpointAddress(literal: literal, port: Self.dnsPort) else {
            return nil
        }
        self.literal = address.literal
        self.isIPv6 = address.isIPv6
    }
}

/// How to obtain the peer's address, decided without ever consulting the system resolver.
///
/// ## The deadlock this exists to avoid
///
/// Chained mode claims `0.0.0.0/0` and sets `matchDomains [""]`, so **every** name lookup on
/// the device — including the packet tunnel's own — is directed at `10.255.0.1`, the tunnel's
/// DNS address. At the moment the endpoint needs resolving, that tunnel is either not up yet
/// (start) or has just lost its path (roam). So calling `getaddrinfo` here asks the tunnel to
/// resolve the address it needs in order to come up. It does not fail fast; it hangs until
/// something times out, and the user sees a VPN that reports itself connecting and never
/// connects.
///
/// The fix is not "resolve carefully". It is that this type has **no case meaning `use the
/// system resolver`**, so the deadlock is not expressible. `queryDirectly` carries the
/// resolver addresses to dial, and they are numeric — the query cannot itself need a query.
/// That is the same technique ``ChainedSessionEndCause`` uses on the reconnect policy.
///
/// ## What each outcome costs the user
///
/// `useLiteral` is free and leaks nothing: no lookup happens at all. It is the posture to
/// prefer and the one worth saying so in the Settings copy.
///
/// `queryDirectly` works, and it has a real privacy cost that is easy to miss: the query goes
/// out on the physical interface to the network's own resolver — usually the ISP's — so **the
/// endpoint hostname is disclosed outside the VPN**, to exactly the observer the user is
/// chaining an upstream to avoid. It is unavoidable for a hostname endpoint (the tunnel that
/// would hide the query is the tunnel being built), so it is disclosed rather than hidden, and
/// belongs in the subpage copy Phase 4 writes.
///
/// `unresolvable` is not an error path to retry. It means the tunnel must not claim the
/// default route at all, so it resolves DNS-only per `INV-CHAIN-1` — a working, filtered
/// connection rather than a blackhole.
public struct ChainedEndpointResolutionPlan: Equatable, Sendable {
    /// What a plan says to do. A read-only PROJECTION: callers switch on this, and building
    /// one does not build a plan.
    public enum Outcome: Equatable, Sendable {
        /// The configuration already names an address. No lookup happens.
        case useLiteral(ChainedEndpointAddress)
        /// A hostname. Query these resolvers, in order, over the physical interface.
        case queryDirectly(name: String, port: UInt16, resolvers: [ChainedResolverAddress])
        /// No lookup is possible without the system resolver, so chaining cannot start.
        case unresolvable(ChainedEndpointResolutionPolicy.Unresolvable)
    }

    /// The decision. Read it, switch on it; you cannot make a plan out of one.
    public let outcome: Outcome

    /// Deliberately not public.
    ///
    /// Four separate findings on this type were the same shape: a public case with a raw
    /// payload let a caller hand-assemble a state `plan` would never emit — a hostname
    /// resolver, a resolver on a non-DNS port, the tunnel's own listener, an unusable or
    /// empty resolver list, a literal endpoint filed as a query. Each was closed individually
    /// and the next one appeared, because the shape was wrong rather than the contents.
    ///
    /// Making the plan itself unconstructible ends the class: the ONLY way to obtain one is
    /// `ChainedEndpointResolutionPolicy.plan`, which applies every rule. A caller can still
    /// build an `Outcome` and switch on it — that is harmless, because nothing consumes a
    /// bare outcome.
    fileprivate init(_ outcome: Outcome) {
        self.outcome = outcome
    }
}

/// What a path change means for an endpoint that is already resolved.
public enum ChainedEndpointRoamDecision: Equatable, Sendable {
    /// A literal endpoint has nothing to re-resolve. The address is as valid on the new path
    /// as the old one.
    case keepCurrent
    /// A hostname endpoint re-resolves, and **keeps sending to the current address while the
    /// lookup runs**.
    ///
    /// Dropping it first would be the tidier-looking choice and is worse: WireGuard is
    /// connectionless, the peer is frequently reachable on the new path at the same address,
    /// and a lookup on a network that has just changed is exactly when a resolver is slowest.
    /// Discarding a working address to wait for an answer we may already have converts a
    /// re-resolve into a guaranteed outage, and the outage budget is 15 seconds.
    case reResolveRetainingCurrent(ChainedEndpointAddress)
}

/// Decides how the peer's address is obtained.
///
/// Plan: lavasec-infra `plans/backlog/2026-07-27-vpn-upstream-phase-3-data-path-plan.md` (S1),
/// implementing D5's "endpoint resolution never uses the system resolver".
public enum ChainedEndpointResolutionPolicy {
    /// Resolvers are dialed on ``ChainedResolverAddress/dnsPort``. Re-exported here because
    /// callers reach for the policy first; the constant itself lives with the type that
    /// guarantees it, so there is exactly one definition.
    public static var dnsPort: UInt16 { ChainedResolverAddress.dnsPort }

    /// Why no lookup is possible.
    ///
    /// The two are kept apart because they point at different problems: one says the capture
    /// never ran or was masked, the other says it ran and produced addresses that cannot be
    /// dialed. A field log conflating them cannot tell a timing bug from a bad network.
    public enum Unresolvable: String, Equatable, Sendable {
        /// Nothing was captured before the tunnel took over DNS. `INV-DNS-5` explains why an
        /// empty capture is not evidence of anything: while the tunnel owns device DNS the
        /// in-process read is masked, so an empty list may simply mean we asked too late.
        case noCapturedDeviceResolvers
        /// Addresses were captured, and every one is structurally unusable as a resolver —
        /// loopback, unspecified, link-local, or the well-known NAT64 prefix. Dialing any of
        /// them wedges the query on an address that cannot answer.
        case everyCapturedResolverUnusable
        /// Every captured address collided with the tunnel's own DNS listener.
        ///
        /// Deliberately not folded into ``everyCapturedResolverUnusable``, because the two
        /// mean opposite things about the address. Those cannot answer; this one CAN — which
        /// is exactly why it is refused, since answering would mean the tunnel resolving the
        /// endpoint it needs in order to come up.
        ///
        /// Named for the COLLISION, not for its cause. A masked read that saw our own listener
        /// (`INV-DNS-5`) is the likely explanation and a timing bug in our code, but the input
        /// is a list of addresses with no provenance — a physical network is free to advertise
        /// `10.255.0.1` as its router resolver, and on that network this reason means the
        /// user's own gateway collided with ours. Both are refused for the same reason and the
        /// diagnosis between them is not available here.
        case onlyTheTunnelsOwnResolverCaptured
    }

    /// Plans resolution for a configured endpoint.
    ///
    /// - Parameters:
    ///   - host: `ChainedUpstreamConfiguration.endpointHost`, already validated as a plausible
    ///     host. Note it can never be a bare IPv6 literal — the configuration rejects any host
    ///     containing a colon, in every spelling including the bracketed `[2001:db8::1]` form.
    ///     A hostname may still resolve to an IPv6 address, so the resolved family is not
    ///     constrained; only the *configured* one is.
    ///   - port: the peer's UDP port.
    ///   - capturedDeviceResolvers: the device resolvers captured before the tunnel took over
    ///     DNS. Order is preserved — it is the order the system intended.
    public static func plan(
        host: String,
        port: UInt16,
        capturedDeviceResolvers: [String]
    ) -> ChainedEndpointResolutionPlan {
        if let literal = ChainedEndpointAddress(literal: host, port: port) {
            return ChainedEndpointResolutionPlan(.useLiteral(literal))
        }

        guard !capturedDeviceResolvers.isEmpty else {
            return ChainedEndpointResolutionPlan(.unresolvable(.noCapturedDeviceResolvers))
        }

        // Two rejections, and borrowing only the second one was a real hole.
        //
        // FIRST, the tunnel's own DNS listener. `TunnelRoutePlan.dnsServerAddress` is an
        // ordinary private address, so the structural predicate below has no reason to refuse
        // it — and the capture can legitimately surface it, because while the tunnel owns
        // device DNS the in-process read is masked (`INV-DNS-5`) and can report the tunnel's
        // own resolver back to us. Querying that address to bootstrap the tunnel is precisely
        // the circular wait this whole type exists to make impossible, so it is refused first.
        // `PacketTunnelProvider.isUsableDeviceDNSServer` makes the same rejection for the same
        // reason; the predicate below deliberately leaves this config-specific address to its
        // callers, and this caller has to make it too rather than assume it inherited it.
        //
        // SECOND, the structural cases — loopback, unspecified, link-local, NAT64. Those live
        // in `DeviceDNSFallbackPolicy` so the rule has one home rather than a copy here that
        // drifts.
        //
        // Deduplicated because the same resolver commonly appears twice across interfaces, and
        // a duplicate is a wasted timeout on a path where the whole budget is 15 seconds.
        var seen = Set<String>()
        var sawOwnListener = false
        let usable = capturedDeviceResolvers.compactMap { address -> ChainedResolverAddress? in
            if address == TunnelRoutePlan.dnsServerAddress {
                sawOwnListener = true
                return nil
            }
            guard DeviceDNSFallbackPolicy.isUsableResolverAddress(address) else { return nil }
            guard seen.insert(address).inserted else { return nil }
            // Numeric by construction. A captured address that will not parse cannot be dialed
            // without a lookup, which is the thing being avoided.
            // `ChainedResolverAddress` refuses the listener too — this is not redundant, it
            // is what lets the refusal be REPORTED rather than silently dropped.
            return ChainedResolverAddress(literal: address)
        }
        guard !usable.isEmpty else {
            // Which refusal, when both apply? The collision wins, because it is the more
            // specific observation: the structural reason says only "nothing dialable", while
            // this one names the address that was refused and points at a concrete next check.
            return ChainedEndpointResolutionPlan(
                .unresolvable(
                    sawOwnListener
                        ? .onlyTheTunnelsOwnResolverCaptured : .everyCapturedResolverUnusable))
        }

        return ChainedEndpointResolutionPlan(.queryDirectly(name: host, port: port, resolvers: usable))
    }

    /// Decides what a path change means for an endpoint that already resolved.
    ///
    /// - Parameters:
    ///   - plan: the plan that produced `current`.
    ///   - current: the address the session is using now.
    public static func decisionOnPathChange(
        for plan: ChainedEndpointResolutionPlan,
        current: ChainedEndpointAddress
    ) -> ChainedEndpointRoamDecision {
        switch plan.outcome {
        case .useLiteral:
            return .keepCurrent
        case .queryDirectly:
            return .reResolveRetainingCurrent(current)
        case .unresolvable:
            // Reachable only if a caller kept an address from a plan that produced none, which
            // is a caller bug rather than a network event. Keeping what it has is the safe
            // reading: this function must not manufacture a lookup the plan said was impossible.
            return .keepCurrent
        }
    }
}

extension ChainedEndpointResolutionPlan {
    /// Whether this plan discloses the endpoint hostname to the local network.
    ///
    /// Surfaced as a property rather than left for the caller to infer from the case, because
    /// the Settings copy and the device log both need to state it and must not disagree.
    /// pinned: ChainedEndpointResolutionTests.testOnlyTheHostnamePathDisclosesTheEndpointName
    public var disclosesEndpointNameToLocalNetwork: Bool {
        switch outcome {
        case .queryDirectly:
            return true
        case .useLiteral, .unresolvable:
            return false
        }
    }

    /// Stable identifier for device logs. Never user copy, and never the hostname itself —
    /// the point of the privacy note above is undone by writing the name into a log that
    /// travels in a bug report.
    public var logValue: String {
        switch outcome {
        case .useLiteral(let address):
            return "endpoint-literal-\(address.isIPv6 ? "v6" : "v4")"
        case .queryDirectly(_, _, let resolvers):
            return "endpoint-query-\(resolvers.count)-resolver\(resolvers.count == 1 ? "" : "s")"
        case .unresolvable(let reason):
            return "endpoint-unresolvable-\(reason.rawValue)"
        }
    }
}
