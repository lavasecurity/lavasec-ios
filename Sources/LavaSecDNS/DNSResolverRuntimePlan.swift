import Foundation
import LavaSecKit

/// Boxes a nested fallback plan so a `DNSResolverRuntimePlan` (a value type) can
/// carry another plan as its encrypted fallback without self-containment by value.
public final class DNSResolverFallbackPlan: Equatable, @unchecked Sendable {
    public let plan: DNSResolverRuntimePlan
    public init(_ plan: DNSResolverRuntimePlan) { self.plan = plan }
    public static func == (lhs: DNSResolverFallbackPlan, rhs: DNSResolverFallbackPlan) -> Bool { lhs.plan == rhs.plan }
}

public struct DNSResolverRuntimePlan: Equatable, Sendable {
    public let transport: DNSResolverTransport
    public let plainAddresses: [String]
    public let dohEndpoints: [DNSOverHTTPSEndpoint]
    public let dotEndpoints: [DNSOverTLSEndpoint]
    public let doqEndpoints: [DNSOverQUICEndpoint]
    public let cacheIdentifier: String
    public let deviceDNSFallbackAddresses: [String]
    public let shouldFallbackToDeviceDNS: Bool
    public let usesDeviceDNSFallbackMode: Bool
    // Inverse of shouldFallbackToDeviceDNS: when the *primary* is Device DNS and it
    // is wedged, fall back per-query to an encrypted resolver (Mullvad DoH) so a
    // single bad/stale local resolver doesn't strand the user. Mutually exclusive
    // with shouldFallbackToDeviceDNS (that requires a non-device primary).
    public let shouldFallbackToEncrypted: Bool
    // The per-query encrypted fallback for a Device-DNS primary, as a fully-formed
    // nested plan resolved through the user-selected fallback resolver and its
    // transport (plain / DoH / DoT). Nil when no encrypted fallback applies.
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
    // Whether a server-side refusal (SERVFAIL/REFUSED) from the Device-DNS primary
    // should trigger the encrypted fallback. Only set when the resolver is already
    // health-confirmed as broadly wedged: a one-off refusal on an otherwise-healthy
    // resolver is an authoritative verdict (a managed-network block or a DNSSEC
    // failure) that must pass through, not be re-asked on the fallback resolver.
    // No-response failures fall back regardless of this flag.
    public let treatsResolverRejectionAsFallbackTrigger: Bool

    /// Fixed encrypted fallback resolver for Device-DNS primary: Mullvad's
    /// non-filtering DoH endpoint (Lava filters locally, so the upstream must not
    /// also filter). DoH/443 is chosen for firewall-friendliness on the degraded
    /// networks where the local resolver just failed. It works precisely when the
    /// tunnel's *captured* device resolver is stale/refusing: the DoH client resolves
    /// `dns.mullvad.net` by hostname (URLSession), and that lookup loops back through
    /// the tunnel where `dohBootstrapResponse` answers it from the bootstrap IPs
    /// below — so the fallback reaches Mullvad without depending on the wedged
    /// device resolver. (DoT/DoQ consume their bootstrap IPs directly via NWConnection.)
    // Aliased to the Mullvad DoH preset's endpoint so the default encrypted
    // fallback (when no resolver is selected) and this constant can't drift.
    public static var mullvadEncryptedFallbackEndpoint: DNSOverHTTPSEndpoint { DNSResolverPreset.mullvadDoH.dohEndpoint! }

