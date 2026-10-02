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

// The chained runtime types the provider's single file declared at file scope, not one of its
// `// MARK:` concerns. See LavaSecTunnel/PacketTunnelProvider.swift for the class itself.
// MARK: - Chained runtime types (S8.8b)

/// One lifecycle's chained runtime, held together so the teardown funnel can retire and
/// release it as a unit. Deliberately minimal: the driver owns the factory (its session
/// source) and the factory owns the seam adapters, so this holds only what the provider
/// itself must reach — the driver to drive, the engine queue to hop path events onto, the
/// stash the path handler feeds, and the DNS adapter whose drop tally teardown reports.
final class ChainedTunnelRuntime: @unchecked Sendable {
    let engineQueue: ChainedEngineQueue
    let driver: ChainedOutageDriver
    let dnsServingAdapter: ChainedDNSServingAdapter
    let interfaceStash: ChainedEligibleInterfaceStash
    /// The transport/pressure telemetry aggregator the factory's sinks feed — held here so
    /// the 60 s liveness line can difference its tallies (brief-stall observability).
    let transportDiagnostics: ChainedTransportDiagnosticsRecorder
    let directDNS: TunnelUDPResolver?

    init(
        engineQueue: ChainedEngineQueue,
        driver: ChainedOutageDriver,
        dnsServingAdapter: ChainedDNSServingAdapter,
        interfaceStash: ChainedEligibleInterfaceStash,
        transportDiagnostics: ChainedTransportDiagnosticsRecorder,
        directDNS: TunnelUDPResolver? = nil
    ) {
        self.engineQueue = engineQueue
        self.driver = driver
        self.dnsServingAdapter = dnsServingAdapter
        self.interfaceStash = interfaceStash
        self.transportDiagnostics = transportDiagnostics
        self.directDNS = directDNS
    }
}

/// Intercepts direct resolver replies before they reach the kernel; other packets keep the
/// existing weak-host writer. This object belongs to one provider runtime, never a later start.
final class ChainedDNSReplyWriter: ChainedTunnelWriter, @unchecked Sendable {
    private let resolver: TunnelUDPResolver
    private let downstream: ChainedTunnelWriter
    init(resolver: TunnelUDPResolver, downstream: ChainedTunnelWriter) {
        self.resolver = resolver
        self.downstream = downstream
    }
    func write(_ packets: [Data], protocols: [NSNumber]) {
        for (packet, family) in zip(packets, protocols) where !resolver.consumeReply(packet) {
            downstream.write([packet], protocols: [family])
        }
    }
}

/// The tick wiring's weak seam: the timers' repeating source retains its handler for its
/// own lifetime, so the handler reaches the driver through this box or the engine stays
/// resident past retirement.
final class ChainedWeakDriverBox: @unchecked Sendable {
    weak var driver: ChainedOutageDriver?
}

/// The surrender persist could not even reach the store — thrown so
/// `ChainedSurrenderRecovery` restarts anyway and the log says why the suppression is
/// missing.
struct ChainedSurrenderPersistUnavailable: Error {}

/// The explicit retry handoff reached the tunnel, but this target could not resolve the
/// shared eligibility store. Failing the start closed preserves the request for a later retry.
struct ChainedExplicitRetryUnavailable: Error {}

/// A newer explicit retry advanced the marker revision while this start was resetting the
/// chained suppression. This provider is retired before it ever latched a data path, so it
/// fails closed rather than adopting the revision the newer attempt owns.
struct ChainedExplicitRetrySuperseded: Error {}
