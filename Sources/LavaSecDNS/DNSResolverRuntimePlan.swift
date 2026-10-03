import Foundation
import LavaSecKit

/// Boxes a nested fallback plan so a `DNSResolverRuntimePlan` (a value type) can
/// carry another plan as its encrypted fallback without self-containment by value.
public final class DNSResolverFallbackPlan: Equatable, @unchecked Sendable {
    package let plan: DNSResolverRuntimePlan
    package init(_ plan: DNSResolverRuntimePlan) { self.plan = plan }
    /// Compares the complete nested plans rather than the reference identity of their boxes.
    public static func == (lhs: DNSResolverFallbackPlan, rhs: DNSResolverFallbackPlan) -> Bool { lhs.plan == rhs.plan }
}

/// An immutable resolver-routing snapshot captured for one query and safe to pass into tunnel orchestration.
public struct DNSResolverRuntimePlan: Equatable, Sendable {
    /// The saved canonical tier supplying this plan's configured primary resolver.
    /// Runtime Device DNS fallback promotion keeps this origin unchanged.
    public let configuredPrimaryTier: DNSResolverTier
    /// The effective primary transport after applying device-DNS mode and endpoint availability.
    public let transport: DNSResolverTransport
    package let plainAddresses: [String]
    /// Ordered DoH endpoints used when the effective transport is DNS over HTTPS.
    public let dohEndpoints: [DNSOverHTTPSEndpoint]
    /// Ordered DoT endpoints used when the effective transport is DNS over TLS.
    public let dotEndpoints: [DNSOverTLSEndpoint]
    /// Ordered DoQ endpoints used when the effective transport is DNS over QUIC.
    public let doqEndpoints: [DNSOverQUICEndpoint]
    /// Stable resolver identity that namespaces cached responses and in-flight coalescing.
    public let cacheIdentifier: String
    /// Captured device-resolver strings; recognized families are ordered for the network and other strings may remain.
    public let deviceDNSFallbackAddresses: [String]
    package let shouldFallbackToDeviceDNS: Bool
    package let usesDeviceDNSFallbackMode: Bool
    // The historical names remain for compatibility. An explicitly selected alternative
    // can follow any primary; legacy preferences activate it only beneath Device DNS.
    /// Whether a failed primary may activate the user-selected alternative fallback.
    public let shouldFallbackToEncrypted: Bool
    /// Fully resolved alternative fallback route, or `nil` when no alternative is selected.
    public let encryptedFallback: DNSResolverFallbackPlan?

    /// Back-compat accessor for readers that only need the DoH endpoints of the
    /// fallback (e.g. the loopback DoH bootstrap). Empty for non-DoH fallbacks.
    public var encryptedFallbackEndpoints: [DNSOverHTTPSEndpoint] { encryptedFallback?.plan.dohEndpoints ?? [] }

    /// DoQ endpoints of the encrypted fallback. A custom `doq://` fallback resolver
    /// keeps its hostname here, so the tunnel must bootstrap/prewarm it the same way
    /// it does the primary's DoQ endpoints — otherwise the DoQ connection's hostname
    /// lookup recurses through the (wedged) Device DNS the fallback exists to escape.
    /// Empty for non-DoQ fallbacks.
    public var encryptedFallbackDoQEndpoints: [DNSOverQUICEndpoint] { encryptedFallback?.plan.doqEndpoints ?? [] }

    /// DoT endpoints of the encrypted fallback. A custom `tls://` / `dot://` fallback
    /// resolver keeps its hostname here; like DoH/DoQ it must be bootstrapped/prewarmed
    /// or its hostname lookup recurses through the (wedged) Device DNS the fallback
    /// exists to escape. Empty for non-DoT fallbacks.
    public var encryptedFallbackDoTEndpoints: [DNSOverTLSEndpoint] { encryptedFallback?.plan.dotEndpoints ?? [] }
    // Whether a server-side error from the Device-DNS primary
    // should trigger the encrypted fallback. Only set when the resolver is already
    // health-confirmed as broadly wedged: a one-off refusal on an otherwise-healthy
    // resolver is an authoritative verdict (a managed-network block or a DNSSEC
    // failure) that must pass through, not be re-asked on the fallback resolver.
    // No-response failures fall back regardless of this flag.
    package let treatsResolverRejectionAsFallbackTrigger: Bool

