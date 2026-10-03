import Foundation
import LavaSecKit

/// Describes observed chained connectivity without changing the tunnel's recovery policy.
public enum ChainedConnectivityPresentation {
    /// A localizable display key for the live lifecycle and sampled link/forwarding evidence.
    /// Nil prompt replies never reuse a prior session's handshake. Quiet traffic and a silent
    /// destination do not establish that the internet, or the entire VPN, is down.
    public static func summary(
        _ health: TunnelHealthSnapshot, handshake: ChainedHandshakeStatus?,
        isConnected: Bool, now: Date = Date()
    ) -> String {
        guard isConnected else { return "Not connected" }
        guard let handshake else { return "Status unavailable" }
        guard handshake.lifecycleIsActive else { return "Not connected" }
        guard handshake.isChained else { return "DNS-only" }
        guard handshake.hasHandshake else {
            return handshake.everHandshaked ? "Handshake expired" : "Connecting…"
        }
        // The app requests a throttled flush every 30 s; the provider may mirror at
        // up to 60 s. Beyond a full mirror plus flush interval it is historical data.
        // Future dates (clock changes) and a previous DNS-only sample are unknown too.
        let age = now.timeIntervalSince(health.updatedAt)
        guard health.isChainedUpstreamActive, age >= 0, age <= 90 else { return "Sample out of date" }
        let assessment = ConnectivityHealthSupervisor().assess(
            for: ConnectivityHealthInputs(isConnected: true, health: health,
                dataPath: DataPathObservation(
                    transmittedByteDelta: health.chainedDataPathTransmitWindowBytes,
                    receivedByteDelta: health.chainedDataPathReceiveWindowBytes,
                    hasHandshake: handshake.hasHandshake, everHandshaked: handshake.everHandshaked,
                    unansweredDestinationSeconds: health.chainedLongestUnansweredDestinationSeconds)),
            authority: DNSHealthAuthority(chainedIsLatched: true), now: now)
        if assessment.verdict(for: .linkPath).level != .healthy { return "Network unavailable" }
        switch assessment.verdict(for: .dataPath).reason {
        case DataPathHealth.destinationUnansweredReason: return "Some destinations unanswered"
        case DataPathHealth.upstreamQuietReason: return "Few replies observed"
        case nil: return "No issues observed"
        default: return "Status unavailable"
        }
    }
}
