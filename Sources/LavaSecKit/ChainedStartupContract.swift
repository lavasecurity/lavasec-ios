import Foundation

/// Keeps the forwarding path compatible with the installed profile during startup.
///
/// Under ordinary routing, a refusal falls back to the latched DNS-only path: it
/// starts, the refusal is recorded for disclosure, and chaining stays requested until an
/// explicit user action changes it. The saved chaining intent still governs which mode runs;
/// only the failure handling changed. Refusing the start turned a transient locked-device read
/// into an automatic OFF on 2026-09-17 (a terminal marker disarmed Connect-On-Demand, the app
/// persisted OFF, and the device sat unfiltered until the user noticed) —
/// plans/2026-09-18-fail-closed-protection-startup-failures-plan.md. An all-network profile
/// instead requires a full forwarding path; a DNS-only fallback would strand allowed traffic.
public enum ChainedStartupContract {
    /// Whether the provider may install network settings for the latched data path.
    public enum Decision: Equatable, Sendable {
        /// The latch matches the saved request, so startup continues as latched.
        case start
        /// Chaining was requested but the latch refused it. Startup continues on the latched
        /// DNS-only path; the refusal is recorded for disclosure and explicit recovery.
        case startDegraded(refusal: TunnelDataPathLatch.Refusal?)
        /// An all-network profile cannot run a DNS-only or split forwarding path.
        case rejectStrictProfile(refusal: TunnelDataPathLatch.Refusal?)
    }

    /// Validates the provider's immutable latch against the readable saved chaining setting.
    ///
    /// pinned: ChainedStartupContractTests.testARequestedChainNeverStartsUnfiltered
    public static func decide(
        chainedUpstreamEnabled: Bool,
        latchedMode: TunnelDataPathMode,
        refusal: TunnelDataPathLatch.Refusal?,
        includeAllNetworks: Bool = false
    ) -> Decision {
        if includeAllNetworks {
            guard chainedUpstreamEnabled,
                  case .chainedUpstream(let upstream) = latchedMode,
                  upstream.effectiveRoutingPolicy == .fullTunnel else {
                return .rejectStrictProfile(refusal: refusal)
            }
        }
        guard chainedUpstreamEnabled, !latchedMode.isChainedUpstream else {
            return .start
        }
        return .startDegraded(refusal: refusal)
    }
}
