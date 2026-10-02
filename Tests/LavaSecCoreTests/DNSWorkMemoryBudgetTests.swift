import Darwin
import Foundation
import XCTest
@testable import LavaSecCore

final class DNSWorkMemoryBudgetTests: XCTestCase {
    func testProductionOwnersBoundRetainedPayloadDuringADistinctQueryBurst() throws {
        let before = allocatedBytes()
        let queue = BoundedWorkAdmission<Data>(bound: 8)
        let waiters = InFlightDNSQueryCoalescer<PendingDNSResponse>()
        let deadline = MonotonicDeadline(after: 12)
        for index in 0..<10_000 {
            var wire = Data(repeating: 0, count: 4096)
            wire[12] = UInt8(index >> 8)
            wire[13] = UInt8(index & 255)
            let request = try XCTUnwrap(IPv4UDPDNSPacket(packet(wire)))
            let pending = PendingDNSResponse(request: request, protocolNumber: Int(AF_INET),
                maximumAnswerTTL: nil, temporaryPauseNormalizedDomain: nil)
            let key = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "memory-test", dnsPayload: wire))
            if case .startedResolution = waiters.enqueue(pending, for: key, retainedBytes: 2 * wire.count + 128) {
                _ = queue.submit(wire, retainedBytes: wire.count + 256, deadline: deadline)
            }
        }
        let retainedAllocationDelta = max(0, allocatedBytes() - before)
        print("DNS retained-memory sample: \(retainedAllocationDelta) allocated bytes; \(waiters.waiterCount) waiters; \(queue.pendingWorkCount) pending; \(MemoryLayout<PendingDNSResponse>.stride)-byte waiter value")
        XCTAssertLessThanOrEqual(waiters.retainedByteCount, 1024 * 1024)
        XCTAssertLessThanOrEqual(queue.pendingByteCount, 512 * 1024)
        XCTAssertEqual(queue.activeWorkCount, 8)
        XCTAssertLessThanOrEqual(queue.pendingWorkCount, 128)
        // Payload accounting remains conservative even when the waiter value gains metadata.
        XCTAssertLessThanOrEqual(MemoryLayout<PendingDNSResponse>.stride, 128)
        withExtendedLifetime((queue, waiters)) {}
    }

    private func allocatedBytes() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
    }

    private func packet(_ wire: Data) -> Data {
        var packet = Data(repeating: 0, count: 28)
        let length = wire.count + 28
        packet[0] = 0x45
        packet[2] = UInt8(length >> 8); packet[3] = UInt8(length & 255)
        packet[9] = UInt8(IPPROTO_UDP)
        packet[12] = 10; packet[16] = 1
        packet[20] = 0x12; packet[21] = 0x34; packet[23] = 53
        packet[24] = UInt8((wire.count + 8) >> 8); packet[25] = UInt8((wire.count + 8) & 255)
        packet.append(wire)
        return packet
    }
}