    /// Fixed encrypted fallback resolver for Device-DNS primary: Quad9's
    /// non-filtering DoH endpoint (Lava filters locally, so the upstream must not
    /// also filter). DoH/443 is chosen for firewall-friendliness on the degraded
    /// networks where the local resolver just failed. It works precisely when the
    /// tunnel's *captured* device resolver is stale/refusing: the DoH client resolves
    /// `dns10.quad9.net` by hostname (URLSession), and that lookup loops back through
    /// the tunnel where `dohBootstrapResponse` answers it from the bootstrap IPs
    /// below — so the fallback reaches Quad9 without depending on the wedged
    /// device resolver. (DoT/DoQ consume their bootstrap IPs directly via NWConnection.)
    // Aliased to the Quad9 DoH preset's endpoint so the default encrypted
    // fallback (when no resolver is selected) and this constant can't drift.
    package static var defaultEncryptedFallbackEndpoint: DNSOverHTTPSEndpoint { DNSResolverPreset.quad9UnfilteredDoH.dohEndpoint! }

    /// This plan with its plain-DNS addresses narrowed to `admitted`, or `nil` when a plain-DNS
    /// plan has nothing admitted left to ask.
    ///
    /// THE T1 RUNG'S PLAN MUST BE THE ADMITTED SET, and the restriction is not cosmetic.
    /// `PacketTunnelProvider.resolvePlainDNS` returns on the FIRST address that produces any
    /// packet — SERVFAIL included, because a reply is a reply. So a preset that partially overlaps
    /// the upstream's own `DNS =` (Cloudflare against `DNS = 1.1.1.1`) would re-ask the very
    /// resolver that just declined the name, stop on its second refusal, and never reach the
    /// address the panel calls admitted (Codex, PR #590). Addresses reported `.alreadyPrimary` or
    /// `.unusable` must not reach the wire at all.
    ///
    /// ORDER IS PRESERVED, not re-derived: `make` has already ordered these for the current
    /// network kind, and re-sorting by the admitted set's order would undo that.
    ///
    /// NIL ONLY FOR AN ADDRESS-ROUTED PLAN — `.plainDNS` and, since PR #592, `.deviceDNS`. For
    /// both, `plainAddresses` IS the route: emptied, the plan has nowhere to send the query, and
    /// nil is the honest answer ("no second opinion to ask") rather than a plan that fails at the
    /// socket. An encrypted plan's addresses are its degradation path, not its primary route, so
    /// emptying them narrows where a degraded query may go without removing the endpoints the
    /// rung actually resolves through.
    ///
    /// A `.deviceDNS` plan can lose its last address here even when the caller saw a non-empty
    /// admitted set: `make` orders and filters the live capture for the current network kind, so
    /// the intersection can be empty where the raw capture's was not.
    /// pinned: DNSResolverRuntimePlanTests.testTheRungPlanKeepsOnlyAdmittedPlainAddresses
    /// pinned: DNSResolverRuntimePlanTests.testADeviceDNSRungPlanWithNothingAdmittedIsNoPlanAtAll
    public func restrictingPlainAddresses(to admitted: [String]) -> DNSResolverRuntimePlan? {
        let allowed = Set(admitted)
        let kept = plainAddresses.filter { allowed.contains($0) }
        if transport == .plainDNS || transport == .deviceDNS, kept.isEmpty { return nil }
        return DNSResolverRuntimePlan(
            transport: transport,
            plainAddresses: kept,
            dohEndpoints: dohEndpoints,
            dotEndpoints: dotEndpoints,
            doqEndpoints: doqEndpoints,
            cacheIdentifier: cacheIdentifier,
            deviceDNSFallbackAddresses: deviceDNSFallbackAddresses,
            shouldFallbackToDeviceDNS: shouldFallbackToDeviceDNS,
            usesDeviceDNSFallbackMode: usesDeviceDNSFallbackMode,
            shouldFallbackToEncrypted: shouldFallbackToEncrypted,
            encryptedFallback: encryptedFallback,
            treatsResolverRejectionAsFallbackTrigger: treatsResolverRejectionAsFallbackTrigger,
            configuredPrimaryTier: configuredPrimaryTier)
    }

