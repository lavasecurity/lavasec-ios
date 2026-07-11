import XCTest
import LavaSecDNS
@testable import LavaSecCore
@testable import LavaSecKit

final class InFlightDNSQueryCoalescerTests: XCTestCase {
    private func makeKey(_ domain: String) throws -> DNSCacheKey {
        var payload = Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        payload.append(Data(domain.utf8))
        return try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:test", dnsPayload: payload))
    }

    func testFirstWaiterStartsAndDuplicatesJoin() throws {
        let coalescer = InFlightDNSQueryCoalescer<String>()
        let key = try makeKey("example.com")

        XCTAssertEqual(coalescer.enqueue("first", for: key), .startedResolution)
        XCTAssertEqual(coalescer.enqueue("second", for: key), .joinedExistingResolution)
        XCTAssertEqual(coalescer.enqueue("third", for: key), .joinedExistingResolution)
        XCTAssertEqual(coalescer.inFlightKeyCount, 1)
    }

    func testDrainReturnsWaitersInEnqueueOrderExactlyOnce() throws {
        let coalescer = InFlightDNSQueryCoalescer<String>()
        let key = try makeKey("example.com")
        _ = coalescer.enqueue("first", for: key)
        _ = coalescer.enqueue("second", for: key)

        XCTAssertEqual(coalescer.drain(key), ["first", "second"])
        XCTAssertEqual(coalescer.drain(key), [], "One drain per started resolution — a second drain finds nothing.")
        XCTAssertEqual(coalescer.inFlightKeyCount, 0)
    }

    func testEnqueueAfterDrainStartsANewResolution() throws {
        let coalescer = InFlightDNSQueryCoalescer<String>()
        let key = try makeKey("example.com")
        _ = coalescer.enqueue("first", for: key)
        _ = coalescer.drain(key)

        XCTAssertEqual(
            coalescer.enqueue("fresh", for: key), .startedResolution,
            "After the in-flight resolution completes, the next identical query starts a new one."
        )
    }

    func testIndependentKeysCoalesceIndependently() throws {
        let coalescer = InFlightDNSQueryCoalescer<String>()
        let keyA = try makeKey("a.example.com")
        let keyB = try makeKey("b.example.com")

        XCTAssertEqual(coalescer.enqueue("a1", for: keyA), .startedResolution)
        XCTAssertEqual(coalescer.enqueue("b1", for: keyB), .startedResolution)
        XCTAssertEqual(coalescer.enqueue("a2", for: keyA), .joinedExistingResolution)

        XCTAssertEqual(coalescer.drain(keyA), ["a1", "a2"])
        XCTAssertEqual(coalescer.drain(keyB), ["b1"])
    }

    func testDrainAllReturnsEveryWaiterAndClears() throws {
        let coalescer = InFlightDNSQueryCoalescer<String>()
        let keyA = try makeKey("a.example.com")
        let keyB = try makeKey("b.example.com")
        _ = coalescer.enqueue("a1", for: keyA)
        _ = coalescer.enqueue("a2", for: keyA)
        _ = coalescer.enqueue("b1", for: keyB)

        let drained = coalescer.drainAll()

        XCTAssertEqual(drained.count, 3)
        XCTAssertEqual(Set(drained), ["a1", "a2", "b1"])
        XCTAssertEqual(coalescer.inFlightKeyCount, 0)
        XCTAssertEqual(coalescer.enqueue("fresh", for: keyA), .startedResolution)
    }
}
