import Foundation
import XCTest

final class DNSWireTestSupportTests: XCTestCase {
    func testAppendUInt16UsesNetworkByteOrder() {
        var data = Data([0xEE])

        DNSWireTestSupport.appendUInt16(0x1234, to: &data)

        XCTAssertEqual(data, Data([0xEE, 0x12, 0x34]))
    }

    func testReadUInt16UsesNetworkByteOrderAtNonzeroOffset() {
        let data = Data([0xEE, 0xAB, 0xCD, 0xFF])

        XCTAssertEqual(DNSWireTestSupport.readUInt16(data, at: 1), 0xABCD)
    }

    func testUInt16BoundaryValuesRoundTrip() {
        var data = Data()
        let values: [UInt16] = [0, 1, 0x7FFF, 0x8000, .max]

        for value in values {
            DNSWireTestSupport.appendUInt16(value, to: &data)
        }

        for (index, value) in values.enumerated() {
            XCTAssertEqual(
                DNSWireTestSupport.readUInt16(data, at: index * MemoryLayout<UInt16>.size),
                value
            )
        }
    }
}
