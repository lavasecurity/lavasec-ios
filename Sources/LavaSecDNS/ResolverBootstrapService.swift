import Foundation
import LavaSecKit

// Bootstrap address resolution for encrypted resolvers whose endpoints carry
// no preset IPs (custom DoQ hostnames). The packet path may only consult the
// cache — the actual lookup (a blocking device-DNS exchange, injected by the
// tunnel) runs on the service's own utility queue, kicked by pre-warms at
// tunnel start, resolver switches, and network changes, or by a cold miss.
// Failed lookups are never cached so the next pre-warm retries.
public final class ResolverBootstrapService: @unchecked Sendable {
    public struct ResolvedAddresses: Equatable, Sendable {
        public let ipv4: [String]
        public let ipv6: [String]

        public var isEmpty: Bool {
            ipv4.isEmpty && ipv6.isEmpty
        }

        public init(ipv4: [String], ipv6: [String]) {
            self.ipv4 = ipv4
            self.ipv6 = ipv6
        }
    }

    public typealias AddressResolver = @Sendable (_ hostname: String) -> ResolvedAddresses

    private let resolveAddresses: AddressResolver
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var cachedAddressesByHostname: [String: ResolvedAddresses] = [:]
    // hostname → the generation its in-flight lookup was kicked at. A prewarm is
    // suppressed only while a lookup for the *current* generation is running, so
    // after invalidateAll() bumps the generation a fresh prewarm can re-kick even
    // if the superseded lookup is still finishing (it won't reuse the empty cache).
    private var inFlightGenerationByHostname: [String: UInt64] = [:]
    // Bumped by invalidateAll(). A lookup captures the generation when it starts
    // and only caches its result if the generation is unchanged on completion, so
    // a lookup kicked on a previous network (e.g. in flight across a sleep/network
    // change) can't repopulate the freshly-cleared cache with stale addresses.
    private var generation: UInt64 = 0

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
    public func prewarm(hostname: String) {
        lock.lock()
        guard cachedAddressesByHostname[hostname] == nil,
              inFlightGenerationByHostname[hostname] != generation
        else {
            lock.unlock()
            return
        }
        let kickGeneration = generation
        inFlightGenerationByHostname[hostname] = kickGeneration
        lock.unlock()

        queue.async { [weak self] in
            guard let self else {
                return
            }

            let addresses = self.resolveAddresses(hostname)

            self.lock.lock()
            // Only the lookup that still owns the in-flight marker for its
            // generation clears it and may cache. A lookup superseded by a later
            // invalidateAll()/re-prewarm leaves the newer marker intact and drops
            // its own (previous-network) result.
            if self.inFlightGenerationByHostname[hostname] == kickGeneration {
                self.inFlightGenerationByHostname[hostname] = nil
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