    /// This plan with its DEVICE-DNS FALLBACK addresses narrowed to `admitted`.
    ///
    /// THE RUNG'S SECOND LEG NEEDS THE SAME GATE ITS FIRST ONE HAS, and until PR #603 it had none.
    /// ``restrictingPlainAddresses(to:)`` narrows the SELECTED resolver's list, which is the only
    /// list a T1 rung had before PR #596 let it run the full ladder. `deviceDNSFallbackAddresses`
    /// is the tunnel's raw capture, put there by ``make(configuration:deviceDNSAddresses:…)`` without
    /// any chained admission at all — so the newly reachable device leg egressed unadmitted
    /// addresses on `.physical`:
    ///
    /// - an IPv6 device resolver is swallowed by the chained `::/0` blackhole, spending the leg on
    ///   an address that cannot answer, and
    /// - a device resolver that IS the conf's own `DNS =` gets asked the name T0 just declined,
    ///   and `resolveDevice` returns on the first address that yields any packet — SERVFAIL
    ///   included — so its second refusal ends the leg before a usable resolver is tried.
    ///
    /// Both are the failures ``restrictingPlainAddresses(to:)`` exists to prevent, one leg over
    /// (Codex P2, PR #596, on a retro review of the merged code).
    ///
    /// THE FLAG FALLS WITH THE LIST. An empty list is not "ask nothing and continue" — `resolveDevice`
    /// would have nowhere to send the query and the ladder would spend a step discovering it — so a
    /// leg with nothing admitted is switched off here and the ladder moves straight to the
    /// encrypted one. NOT nil like the plain narrowing: emptying THIS list removes a degradation
    /// path, not the plan's route.
    /// pinned: DNSResolverRuntimePlanTests.testTheRungPlanKeepsOnlyAdmittedDeviceFallbackAddresses
    public func restrictingDeviceDNSFallbackAddresses(to admitted: [String]) -> DNSResolverRuntimePlan {
        let allowed = Set(admitted)
        let kept = deviceDNSFallbackAddresses.filter { allowed.contains($0) }
        return DNSResolverRuntimePlan(
            transport: transport,
            plainAddresses: plainAddresses,
            dohEndpoints: dohEndpoints,
            dotEndpoints: dotEndpoints,
            doqEndpoints: doqEndpoints,
            cacheIdentifier: cacheIdentifier,
            deviceDNSFallbackAddresses: kept,
            shouldFallbackToDeviceDNS: shouldFallbackToDeviceDNS && !kept.isEmpty,
            usesDeviceDNSFallbackMode: usesDeviceDNSFallbackMode,
            shouldFallbackToEncrypted: shouldFallbackToEncrypted,
            encryptedFallback: encryptedFallback,
            treatsResolverRejectionAsFallbackTrigger: treatsResolverRejectionAsFallbackTrigger,
            configuredPrimaryTier: configuredPrimaryTier)
    }

