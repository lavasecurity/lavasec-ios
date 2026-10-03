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

// The support types the provider's single file declared at file scope, not one of its
// `// MARK:` concerns. See LavaSecTunnel/PacketTunnelProvider.swift for the class itself.
// MARK: - Private DNS wire, socket & factory types

// Provider-local alias for the runtime plan owned by LavaSecDNS.
typealias ResolverRuntimeConfiguration = DNSResolverRuntimePlan

// The pure DNS wire/socket tail types (IPv4UDPDNSPacket, resolver endpoints,
// UDP/TCP socket resolvers, DNSMessageTraits, bootstrap wire helpers) moved to
// LavaSecDNS in Phase E1 — now public API with executable tests instead of
// source pins. See Sources/LavaSecDNS/.

final class SendableCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ error: Error?) {
        handler(error)
    }
}

/// `SettleWorkScheduling` backed by a one-shot `DispatchSourceTimer` on the
/// tunnel's `dnsStateQueue`, mirroring the existing `protectionPauseResumeTimer`
/// idiom. Used by the resolver-probe coalescer (plan item 430).
final class DispatchSettleWorkScheduler: SettleWorkScheduling {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func schedule(after interval: TimeInterval, _ work: @escaping () -> Void) -> SettleWorkToken {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler {
            work()
        }
        timer.resume()
        return DispatchSettleWorkToken(timer: timer)
    }
}

private final class DispatchSettleWorkToken: SettleWorkToken {
    private let timer: DispatchSourceTimer
    private var isCancelled = false

    init(timer: DispatchSourceTimer) {
        self.timer = timer
    }

    func cancel() {
        guard !isCancelled else {
            return
        }
        isCancelled = true
        timer.cancel()
    }
}
