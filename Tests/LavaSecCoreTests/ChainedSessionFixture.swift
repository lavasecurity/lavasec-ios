import CryptoKit
import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// The shared fixture for everything that drives a real engine outside a Network Extension.
///
/// Extracted from `ChainedSessionRunnerTests` when the outage driver needed the same two real
/// `WireGuardSession`s and the same looping channel. Nothing here is a mock of the crypto: the
/// packets are really encrypted, really decrypted, and really checked against AllowedIPs.

/// Collects what a runner reports about its own death.
final class RecordingSessionEvents: ChainedSessionEvents, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ChainedSessionEndCause] = []
    var ends: [ChainedSessionEndCause] { lock.withLock { storage } }

    /// What the owner does from INSIDE the callback. The driver retires the runner and builds a
    /// replacement here, so a test that wants to exercise that ordering installs it.
    var onEnd: (@Sendable (ChainedSessionEndCause) -> Void)?

    func sessionEnded(_ cause: ChainedSessionEndCause) {
        lock.withLock { storage.append(cause) }
        onEnd?(cause)
    }
}


/// A stand-in for the engine's clock that only moves when a test moves it.
///
/// Nanoseconds, matching `ChainedSessionRunner.engineClockNanoseconds()`. Starts at a large
/// non-zero value so a test cannot accidentally pass because the runner's seed and this clock's
/// origin both happened to be zero — the guard subtracts, and zero minus zero is "fresh" for the
/// wrong reason.
final class SteppableEngineClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 1_000_000_000_000

    var read: @Sendable () -> UInt64 {
        { [self] in lock.withLock { nanoseconds } }
    }

    func advance(by amount: UInt64) {
        lock.withLock { nanoseconds &+= amount }
    }
}