    package init(
        transport: DNSResolverTransport,
        plainAddresses: [String],
        dohEndpoints: [DNSOverHTTPSEndpoint],
        dotEndpoints: [DNSOverTLSEndpoint],
        doqEndpoints: [DNSOverQUICEndpoint],
        cacheIdentifier: String,
        deviceDNSFallbackAddresses: [String],
        shouldFallbackToDeviceDNS: Bool,
        usesDeviceDNSFallbackMode: Bool,
        shouldFallbackToEncrypted: Bool = false,
        encryptedFallback: DNSResolverFallbackPlan? = nil,
        // Convenience for tests/callers that still pass raw DoH endpoints; wrapped
        // into a DoH fallback plan when `encryptedFallback` isn't supplied directly.
        encryptedFallbackEndpoints: [DNSOverHTTPSEndpoint] = [],
        treatsResolverRejectionAsFallbackTrigger: Bool = false,
        configuredPrimaryTier: DNSResolverTier = .tierOne
    ) {
        self.configuredPrimaryTier = configuredPrimaryTier
        self.transport = transport
        self.plainAddresses = plainAddresses
        self.dohEndpoints = dohEndpoints
        self.dotEndpoints = dotEndpoints
        self.doqEndpoints = doqEndpoints
        self.cacheIdentifier = cacheIdentifier
        self.deviceDNSFallbackAddresses = deviceDNSFallbackAddresses
        self.shouldFallbackToDeviceDNS = shouldFallbackToDeviceDNS
        self.usesDeviceDNSFallbackMode = usesDeviceDNSFallbackMode
        self.shouldFallbackToEncrypted = shouldFallbackToEncrypted
        if let encryptedFallback {
            self.encryptedFallback = encryptedFallback
        } else if !encryptedFallbackEndpoints.isEmpty {
            self.encryptedFallback = DNSResolverFallbackPlan(DNSResolverRuntimePlan(
                transport: .dnsOverHTTPS,
                plainAddresses: [],
                dohEndpoints: encryptedFallbackEndpoints,
                dotEndpoints: [],
                doqEndpoints: [],
                cacheIdentifier: "doh-fallback",
                deviceDNSFallbackAddresses: [],
                shouldFallbackToDeviceDNS: false,
                usesDeviceDNSFallbackMode: false,
                configuredPrimaryTier: .tierTwo
            ))
        } else {
            self.encryptedFallback = nil
        }
        self.treatsResolverRejectionAsFallbackTrigger = treatsResolverRejectionAsFallbackTrigger
    }

    /// A copy of this plan with `treatsResolverRejectionAsFallbackTrigger` recomputed from a
    /// freshly-read wedge state, leaving every other field — including `cacheIdentifier` — unchanged.
    ///
    /// The trigger derives from the device-resolver wedge marker, which is deliberately NOT folded
    /// into `cacheIdentifier` and does not advance the resolver-runtime generation. On the DNS hot
    /// path the plan is captured once (when the packet is classified) and reused when the query
    /// actually resolves; if the wedge marker flips in between, the captured trigger is stale.
    /// Recomputing just this bit from a fresh read lets a query straddling a Device-DNS wedge
    /// transition be carried by the encrypted fallback rather than returning the wedged resolver's
    /// error response authoritatively — without re-deriving (and re-reading the state behind) the
    /// whole plan. `shouldFallbackToEncrypted` is unchanged, so a plan with no encrypted fallback
    /// keeps a `false` trigger regardless of `deviceResolverWedged`.
    public func recomputingResolverRejectionFallbackTrigger(deviceResolverWedged: Bool) -> DNSResolverRuntimePlan {
        DNSResolverRuntimePlan(
            transport: transport,
            plainAddresses: plainAddresses,
            dohEndpoints: dohEndpoints,
            dotEndpoints: dotEndpoints,
            doqEndpoints: doqEndpoints,
            cacheIdentifier: cacheIdentifier,
            deviceDNSFallbackAddresses: deviceDNSFallbackAddresses,
            shouldFallbackToDeviceDNS: shouldFallbackToDeviceDNS,
            usesDeviceDNSFallbackMode: usesDeviceDNSFallbackMode,
            shouldFallbackToEncrypted: shouldFallbackToEncrypted,
            encryptedFallback: encryptedFallback,
            treatsResolverRejectionAsFallbackTrigger: shouldFallbackToEncrypted && deviceResolverWedged,
            configuredPrimaryTier: configuredPrimaryTier
        )
    }

