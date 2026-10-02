import Foundation
@preconcurrency import Network
import LavaSecKit

/// Observes the effective address of the patch's IPv4 server on Wi-Fi and cellular.
/// No DNS question, website request or UDP payload is sent. An unsent UDP connection
/// asks Network.framework to evaluate the physical path, including NAT64 synthesis.
/// Whether iOS exposes every translated endpoint here remains a physical-device gate.
public final class DNSPatchRouteDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.lavasecurity.dns-patch-discovery")
    private let contract: DNSPatchContract
    private let update: @Sendable ([String]) -> Void
    private let initialCompletion: @Sendable (DNSPatchInitialDiscoveryPolicy.Completion) -> Void
    // All mutable state is queue-confined; cancel fences callbacks before clearing it.
    private var stopped = false
    private var monitors: [NWPathMonitor] = []
    private var connections: [Int: NWConnection] = [:]
    private var observations: [Int: String] = [:]
    private var initialPolicy = DNSPatchInitialDiscoveryPolicy()

    /// Starts bounded path evaluation for the two physical transports used by Assist.
    public init(contract: DNSPatchContract,
        initialCompletion: @escaping @Sendable (DNSPatchInitialDiscoveryPolicy.Completion) -> Void,
        update: @escaping @Sendable ([String]) -> Void) {
        self.contract = contract
        self.initialCompletion = initialCompletion
        self.update = update
        queue.async { [self] in start() }
    }

    /// Quiesces monitors and pending evaluations; late callbacks cannot publish new routes.
    public func cancel() {
        queue.async { [self] in
            let action = initialPolicy.cancel()
            stopMonitoring()
            publishInitialAction(action)
        }
    }

    private func start() {
        guard !stopped else { return }
        // One overall bound covers BOTH a silent first monitor and a pending
        // connection. Expiry is failure, never approval of an unknown NAT64 route.
        // pinned: DNSPatchRouteDiscoverySourceTests.testInitialDiscoveryHasOneDeadlineAndPublishesEndpointsBeforeSettlement
        queue.asyncAfter(deadline: .now() + DNSPatchInitialDiscoveryPolicy.timeoutSeconds) { [weak self] in
            guard let self, !self.stopped else { return }
            self.publishInitialAction(self.initialPolicy.deadlineDidExpire())
        }
        for (key, type) in [NWInterface.InterfaceType.wifi, .cellular].enumerated() {
            let monitor = NWPathMonitor(requiredInterfaceType: type)
            monitor.pathUpdateHandler = { [weak self] path in
                self?.evaluate(path, key: key, type: type)
            }
            monitors.append(monitor)
            monitor.start(queue: queue)
        }
    }

    private func evaluate(_ path: NWPath, key: Int, type: NWInterface.InterfaceType) {
        guard !stopped else { return }
        connections.removeValue(forKey: key)?.cancel()
        guard let initialInterface = DNSPatchInitialDiscoveryPolicy.Interface(rawValue: key) else { return }
        let initialAction = initialPolicy.pathObserved(initialInterface, isSatisfied: path.status == .satisfied)
        publishInitialAction(initialAction)
        let initialToken: UInt64?
        if case .evaluate(let token) = initialAction { initialToken = token } else { initialToken = nil }
        // Retain the last exact server route during a handoff; it claims no broad prefix.
        guard path.status == .satisfied else { return }
        guard let interface = path.availableInterfaces.first(where: { $0.type == type }),
              let literal = contract.serverAddresses.first(where: { IPv4Address($0) != nil }) else {
            if let initialToken {
                publishInitialAction(initialPolicy.evaluationCompleted(
                    initialInterface, token: initialToken, endpointIsAdmitted: false))
            }
            return
        }
        let parameters = NWParameters.udp
        parameters.requiredInterface = interface
        let connection = NWConnection(host: NWEndpoint.Host(literal), port: contract.serverURL == nil ? 853 : 443, using: parameters)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, !self.stopped, self.connections[key] === connection else { return }
            switch state {
            case .ready:
                var endpointIsAdmitted = false
                if let path = connection.currentPath, path.usesInterfaceType(type),
                   case .hostPort(let host, _) = path.remoteEndpoint {
                    let address: String?
                    switch host {
                    case .ipv4(let value): address = value.debugDescription
                    case .ipv6(let value): address = value.debugDescription
                    default: address = nil
                    }
                    if let address, self.contract.admitsObservedEndpoint(address) {
                        self.observations[key] = address
                        self.update(self.observations.keys.sorted().compactMap { self.observations[$0] })
                        endpointIsAdmitted = true
                    }
                }
                self.connections.removeValue(forKey: key)?.cancel()
                // FIFO callback delivery publishes the admitted destination BEFORE the
                // independent settlement signal, including unchanged/empty observations.
                // pinned: DNSPatchRouteDiscoverySourceTests.testInitialDiscoveryHasOneDeadlineAndPublishesEndpointsBeforeSettlement
                if let initialToken {
                    self.publishInitialAction(self.initialPolicy.evaluationCompleted(
                        initialInterface, token: initialToken, endpointIsAdmitted: endpointIsAdmitted))
                }
            case .failed, .cancelled:
                self.connections.removeValue(forKey: key)?.cancel()
                if let initialToken {
                    self.publishInitialAction(self.initialPolicy.evaluationCompleted(
                        initialInterface, token: initialToken, endpointIsAdmitted: false))
                }
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection, self.connections[key] === connection else { return }
            self.connections.removeValue(forKey: key)?.cancel()
            if let initialToken {
                self.publishInitialAction(self.initialPolicy.evaluationCompleted(
                    initialInterface, token: initialToken, endpointIsAdmitted: false))
            }
        }
    }

    private func publishInitialAction(_ action: DNSPatchInitialDiscoveryPolicy.Action) {
        guard case .complete(let completion) = action else { return }
        if case .failed = completion { stopMonitoring() }
        initialCompletion(completion)
    }

    private func stopMonitoring() {
        stopped = true
        monitors.forEach { $0.cancel() }
        monitors.removeAll()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        observations.removeAll()
    }
}
