import Darwin
import Foundation
import LavaSecKit

/// Two destination-selected sessions behind the existing outage-driver seam. The
/// first full profile also carries the second session's UDP transport; a split
/// first profile owns an independent socket. All mutation is on the engine queue.
// pinned: ChainedStackTransportTests.testFullThenSplitCarriesSplitInsideFullAndPublicTrafficThroughFull
final class ChainedStackSessionSource: ChainedSessionSource, @unchecked Sendable {
    let configuration: ChainedUpstreamConfiguration
    let credentials: [@Sendable () throws -> ChainedSessionCredentials]
    let writer: ChainedTunnelWriter
    let dnsServer: ChainedDNSServing
    let mtu: Int
    let interface: @Sendable () -> ChainedBindableInterface?
    let livePath: ChainedPrimedLivePath
    let ports: ChainedResolverPortRegistry
    let claimed: ChainedClaimedResolverDestinationsStore
    let channel: (@Sendable (ChainedEndpointAddress, ChainedBindableInterface) -> ChainedUpstreamDatagramChannel?)?
    let telemetry: (@Sendable (Int, ChainedChannelTransportEvent) -> Void)?
    let diagnostics: (@Sendable (ChainedDataPathPressureEvent) -> Void)?
    private var factories: [ChainedUpstreamSessionFactory] = []

    init(configuration: ChainedUpstreamConfiguration, credentials: [@Sendable () throws -> ChainedSessionCredentials],
         writer: ChainedTunnelWriter, dnsServer: ChainedDNSServing, mtu: Int,
         interface: @escaping @Sendable () -> ChainedBindableInterface?, livePath: ChainedPrimedLivePath,
         ports: ChainedResolverPortRegistry, claimed: ChainedClaimedResolverDestinationsStore,
         channel: (@Sendable (ChainedEndpointAddress, ChainedBindableInterface) -> ChainedUpstreamDatagramChannel?)?,
         telemetry: (@Sendable (Int, ChainedChannelTransportEvent) -> Void)?, diagnostics: (@Sendable (ChainedDataPathPressureEvent) -> Void)?) {
        self.configuration = configuration; self.credentials = credentials; self.writer = writer
        self.dnsServer = dnsServer; self.mtu = mtu; self.interface = interface; self.livePath = livePath
        self.ports = ports; self.claimed = claimed; self.channel = channel; self.telemetry = telemetry; self.diagnostics = diagnostics
    }
    func makeChannel(engineQueue: ChainedEngineQueue) throws -> ChainedUpstreamDatagramChannel {
        guard factories.count == 2 else { throw ChainedSessionBuildFailure.noEligibleInterface }
        let first = try factories[0].makeChannel(engineQueue: engineQueue)
        do {
            let second = configuration.usesNestedTransport ? nil : try factories[1].makeChannel(engineQueue: engineQueue)
            return ChainedStackChannels(first: first, second: second)
        } catch { first.close(); throw error }
    }
    func makeSession(engineQueue: ChainedEngineQueue, events: ChainedSessionEvents) throws -> ChainedSessionDriving {
        let profiles = try configuration.orderedHops.map { try $0.withoutEntryHop() }
        guard profiles.count == 2, credentials.count == 2 else { throw WireGuardChainFailure.changed }
        let bridge = ChainedStackEvents(downstream: events)
        let relay = configuration.usesNestedTransport ? try ChainedStackRelay(first: profiles[0], second: profiles[1], queue: engineQueue) : nil
        var runners: [ChainedSessionDriving] = [], built: [ChainedUpstreamSessionFactory] = []
        var translations: [ChainedStackAddressTranslation] = []
        do {
            for index in 0..<2 {
                let profile = profiles[index]
                guard let endpoint = ChainedEndpointAddress(literal: profile.endpointHost, port: profile.endpointPort),
                      let translation = ChainedStackAddressTranslation(local: configuration.clientAddress, remote: profile.clientAddress) else {
                    throw ChainedSessionBuildFailure.unparsableEndpoint
                }
                translations.append(translation)
                let mappedWriter = ChainedStackWriter(translation: translation, downstream: writer, configuration: configuration, index: index)
                let mappedDNS = ChainedStackDNS(translation: translation, downstream: dnsServer)
                let makeChannel: (@Sendable (ChainedEndpointAddress, ChainedBindableInterface) -> ChainedUpstreamDatagramChannel?)?
                if index == 1, let relay { makeChannel = { _, _ in relay } } else { makeChannel = channel }
                let configuration = self.configuration
                let intercept: (@Sendable (Data) -> Bool)? = { packet in
                    if index == 0, let relay, relay.consume(packet) { return true }
                    guard let source = translation.inboundRouteAddress(packet) else { return true }
                    return configuration.routeIndex(forIPv4: source) != index || translation.inbound(packet) == nil
                }
                let factory = ChainedUpstreamSessionFactory(readCredentials: credentials[index],
                    allowedIPs: ChainedAllowedIPs(profile.allowedIPs.compactMap(ChainedIPPrefix.init)),
                    resolverSourceAddresses: ChainedAllowedIPs(configuration.containsFullTunnel ? configuration.stackDNSAddresses.compactMap(ChainedIPPrefix.init) : []),
                    writer: mappedWriter, dnsServer: mappedDNS, mtu: mtu,
                    currentInterface: interface, currentEndpoint: { endpoint }, livePath: livePath, ownResolverPorts: ports,
                    dropsUnfilterableEncryptedDNS: configuration.containsFullTunnel, claimedResolverDestinations: claimed,
                    makeChannel: makeChannel, transportTelemetry: telemetry, dataPathDiagnostics: diagnostics, interceptInbound: intercept)
                let runner = try factory.makeSession(engineQueue: engineQueue, events: bridge)
                built.append(factory); runners.append(runner)
                if index == 0 { relay?.first = runner as? ChainedSessionRunner }
            }
            guard runners[0].acceptedUpstreamGeneration == runners[1].acceptedUpstreamGeneration else {
                throw ChainedSessionCredentialRefusal.configurationRotated
            }
            let stack = ChainedStackSession(configuration: configuration, runners: runners, translations: translations, queue: engineQueue, events: bridge)
            bridge.owner = stack; factories = built
            return stack
        } catch { runners.forEach { $0.shutdown() }; relay?.close(); throw error }
    }
}

