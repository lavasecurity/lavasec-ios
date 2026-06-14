import Foundation

// In-flight DNS query coalescing, extracted from PacketTunnelProvider: the
// first waiter for a cache key starts exactly one upstream resolution and
// every duplicate joins it, so a burst of identical questions costs one wire
// exchange. Generic over the waiter payload — the tunnel keeps its own
// per-request state (packet, protocol, TTL caps) out of core. NOT internally
// synchronized — access is confined to the caller's DNS state queue, matching
// the dictionary this replaces.

public final class InFlightDNSQueryCoalescer<Waiter> {
    public enum EnqueueOutcome: Equatable {
        /// First waiter for this key — the caller must start the resolution.
        case startedResolution
        /// A resolution is already in flight — the waiter rides along.
        case joinedExistingResolution
    }

    private var waitersByKey: [DNSCacheKey: [Waiter]] = [:]

    public init() {}

    public var inFlightKeyCount: Int {
        waitersByKey.count
    }

    public func enqueue(_ waiter: Waiter, for key: DNSCacheKey) -> EnqueueOutcome {
        if waitersByKey[key] != nil {
            waitersByKey[key]?.append(waiter)
            return .joinedExistingResolution
        }

        waitersByKey[key] = [waiter]
        return .startedResolution
    }

    /// Removes and returns the waiters for one completed resolution — exactly
    /// one drain per started key, in enqueue order.
    public func drain(_ key: DNSCacheKey) -> [Waiter] {
        waitersByKey.removeValue(forKey: key) ?? []
    }

    /// Removes and returns ALL waiters (runtime resets answer them with
    /// SERVFAIL so nothing hangs across a resolver identity change).
    public func drainAll() -> [Waiter] {
        let waiters = Array(waitersByKey.values.joined())
        waitersByKey = [:]
        return waiters
    }
}