    /// Resolves persisted configuration and current network state into the immutable plan used for a query.
    public static func make(
        configuration: AppConfiguration,
        deviceDNSAddresses: [String],
        networkKind: TunnelNetworkKind,
        deviceDNSFallbackModeActive: Bool,
        ignoresDeviceDNSFallbackMode: Bool = false,
        allowsQueryFallback: Bool = true,
        deviceResolverWedged: Bool = false
    ) -> DNSResolverRuntimePlan {
        // THROUGH THE PROJECTION, NOT FIELD BY FIELD. `AppConfiguration.resolverLadderInputs` is
        // the one list of configuration inputs that steer a ladder, and
        // `chainedTierOneRungPolicyIdentity` fingerprints that same list to decide whether a
        // running chained session must relatch its T1 rung. Reading fields directly here is
        // what let the two drift: the relatch named the resolver only, so `fallbackToDeviceDNS`,
        // `usesEncryptedDeviceDNSFallback` and `fallbackResolverPreset` moved without it and a
        // running session kept sending failed T1 lookups to the old fallback until restart
        // (Codex P1, PR #599). New inputs, including a saved tier's origin when another row
        // is disabled, join `ResolverLadderInputs` so the runtime and relatch see them together.
        let ladder = configuration.resolverLadderInputs
        return make(
            resolver: ladder.resolver,
            fallbackToDeviceDNS: ladder.fallbackToDeviceDNS,
            usesEncryptedDeviceDNSFallback: ladder.usesEncryptedDeviceDNSFallback,
            usesExplicitDNSTiers: ladder.usesExplicitDNSTiers,
            deviceDNSAddresses: deviceDNSAddresses,
            networkKind: networkKind,
            deviceDNSFallbackModeActive: deviceDNSFallbackModeActive,
            ignoresDeviceDNSFallbackMode: ignoresDeviceDNSFallbackMode,
            allowsQueryFallback: allowsQueryFallback,
            deviceResolverWedged: deviceResolverWedged,
            encryptedFallbackResolver: ladder.encryptedFallbackResolver,
            configuredPrimaryTier: ladder.configuredPrimaryTier
        )
    }

