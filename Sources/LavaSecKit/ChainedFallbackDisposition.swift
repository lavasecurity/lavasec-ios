import Foundation

/// What became of ONE chosen T1 fallback address when the tunnel built its resolver route.
///
/// ## Why this is per address rather than a verdict about the selection
///
/// A fallback selection is a LIST — every built-in provider contributes two IPv4 servers — and its
/// members can meet different fates in the same session: one admitted, one already present in the
/// configuration's own `DNS =` and deduped into T0, one refused outright. Four consecutive
/// review rounds on PR #575 found the same defect in different clothes, and every one of them was
/// a single summary claim standing in for facts that disagreed: an empty T1 set reported as
/// "unusable" when the address had merely deduped, then a deduped-OR-refused mixture reported as
/// "already your primary" because one member happened to have deduped.
///
/// The pattern was the model, not the individual checks. A Bool cannot describe a list whose
/// elements differ, so the summary was always going to be wrong for some arrangement — the only
/// question was which round would find it. Carrying the per-address outcome removes the class:
/// the surface enumerates what actually happened to each address instead of asserting one cause
/// for all of them.
public enum ChainedFallbackDisposition: String, Equatable, Sendable, Codable {
    /// Usable as a genuine T1 entry, and NOT already one of the conf's own resolvers. This is
    /// the only disposition under which the fallback can ever answer anything.
    ///
    /// THE OLD WORDING WAS INVERTED, not merely stale: it said "appended to the resolver route",
    /// and `.admitted` is returned precisely on the branch where `selection.resolvers` does NOT
    /// contain the address — an address that IS in the route returns ``alreadyPrimary``. The
    /// tunnelled route also carries no T1 entry at all now, so nothing is appended to it by
    /// anyone (adversarial review, PR #590).
    ///
    /// What it means today: the address is the set the physical rung may query
    /// (`admittedTierOneAddressesOnQueue` → `restrictingPlainAddresses(to:)`), and the set the
    /// fallback counters aggregate.
    case admitted
    /// Refused nothing — the configuration's own `DNS =` ALREADY carries this address, so the
    /// selection deduped it into T0. The address is perfectly usable; it simply is not a
    /// second opinion, and retrying a name through the resolver that just failed it cannot help.
    case alreadyPrimary = "already-primary"
    /// Refused by a usability gate: not a usable IPv4 literal, multicast/reserved, the tunnel's
    /// own DNS proxy address, or the configuration's client address.
    case unusable
    /// An IPv6 literal, refused because the chained rung is IPv4-only (`INV-CHAIN-1`).
    ///
    /// SEPARATE FROM ``unusable`` because the remedy and the honesty differ. `unusable` says the
    /// address could never answer anything — a multicast literal, the tunnel's own proxy address —
    /// and its copy tells the user to pick a different resolver, which is right. A v6 resolver is
    /// perfectly capable of answering; Lava is what will not ask it.
    ///
    /// It exists because the alternative was SILENCE. A v6-only plain selection projected to an
    /// empty endpoint list, so the gate had nothing to refuse: the panel enumerated nothing, no
    /// address was admitted, and a split-tunnel session ran no rung while claiming nothing about
    /// why (Codex P2, PR #591).
    ///
    /// WHETHER IT MUST STAY REFUSED IS GENUINELY OPEN, and the refusal is the conservative answer
    /// rather than a settled one. `INV-CHAIN-1` is about the TUNNEL's data path — chained claims
    /// `::/0` to drop IPv6 — and the T1 rung is not on it: its socket is unbound and leaves on
    /// the physical interface. Whether the provider's own v6 socket escapes the `::/0` claim is a
    /// device question nobody has answered, and shipping the optimistic guess would blackhole
    /// every T1 lookup for a v6 user rather than refusing one. A measured answer can widen
    /// this; a guess may not.
    case unusableIPv6 = "unusable-ipv6"
    /// UNPRODUCIBLE. Kept only so the raw value still decodes from health snapshots written
    /// before PR #590.
    ///
    /// It asked whether the TUNNEL routes the chosen resolver, and the tunnel no longer carries
    /// T1 at all: the rung egresses on the physical interface, so the peer's `AllowedIPs`
    /// have nothing to say about whether the resolver can be reached. The route-coverage gate in
    /// `fallbackOutcomes` that produced this is gone, and so is the
    /// `openingRoutes(forFallbackResolvers:)` widening that made it almost always false — both
    /// described a mechanism that has been replaced rather than fixed.
    ///
    /// Its successor for "this session cannot use T1 at all" is
    /// ``unavailableInFullTunnel``, which is a different claim: about the ROUTING POLICY, not
    /// about one address.
    ///
    /// It was one. For several rounds this disposition drove a panel reading "Your VPN doesn't
    /// route it — pick a resolver your VPN does route, or use one that carries all your traffic",
    /// which asked the user to go and hand-edit their WireGuard profile to satisfy an
    /// implementation detail. The founder's stated intent, repeatedly, was the opposite: load a
    /// profile, turn the fallback on, and the tunnel does both. A device log from 2026-08-25
    /// shows what shipped instead — `100.64.0.0/10, 10.255.0.0/24 (DNS), rest direct` with
    /// Cloudflare selected and a warning where the feature should have been.
    ///
    /// The earlier attempt that was tried and reverted only carried the address in the DATA
    /// PATH, which made the reply acceptable without making the query routable — half the
    /// problem, so it did not work. The fix is both halves at once, and it is one line because
    /// the route plan, the engine's inbound allowlist and the resolver-admission gate all read
    /// the same `AllowedIPs`.
    case notRoutedBySplitTunnel = "not-routed-by-split-tunnel"
    /// The session's routing policy is FULL TUNNEL, where there is no T1 rung at all.
    ///
    /// Not a fault, and not a property of the address: in a full tunnel every packet already goes
    /// through the upstream, so the physical-interface rung the T1 fallback now runs on has
    /// no path that a full tunnel does not already own. `ChainedResolverEgressPolicy` answers
    /// `false` for `.fullTunnel` deliberately, and the invariant stays absolute there (PR #590).
    ///
    /// Published so the panel can SAY that, rather than reporting `.admitted` for a resolver that
    /// can never be attempted — which rendered as "Ready — not needed yet" for the life of every
    /// full-tunnel session, indefinitely and untruthfully (Codex, PR #590).
    ///
    /// This is a REGRESSION THE SAME PR INTRODUCED, and naming it is the point: before T1
    /// moved to the physical interface it rode the tunnel, so a full-tunnel peer that was an exit
    /// node did forward it and the fallback did work. It no longer can. The plan's D3 recorded
    /// full tunnel as "unchanged", which was imprecise — it is unchanged only for a peer that was
    /// never an exit node.
    case unavailableInFullTunnel = "unavailable-in-full-tunnel"
}

