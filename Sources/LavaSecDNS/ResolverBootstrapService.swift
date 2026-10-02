import Foundation
import LavaSecKit

// Bootstrap address resolution for encrypted resolvers whose endpoints carry
// no preset IPs (custom DoQ hostnames). The packet path may only consult the
// cache — the actual lookup (a blocking device-DNS exchange, injected by the
// tunnel) runs on the service's own utility queue, kicked by pre-warms at
// tunnel start, resolver switches, and network changes, or by a cold miss.
// Failed lookups are never cached so the next pre-warm retries.
/// Thread-safe, generation-aware cache for resolving encrypted-resolver hostnames away from the packet path.
public final class ResolverBootstrapService: @unchecked Sendable {
    /// Caller-classified address strings grouped by intended IP family; this value does not validate them.
    public struct ResolvedAddresses: Equatable, Sendable {
        /// Strings the injected resolver classified as IPv4 addresses.
        public let ipv4: [String]
        /// Strings the injected resolver classified as IPv6 addresses.
        public let ipv6: [String]

        package var isEmpty: Bool {
            ipv4.isEmpty && ipv6.isEmpty
        }

        /// Creates a family-partitioned result without performing additional lookup or validation.
        public init(ipv4: [String], ipv6: [String]) {
            self.ipv4 = ipv4
            self.ipv6 = ipv6
        }
    }

    /// Synchronous hostname lookup invoked on the queue supplied when constructing the service.
    ///
    /// `admittedAtEpoch` is the admission token of the session that KICKED the pre-warm —
    /// captured at the acceptance boundary and carried across this service's queue hop,
    /// never re-read on the far side. A lookup that runs after its kicking session ended
    /// must refuse rather than egress into whatever session is live by then (the resolver
    /// validates the token per wire attempt; PR #524).
    public typealias AddressResolver = @Sendable (_ hostname: String, _ admittedAtEpoch: UInt64) -> ResolvedAddresses

    private let resolveAddresses: AddressResolver
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var cachedAddressesByHostname: [String: ResolvedAddresses] = [:]
    /// The (cache generation, admission token) an in-flight lookup was kicked under.
    private struct InFlightKick: Equatable {
        var generation: UInt64
        var admittedAtEpoch: UInt64
    }
    // hostname → the kick its in-flight lookup runs under. A prewarm is suppressed
    // only while a lookup for the *current* generation AND the *same* session is
    // running: after invalidateAll() bumps the generation a fresh prewarm re-kicks,
    // and a prewarm from a NEW session supersedes an old session's lookup — which
    // correctly resolves nothing once its session ends, so suppressing the newer
    // kick would leave the cache empty until an unrelated cold miss (Codex P2,
    // PR #524). Either way the superseded lookup can no longer cache.
    private var inFlightKickByHostname: [String: InFlightKick] = [:]
    // Bumped by invalidateAll(). A lookup captures the generation when it starts
    // and only caches its result if the generation is unchanged on completion, so
    // a lookup kicked on a previous network (e.g. in flight across a sleep/network
    // change) can't repopulate the freshly-cleared cache with stale addresses.
    private var generation: UInt64 = 0

    /// Creates a cache whose potentially blocking resolver work is owned by the supplied queue.
    public init(
        resolveAddresses: @escaping AddressResolver,
        queue: DispatchQueue = DispatchQueue(label: "com.lavasec.tunnel.resolver.bootstrap", qos: .utility)
    ) {
        self.resolveAddresses = resolveAddresses
        self.queue = queue
    }

    /// Non-blocking; safe on the packet path.
    public func cachedAddresses(forHostname hostname: String) -> ResolvedAddresses? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return cachedAddressesByHostname[hostname]
    }

    /// Resolves asynchronously on the service queue unless the hostname is
    /// already cached or a lookup is already in flight.
    ///
    /// - Parameter admittedAtEpoch: the kicking session's admission token, threaded
    ///   verbatim to the resolver closure. See ``AddressResolver``.
    public func prewarm(hostname: String, admittedAtEpoch: UInt64) {
        lock.lock()
        guard cachedAddressesByHostname[hostname] == nil else {
            lock.unlock()
            return
        }
        // A same-generation in-flight lookup is superseded only by a STRICTLY NEWER
        // session's kick. Lifecycle generations are monotonic, so `>` orders sessions;
        // treating every unequal token as newer let an OLD session's straggling cold-miss
        // kick (fence passed, thread descheduled) displace the LIVE session's marker — the
        // live result was then dropped as unowned while the stale lookup resolved nothing,
        // and the cache stayed empty until an unrelated kick (Codex P2, PR #524). An
        // equal token is the ordinary duplicate and still deduplicates; a different cache
        // generation means invalidateAll() ran and any kick may proceed.
        if let inFlight = inFlightKickByHostname[hostname],
           inFlight.generation == generation,
           admittedAtEpoch <= inFlight.admittedAtEpoch {
            lock.unlock()
            return
        }
        let kickGeneration = generation
        let ownKick = InFlightKick(generation: kickGeneration, admittedAtEpoch: admittedAtEpoch)
        inFlightKickByHostname[hostname] = ownKick
        lock.unlock()

        queue.async { [weak self] in
            guard let self else {
                return
            }

            let addresses = self.resolveAddresses(hostname, admittedAtEpoch)

            self.lock.lock()
            // Only the lookup that still owns the in-flight marker clears it and may
            // cache. A lookup superseded by a later invalidateAll()/re-prewarm — or by
            // a newer session's kick for the same hostname — leaves the newer marker
            // intact and drops its own (previous-network or previous-session) result.
            if self.inFlightKickByHostname[hostname] == ownKick {
                self.inFlightKickByHostname[hostname] = nil
                if kickGeneration == self.generation, !addresses.isEmpty {
                    self.cachedAddressesByHostname[hostname] = addresses
                }
            }
            self.lock.unlock()
        }
    }

    /// Bootstrap addresses are network-dependent; network changes drop them
    /// all and callers pre-warm again. Bumping the generation also discards the
    /// result of any lookup already in flight so it can't repopulate the cache
    /// with addresses resolved on the previous network.
    public func invalidateAll() {
        lock.lock()
        cachedAddressesByHostname = [:]
        generation &+= 1
        lock.unlock()
    }
}