    package static func make(
        resolver: DNSResolverPreset,
        fallbackToDeviceDNS: Bool,
        usesEncryptedDeviceDNSFallback: Bool = false,
        usesExplicitDNSTiers: Bool = false,
        deviceDNSAddresses: [String],
        networkKind: TunnelNetworkKind,
        deviceDNSFallbackModeActive: Bool,
        ignoresDeviceDNSFallbackMode: Bool = false,
        allowsQueryFallback: Bool = true,
        deviceResolverWedged: Bool = false,
        encryptedFallbackResolver: DNSResolverPreset? = nil,
        configuredPrimaryTier: DNSResolverTier = .tierOne
    ) -> DNSResolverRuntimePlan {
        let orderedDeviceDNSAddresses = orderedResolverAddresses(deviceDNSAddresses, networkKind: networkKind)
        let resolverPlainAddresses = orderedResolverAddresses(
            resolver.ipv4Servers + resolver.ipv6Servers,
            networkKind: networkKind
        )
        let defaultPlainFallback = DNSResolverPreset.google.ipv4Servers + DNSResolverPreset.google.ipv6Servers
        let usesDeviceDNSFallbackMode = !ignoresDeviceDNSFallbackMode
            && deviceDNSFallbackModeActive
            && fallbackToDeviceDNS
            && resolver.transport != .deviceDNS
            && !orderedDeviceDNSAddresses.isEmpty

        let effectiveTransport: DNSResolverTransport
        let effectivePlainAddresses: [String]
        let dohEndpoints: [DNSOverHTTPSEndpoint]
        let dotEndpoints: [DNSOverTLSEndpoint]
        let doqEndpoints: [DNSOverQUICEndpoint]

        if usesDeviceDNSFallbackMode || resolver.transport == .deviceDNS {
            effectiveTransport = .deviceDNS
            effectivePlainAddresses = orderedDeviceDNSAddresses
            dohEndpoints = []
            dotEndpoints = []
            doqEndpoints = []
        } else if resolver.transport == .dnsOverHTTPS, !resolver.dohEndpoints.isEmpty {
            effectiveTransport = .dnsOverHTTPS
            effectivePlainAddresses = resolverPlainAddresses.isEmpty ? defaultPlainFallback : resolverPlainAddresses
            dohEndpoints = resolver.dohEndpoints
            dotEndpoints = []
            doqEndpoints = []
        } else if resolver.transport == .dnsOverTLS, !resolver.dotEndpoints.isEmpty {
            effectiveTransport = .dnsOverTLS
            let bootstrapAddresses = orderedResolverAddresses(
                resolver.dotEndpoints.flatMap(\.allBootstrapServers),
                networkKind: networkKind
            )
            effectivePlainAddresses = bootstrapAddresses.isEmpty ? resolverPlainAddresses : bootstrapAddresses
            dohEndpoints = []
            dotEndpoints = resolver.dotEndpoints
            doqEndpoints = []
        } else if resolver.transport == .dnsOverQUIC, !resolver.doqEndpoints.isEmpty {
            effectiveTransport = .dnsOverQUIC
            let bootstrapAddresses = orderedResolverAddresses(
                resolver.doqEndpoints.flatMap(\.allBootstrapServers),
                networkKind: networkKind
            )
            effectivePlainAddresses = bootstrapAddresses.isEmpty ? resolverPlainAddresses : bootstrapAddresses
            dohEndpoints = []
            dotEndpoints = []
            doqEndpoints = resolver.doqEndpoints
        } else {
            effectiveTransport = .plainDNS
            effectivePlainAddresses = resolverPlainAddresses.isEmpty ? defaultPlainFallback : resolverPlainAddresses
            dohEndpoints = []
            dotEndpoints = []
            doqEndpoints = []
        }

        let primaryCacheIdentifier = cacheIdentifier(
            transport: effectiveTransport,
            plainAddresses: effectivePlainAddresses,
            dohEndpoints: dohEndpoints,
            dotEndpoints: dotEndpoints,
            doqEndpoints: doqEndpoints
        )
        // T2, DECIDED ONCE. These two legs are the same tier — "what answers the names T1 could
        // not" — and the settings page has always offered them as one control whose label follows
        // the primary. They used to be computed here as two independent booleans from opposite
        // sides of `resolver.transport == .deviceDNS`: mutually exclusive by construction, but
        // nothing said so and nothing named the tier. `ResolverTierTwo` is that name, and
        // deriving both legs from its one answer is what keeps them in step
        // (`docs/architecture/dns-tiers.md`).
        //
        // Defaulting to Quad9 DoH (when no fallback resolver is passed) keeps resolver-based
        // callers producing the prior behaviour.
        // pinned: ResolverTierTwoTests.testTheTwoLegsAreTheSameTierAndNeverArmTogether
        let resolvedFallbackResolver = encryptedFallbackResolver ?? .quad9UnfilteredDoH
        let tierTwo = ResolverTierTwo.resolve(
            primaryTransport: resolver.transport,
            effectiveTransport: effectiveTransport,
            fallbackToDeviceDNS: fallbackToDeviceDNS,
            usesEncryptedDeviceDNSFallback: usesEncryptedDeviceDNSFallback,
            usesExplicitDNSTiers: usesExplicitDNSTiers,
            encryptedFallbackResolver: resolvedFallbackResolver,
            allowsQueryFallback: allowsQueryFallback,
            hasDeviceDNSAddresses: !orderedDeviceDNSAddresses.isEmpty)
        let shouldFallbackToDeviceDNS = tierTwo == .deviceDNS
        // A Device-DNS *primary* (the configured preset, not the device-DNS-fallback mode) gets a
        // per-query encrypted fallback so a wedged local resolver doesn't strand the user. Opt-in
        // (default off — enabling a third-party encrypted resolver is explicit), and off for the
        // smoke probe (allowsQueryFallback == false) so the probe still measures the *primary*
        // device resolver's health.
        let shouldFallbackToEncrypted = tierTwo.isResolver
        // WHETHER A PLAN CAN BE BUILT IS SEPARATE FROM WHICH TIER WAS CHOSEN. A user whose
        // fallback selection is itself Device DNS has chosen T2 — `shouldFallbackToEncrypted`
        // stays true, and with it `treatsResolverRejectionAsFallbackTrigger` below — but there is
        // no encrypted plan to route it through, so the nested plan is nil exactly as before.
        // The nested plan disables its own fallbacks, so no rung can spawn a rung.
        let encryptedFallback: DNSResolverFallbackPlan? = tierTwo.resolverPreset
            .flatMap { preset -> DNSResolverFallbackPlan? in
                guard preset.transport != .deviceDNS else { return nil }
                return DNSResolverFallbackPlan(DNSResolverRuntimePlan.make(
                    resolver: preset,
                    fallbackToDeviceDNS: false,
                    usesEncryptedDeviceDNSFallback: false,
                    deviceDNSAddresses: [],
                    networkKind: networkKind,
                    deviceDNSFallbackModeActive: false,
                    allowsQueryFallback: false,
                    configuredPrimaryTier: .tierTwo
                ))
            }
        // Only let a device error reply engage the fallback once the
        // resolver is health-confirmed as broadly wedged; otherwise a refusal is an
        // authoritative per-domain verdict and is honored. (No-response failures
        // engage the fallback regardless — see ResolverOrchestrator.)
        let treatsResolverRejectionAsFallbackTrigger = shouldFallbackToEncrypted && deviceResolverWedged
        let fallbackIdentifier = shouldFallbackToDeviceDNS
            ? "|fallback:device:" + orderedDeviceDNSAddresses.joined(separator: ",")
            : ""
        let encryptedFallbackIdentifier = encryptedFallback.map { "|fallback:encrypted:" + $0.plan.cacheIdentifier } ?? ""
        let fallbackModeIdentifier = usesDeviceDNSFallbackMode ? "|mode:device-dns-fallback" : ""
        let tierIdentifier = configuredPrimaryTier == .tierOne
            ? "" : "|configured-primary:\(configuredPrimaryTier.rawValue)"

        return DNSResolverRuntimePlan(
            transport: effectiveTransport,
            plainAddresses: effectivePlainAddresses,
            dohEndpoints: dohEndpoints,
            dotEndpoints: dotEndpoints,
            doqEndpoints: doqEndpoints,
            cacheIdentifier: primaryCacheIdentifier + fallbackIdentifier + encryptedFallbackIdentifier + fallbackModeIdentifier + tierIdentifier,
            deviceDNSFallbackAddresses: orderedDeviceDNSAddresses,
            shouldFallbackToDeviceDNS: shouldFallbackToDeviceDNS,
            usesDeviceDNSFallbackMode: usesDeviceDNSFallbackMode,
            shouldFallbackToEncrypted: shouldFallbackToEncrypted,
            encryptedFallback: encryptedFallback,
            treatsResolverRejectionAsFallbackTrigger: treatsResolverRejectionAsFallbackTrigger,
            configuredPrimaryTier: configuredPrimaryTier
        )
    }

