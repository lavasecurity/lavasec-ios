import Foundation

/// The block-all runtime snapshot the tunnel installs when NO usable rule snapshot is
/// resident — over budget, a build failure such as a blocklist whose upstream rotated past
/// the catalog's pinned hash, or the brief cold-start window during a (re)start. This is
/// the terminal step of INV-DNS-1's degradation order: real snapshot → config-exact
/// last-known-good (INV-DNS-3) → fail-closed.
///
/// Blocks EVERY domain. The reason is `.protectionUnavailable` (NOT `.blocklist`): these
/// are precautionary fail-closed blocks, not curated matches, so labelling them
/// `.blocklist` would forge a blocklist verdict for legitimate domains (the false
/// positives that filled the Blocked tab with google.com / icloud / apple endpoints
/// during fail-closed windows). The honest reason propagates to Domain History (where
/// DiagnosticsStore drops it), bug reports, and CSV export.
///
/// Lives in the package (not the tunnel target) so the block-all semantics are enforced
/// by executable tests instead of source pins on the provider; the provider keeps only
/// the install-site wiring, which `PacketTunnelDNSRuntimeSourceTests` pins.
// pinned: FailClosedRuntimeSnapshotTests.testBlocksEveryDomainWithProtectionUnavailableReason
public struct FailClosedRuntimeSnapshot: FilterRuntimeSnapshot {
    /// Resolver preset the tunnel keeps forwarding through while fail-closed, so upstream
    /// selection stays consistent with the active configuration even though every
    /// filtering decision blocks.
    public let resolver: DNSResolverPreset

    /// No rule artifact is resident while fail-closed; all rule counts are zero.
    public var blockRuleCount: Int { 0 }
    /// No rule artifact is resident while fail-closed; all rule counts are zero.
    public var allowRuleCount: Int { 0 }
    /// No rule artifact is resident while fail-closed; all rule counts are zero.
    public var guardrailRuleCount: Int { 0 }

    /// Creates the block-all snapshot for the given resolver preset.
    public init(resolver: DNSResolverPreset) {
        self.resolver = resolver
    }

    /// Blocks regardless of input — including raw domains that would not normalize.
    public func decision(for rawDomain: String) -> FilterDecision {
        FilterDecision(action: .block, reason: .protectionUnavailable)
    }

    /// Blocks regardless of input.
    public func decision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        FilterDecision(action: .block, reason: .protectionUnavailable)
    }
}