final class ChainedSessionHarness {
    let runner: ChainedSessionRunner
    /// Exposed so a test can claim a port and watch the carve-out reach the runner.
    let ownResolverPorts: ChainedResolverPortRegistry
    let channel = FakeChannel()
    let writer = FakeWriter()
    /// Every packet the classifier judged to be a client DNS query.
    let dnsServer = RecordingDNSServer()
    let session: WireGuardSession
    let peerSession: WireGuardSession
    private var scratch = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)

    /// The queue every runner in this fixture shares, like the driver's.
    let engineQueue: ChainedEngineQueue
    /// What the runner reported about its own death.
    let events = RecordingSessionEvents()

    /// The key material this harness used, so a test can build a SECOND harness that is the
    /// same peer relationship with a fresh engine — which is what the driver does on every
    /// retry attempt, and the only way to exercise anything that resets with the session.
    let keys: (local: (privateKey: [UInt8], publicKey: [UInt8]), peer: (privateKey: [UInt8], publicKey: [UInt8]))

    init(
        allowedIPs list: String = "0.0.0.0/0",
        /// The tunnel's upstream DNS resolver(s), comma-separated. A delivered packet from one of
        /// these is DNS, not general forwarding, so its bytes are excluded from the runner's
        /// `forwardedNonDNSByteCount`. `nil` = none excluded (the pre-tighten behaviour).
        resolverSourceAddresses resolverList: String? = nil,
        engineQueue: ChainedEngineQueue? = nil,
        ownResolverPorts: ChainedResolverPortRegistry? = nil,
        dropsUnfilterableEncryptedDNS: Bool = false,
        claimedResolverDestinations: ChainedClaimedResolverDestinationsStore = ChainedClaimedResolverDestinationsStore(),
        reusing existingKeys: (
            local: (privateKey: [UInt8], publicKey: [UInt8]),
            peer: (privateKey: [UInt8], publicKey: [UInt8])
        )? = nil,
        /// Lets a test stall the engine's timer clock without sleeping for a real second.
        /// `nil` takes the runner's default, which reads the clock boringtun itself reads.
        engineClock: (@Sendable () -> UInt64)? = nil,
        /// Persistent keepalive on the LOCAL session, in the engine's own seconds. Production
        /// leaves this off; a test sets `1` when it needs a timer pass to EMIT something on
        /// demand — the only deterministic way to make `update_timers` produce a datagram
        /// inside a unit test, since the engine's timers run on its own real clock.
        keepaliveSeconds: UInt16 = 0,
        /// The clock the destination-reachability windows are measured on. `nil` takes the
        /// runner's default (a private `ChainedUptimeClock`); a test that needs a wait to reach
        /// the threshold without sleeping for twenty-one real seconds passes a `SetTestClock`.
        reachabilityClock: ChainedMonotonicClock? = nil,
        /// Where the runner's pressure events go; nil (production's default) installs none.
        diagnostics: (@Sendable (ChainedDataPathPressureEvent) -> Void)? = nil
    ) throws {
        self.engineQueue = engineQueue ?? ChainedEngineQueue(label: "com.lavasec.test.engine")
        self.ownResolverPorts = ownResolverPorts
            ?? ChainedResolverPortRegistry(
                uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds })
        let a = existingKeys?.local ?? Self.keyPair()
        let b = existingKeys?.peer ?? Self.keyPair()
        self.keys = (local: a, peer: b)
        session = try WireGuardSession(
            privateKey: a.privateKey, peerPublicKey: b.publicKey,
            keepaliveSeconds: keepaliveSeconds, index: 1)
        peerSession = try WireGuardSession(privateKey: b.privateKey, peerPublicKey: a.publicKey, index: 2)
        runner = ChainedSessionRunner(
            session: session,
            peer: WireGuardPeerAddress(octets: [203, 0, 113, 9])!,
            allowedIPs: ChainedAllowedIPs(list: list)!,
            resolverSourceAddresses: resolverList.flatMap { ChainedAllowedIPs(list: $0) } ?? ChainedAllowedIPs([]),
            channel: channel,
            writer: writer,
            dnsServer: dnsServer,
            queueLimits: ChainedPacketQueueLimits.forChainedTunnel(mtu: 1280),
            engineQueue: self.engineQueue,
            events: events,
            ownResolverPorts: self.ownResolverPorts,
            dropsUnfilterableEncryptedDNS: dropsUnfilterableEncryptedDNS,
            claimedResolverDestinations: claimedResolverDestinations,
            engineClock: engineClock ?? ChainedSessionRunner.engineClockNanoseconds,
            reachabilityClock: reachabilityClock ?? ChainedUptimeClock(),
            diagnostics: diagnostics)!
    }

    /// Drives the handshake to completion through the two real sessions.
    func completeHandshake() throws {
        let initiation = try session.forceHandshake(into: &scratch)
        var response = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let responded = try peerSession.decapsulate(
            Array(scratch[..<initiation.byteCount]), from: .unknown, into: &response)
        var keepalive = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let completed = try session.decapsulate(
            Array(response[..<responded.byteCount]), from: .unknown, into: &keepalive)
        var sink = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        _ = try peerSession.decapsulate(
            Array(keepalive[..<completed.byteCount]), from: .unknown, into: &sink)
        settle()
    }

    /// Completes the handshake the way the runtime will, THROUGH the runner.
    ///
    /// `completeHandshake()` drives the two sessions directly, which is right when the
    /// handshake is setup rather than subject. This one requires the runner to have already
    /// emitted an initiation, feeds the peer's answer back in on the receive path, and so
    /// exercises the moment the engine's queue becomes releasable — the only path that
    /// reaches the drain with a full queue.
    func completeHandshakeThroughTheChannel() throws {
        guard let initiation = channel.sent.first else {
            XCTFail("the runner has not sent a handshake initiation yet")
            return
        }
        var response = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let responded = try peerSession.decapsulate(initiation, from: .unknown, into: &response)
        response.withUnsafeBytes { whole in
            channel.deliver(UnsafeRawBufferPointer(rebasing: whole[..<responded.byteCount]))
        }
        settle()
    }

    /// The peer's encrypted datagram for one inner packet, WITHOUT delivering it.
    ///
    /// Separated from `peerSendsInnerPacket` so a test can decide when — or whether — the
    /// runner sees it, which is what the shutdown latch is about.
    func peerEncapsulated(source: [UInt8]) throws -> [UInt8] {
        try completeHandshake()
        let inner = Self.ipv4Packet(byteCount: 120, source: source)
        var wire = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let sent = try peerSession.encapsulate(inner, into: &wire)
        guard case .writeToNetwork(let byteCount) = sent else {
            XCTFail("the peer did not produce a datagram")
            return []
        }
        return Array(wire[..<byteCount])
    }

    /// Has the peer encrypt an inner packet and hands it to the runner's receive path.
    /// Has the peer encrypt an arbitrary inner packet and hands it to the receive path — for the
    /// cases where the packet's TRANSPORT shape, not just its source address, is the subject.
    func peerSendsInnerPacket(_ inner: [UInt8]) throws {
        try completeHandshake()
        var wire = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let sent = try peerSession.encapsulate(inner, into: &wire)
        guard case .writeToNetwork(let byteCount) = sent else {
            XCTFail("the peer did not produce a datagram")
            return
        }
        wire.withUnsafeBytes { whole in
            channel.deliver(UnsafeRawBufferPointer(rebasing: whole[..<byteCount]))
        }
        settle()
    }

    func peerSendsInnerPacket(source: [UInt8]) throws {
        try completeHandshake()
        let inner = Self.ipv4Packet(byteCount: 120, source: source)
        var wire = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let sent = try peerSession.encapsulate(inner, into: &wire)
        guard case .writeToNetwork(let byteCount) = sent else {
            XCTFail("the peer did not produce a datagram")
            return
        }
        wire.withUnsafeBytes { whole in
            channel.deliver(UnsafeRawBufferPointer(rebasing: whole[..<byteCount]))
        }
        settle()
    }

    /// Has the peer encrypt an inner packet and hands it to the runner's receive path,
    /// WITHOUT driving the handshake — for tests that deliver repeatedly after completing
    /// it once. ``peerSendsInnerPacket(source:)`` re-runs the handshake per call, which is
    /// right for a single delivery and wrong for a sequence.
    func deliverInnerPacketFromPeer(source: [UInt8]) throws {
        try deliverRawInnerPacketFromPeer(Self.ipv4Packet(byteCount: 120, source: source))
    }

    /// The same delivery for a caller-built inner packet, so a test can send a real DNS
    /// ANSWER rather than the generic filler (S6). Kept separate from the `source:` form
    /// because that one's whole job is exercising the AllowedIPs verdict on an arbitrary
    /// source, and a builder argument would have made every existing call site restate the
    /// packet it did not care about.
    func deliverRawInnerPacketFromPeer(_ inner: [UInt8]) throws {
        var wire = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let sent = try peerSession.encapsulate(inner, into: &wire)
        guard case .writeToNetwork(let byteCount) = sent else {
            XCTFail("the peer did not produce a datagram")
            return
        }
        wire.withUnsafeBytes { whole in
            channel.deliver(UnsafeRawBufferPointer(rebasing: whole[..<byteCount]))
        }
        settle()
    }

    /// Submits `count` one-packet batches with a queue barrier every eighth, so a flood
    /// exercises the pressure it is aimed at — withheld completions filling the QUEUE —
    /// rather than the dispatch backlog, which the boundary refuses past its ceiling
    /// (``ChainedAdmissionGauge``). An unpaced tight loop from the test thread IS the
    /// producer-overrun that boundary exists to shed, and several of these tests predate
    /// it. The boundary's refusal is tested where it is the subject.
    func submitPaced(_ packet: Data, count: Int) {
        for index in 0..<count {
            runner.handleOutboundBatch([packet], protocols: [NSNumber(value: AF_INET)])
            if index % 8 == 7 { _ = runner.snapshotCounters() }
        }
    }

    /// Feeds the first datagram the runner sent into the peer and returns the inner packet.
    func loopBackThroughPeer(_ expected: [UInt8]) throws -> [UInt8]? {
        var inner = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        for datagram in channel.sent {
            let outcome = try? peerSession.decapsulate(datagram, from: .unknown, into: &inner)
            if case .writeToTunnelIPv4(let byteCount) = outcome {
                return Array(inner[..<byteCount])
            }
        }
        return nil
    }

    /// Drains whatever the runner scheduled.
    ///
    /// `snapshotCounters()` synchronises on the runner queue, so calling it IS the barrier —
    /// anything enqueued before it has run by the time it returns. Repeated because a send
    /// completion schedules a further hop to release parked packets.
    func settle() {
        for _ in 0..<4 { _ = runner.snapshotCounters() }
    }

    static func keyPair() -> (privateKey: [UInt8], publicKey: [UInt8]) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (Array(key.rawRepresentation), Array(key.publicKey.rawRepresentation))
    }

    /// The first fragment of a UDP/53 query, shaped the way the stack emits one: the UDP
    /// length field describes the whole reassembled datagram, so it overruns this fragment.
    static func fragmentedDNSHead(identification: UInt16) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 1500)
        packet[0] = 0x45
        packet[2] = UInt8((1500 >> 8) & 0xFF)
        packet[3] = UInt8(1500 & 0xFF)
        packet[4] = UInt8((identification >> 8) & 0xFF)
        packet[5] = UInt8(identification & 0xFF)
        packet[6] = 0x20  // more-fragments, offset 0
        packet[9] = UInt8(IPPROTO_UDP)
        packet[12...15] = [10, 64, 0, 5]
        packet[16...19] = [8, 8, 8, 8]
        packet[20] = 0xC0  // source port 49152
        packet[22] = 0x00
        packet[23] = 0x35  // destination port 53
        packet[24] = 0x0B  // UDP length 3000: the reassembled datagram, not this fragment
        packet[25] = 0xB8
        return packet
    }

    /// A packet carrying its arrival index, so the order the PEER decrypts them in is
    /// readable. Written into the IPv4 identification field and echoed in the payload; the
    /// identification is what survives being encrypted, decrypted and compared without
    /// depending on payload framing.
    static func taggedPacket(_ tag: Int) -> [UInt8] {
        var packet = ipv4Packet(byteCount: 120, source: [10, 64, 0, 5])
        packet[4] = UInt8((tag >> 8) & 0xFF)
        packet[5] = UInt8(tag & 0xFF)
        return packet
    }

    /// The tags the peer successfully decrypted, in the order the datagrams were sent.
    func tagsDecryptedByPeer() throws -> [Int] {
        var tags: [Int] = []
        var inner = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        for datagram in channel.sent {
            guard case .writeToTunnelIPv4(let byteCount) = try? peerSession.decapsulate(
                datagram, from: .unknown, into: &inner)
            else { continue }
            guard byteCount >= 6 else { continue }
            tags.append(Int(inner[4]) << 8 | Int(inner[5]))
        }
        return tags
    }

    /// An IPv4 UDP query to port 53 — what the classifier answers `.handleAsDNS` for.
    ///
    /// The default source is the DNS-only tunnel address; a chained-mode test passes the
    /// configured client address instead, because that is what the interface is numbered
    /// with once the route plan carries the `[Interface]` Address (C7).
    static func dnsQueryPacket(
        sourcePort: UInt16, payloadByteCount: Int = 12, source: [UInt8] = [10, 255, 0, 2],
        destination: [UInt8] = [10, 255, 0, 1]
    ) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 20 + 8 + payloadByteCount)
        packet[0] = 0x45
        packet[2] = UInt8((packet.count >> 8) & 0xFF)
        packet[3] = UInt8(packet.count & 0xFF)
        packet[9] = UInt8(IPPROTO_UDP)
        packet[12...15] = ArraySlice(source)
        packet[16...19] = ArraySlice(destination)
        packet[20] = UInt8((sourcePort >> 8) & 0xFF)
        packet[21] = UInt8(sourcePort & 0xFF)
        packet[22] = 0
        packet[23] = 53
        let udpLength = 8 + payloadByteCount
        packet[24] = UInt8((udpLength >> 8) & 0xFF)
        packet[25] = UInt8(udpLength & 0xFF)
        return packet
    }

    /// The peer's answer to one of OUR resolver's queries: UDP from the upstream resolver's
    /// :53 back to the tunnel address and the port the query claimed (S6).
    ///
    /// The direction the fixture had no builder for. A client query travels
    /// device → tunnel and is answered locally by the DNS proxy, so `dnsQueryPacket` plus
    /// `RecordingDNSServer` covered it; the S6 carry adds the opposite leg — our own query
    /// leaves through the peer and the ANSWER arrives as an ordinary decrypted inner packet,
    /// which the runner delivers only if its inner source clears AllowedIPs. That makes this
    /// builder the capture harness's other half: what the peer sends back is what the kernel
    /// would hand to the pinned socket in production.
    static func dnsResponsePacket(
        destinationPort: UInt16,
        payloadByteCount: Int = 12,
        resolver: [UInt8] = [10, 64, 0, 1],
        client: [UInt8] = [10, 64, 0, 5]
    ) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 20 + 8 + payloadByteCount)
        packet[0] = 0x45
        packet[2] = UInt8((packet.count >> 8) & 0xFF)
        packet[3] = UInt8(packet.count & 0xFF)
        packet[9] = UInt8(IPPROTO_UDP)
        packet[12...15] = ArraySlice(resolver)
        packet[16...19] = ArraySlice(client)
        packet[20] = 0
        packet[21] = 53
        packet[22] = UInt8((destinationPort >> 8) & 0xFF)
        packet[23] = UInt8(destinationPort & 0xFF)
        let udpLength = 8 + payloadByteCount
        packet[24] = UInt8((udpLength >> 8) & 0xFF)
        packet[25] = UInt8(udpLength & 0xFF)
        return packet
    }

    static func ipv4Packet(byteCount: Int, source: [UInt8]) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: byteCount)
        packet[0] = 0x45
        packet[2] = UInt8((byteCount >> 8) & 0xFF)
        packet[3] = UInt8(byteCount & 0xFF)
        packet[9] = UInt8(IPPROTO_TCP)
        packet[12...15] = ArraySlice(source)
        packet[16...19] = [93, 184, 216, 34]
        return packet
    }

}

