import Foundation
import LavaSecKit

/// Which of a chained configuration's `DNS =` entries the tunnel can actually use (S6).
///
/// SELECTION, deliberately distinct from the validation the configuration boundary does.
/// The boundary refuses a config whose entries are not IP literals; this policy picks the
/// subset a latched chained session can speak to, and the split follows the plan's S7 rule
/// ("usable means semantically usable, and where the field is a list readiness returns the
/// selected set"): `DNS = 0.0.0.0` is well-formed and unusable, and `0.0.0.0, 10.64.0.1`
/// must yield exactly `10.64.0.1` — an existential check would pass it while a first-entry
/// consumer sources from the unusable address. So the consumer uses THIS selected set and
/// nothing else.
///
/// Why each rule exists:
/// - **IPv4 only.** Chained mode claims `::/0` in order to DROP IPv6, not carry it
///   (`INV-CHAIN-1`), so a v6 resolver would validate, latch, and then blackhole every
///   query — the failure shape that looks like "chained DNS is broken" instead of naming
///   the config.
/// - **Structural usability** is `DeviceDNSFallbackPolicy.isUsableResolverAddress` — one
///   shared judgement of "can this address ever answer", not a second copy of it.
/// - **Not the tunnel's own DNS proxy address** (`TunnelRoutePlan.dnsServerAddress`):
///   queries to it are served by interception, so "use it as the upstream" is a loop, and
///   the OS delivers to it locally rather than routing into the tunnel — the same reason
///   `ChainedResolverAddress` refuses it for the bootstrap world.
/// - **Not the config's own `clientAddress`**: the interface owns that address, so the OS
///   treats it as local delivery too — the collision the configuration boundary refuses
///   for the DNS proxy, arising here on a different field.
/// - **Covered by `AllowedIPs`.** The resolver's reply arrives FROM the resolver's address,
///   and the runner enforces the peer's `AllowedIPs` on that inbound source
///   (`ChainedAllowedIPs`), dropping anything outside it as a spoof. A resolver off-tunnel —
///   a split `AllowedIPs` whose `DNS =` sits outside it — would latch ready and then fail
///   every lookup, so it is not usable. Full tunnel covers `0.0.0.0/0`, so this excludes
///   nothing there. (Codex `#546` P1.)
///
/// Duplicates collapse to the first occurrence: a failover loop that retries the same
/// resolver twice buys latency, not redundancy.
///
/// NOT `ChainedResolverAddress`. That type is the endpoint BOOTSTRAP's vocabulary — its
/// egress is deliberately not a `ChainedResolverEgress`, and it admits IPv6 because
/// captured device resolvers can be v6. Reusing it here would blur the exact boundary
/// `ChainedResolverEgressPolicy` keeps sharp between the one sanctioned physical-interface
/// egress and the tunnel-only resolver path.
public enum ChainedTunnelResolverSelection {
    /// A resolver selection: the ordered usable subset of the configuration's own `DNS =`.
    ///
    /// IT CARRIED A SECOND LIST, `appendedFallback` — the T1 addresses that passed this gate
    /// and were not already contributed by the conf. It existed to attribute a rescue to the
    /// alternative DNS while T1 rode the tunnel. T1 egresses on the physical interface
    /// now (PR #590), so nothing is appended to this selection by anyone and the rung reports its
    /// own evidence (`ResolverOrchestrator.TierOneRungEvidence`). A struct wrapping one field is
    /// kept rather than collapsed to `[String]` because `selection(from:)` and `selectedResolvers`
    /// are two questions with two call sites, and the type is where the doc above lives.
    public struct Selection: Equatable, Sendable {
        public let resolvers: [String]
    }

    /// The ordered usable subset of the configuration's `DNS =` entries.
    ///
    /// Empty means the configuration cannot serve chained DNS at all; readiness turns
    /// that into a latch refusal (`ChainedUpstreamReadiness.Refusal.noUsableTunnelDNS`),
    /// so a session this policy answers empty for never exists.
    public static func selectedResolvers(
        from configuration: ChainedUpstreamConfiguration
    ) -> [String] {
        selection(from: configuration).resolvers
    }

