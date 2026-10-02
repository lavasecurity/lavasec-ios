import XCTest
import LavaSecDNS
@testable import LavaSecCore

final class InFlightDNSQueryCoalescerTests: XCTestCase {
    private func key(_ name: String = "example.com") throws -> DNSCacheKey {
        var payload = Data(repeating: 0, count: 12)
        payload.append(Data(name.utf8))
        return try XCTUnwrap(DNSCacheKey(resolverIdentifier: "test", dnsPayload: payload))
    }

    func testDuplicatesJoinInOrderAndOnlyTheOwnerCanDrain() throws {
        let owner = InFlightDNSQueryCoalescer<Int>()
        let key = try key()
        XCTAssertEqual(owner.enqueue(1, for: key, retainedBytes: 10), .startedResolution(1))
        XCTAssertEqual(owner.enqueue(2, for: key, retainedBytes: 20), .joinedExistingResolution)
        XCTAssertEqual(owner.drain(key, resolutionID: 9), [])
        XCTAssertEqual(owner.drain(key, resolutionID: 1), [1, 2])
        XCTAssertEqual(owner.drain(key, resolutionID: 1), [])
        XCTAssertEqual(owner.retainedByteCount, 0)
        XCTAssertEqual(owner.waiterCount, 0)
    }

    func testLateCompletionCannotDrainSuccessorAfterResetOrExpiry() throws {
        let owner = InFlightDNSQueryCoalescer<Int>()
        let key = try key()
        _ = owner.enqueue(1, for: key, retainedBytes: 1)
        XCTAssertEqual(owner.drainAll(), [1])
        XCTAssertEqual(owner.enqueue(2, for: key, retainedBytes: 1), .startedResolution(2))
        XCTAssertEqual(owner.drain(key, resolutionID: 1), [])
        XCTAssertEqual(owner.drain(key, resolutionID: 2), [2])
        XCTAssertEqual(owner.enqueue(3, for: key, retainedBytes: 1), .startedResolution(3))
        XCTAssertEqual(owner.drain(key, resolutionID: 2), [])
        XCTAssertEqual(owner.drain(key, resolutionID: 3), [3])
    }

    func testDuplicateBurstAndDistinctBurstStayWithinIndependentBudgets() throws {
        let owner = InFlightDNSQueryCoalescer<Int>(
            maximumWaiterCount: 32, maximumWaitersPerKey: 4, maximumRetainedBytes: 100)
        let same = try key()
        for value in 0..<10_000 {
            let result = owner.enqueue(value, for: same, retainedBytes: 10)
            if value >= 4 { XCTAssertEqual(result, .rejected) }
        }
        XCTAssertEqual(owner.waiterCount, 4)
        for value in 0..<10_000 {
            _ = owner.enqueue(value, for: try key("q\(value)"), retainedBytes: 10)
            XCTAssertLessThanOrEqual(owner.retainedByteCount, 100)
        }
        XCTAssertEqual(owner.waiterCount, 10)
        XCTAssertEqual(owner.inFlightKeyCount, 7)
        XCTAssertEqual(owner.drainAll().count, 10)
        XCTAssertEqual(owner.retainedByteCount, 0)
    }

    func testTotalCountLimitAndCapacityRecovery() throws {
        let owner = InFlightDNSQueryCoalescer<Int>(
            maximumWaiterCount: 2, maximumWaitersPerKey: 2, maximumRetainedBytes: 100)
        let a = try key("a"), b = try key("b")
        _ = owner.enqueue(1, for: a, retainedBytes: 1)
        _ = owner.enqueue(2, for: b, retainedBytes: 1)
        XCTAssertEqual(owner.enqueue(3, for: b, retainedBytes: 1), .rejected)
        XCTAssertEqual(owner.drain(a, resolutionID: 1), [1])
        XCTAssertEqual(owner.enqueue(3, for: b, retainedBytes: 1), .joinedExistingResolution)
        XCTAssertEqual(owner.drain(b, resolutionID: 2), [2, 3])
    }
}
