import Foundation
import XCTest
@testable import LavaSecDNS
import LavaSecKit

final class TunnelUDPResolverTests: XCTestCase {
    private let query = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
                              7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0, 0, 1, 0, 1])
    private var endpoint: ResolverEndpoint { ResolverEndpoint(address: "10.64.0.1")! }
    private func reply(to packet: Data, mutate: (inout Data) -> Void = { _ in }) throws -> Data {
        let request = try XCTUnwrap(IPv4UDPDNSPacket(packet))
        var payload = query
        payload[2] = 0x81; payload[3] = 0x80
        mutate(&payload)
        return try XCTUnwrap(request.response(dnsPayload: payload))
    }

    func testDirectRoundTripPreservesDNSIdentityWithoutRegisteringAClientCarveOut() throws {
        let resolver = try XCTUnwrap(TunnelUDPResolver(sourceAddress: "10.66.0.2"))
        var sends = 0
        let result = resolver.resolve(query, endpoint: endpoint, timeout: 0.2) { packet, deadline in
            sends += 1
            XCTAssertFalse(deadline.hasExpired())
            let request = IPv4UDPDNSPacket(packet)!
            XCTAssertEqual(request.sourceAddress, Data([10, 66, 0, 2]))
            XCTAssertEqual(request.destinationAddress, Data([10, 64, 0, 1]))
            XCTAssertGreaterThan(request.sourcePort, 0)
            XCTAssertTrue(resolver.consumeReply(try! self.reply(to: packet)))
            return true
        }
        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(sends, 1)
        XCTAssertTrue(DNSWireMessage.isValidResponse(try XCTUnwrap(result.response), matching: query))
    }

    func testMismatchedReplyCannotCompleteAndValidLaterReplyCan() throws {
        let resolver = try XCTUnwrap(TunnelUDPResolver(sourceAddress: "10.66.0.2"))
        let result = resolver.resolve(query, endpoint: endpoint, timeout: 0.2) { packet, _ in
            XCTAssertTrue(resolver.consumeReply(try! self.reply(to: packet) { $0[0] ^= 1 }))
            XCTAssertTrue(resolver.consumeReply(try! self.reply(to: packet)))
            return true
        }
        XCTAssertEqual(result.outcome, .success)
    }

    func testWrongSourceFragmentAndBadChecksumsCannotComplete() throws {
        let resolver = try XCTUnwrap(TunnelUDPResolver(sourceAddress: "10.66.0.2"))
        let result = resolver.resolve(query, endpoint: endpoint, timeout: 0.02) { packet, _ in
            let request = TunnelUDPDatagram(packet)!
            let wrongSource = TunnelUDPDatagram.make(
                source: Data([10, 64, 0, 9]), destination: request.source,
                sourcePort: 53, destinationPort: request.sourcePort, payload: self.query)
            XCTAssertTrue(resolver.consumeReply(wrongSource))
            var badIP = try! self.reply(to: packet); badIP[10] ^= 1
            XCTAssertFalse(resolver.consumeReply(badIP))
            var fragment = try! self.reply(to: packet); fragment[6] = 0x20
            XCTAssertFalse(resolver.consumeReply(fragment))
            var badUDP = try! self.reply(to: packet); badUDP[26] = 1
            XCTAssertFalse(resolver.consumeReply(badUDP))
            return true
        }
        XCTAssertEqual(result.outcome, .timeout)
    }

    func testExpiredAndRetiredRequestsNeverSend() throws {
        let resolver = try XCTUnwrap(TunnelUDPResolver(sourceAddress: "10.66.0.2"))
        let expired = resolver.resolve(query, endpoint: endpoint, timeout: 0) { _, _ in
            XCTFail("expired DNS reached the engine"); return true
        }
        XCTAssertEqual(expired.outcome, .expiredBeforeSend)
        resolver.retire()
        let retired = resolver.resolve(query, endpoint: endpoint, timeout: 0.1) { _, _ in
            XCTFail("retired DNS reached the engine"); return true
        }
        XCTAssertNil(retired.response)
    }

    func testRetirementWakesAnOutstandingExchange() throws {
        let resolver = try XCTUnwrap(TunnelUDPResolver(sourceAddress: "10.66.0.2"))
        let result = resolver.resolve(query, endpoint: endpoint, timeout: 5) { _, _ in
            resolver.retire()
            return true
        }
        XCTAssertEqual(result.outcome, .refusedAfterLifecycleEnded)
    }

    func testCapacityRefusesAdditionalQueriesAndIsReleasedAfterCompletion() throws {
        let resolver = try XCTUnwrap(TunnelUDPResolver(sourceAddress: "10.66.0.2", capacity: 1))
        let result = resolver.resolve(query, endpoint: endpoint, timeout: 0.2) { packet, _ in
            let refused = resolver.resolve(self.query, endpoint: self.endpoint, timeout: 0.1) { _, _ in
                XCTFail("capacity limit was bypassed"); return true
            }
            XCTAssertEqual(refused.outcome, .resolverPortUnavailable)
            XCTAssertTrue(resolver.consumeReply(try! self.reply(to: packet)))
            return true
        }
        XCTAssertEqual(result.outcome, .success)
        let next = resolver.resolve(query, endpoint: endpoint, timeout: 0.2) { packet, _ in
            XCTAssertTrue(resolver.consumeReply(try! self.reply(to: packet))); return true
        }
        XCTAssertEqual(next.outcome, .success)
    }

    func testReadinessWaitCannotExtendDeadlineOrSendAfterLifetimeInvalidation() throws {
        let resolver = try XCTUnwrap(TunnelUDPResolver(sourceAddress: "10.66.0.2"))
        let active = LockedFlag()
        // Give admission ample time on a loaded CI host, then deliberately let the
        // deadline pass inside the readiness callback after ending the lifetime.
        let lifetime = DNSResolutionLifetime(deadline: MonotonicDeadline(after: 2)) { active.value }
        var attempts = 0
        let result = resolver.resolve(query, endpoint: endpoint, timeout: 5, lifetime: lifetime) { _, _ in
            attempts += 1
            active.clear()
            Thread.sleep(forTimeInterval: 2.05)
            return false
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(result.outcome, .refusedAfterLifecycleEnded)
    }

    func testLifetimeDeadlineStillClassifiesSentQueryAsTimeout() throws {
        let resolver = try XCTUnwrap(TunnelUDPResolver(sourceAddress: "10.66.0.2"))
        let lifetime = DNSResolutionLifetime(deadline: MonotonicDeadline(after: 2)) { true }
        var attempts = 0
        let result = resolver.resolve(query, endpoint: endpoint, timeout: 5, lifetime: lifetime) { _, deadline in
            attempts += 1
            let admitted = !deadline.hasExpired()
            Thread.sleep(forTimeInterval: 2.05)
            return admitted
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(result.outcome, .timeout)
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = true
        var value: Bool { lock.withLock { stored } }
        func clear() { lock.withLock { stored = false } }
    }
}