/// One chosen fallback address and what became of it. Ordered by the caller so the surface can
/// enumerate in the order the user chose.
public struct ChainedFallbackAddressOutcome: Equatable, Sendable, Codable {
    public let address: String
    public let disposition: ChainedFallbackDisposition

    public init(address: String, disposition: ChainedFallbackDisposition) {
        self.address = address
        self.disposition = disposition
    }

    /// Why this address contributes nothing, phrased for the settings panel. `nil` for an
    /// admitted address, which contributes plenty.
    ///
    /// Names the address every time. A list that says "one is already your resolver and one
    /// collides" without saying WHICH leaves the user to guess, and guessing is what the whole
    /// panel exists to remove.
    public var refusalReason: String? {
        switch disposition {
        case .admitted:
            return nil
        case .alreadyPrimary:
            return "\(address) is already your VPN's own resolver"
        case .unusable:
            return "\(address) can't be a resolver (reserved, or already used by your tunnel)"
        case .unusableIPv6:
            // Names Lava as the limit, not the resolver. The address is fine; we do not ask it.
            return "\(address) is IPv6 — Lava's VPN chaining only uses IPv4 resolvers"
        case .notRoutedBySplitTunnel:
            // Never instructs the user to change their VPN. Lava opens the route itself at latch
            // time and declines only when THIS address would change the tunnel's routing shape —
            // a property of the address, which is why the remedy is another address.
            return "\(address) can't be added without changing how your VPN routes"
        case .unavailableInFullTunnel:
            // NO REMEDY OFFERED, because there is no fault and nothing for the user to fix. The
            // sentence says what is true and stops: another address would fare identically, and
            // the alternative — telling them to re-shape their VPN profile — is exactly the
            // "go hand-edit your AllowedIPs" instruction this surface refuses to give.
            return "\(address) isn't used while your VPN carries all your traffic"
        }
    }
}