private final class ChainedStackEvents: ChainedSessionEvents, @unchecked Sendable {
    let downstream: ChainedSessionEvents
    weak var owner: ChainedStackSession?
    var ended = false
    init(downstream: ChainedSessionEvents) { self.downstream = downstream }
    func sessionEnded(_ cause: ChainedSessionEndCause) {
        guard !ended else { return }; ended = true
        owner?.shutdown(); downstream.sessionEnded(cause)
    }
}

private final class ChainedStackDNS: ChainedDNSServing, @unchecked Sendable {
    let translation: ChainedStackAddressTranslation
    let downstream: ChainedDNSServing
    init(translation: ChainedStackAddressTranslation, downstream: ChainedDNSServing) { self.translation = translation; self.downstream = downstream }
    func serveDNS(_ packet: Data) { if packet.first.map({ $0 >> 4 == 6 }) == true { downstream.serveDNS(packet); return }; if let restored = translation.interceptedDNS(packet) { downstream.serveDNS(restored) } }
}

private final class ChainedStackWriter: ChainedTunnelWriter, @unchecked Sendable {
    let translation: ChainedStackAddressTranslation
    let downstream: ChainedTunnelWriter
    let configuration: ChainedUpstreamConfiguration
    let index: Int
    init(translation: ChainedStackAddressTranslation, downstream: ChainedTunnelWriter, configuration: ChainedUpstreamConfiguration, index: Int) {
        self.translation = translation; self.downstream = downstream; self.configuration = configuration; self.index = index
    }
    func write(_ packets: [Data], protocols: [NSNumber]) {
        for packet in packets {
            guard let source = translation.inboundRouteAddress(packet) else { continue }
            // A full peer must not inject replies owned by the other profile.
            guard configuration.routeIndex(forIPv4: source) == index, let restored = translation.inbound(packet) else { continue }
            downstream.write([restored], protocols: [NSNumber(value: AF_INET)])
        }
    }
}