    /// The same set as ``Selection``.
    public static func selection(
        from configuration: ChainedUpstreamConfiguration
    ) -> Selection {
        // The peer's cryptokey-routing allowlist, built EXACTLY as the data path builds it
        // (`PacketTunnelProvider`: `ChainedAllowedIPs(allowedIPs.compactMap(ChainedIPPrefix.init))`),
        // so the coverage gate below cannot disagree with the verdict the runner enforces on
        // every decrypted packet's source.
        let inboundAllowlist = ChainedAllowedIPs(
            configuration.capturedAllowedIPs.compactMap(ChainedIPPrefix.init))
        var seen = Set<String>()
        var selected: [String] = []

        // The per-address gate, applied to the conf's own `DNS =`.
        func admit(_ address: String) {
            guard Self.isUsableResolverAddress(address, in: configuration) else { return }
            // The resolver's REPLY must survive the inbound AllowedIPs check, or the tunnel
            // encapsulates the query and `ChainedSessionRunner.deliverOnQueue` drops the answer
            // as `dropSpoofedSource`: a resolver OUTSIDE `AllowedIPs` (a split tunnel whose DNS
            // lives off-tunnel — e.g. `AllowedIPs = 10.0.0.0/8` with `DNS = 1.1.1.1`) would
            // otherwise latch "ready" and then fail EVERY lookup. Full tunnel covers `0.0.0.0/0`,
            // so this filters nothing there; split filters exactly the resolvers whose replies
            // the data path would reject. Same allowlist the runner enforces, so readiness and
            // the data path cannot disagree. (Codex #546 P1; infra `#198` §3.4.)
            guard let octets = Self.ipv4Octets(address),
                  inboundAllowlist.permits(sourceOctets: octets)
            else { return }
            if !configuration.precedingHops.isEmpty {
                let owner = configuration.stackDNSProfileIndex
                let destination = octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                // Overlapping private ranges must not silently send one provider's DNS
                // address to the other provider. A conflicting resolver is unusable.
                guard configuration.routeIndex(forIPv4: destination) == owner else { return }
            }
            guard seen.insert(address).inserted else { return }
            selected.append(address)
        }

        for address in configuration.stackDNSAddresses { admit(address) }

        return Selection(resolvers: selected)
    }

    /// Whether `address` could serve as a resolver for THIS configuration at all — the USABILITY
    /// half of ``selection(from:)``'s gate, deliberately excluding the routing half.
    ///
    /// Split out because the two refusals send the user to different places, and the difference
    /// cannot be recovered from route coverage afterwards. An address that is BOTH unusable and
    /// unrouted — a multicast literal on a split tunnel — reads as unrouted if coverage is the
    /// arbiter, so the panel blames the user's VPN and recommends a full tunnel, advice that is
    /// still wrong once they have one (Kilo, PR #575).
    ///
    /// The rules, in order:
    /// - ``DeviceDNSFallbackPolicy/isUsableResolverAddress(_:)`` — the shared "can this address
    ///   ever answer" judgement, not a second copy of it.
    /// - IPv4 only, first octet < 224. A v6 literal never yields a parseable first octet, so the
    ///   family rule is enforced by this same parse — a separate colon check was redundant with
    ///   it (its removal survived a mutation sweep), and two enforcements of one rule is how they
    ///   drift. Multicast, reserved and broadcast are not destinations a WireGuard peer routes,
    ///   so a "resolver" there is a blackhole. The device-DNS policy never sees them (system
    ///   captures do not carry multicast resolvers); a hand-written `DNS =` line can.
    /// - Not the tunnel's own DNS proxy address, and not the configuration's `clientAddress` —
    ///   both are delivered locally rather than routed into the tunnel.
    ///
    /// pinned: ChainedTunnelResolverSelectionTests.testUsabilityIsJudgedWithoutConsultingRouteCoverage
    public static func isUsableResolverAddress(
        _ address: String, in configuration: ChainedUpstreamConfiguration
    ) -> Bool {
        guard DeviceDNSFallbackPolicy.isUsableResolverAddress(address) else { return false }
        guard let firstOctet = address.split(separator: ".").first.flatMap({ UInt8($0) }),
            firstOctet < 224
        else { return false }
        guard address != TunnelRoutePlan.dnsServerAddress else { return false }
        guard configuration.orderedHops.allSatisfy({ address != $0.clientAddress }) else { return false }
        return true
    }

