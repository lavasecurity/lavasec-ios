@preconcurrency import ActivityKit
import Foundation
import Darwin
import Network
@preconcurrency import NetworkExtension
import Security
@preconcurrency import UserNotifications
import LavaSecChainedUpstream
import LavaSecDNS
import LavaSecFilterPipeline
import LavaSecKit

// The provider's `ChainedTunnelSeamHost` conformance — a protocol witness rather than one of
// the class's `// MARK:` concerns. See LavaSecTunnel/PacketTunnelProvider.swift for the class.
// MARK: - Chained tunnel seam host (S8.8b)

/// The provider's halves of the two chained seams. Internal, not private — witnesses for
/// a public protocol must be at least internal — and delegating straight to the members
/// the DNS-only path already uses, so the two paths cannot drift.
extension PacketTunnelProvider: ChainedTunnelSeamHost {
    /// Called ON the engine queue. `NEPacketTunnelFlow.writePackets` consumes the arrays
    /// synchronously, which is what makes the runner's buffer reuse safe (the seam doc);
    /// nothing here may retain them past the call.
    func writeDecryptedPackets(_ packets: [Data], protocols: [NSNumber]) {
        packetFlow.writePackets(packets, withProtocols: protocols)
    }

    /// Called OFF the engine queue, on the serving adapter's own serial queue — the third
    /// queue the seam doc requires. The blocking `dnsStateQueue.sync` hops inside
    /// `handleDNSRequest` are expected and safe from here, exactly as they are from
    /// `readPackets`' callback context, which this queue mimics. The family is recovered from
    /// the packet itself (the classifier routes both IPv4 and IPv6 DNS here since F3c), so the
    /// protocol number always matches the datagram the reply is built for.
    /// pinned: ChainedProviderConstructionSourceTests.testTheDNSSeamHostDelegatesToTheOneDNSPath
    func serveClientDNSQuery(_ packet: Data, lifecycleToken: UInt64) {
        // DROPPED, never answered — the same disposition the fence inside
        // `handleDNSRequest` now applies (PR #524; it used to write a SERVFAIL, which for
        // a retired lifecycle's query meant injecting a failure built from the OLD session
        // into the CURRENT packet flow — a reused client tuple and transaction ID can make
        // that stale reply fail a live query, Codex, PR #508). A query whose lifecycle is
        // gone has no correct answer; silence is the only one. This early-out skips the
        // parse for a batch already known stale; the fence re-checks because staleness can
        // land between here and there.
        guard isCurrentTunnelLifecycle(lifecycleToken) else {
            // The identical condition one call deeper IS traced (`stale-lifecycle-at-handler`),
            // and this early-out exists to skip the parse for a batch already known stale — so
            // without this, every chained-mode stale-lifecycle drop leaves no record at all
            // while the DNS-only path's does. The parse the early-out avoids is done HERE ONLY
            // under the QA gate, so a Release build keeps the zero-cost early-out and a QA
            // capture still gets the address family.
            #if DEBUG || LAVA_QA_TOOLS
            if let staleRequest = parseDNSDatagram(packet) {
                recordUnansweredDNSQuery(
                    reason: "stale-lifecycle-at-serve", query: staleRequest.dnsPayload)
            }
            #endif
            return
        }
        guard let request = parseDNSDatagram(packet) else {
            return
        }
        // The token FENCES the query: it identifies the runtime that enqueued it, and a
        // query still sitting on the serving queue when its lifecycle tore down must not
        // resolve against the NEXT lifecycle's configuration, mutate its DNS health state,
        // or write a stale answer into its packet flow (Codex, PR #508). The fence
        // parameter is non-optional since PR #524 — every caller names the session that
        // accepted the work, and this one's is the serving runtime's token.
        handleDNSRequest(
            request,
            protocolNumber: request is IPv6UDPDNSPacket ? Int(AF_INET6) : Int(AF_INET),
            allowsTransientBootstrapDeferral: true,
            expectedLifecycleGeneration: lifecycleToken
        )
    }
}