    public init(
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
        treatsResolverRejectionAsFallbackTrigger: Bool = false
    ) {
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
                usesDeviceDNSFallbackMode: false
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
    /// SERVFAIL/REFUSED authoritatively — without re-deriving (and re-reading the state behind) the
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
            treatsResolverRejectionAsFallbackTrigger: shouldFallbackToEncrypted && deviceResolverWedged
        )
    }

    public static func make(
        configuration: AppConfiguration,
        deviceDNSAddresses: [String],
        networkKind: TunnelNetworkKind,
        deviceDNSFallbackModeActive: Bool,
        ignoresDeviceDNSFallbackMode: Bool = false,
        allowsQueryFallback: Bool = true,
        deviceResolverWedged: Bool = false
    ) -> DNSResolverRuntimePlan {
        make(
            resolver: configuration.resolverPreset,
            fallbackToDeviceDNS: configuration.fallbackToDeviceDNS,
            usesEncryptedDeviceDNSFallback: configuration.usesEncryptedDeviceDNSFallback,
            deviceDNSAddresses: deviceDNSAddresses,
            networkKind: networkKind,
            deviceDNSFallbackModeActive: deviceDNSFallbackModeActive,
            ignoresDeviceDNSFallbackMode: ignoresDeviceDNSFallbackMode,
            allowsQueryFallback: allowsQueryFallback,
            deviceResolverWedged: deviceResolverWedged,
            encryptedFallbackResolver: configuration.fallbackResolverPreset
        )
    }

    public static func make(
        resolver: DNSResolverPreset,
        fallbackToDeviceDNS: Bool,
        usesEncryptedDeviceDNSFallback: Bool = false,
        deviceDNSAddresses: [String],
        networkKind: TunnelNetworkKind,
        deviceDNSFallbackModeActive: Bool,
        ignoresDeviceDNSFallbackMode: Bool = false,
        allowsQueryFallback: Bool = true,
        deviceResolverWedged: Bool = false,
        encryptedFallbackResolver: DNSResolverPreset? = nil
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
        let shouldFallbackToDeviceDNS = fallbackToDeviceDNS
            && allowsQueryFallback
            && effectiveTransport != .deviceDNS
            && !orderedDeviceDNSAddresses.isEmpty
        // Inverse direction: a Device-DNS *primary* (the configured preset, not the
        // device-DNS-fallback mode) gets a per-query encrypted fallback so a wedged
        // local resolver doesn't strand the user. Gated by its own opt-in flag
        // (default off — enabling a third-party encrypted resolver is explicit), and
        // off for the smoke probe (allowsQueryFallback == false) so the probe still
        // measures the *primary* device resolver's health.
        let shouldFallbackToEncrypted = usesEncryptedDeviceDNSFallback
            && allowsQueryFallback
            && resolver.transport == .deviceDNS
        // Build the encrypted fallback as a fully-formed nested plan resolved through
        // the user-selected fallback resolver and its transport. Defaulting to Mullvad
        // DoH (when none is passed) keeps resolver-based callers producing the prior
        // behavior. The nested plan disables its own encrypted/device fallbacks so
        // there's no infinite recursion.
        let resolvedFallbackResolver = encryptedFallbackResolver ?? .mullvadDoH
        let encryptedFallback: DNSResolverFallbackPlan?
        if shouldFallbackToEncrypted, resolvedFallbackResolver.transport != .deviceDNS {
            encryptedFallback = DNSResolverFallbackPlan(DNSResolverRuntimePlan.make(
                resolver: resolvedFallbackResolver,
                fallbackToDeviceDNS: false,
                usesEncryptedDeviceDNSFallback: false,
                deviceDNSAddresses: [],
                networkKind: networkKind,
                deviceDNSFallbackModeActive: false,
                allowsQueryFallback: false
            ))
        } else {
            encryptedFallback = nil
        }
        // Only let a SERVFAIL/REFUSED device reply engage the fallback once the
        // resolver is health-confirmed as broadly wedged; otherwise a refusal is an
        // authoritative per-domain verdict and is honored. (No-response failures
        // engage the fallback regardless — see ResolverOrchestrator.)
        let treatsResolverRejectionAsFallbackTrigger = shouldFallbackToEncrypted && deviceResolverWedged
        let fallbackIdentifier = shouldFallbackToDeviceDNS
            ? "|fallback:device:" + orderedDeviceDNSAddresses.joined(separator: ",")
            : ""
        let encryptedFallbackIdentifier = encryptedFallback.map { "|fallback:encrypted:" + $0.plan.cacheIdentifier } ?? ""
        let fallbackModeIdentifier = usesDeviceDNSFallbackMode ? "|mode:device-dns-fallback" : ""

        return DNSResolverRuntimePlan(
            transport: effectiveTransport,
            plainAddresses: effectivePlainAddresses,
            dohEndpoints: dohEndpoints,
            dotEndpoints: dotEndpoints,
            doqEndpoints: doqEndpoints,
            cacheIdentifier: primaryCacheIdentifier + fallbackIdentifier + encryptedFallbackIdentifier + fallbackModeIdentifier,
            deviceDNSFallbackAddresses: orderedDeviceDNSAddresses,
            shouldFallbackToDeviceDNS: shouldFallbackToDeviceDNS,
            usesDeviceDNSFallbackMode: usesDeviceDNSFallbackMode,
            shouldFallbackToEncrypted: shouldFallbackToEncrypted,
            encryptedFallback: encryptedFallback,
            treatsResolverRejectionAsFallbackTrigger: treatsResolverRejectionAsFallbackTrigger
        )
    }

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
