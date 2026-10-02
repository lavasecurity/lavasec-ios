import Foundation

/// Which clear-text DNS a running tunnel can actually see, derived from the routes it claims.
///
/// ## Why this is a type and not a sentence in a plan
///
/// "Lava filters your DNS" is true in every mode, and it means three different things. The
/// SYSTEM resolver is captured in all of them — `NEDNSSettings` with `matchDomains = [""]`
/// points it at the in-tunnel proxy whatever else is routed
/// (`PacketTunnelProvider+Lifecycle.swift`, claim #13 of the anchors plan). What changes is
/// the app that ignores the system resolver and dials `8.8.8.8:53` itself: that datagram is
/// only filterable if the tunnel CLAIMED the route to it, because a destination the tunnel
/// does not claim never enters the NE at all.
///
/// So the capture set is not a property of "chained vs DNS-only". It is a property of the
/// ROUTE SET, and deriving it from ``TunnelRoutePlan`` rather than from `TunnelDataPathMode`
/// is what stops the two from drifting: a mode-keyed switch would have to be edited by hand
/// every time the route plan gained a shape, and the shape it already gained — the split
/// tunnel — is exactly the one a two-mode reading gets wrong.
///
/// ## The three shapes this collapses to two
///
/// | Data path | Claims | Scope |
/// |---|---|---|
/// | chained, full tunnel | `0.0.0.0/0` + `::/0` | ``everyDestination`` |
/// | chained, split tunnel | `AllowedIPs` + the DNS-capture `/24` + `::/0` | ``systemResolverAndClaimedRoutes`` |
/// | DNS-only | the DNS-capture `/24` | ``systemResolverAndClaimedRoutes`` |
///
/// Split and DNS-only share a case deliberately. They differ in how MANY prefixes they claim,
/// not in the RULE — both capture the system resolver plus whatever they routed, and let a
/// hardcoded resolver at any other destination egress direct and unfiltered. `TunnelRoutePlan`
/// already says so for split in prose ("A raw socket to a hardcoded resolver at a DIRECT
/// destination egresses unfiltered: dns-only-grade for the direct portion"); this type is that
/// sentence made checkable. A split configuration whose own `AllowedIPs` cover the default
/// route is not a third shape — `ChainedRoutingPolicy` derives `.fullTunnel` for it, so it
/// arrives here claiming `0.0.0.0/0` and gets the scope it earned.
///
/// ## IPv6 is a TERM of the strongest scope, not an aside
///
/// ``everyDestination`` requires the plan to claim IPv6 as well, and the reason is that the two
/// ways a plan can treat IPv6 are not the same fact. A full tunnel from `TunnelRoutePlan.make`
/// claims `::/0` in order to BLACKHOLE it (`INV-CHAIN-1`), so an IPv6 DNS query is dropped
/// rather than resolved: fail-closed, and no escape. A plan that claims `0.0.0.0/0` and NO
/// `::/0` leaves IPv6 on the physical interface, where a hardcoded IPv6 resolver is neither
/// captured nor dropped — it simply leaves. `TunnelRoutePlan` already names that second shape
/// ``TunnelRoutePlan/leaksIPv6AroundTheTunnel``, and ``forRoutePlan(_:)`` reads that predicate
/// rather than assuming the factory paired the two claims.
///
/// Claiming `::/0` is still not sufficient, because a claim is not an installation: iOS is
/// handed `NEIPv6Settings` only when the plan carries an address and prefix length as well, so
/// ``TunnelRoutePlan/installsIPv6Settings`` is a term of the strongest scope too.
///
/// Under ``systemResolverAndClaimedRoutes`` the plan does not claim the IPv4 default route, so a
/// hardcoded IPv4 resolver at a direct destination still escapes — that is this scope's honest
/// ceiling, and why it is weaker than ``everyDestination``. IPv6 is no longer part of that gap:
/// split tunnel claims `::/0` to blackhole it too (2026-09-17/19), so a v6 query is dropped
/// rather than answered unfiltered and only the IPv4 half stays selective. DNS-only still leaves
/// IPv6 on the physical path, from which `make` claims it no IPv6.
///
/// `INV-DNS-7` is the registry entry; `DNSCaptureScopeTests` is its enforcement.
public enum DNSCaptureScope: Equatable, Sendable {
    /// Every clear-text DNS datagram leaving the device is captured and filtered, whatever
    /// resolver it names — IPv4 intercepted on port 53, IPv6 dropped at the route it claimed
    /// (`INV-CHAIN-1`), neither escaping. Only a tunnel claiming BOTH default routes — and
    /// carrying the IPv6 address and prefix that make the v6 claim installable — can say this;
    /// a plan that leaves the IPv4 default unclaimed earns the weaker scope whatever it does
    /// with IPv6.
    case everyDestination
    /// The system resolver (through `NEDNSSettings`), plus clear-text DNS aimed at a
    /// destination inside the claimed routes — a hardcoded resolver the profile's own
    /// `AllowedIPs` happen to cover IS captured and filtered, on the same port-53 rule. A
    /// hardcoded resolver anywhere else egresses DIRECT and unfiltered — the signed-off
    /// `INV-DNS-1` scope for these shapes, not a regression.
    case systemResolverAndClaimedRoutes