    /// Groups resolver literals by family, preferring IPv6 on cellular and preserving relative order within each group.
    public static func orderedResolverAddresses(
        _ addresses: [String],
        networkKind: TunnelNetworkKind
    ) -> [String] {
        var ipv4Addresses: [String] = []
        var ipv6Addresses: [String] = []
        var otherAddresses: [String] = []

        for address in addresses {
            if let families = NetworkEndpointValidator.dnsResolverAddresses(from: address) {
                if !families.ipv4.isEmpty {
                    ipv4Addresses.append(address)
                } else if !families.ipv6.isEmpty {
                    ipv6Addresses.append(address)
                } else {
                    otherAddresses.append(address)
                }
            } else {
                otherAddresses.append(address)
            }
        }

        if networkKind == .cellular {
            return ipv6Addresses + ipv4Addresses + otherAddresses
        }

        return ipv4Addresses + ipv6Addresses + otherAddresses
    }

    /// The identity of the PRIMARY resolver alone (its effective transport + addresses/endpoints),
    /// WITHOUT the `|fallback:…` / `|mode:…` components that `cacheIdentifier` also folds in.
    /// Recomputed from the plan's stored primary fields, so it stays stable when only a fallback
    /// wrapper changes (e.g. the encrypted fallback resolver, or — for a Device-DNS primary, which
    /// is this feature's scope — there is no device-DNS-fallback MODE to flip the effective transport).
    /// Used to detect a genuine primary-resolver switch vs a fallback-only runtime reset.
    /// Canonical against the AUTOMATIC reorder only: `orderedResolverAddresses` flips the v4/v6
    /// family ordering by network kind, so the SAME address set must not read as a different
    /// identity across a wifi↔cellular flap — identity-scoped evidence (the LAV-87
    /// rejected-response streak) keys on this value and must survive that churn. User-semantic
    /// ordering is preserved: relative order WITHIN a family (a custom resolver's
    /// primary/secondary swap changes try-order behavior) and endpoint-list order (never
    /// touched by the network-kind reorder) still register as real identity changes that clear
    /// identity-scoped evidence. The full `cacheIdentifier` stays fully order-SENSITIVE on
    /// purpose: it is the runtime-reset no-op key, where any reorder is a real "connections
    /// need rebuilding" signal.
    public var primaryCacheIdentifier: String {
        Self.cacheIdentifier(
            transport: transport,
            plainAddresses: Self.canonicalIdentityAddressOrder(plainAddresses),
            dohEndpoints: dohEndpoints,
            dotEndpoints: dotEndpoints,
            doqEndpoints: doqEndpoints
        )
    }

    /// Re-emits addresses in the fixed non-cellular family order (v4, v6, other) that
    /// `orderedResolverAddresses` produces for wifi, preserving relative order within each
    /// family — neutralizing exactly the cellular family flip and nothing else.
    private static func canonicalIdentityAddressOrder(_ addresses: [String]) -> [String] {
        orderedResolverAddresses(addresses, networkKind: .wifi)
    }

    private static func cacheIdentifier(
        transport: DNSResolverTransport,
        plainAddresses: [String],
        dohEndpoints: [DNSOverHTTPSEndpoint],
        dotEndpoints: [DNSOverTLSEndpoint],
        doqEndpoints: [DNSOverQUICEndpoint]
    ) -> String {
        switch transport {
        case .deviceDNS:
            "device:" + plainAddresses.joined(separator: ",")
        case .dnsOverHTTPS:
            dohEndpoints.map(\.cacheIdentifier).joined(separator: ",")
        case .dnsOverTLS:
            dotEndpoints.map(\.cacheIdentifier).joined(separator: ",")
        case .dnsOverQUIC:
            doqEndpoints.map(\.cacheIdentifier).joined(separator: ",")
        case .plainDNS:
            plainAddresses.joined(separator: ",")
        }
    }
}
