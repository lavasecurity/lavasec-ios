import Foundation

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
    private var inFlightHostnames: Set<String> = []

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
              inFlightHostnames.insert(hostname).inserted
        else {
            lock.unlock()
            return
        }
        lock.unlock()

        queue.async { [weak self] in
            guard let self else {
                return
            }

            let addresses = self.resolveAddresses(hostname)

            self.lock.lock()
            self.inFlightHostnames.remove(hostname)
            if !addresses.isEmpty {
                self.cachedAddressesByHostname[hostname] = addresses
            }
            self.lock.unlock()
        }
    }

    /// Bootstrap addresses are network-dependent; network changes drop them
    /// all and callers pre-warm again.
    public func invalidateAll() {
        lock.lock()
        cachedAddressesByHostname = [:]
        lock.unlock()
    }
}
