import CryptoKit
import XCTest

@testable import LavaSecChainedUpstream

/// Drives a real 4-leg Noise handshake and a transport round-trip through the Swift
/// wrapper and the committed engine xcframework. This is the Swift twin of the crate's
/// `tests/engine_abi.rs`: it proves the macOS slice of `LavaSecWGCore.xcframework`
/// links from SwiftPM (the reason that slice exists) and that the wrapper's buffer,
/// error, and drain contracts hold against the real engine — not a stub.
final class WireGuardSessionTests: XCTestCase {
    private func keyPair() -> (privateKey: [UInt8], publicKey: [UInt8]) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (Array(key.rawRepresentation), Array(key.publicKey.rawRepresentation))
    }

    private func buffer() -> [UInt8] {
        [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
    }

    private func ipv4Packet(byteCount: Int = 40) -> [UInt8] {
        precondition(byteCount >= 40)
        var packet = [UInt8](repeating: 0, count: byteCount)
        packet[0] = 0x45
        packet[2] = UInt8(byteCount >> 8)
        packet[3] = UInt8(byteCount & 0xFF)
        packet[9] = 17
        packet[12...15] = [192, 168, 1, 2]
        packet[16...19] = [192, 168, 1, 3]
        for index in 20..<byteCount { packet[index] = UInt8(index % 251) }
        return packet
    }

    private func ipv6Packet() -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 40)
        packet[0] = 0x60
        packet[6] = 59
        packet[7] = 64
        packet[8...23] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        packet[24...39] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]
        return packet
    }

    /// Completes the handshake and returns both sessions.
    private func establishedPair() throws -> (WireGuardSession, WireGuardSession) {
        let alice = keyPair()
        let bob = keyPair()
        let a = try WireGuardSession(
            privateKey: alice.privateKey,
            peerPublicKey: bob.publicKey,
            keepaliveSeconds: 25,
            index: 1
        )
        let b = try WireGuardSession(
            privateKey: bob.privateKey,
            peerPublicKey: alice.publicKey,
            keepaliveSeconds: 25,
            index: 2
        )

        var wire = buffer()
        let initiation = try a.forceHandshake(into: &wire)
        XCTAssertEqual(initiation, .writeToNetwork(byteCount: WireGuardSession.minimumControlByteCount))

        var response = buffer()
        let responded = try b.decapsulate(Array(wire[..<initiation.byteCount]), from: .unknown, into: &response)
        guard case .writeToNetwork = responded else {
            XCTFail("expected a handshake response, got \(responded)")
            return (a, b)
        }

        var keepalive = buffer()
        let completed = try a.decapsulate(Array(response[..<responded.byteCount]), from: .unknown, into: &keepalive)
        guard case .writeToNetwork = completed else {
            XCTFail("expected the completion keepalive, got \(completed)")
            return (a, b)
        }

        var sink = buffer()
        let finalized = try b.decapsulate(Array(keepalive[..<completed.byteCount]), from: .unknown, into: &sink)
        XCTAssertEqual(finalized, .none, "the keepalive finalizes the responder's session")
        return (a, b)
    }

    func testHandshakeAndTransportRoundTripThroughTheEngine() throws {
        let (a, b) = try establishedPair()

        let payload = ipv4Packet()
        var encrypted = buffer()
        let sent = try a.encapsulate(payload, into: &encrypted)
        XCTAssertEqual(
            sent,
            .writeToNetwork(byteCount: payload.count + WireGuardABI.dataOverhead),
            "transport ciphertext carries exactly the WG data overhead"
        )

        var decrypted = buffer()
        var source = WireGuardSourceAddress()
        let received = try b.decapsulate(
            Array(encrypted[..<sent.byteCount]),
            from: .unknown,
            into: &decrypted,
            capturingSourceAddress: &source
        )
        XCTAssertEqual(received, .writeToTunnelIPv4(byteCount: payload.count))
        XCTAssertEqual(Array(decrypted[..<received.byteCount]), payload, "byte-exact round trip")
        XCTAssertEqual(source.byteCount, 4)
        XCTAssertEqual(source.octets, [192, 168, 1, 2], "inner source address surfaced")

        let stats = try a.statistics()
        XCTAssertNotNil(stats.timeSinceLastHandshake, "a completed handshake reports an age")
        XCTAssertGreaterThanOrEqual(stats.transmittedByteCount, UInt64(payload.count))
    }

    func testIPv6DecapsulationSurfacesASixteenByteSource() throws {
        let (a, b) = try establishedPair()
        let payload = ipv6Packet()
        var encrypted = buffer()
        let sent = try a.encapsulate(payload, into: &encrypted)

        var decrypted = buffer()
        var source = WireGuardSourceAddress()
        let received = try b.decapsulate(
            Array(encrypted[..<sent.byteCount]),
            from: .unknown,
            into: &decrypted,
            capturingSourceAddress: &source
        )
        XCTAssertEqual(received, .writeToTunnelIPv6(byteCount: payload.count))
        XCTAssertEqual(source.byteCount, 16)
        XCTAssertEqual(source.octets, Array(payload[8...23]))
    }

    func testDrainFlushesAPacketQueuedBeforeTheHandshakeCompleted() throws {
        let alice = keyPair()
        let bob = keyPair()
        let a = try WireGuardSession(privateKey: alice.privateKey, peerPublicKey: bob.publicKey, index: 1)
        let b = try WireGuardSession(privateKey: bob.privateKey, peerPublicKey: alice.publicKey, index: 2)

        // Traffic before the session exists: the engine queues the packet and emits the
        // handshake initiation instead. A large packet on purpose — its re-encapsulation
        // is what makes the uniform buffer contract load-bearing.
        let queued = ipv4Packet(byteCount: 1400)
        var wire = buffer()
        let initiation = try a.encapsulate(queued, into: &wire)
        XCTAssertEqual(initiation, .writeToNetwork(byteCount: WireGuardSession.minimumControlByteCount))

        var response = buffer()
        let responded = try b.decapsulate(Array(wire[..<initiation.byteCount]), from: .unknown, into: &response)
        var keepalive = buffer()
        let completed = try a.decapsulate(Array(response[..<responded.byteCount]), from: .unknown, into: &keepalive)
        var sink = buffer()
        _ = try b.decapsulate(Array(keepalive[..<completed.byteCount]), from: .unknown, into: &sink)

        var flushed = buffer()
        let drained = try a.drain(into: &flushed)
        XCTAssertEqual(
            drained,
            .writeToNetwork(byteCount: queued.count + WireGuardABI.dataOverhead),
            "the drain releases the queued packet"
        )

        var decrypted = buffer()
        let received = try b.decapsulate(Array(flushed[..<drained.byteCount]), from: .unknown, into: &decrypted)
        XCTAssertEqual(received, .writeToTunnelIPv4(byteCount: queued.count))
        XCTAssertEqual(Array(decrypted[..<received.byteCount]), queued)

        XCTAssertEqual(try a.drain(into: &flushed), .none, "the drain loop terminates")
    }

    func testBufferAndPacketContractsAreEnforcedBeforeReachingTheEngine() throws {
        let (a, _) = try establishedPair()

        var undersized = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount - 1)
        XCTAssertThrowsError(try a.encapsulate(ipv4Packet(), into: &undersized)) { error in
            XCTAssertEqual(error as? WireGuardEngineError, .destinationBufferTooSmall)
        }
        XCTAssertThrowsError(try a.decapsulate([1, 2, 3], from: .unknown, into: &undersized)) { error in
            XCTAssertEqual(error as? WireGuardEngineError, .destinationBufferTooSmall)
        }

        var tooSmallForControl = [UInt8](repeating: 0, count: WireGuardSession.minimumControlByteCount - 1)
        XCTAssertThrowsError(try a.tick(into: &tooSmallForControl)) { error in
            XCTAssertEqual(error as? WireGuardEngineError, .destinationBufferTooSmall)
        }

        var adequate = buffer()
        let oversized = [UInt8](repeating: 0, count: WireGuardSession.maximumIPPacketByteCount + 1)
        XCTAssertThrowsError(try a.encapsulate(oversized, into: &adequate)) { error in
            XCTAssertEqual(error as? WireGuardEngineError, .packetTooLarge)
        }
    }

    func testMalformedDatagramIsAPerPacketErrorAndTheSessionSurvives() throws {
        let (a, b) = try establishedPair()
        var out = buffer()
        XCTAssertThrowsError(try b.decapsulate([UInt8](repeating: 0xAB, count: 200), from: .unknown, into: &out)) { error in
            XCTAssertEqual(
                error as? WireGuardEngineError,
                .protocolViolation,
                "garbage must be a per-packet verdict, never the reconnect signal"
            )
        }

        let payload = ipv4Packet()
        var encrypted = buffer()
        let sent = try a.encapsulate(payload, into: &encrypted)
        var decrypted = buffer()
        let received = try b.decapsulate(Array(encrypted[..<sent.byteCount]), from: .unknown, into: &decrypted)
        XCTAssertEqual(received, .writeToTunnelIPv4(byteCount: payload.count), "session survives garbage")
    }

    func testSessionRejectsMalformedKeyMaterial() {
        let valid = keyPair()
        XCTAssertThrowsError(
            try WireGuardSession(privateKey: [1, 2, 3], peerPublicKey: valid.publicKey)
        ) { XCTAssertEqual($0 as? WireGuardEngineError, .sessionCreationFailed) }
        XCTAssertThrowsError(
            try WireGuardSession(privateKey: valid.privateKey, peerPublicKey: [])
        ) { XCTAssertEqual($0 as? WireGuardEngineError, .sessionCreationFailed) }
        XCTAssertThrowsError(
            try WireGuardSession(
                privateKey: valid.privateKey,
                peerPublicKey: valid.publicKey,
                presharedKey: [0, 1]
            )
        ) { XCTAssertEqual($0 as? WireGuardEngineError, .sessionCreationFailed) }
    }

    func testStatisticsLayoutAndSentinelsMatchTheABI() throws {
        XCTAssertEqual(
            MemoryLayout<LavaWGStatsRaw>.size,
            32,
            "LavaWGStats is 8+8+8+4+4 bytes with no padding; a mismatch means the twins drifted"
        )

        let alice = keyPair()
        let bob = keyPair()
        let fresh = try WireGuardSession(privateKey: alice.privateKey, peerPublicKey: bob.publicKey)
        let stats = try fresh.statistics()
        XCTAssertNil(stats.timeSinceLastHandshake, "no completed handshake maps the -1 sentinel to nil")
        XCTAssertNil(stats.estimatedRoundTrip, "unknown rtt maps the -1 sentinel to nil")
        XCTAssertEqual(stats.transmittedByteCount, 0)
        XCTAssertEqual(stats.receivedByteCount, 0)
    }

    func testAnOversizedInboundDatagramIsItsOwnErrorNotABufferContractFailure() throws {
        // The size of an inbound datagram is chosen by whoever sent it; the size of our
        // buffer is chosen by us. Collapsing both into destinationBufferTooSmall let a
        // remote sender's packet be indistinguishable from our own defect, which a
        // consumer could reasonably escalate on. They are separate cases now.
        let (session, _) = try establishedPair()
        var buffer = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let oversized = [UInt8](repeating: 4, count: WireGuardSession.maximumDatagramByteCount + 1)

        XCTAssertThrowsError(try session.decapsulate(oversized, from: .unknown, into: &buffer)) { error in
            XCTAssertEqual(error as? WireGuardEngineError, .oversizedDatagram)
            XCTAssertNotEqual(
                error as? WireGuardEngineError, .destinationBufferTooSmall,
                "a remotely-chosen datagram size must not read as our buffer being wrong"
            )
        }

        // A correctly-sized datagram still reaches the engine: the guard bounds the input,
        // it does not disable the path. (Garbage content is a per-packet protocol error,
        // which is the point — it got past the guard and was judged by the engine.)
        XCTAssertThrowsError(try session.decapsulate([UInt8](repeating: 4, count: 64), from: .unknown, into: &buffer)) { error in
            XCTAssertEqual(error as? WireGuardEngineError, .protocolViolation)
        }
    }

    // MARK: - The peer address is the DoS mitigation, not a diagnostic

    /// The transport-counter ceiling reaches Swift as a protocol violation, and keeps the session.
    ///
    /// The Rust unit tests pin the predicate and `engine_abi.rs` pins the refusal at the C
    /// boundary. Neither covers the wrapper's ERROR MAPPING, which is the one place a silent
    /// reclassification can still creep in: promoting this to a session-fatal code would hand a
    /// hostile peer a reconnect storm, and demoting it to a caller bug would hide wire input as an
    /// ABI violation.
    ///
    /// Boundary probes deliberately assert what the guard does NOT do. One below the limit is the
    /// peer's business, so it fails AEAD — which is correct, and the assertion is that the failure
    /// is not session-fatal rather than that it succeeds.
    func testATransportCounterPastTheLimitIsAProtocolViolationAndKeepsTheSession() throws {
        let (_, b) = try establishedPair()
        var buffer = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let peer = try XCTUnwrap(WireGuardPeerAddress(octets: [203, 0, 113, 9]))

        func datagram(counter: UInt64) -> [UInt8] {
            var packet = [UInt8](repeating: 0, count: 64)
            packet[0] = 4
            packet[8..<16] = ArraySlice(withUnsafeBytes(of: counter.littleEndian) { Array($0) })
            return packet
        }

        // At or above the limit: refused by our guard, before authentication.
        for counter in [UInt64.max, UInt64(18_446_744_073_709_543_423)] {
            do {
                _ = try b.decapsulate(datagram(counter: counter), from: peer, into: &buffer)
                XCTFail("a counter of \(counter) was accepted")
            } catch let error as WireGuardEngineError {
                XCTAssertEqual(
                    error, .protocolViolation,
                    "the ceiling reached Swift as \(error); promoting it to a session-fatal code "
                        + "hands a hostile peer a reconnect storm, and demoting it to a caller bug "
                        + "reports wire input as an ABI violation")
            }
        }

        // One BELOW the limit is not this guard's business. It fails AEAD, which is right — what
        // must not happen is that it fails fatally.
        do {
            _ = try b.decapsulate(
                datagram(counter: 18_446_744_073_709_543_422), from: peer, into: &buffer)
        } catch let error as WireGuardEngineError {
            XCTAssertNotEqual(
                error, .connectionExpired,
                "a counter the specification permits ended the session")
        }

        // AND THE SESSION STILL WORKS. This is the keep-session disposition, pinned so a refactor
        // cannot quietly make the refusal fatal.
        // `b`, NOT `a`. Every crafted datagram above went to `b`, so `b` is the only session
        // whose survival says anything — asserting on `a` tested a session that never saw the
        // refusal, which is an assertion with no failing case (Codex, PR #496).
        let inner = [UInt8](repeating: 0x45, count: 40)
        var wire = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        guard case .writeToNetwork(let byteCount) = try b.encapsulate(inner, into: &wire) else {
            return XCTFail("the session that received the refused datagrams could not encapsulate")
        }
        XCTAssertGreaterThan(
            byteCount, 0,
            "the session did not survive a refused datagram, so the refusal is session-fatal in "
                + "practice however it is spelled")
    }

    func testAHandshakeFloodIsAnsweredWithCookiesWhenThePeerIsKnown() throws {
        // Why the parameter exists. boringtun counts every MAC1-valid handshake packet
        // against PEER_HANDSHAKE_RATE_LIMIT (10/second). Past that it wants to reply with a
        // COOKIE the sender must echo back, proving it holds the address it claims — and
        // that path needs an address. With `.unknown` the limiter short-circuits to a hard
        // `underLoad` error instead, which is what let a replayed handshake flood starve the
        // real handshake and drive the tunnel to DNS-only.
        //
        // Replay needs no forgery: the same captured initiation stays MAC1-valid, which is
        // exactly what this does.
        // Keeps what the engine SENT, not just whether the call failed.
        func flood(from peer: WireGuardPeerAddress) throws -> (outcomes: [String], cookies: Int) {
            let alice = keyPair()
            let bob = keyPair()
            let a = try WireGuardSession(
                privateKey: alice.privateKey, peerPublicKey: bob.publicKey,
                keepaliveSeconds: 25, index: 1)
            let b = try WireGuardSession(
                privateKey: bob.privateKey, peerPublicKey: alice.publicKey,
                keepaliveSeconds: 25, index: 2)

            var wire = buffer()
            let initiation = try a.forceHandshake(into: &wire)
            let datagram = Array(wire[..<initiation.byteCount])

            // A WireGuard cookie reply is message type 3 and exactly 64 bytes:
            // 4 type/reserved + 4 receiver index + 24 nonce + 32 encrypted cookie.
            let cookieReplyType: UInt8 = 3
            let cookieReplyByteCount = 64

            var outcomes: [String] = []
            var cookies = 0
            for _ in 0..<15 {
                var out = buffer()
                do {
                    let op = try b.decapsulate(datagram, from: peer, into: &out)
                    outcomes.append(String(describing: op))
                    if case .writeToNetwork(let byteCount) = op,
                       byteCount == cookieReplyByteCount,
                       out.first == cookieReplyType {
                        cookies += 1
                    }
                } catch let error as WireGuardEngineError {
                    outcomes.append(String(describing: error))
                }
            }
            return (outcomes, cookies)
        }

        let withoutAddress = try flood(from: .unknown)
        XCTAssertTrue(
            withoutAddress.outcomes.contains("underLoad"),
            "without a peer address the limiter should hard-fail; got \(withoutAddress.outcomes)"
        )

        let peer = try XCTUnwrap(WireGuardPeerAddress(octets: [203, 0, 113, 9]))
        let withAddress = try flood(from: peer)
        // POSITIVE assertion, deliberately. Requiring merely the ABSENCE of `underLoad`
        // would pass for any other outcome — a run of protocol errors, or plain `.none`
        // results — none of which mitigates anything. What proves the mitigation is the
        // engine actually EMITTING cookie replies.
        XCTAssertGreaterThan(
            withAddress.cookies, 0,
            "with a peer address the engine should EMIT cookie replies (type 3, 64 bytes); "
                + "got \(withAddress.outcomes)"
        )
        XCTAssertFalse(
            withAddress.outcomes.contains("underLoad"),
            "with a peer address the engine should not hard-fail"
        )
    }

    func testAPeerAddressRejectsLengthsThatCannotBeAnIPAddress() {
        // A wrong address is worse than none, so anything that is not 4 or 16 octets is
        // refused rather than padded or truncated.
        XCTAssertNotNil(WireGuardPeerAddress(octets: [192, 0, 2, 1]))
        XCTAssertNotNil(WireGuardPeerAddress(octets: [UInt8](repeating: 1, count: 16)))
        for count in [0, 1, 3, 5, 8, 15, 17, 32] {
            XCTAssertNil(
                WireGuardPeerAddress(octets: [UInt8](repeating: 1, count: count)),
                "\(count) octets is not an IP address"
            )
        }
        XCTAssertEqual(WireGuardPeerAddress.unknown.byteCount, 0)
        XCTAssertEqual(WireGuardPeerAddress.unknown.octets, [])
        XCTAssertEqual(WireGuardPeerAddress(octets: [192, 0, 2, 1])?.octets, [192, 0, 2, 1])
    }

    func testAPeerAddressSurvivesBeingPassedToTheEngine() throws {
        // The storage is a (UInt64, UInt64) tuple. Handing a UInt8 pointer to the ABI used
        // `bindMemory`, which rebinds PERMANENTLY — so every later typed access, including
        // the implicit ones a copy or an `==` performs, touched memory bound to something
        // else. Optimized builds may miscompile that. This exercises exactly those accesses
        // after the value has been through a real engine call.
        let peer = try XCTUnwrap(WireGuardPeerAddress(octets: [198, 51, 100, 7]))
        let (_, b) = try establishedPair()

        var out = buffer()
        _ = try? b.decapsulate([], from: peer, into: &out)

        XCTAssertEqual(peer.octets, [198, 51, 100, 7], "octets changed after an engine call")
        XCTAssertEqual(peer.byteCount, 4)
        let copy = peer
        XCTAssertEqual(copy, peer, "a copy no longer compares equal to its source")
        XCTAssertNotEqual(peer, .unknown)
    }
}