final class FakeChannel: ChainedUpstreamDatagramChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (UnsafeRawBufferPointer) -> Void)?
    private var pending: [@Sendable (Bool) -> Void] = []
    var sent: [[UInt8]] { lock.withLock { sentStorage } }
    private var sentStorage: [[UInt8]] = []
    var withholdCompletions = false
    /// Answers every send inline with `false` — a transport whose stack refuses the datagram,
    /// which is the completion outcome the runner used to discard.
    var completeWithFailure = false
    /// Answers inline up to this many sends and withholds everything after, which is the only
    /// way to stall a batch DEEP rather than at its sixteenth packet — the distinction a
    /// whole-array residency bound turns on.
    var withholdAfterSends: Int?
    /// Runs from INSIDE `send`, which is the only deterministic way to observe the runner
    /// mid-batch: the queue is serial, so anything a test does from its own thread is
    /// necessarily before or after a batch, never during one.
    var onSend: (@Sendable () -> Void)?
    /// Answers every send by SCHEDULING the completion onto the shared engine queue, which is
    /// the third case the runner has to tell apart: on the queue, but not inside the send call.
    /// A channel handed the engine queue — which the public, shared queue invites — behaves
    /// exactly like this.
    var completeAsynchronouslyOn: ChainedEngineQueue?
    /// Deepest NESTING of `send` observed — 1 means no send began before the previous one
    /// returned. The direct observable for the completion recursion.
    private(set) var maxNestedSendDepth = 0
    private var sendDepth = 0

    func send(_ datagram: UnsafeRawBufferPointer, completion: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { onSend }?()
        let withhold: Bool = lock.withLock {
            sentStorage.append([UInt8](datagram))
            sendDepth += 1
            maxNestedSendDepth = max(maxNestedSendDepth, sendDepth)
            if let limit = withholdAfterSends, sentStorage.count > limit { return true }
            return withholdCompletions
        }
        if let queue = lock.withLock({ completeAsynchronouslyOn }) {
            lock.withLock { sendDepth -= 1 }
            queue.enqueue { completion(true) }
            return
        }
        if withhold {
            lock.withLock { pending.append(completion) }
        } else {
            // Inline, on the caller's queue, which is what a transport that answers
            // immediately does — and the path the recursion lived on.
            completion(!lock.withLock { completeWithFailure })
        }
        lock.withLock { sendDepth -= 1 }
    }

    func resetSendDepth() {
        lock.withLock { maxNestedSendDepth = 0 }
    }

    func setReceiveHandler(_ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func close() {}

    func deliver(_ datagram: UnsafeRawBufferPointer) {
        lock.withLock { handler }?(datagram)
    }

    /// Answers exactly the OLDEST outstanding send, leaving the rest withheld — the shape of
    /// a transport draining one datagram at a time rather than recovering all at once, which
    /// is what lets a test observe the runner's behaviour on a SINGLE freed slot.
    func releaseOneCompletion() {
        let oldest: (@Sendable (Bool) -> Void)? = lock.withLock {
            pending.isEmpty ? nil : pending.removeFirst()
        }
        oldest?(true)
    }

    /// Answers everything outstanding.
    ///
    /// `resumeWithholding` keeps the channel in withhold mode afterwards, which models a
    /// transport that keeps up but can only answer while the runner is not holding its
    /// queue. Without it the channel becomes synchronous, and a synchronous transport never
    /// accumulates outstanding sends at all.
    /// `succeeded: false` answers the withheld sends the way a transport whose socket died
    /// under them does — the outcome the runner tallies, and the one a RETIRED channel must
    /// not be able to tally against its replacement.
    func releaseCompletions(resumeWithholding: Bool = false, succeeded: Bool = true) {
        let waiting: [@Sendable (Bool) -> Void] = lock.withLock {
            withholdCompletions = resumeWithholding
            let all = pending
            pending = []
            return all
        }
        for completion in waiting { completion(succeeded) }
    }
}

/// Records the packets the runner handed back as client DNS queries.
final class RecordingDNSServer: ChainedDNSServing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    var served: [Data] { lock.withLock { storage } }
    var count: Int { lock.withLock { storage.count } }

    func serveDNS(_ packet: Data) { lock.withLock { storage.append(packet) } }
}

final class FakeWriter: ChainedTunnelWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[Data]] = []
    var written: [[Data]] { lock.withLock { storage } }
    func write(_ packets: [Data], protocols: [NSNumber]) {
        lock.withLock { storage.append(packets) }
    }
}