/// Connected nested UDP transport sharing the first runner's engine and socket.
/// Replies are intercepted before they can count as general forwarding evidence.
private final class ChainedStackRelay: ChainedUpstreamDatagramChannel, @unchecked Sendable {
    weak var first: ChainedSessionRunner?
    let envelope: ChainedHopPacket
    let queue: ChainedEngineQueue
    var handler: (@Sendable (UnsafeRawBufferPointer) -> Void)?
    var closed = false
    init(first: ChainedUpstreamConfiguration, second: ChainedUpstreamConfiguration, queue: ChainedEngineQueue) throws {
        guard let envelope = ChainedHopPacket(source: first.clientAddress, destination: second.endpointHost,
            sourcePort: UInt16.random(in: 49152...65535), destinationPort: second.endpointPort) else { throw ChainedSessionBuildFailure.unparsableEndpoint }
        self.envelope = envelope; self.queue = queue
    }
    func send(_ datagram: UnsafeRawBufferPointer, completion: @escaping @Sendable (Bool) -> Void) {
        queue.run {
            guard !closed, let packet = envelope.wrap(datagram), let first else { completion(false); return }
            completion(first.sendTransportPacket(packet))
        }
    }
    func setReceiveHandler(_ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) { queue.run { self.handler = handler } }
    func close() { queue.run { closed = true; handler = nil; first = nil } }
    func consume(_ packet: Data) -> Bool {
        queue.run {
            guard !closed else { return false }
            guard let payload = packet.withUnsafeBytes({ envelope.unwrap($0).map { Data($0) } }) else { return false }
            payload.withUnsafeBytes { handler?($0) }; return true
        }
    }
}

private final class ChainedStackChannels: ChainedUpstreamDatagramChannel, @unchecked Sendable {
    let first: ChainedUpstreamDatagramChannel
    let second: ChainedUpstreamDatagramChannel?
    init(first: ChainedUpstreamDatagramChannel, second: ChainedUpstreamDatagramChannel?) { self.first = first; self.second = second }
    func send(_ datagram: UnsafeRawBufferPointer, completion: @escaping @Sendable (Bool) -> Void) { completion(false) }
    func setReceiveHandler(_ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) {}
    func close() { first.close(); second?.close() }
}

