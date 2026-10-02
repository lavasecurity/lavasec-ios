/// Selects route enforcement without applying split-route semantics to a full tunnel.
public enum DNSRouteEnforcementPolicy {
    /// Whether this profile uses specific DNS/peer routes that must override interface scoping.
    /// An unreadable chained configuration must not be guessed to use split routes.
    /// The optional resolver-capture comparison applies only to DNS-only/split profiles;
    /// retaining its preference must not enable default-route enforcement after switching to full.
    public static func shouldEnforce(
        chainedUpstreamEnabled: Bool,
        routingPolicy: ChainedRoutingPolicy?,
        resolverCaptureOverride: Bool? = nil
    ) -> Bool {
        guard !chainedUpstreamEnabled || routingPolicy == .splitTunnel else { return false }
        return resolverCaptureOverride ?? true
    }

    /// Gates an explicitly requested full-tunnel enforcement experiment. Split, DNS-only,
    /// and unreadable configurations must never capture traffic they cannot forward.
    public static func shouldIncludeAllNetworks(
        requested: Bool,
        chainedUpstreamEnabled: Bool,
        routingPolicy: ChainedRoutingPolicy?
    ) -> Bool {
        requested && chainedUpstreamEnabled && routingPolicy == .fullTunnel
    }
}