    /// What became of each latched T1 fallback address, for the settings panel.
    ///
    /// Lives HERE rather than in the provider because usability is this type's judgement and a
    /// second copy of it in the app is the drift the selection's own doc refuses. It was once the
    /// exact inverse of the admission gate above — an address missing from the selected set had
    /// been refused by one of those rules — and it is no longer, because T1 is not admitted
    /// through that gate at all: it egresses on the physical interface and the tunnel's
    /// `AllowedIPs` have nothing to say about it (PR #590). The selection is still consulted, for
    /// the one question that survives: is this address already the conf's own resolver.
    ///
    /// The history is kept because it names a real trap: deriving this in the provider meant
    /// re-deriving route coverage there and using it as the arbiter between
    /// ``ChainedFallbackDisposition/unusable`` and
    /// ``ChainedFallbackDisposition/notRoutedBySplitTunnel``, which mislabelled every address that
    /// was both and sat in `PacketTunnelProvider` with no executable coverage (Kilo, PR #575).
    ///
    /// pinned: ChainedTunnelResolverSelectionTests.testAnUnusableAddressIsNamedUnusableEvenWhenTheTunnelAlsoCannotRouteIt
    public static func fallbackOutcomes(
        latched: [String],
        resolvesOverPlainDNS: Bool,
        selection: Selection,
        configuration: ChainedUpstreamConfiguration
    ) -> [ChainedFallbackAddressOutcome] {
        // NO ROUTE-COVERAGE GATE ANY MORE. T1 is not carried by the tunnel: it egresses on the
        // physical interface, so whether the peer's `AllowedIPs` happen to cover the address has
        // stopped being a question about whether the resolver can be used (PR #590). What is left
        // is what was always the real question — is this address usable at all, and is it already
        // the conf's own resolver rather than a second opinion.
        //
        // `.notRoutedBySplitTunnel` therefore becomes unproducible. The case survives only to
        // decode health snapshots written before this, exactly as its own doc anticipated.
        // pinned: ChainedTunnelResolverSelectionTests.testATierOneAddressIsAdmittedWithoutTheTunnelRoutingIt
        // THE ROUTING POLICY DECIDES BEFORE ANY PER-ADDRESS QUESTION DOES. There is no T1
        // rung at all in a full tunnel — `ChainedResolverEgressPolicy` answers false for
        // `.fullTunnel`, deliberately and absolutely — so reporting a structurally usable address
        // as `.admitted` there described a resolver that could never be attempted. With no
        // attempts to move the counters, `ChainedFallbackStatus.status` read that as
        // `.readyUnused` and the panel said "Ready — not needed yet" for the life of every
        // full-tunnel session (Codex, PR #590).
        //
        // It is the SESSION's shape, not the address's, which is why it is one verdict for the
        // whole list — the one case where a per-address answer would be the wrong model, since
        // every address meets exactly the same fate for exactly the same reason.
        // pinned: ChainedTunnelResolverSelectionTests.testAFullTunnelReportsTierOneUnavailableRatherThanAdmitted
        guard configuration.effectiveRoutingPolicy == .splitTunnel else {
            return latched.map {
                ChainedFallbackAddressOutcome(
                    address: $0, disposition: .unavailableInFullTunnel)
            }
        }
        // AN ENCRYPTED SELECTION HAS NO ADDRESS QUESTION TO ANSWER, so it is admitted whole.
        //
        // Both remaining gates are about IPv4 literals. `alreadyPrimary` asks whether this is the
        // conf's own `DNS =` — a DoH URL cannot be, and its provider's unrelated plain IPv4
        // matching is a coincidence, not an identity. `unusable` asks whether an IPv4 literal can
        // ever answer (multicast, reserved, the tunnel's own proxy address, the client address);
        // a hostname reached over TLS on the physical path is outside every one of those rules.
        //
        // Answering `.unusable` for a DoH host — which is what running these gates over a
        // non-dotted-quad string does, since `ipv4Octets` refuses it — would report the user's
        // working resolver as broken and drive the panel to "pick a different resolver". So the
        // caller states the transport rather than letting the string shape decide.
        // pinned: ChainedTunnelResolverSelectionTests.testAnEncryptedTierOneEndpointIsAdmittedWithoutAnIPv4Gate
        guard resolvesOverPlainDNS else {
            return latched.map {
                ChainedFallbackAddressOutcome(address: $0, disposition: .admitted)
            }
        }
        return latched.map { address in
            if selection.resolvers.contains(address) {
                return ChainedFallbackAddressOutcome(
                    address: address, disposition: .alreadyPrimary)
            }
            // IPv6 BEFORE the usability gate, because that gate answers false for a v6 literal
            // and `.unusable`'s copy ("can't be a resolver") would then blame an address that is
            // perfectly capable of answering. `INV-CHAIN-1` keeps the rung IPv4-only; saying so is
            // a different sentence from calling the resolver broken (Codex P2, PR #591).
            // pinned: ChainedTunnelResolverSelectionTests.testAnIPv6TierOneAddressIsNamedIPv6RatherThanUnusable
            if address.contains(":") {
                return ChainedFallbackAddressOutcome(
                    address: address, disposition: .unusableIPv6)
            }
            return ChainedFallbackAddressOutcome(
                address: address,
                disposition: isUsableResolverAddress(address, in: configuration)
                    ? .admitted : .unusable)
        }
    }

    /// The four octets of a dotted-quad IPv4 literal, or `nil`.
    ///
    /// A parse, not a validator: the addresses reaching it have already passed the IPv4-only
    /// and usability gates above. It exists only to feed
    /// ``ChainedAllowedIPs/permits(sourceOctets:)`` the same octet form the data path checks a
    /// decrypted packet's source in, so the readiness gate and the runtime drop share one
    /// judgement.
    private static func ipv4Octets(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            octets.append(octet)
        }
        return octets
    }
}