    /// The scope `plan`'s routes produce.
    ///
    /// Three terms, and ALL are load-bearing. ``TunnelRoutePlan/claimsDefaultRoute`` is the
    /// condition under which no IPv4 destination sits outside the claim. `!plan.`
    /// ``TunnelRoutePlan/leaksIPv6AroundTheTunnel`` is the condition under which no IPv6 one
    /// does either — and it cannot be assumed from the first, because a plan claiming
    /// `0.0.0.0/0` while claiming no `::/0` is CONSTRUCTIBLE through the public initializer
    /// and is built deliberately by `TunnelRoutePlanTests.testTheLeakPredicateActuallyDetectsALeak`.
    /// On such a plan a hardcoded IPv6 resolver egresses direct and unfiltered, so
    /// ``everyDestination`` would be an over-claim (Codex, PR #728).
    ///
    /// Spelled through the LEAK predicate rather than as `claimsDefaultRoute &&
    /// claimsIPv6DefaultRoute` — the same Boolean, chosen for what it ties together. "IPv6
    /// escapes this plan" then has ONE definition that both the leak guard and this scope
    /// read, so a future refinement of it (a partial IPv6 route the upstream really carries,
    /// say) moves the coverage claim with it instead of leaving the two to disagree.
    ///
    /// ``TunnelRoutePlan/installsIPv6Settings`` is the THIRD term, and it is not redundant with
    /// the second: a route array is a CLAIM, and the provider installs `NEIPv6Settings` only
    /// when the plan also carries an address and a prefix length. A plan claiming `::/0` with
    /// `tunnelIPv6Address` nil therefore leaks IPv6 exactly as one claiming no route does,
    /// while `leaksIPv6AroundTheTunnel` — which asks only about the route claim — reports no
    /// leak. `make` never emits the mixed shape — a full tunnel sets all three, DNS-only and
    /// split set none — so no running tunnel is narrowed by this term, but the function takes
    /// any plan and must not claim coverage iOS was never asked to install (Codex, PR #728).
    ///
    /// Nothing here is special-cased per mode, which is the point: a future route shape gets
    /// its scope from what it claims rather than from a list someone has to remember to
    /// extend.
    ///
    /// ## What "the route set" means here, exactly
    ///
    /// ``TunnelRoutePlan/claimsDefaultRoute`` requires a literal `0.0.0.0/0` and no exclusions.
    /// The QA DNS-only default declaration therefore retains the limited scope. This is not
    /// an aggregate coverage computation, so a hand-built plan spelling the route as `0.0.0.0/1` +
    /// `128.0.0.0/1` reports ``systemResolverAndClaimedRoutes`` though every IPv4 destination is
    /// in fact claimed. That is an UNDER-claim, and it is left standing deliberately (Codex,
    /// PR #728):
    ///
    /// - The aggregate sweep already happens one layer up, on the `AllowedIPs` the user
    ///   supplies — `ChainedUpstreamConfiguration.coversIPv4DefaultRoute` derives `.fullTunnel`
    ///   for the two-halves idiom, and `make` then emits the literal `/0`. Every plan in
    ///   shipping code comes from `make`; the public initializer is used only by tests.
    /// - Re-deriving coverage here would put a SECOND definition of "claims the whole IPv4
    ///   space" beside `claimsDefaultRoute` — the two-descriptions-of-one-routing split
    ///   `TunnelRoutePlan` exists to close.
    /// - It would also desynchronize this from ``TunnelRoutePlan/leaksIPv6AroundTheTunnel``,
    ///   which keys on that same literal: a two-halves plan would become ``everyDestination``
    ///   while the leak predicate, believing no default route is claimed, reports no leak — so
    ///   its IPv6 status would go unchecked, reopening the over-claim the paragraph above
    ///   closes.
    ///
    /// Under-reporting coverage cannot produce a false safety claim, which is the failure
    /// `INV-DNS-7` exists to prevent; over-reporting can. If aggregate awareness is ever
    /// wanted, its home is `claimsDefaultRoute` itself, so the leak guard and this scope move
    /// together.
    public static func forRoutePlan(_ plan: TunnelRoutePlan) -> DNSCaptureScope {
        plan.claimsDefaultRoute && !plan.leaksIPv6AroundTheTunnel && plan.installsIPv6Settings
            ? .everyDestination
            : .systemResolverAndClaimedRoutes
    }