private final class ChainedStackSession: ChainedSessionDriving, @unchecked Sendable {
    let configuration: ChainedUpstreamConfiguration
    let runners: [ChainedSessionDriving]
    let translations: [ChainedStackAddressTranslation]
    let queue: ChainedEngineQueue
    let events: ChainedStackEvents
    var authPending = [false, false], dataPending = [false, false]
    var stopped = false
    private var nestedForwardingBaseline: UInt64 = 0
    var acceptedUpstreamGeneration: UInt64 { runners[0].acceptedUpstreamGeneration }
    init(configuration: ChainedUpstreamConfiguration, runners: [ChainedSessionDriving], translations: [ChainedStackAddressTranslation], queue: ChainedEngineQueue, events: ChainedStackEvents) {
        self.configuration = configuration; self.runners = runners; self.translations = translations; self.queue = queue; self.events = events
    }
    func adoptChannel(_ channel: ChainedUpstreamDatagramChannel) -> ChainedRebindOutcome {
        queue.run {
            guard !stopped, let pair = channel as? ChainedStackChannels else { channel.close(); return .refused }
            // The inner engine survives, but bytes from its retired outer transport
            // cannot certify the replacement. Capture before adoption can deliver new replies.
            // pinned: ChainedStackTransportTests.testTwoFullProfilesStillUseSuccessiveHops
            if pair.second == nil {
                nestedForwardingBaseline = runners[1].sampleStatistics()?.forwardedNonDNSByteCount ?? 0
                _ = runners[1].takeLivenessSample()
            }
            let first = runners[0].adoptChannel(pair.first)
            let second = pair.second.map { runners[1].adoptChannel($0) } ?? .rebound
            authPending = [false, false]; dataPending = [false, false]
            return first == .rebound && second == .rebound ? .rebound : .noCurrentSession
        }
    }
    func handleOutboundBatch(_ packets: [Data], protocols: [NSNumber]) {
        // Deliver a complete partition to each selected runner: its admission and
        // parked cursor own back-pressure. Batch length alone must not drop all traffic.
        // pinned: ChainedStackTransportTests.testSplitThenFullUsesIndependentDestinationSelectedTunnels
        guard packets.count == protocols.count else { return }
        var batches = [[Data](), [Data]()], families = [[NSNumber](), [NSNumber]()]
        for (packet, proto) in zip(packets, protocols) {
            if proto.int32Value != AF_INET { batches[0].append(packet); families[0].append(proto); continue }
            guard let destination = packet.withUnsafeBytes({ ChainedOutboundPacketClassifier.ipv4Destination(of: $0) }) else { continue }
            // DNS capture-floor traffic still reaches filtering even outside split routes.
            let selected = configuration.routeIndex(forIPv4: destination)
            if selected == nil {
                let header = Int(packet[0] & 15) * 4
                guard packet.count >= header + 8, packet[9] == 17,
                      packet[header+2] == 0, packet[header+3] == 53 else { continue }
            }
            let index = selected ?? 0
            guard let mapped = translations[index].outbound(packet) else { continue }
            batches[index].append(mapped); families[index].append(proto)
        }
        for index in 0..<2 where !batches[index].isEmpty { runners[index].handleOutboundBatch(batches[index], protocols: families[index]) }
    }
    func sendResolverPacket(_ packet: Data, deadline: MonotonicDeadline) -> Bool {
        guard let destination = packet.withUnsafeBytes({ ChainedOutboundPacketClassifier.ipv4Destination(of: $0) }),
              let index = configuration.routeIndex(forIPv4: destination), let mapped = translations[index].outbound(packet) else { return false }
        return runners[index].sendResolverPacket(mapped, deadline: deadline)
    }
    func tick() { queue.run { if !stopped { runners.forEach { $0.tick() } } } }
    func forceHandshake() { queue.run { if !stopped { runners.forEach { $0.forceHandshake() } } } }
    func shutdown() { queue.run { guard !stopped else { return }; stopped = true; runners.reversed().forEach { $0.shutdown() } } }
    // A healthy branch cannot certify pending demand on the other branch.
    // pinned: ChainedStackTransportTests.testFullThenSplitCarriesSplitInsideFullAndPublicTrafficThroughFull
    func takeLivenessSample() -> ChainedLivenessSample {
        queue.run {
            let samples = runners.map { $0.takeLivenessSample() }
            for i in 0..<2 {
                if samples[i].sawObligingSend { authPending[i] = true }
                if samples[i].sawObligingNonDNSSend { dataPending[i] = true }
                if samples[i].sawAuthenticatedPeerDatagram { authPending[i] = false }
                if samples[i].sawInboundData { dataPending[i] = false }
            }
            return ChainedLivenessSample(
                sawAuthenticatedPeerDatagram: !authPending.contains(true) && samples.contains { $0.sawAuthenticatedPeerDatagram },
                sawInboundData: !dataPending.contains(true) && samples.contains { $0.sawInboundData },
                sawObligingSend: samples.contains { $0.sawObligingSend },
                sawObligingNonDNSSend: samples.contains { $0.sawObligingNonDNSSend },
                sendChannelSaturated: samples.contains { $0.sendChannelSaturated })
        }
    }
    func sampleStatistics() -> ChainedRunnerStatistics? {
        queue.run {
            guard !stopped, let a = runners[0].sampleStatistics(), let b = runners[1].sampleStatistics() else { return nil }
            return ChainedRunnerStatistics(transmittedByteCount: a.transmittedByteCount &+ b.transmittedByteCount,
                receivedByteCount: a.receivedByteCount &+ b.receivedByteCount, hasHandshake: a.hasHandshake && b.hasHandshake,
                forwardedNonDNSByteCount: a.forwardedNonDNSByteCount &+ (b.forwardedNonDNSByteCount >= nestedForwardingBaseline ? b.forwardedNonDNSByteCount - nestedForwardingBaseline : 0),
                transportGeneration: max(a.transportGeneration, b.transportGeneration))
        }
    }
    func snapshotCounters() -> ChainedRunnerCounters {
        queue.run {
            var total = ChainedRunnerCounters()
            for runner in runners { total.addStackCounters(runner.snapshotCounters()) }
            return total
        }
    }
}