    /// Whether an app that ignores the system resolver and dials a resolver address itself is
    /// filtered NO MATTER WHICH address it dialled.
    ///
    /// The one product question this type exists to answer, and the one a coverage claim must
    /// not overstate: it is TRUE only under ``everyDestination``.
    ///
    /// It is deliberately NOT spelled "captures hardcoded-resolver queries", because that
    /// question has no scope-level answer under ``systemResolverAndClaimedRoutes`` and a
    /// `false` there would UNDER-report. A split profile whose `AllowedIPs` contain the
    /// resolver DOES capture it: the route plan draws that query into the tunnel, and the
    /// classifier intercepts it on port 53 exactly as under a full tunnel. So the answer turns
    /// on the destination, which a scope-level Boolean does not have.
    ///
    /// That is the ORDINARY shape rather than a contrived one, which is why the name matters:
    /// the Tailscale profile this feature is repeatedly tested against carries
    /// `AllowedIPs = 100.64.0.0/10` and `DNS = 100.100.100.100` (field captures 2026-08-26 and
    /// 2026-09-01, `ChainedResolverEgress` / `ChainedOutageDriver`), and MagicDNS at
    /// `100.100.100.100` is INSIDE that `/10`. So an app on that profile dialling MagicDNS
    /// directly IS captured and filtered, while the same app dialling `8.8.8.8` is not — one
    /// profile, both answers. Which destinations fall each way is a property of the profile's
    /// prefixes, not of the scope. Answering per query needs the destination and the plan's
    /// routes; this accessor answers the only question the scope alone settles.
    /// (Codex, PR #728.)
    public var capturesEveryHardcodedResolverDestination: Bool {
        self == .everyDestination
    }

    /// Stable identifier for device logs. Never user copy.
    ///
    /// Logged beside the claimed route at settings-apply time, for the same reason the route
    /// description names both families: a field log has to be able to confirm which coverage
    /// the session actually got, rather than which one the configuration asked for.
    public var logValue: String {
        switch self {
        case .everyDestination:
            return "every-destination"
        case .systemResolverAndClaimedRoutes:
            return "system-resolver-and-claimed-routes"
        }
    }
}
