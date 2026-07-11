import Foundation

/// Network-byte-order primitives shared by DNS wire-format test fixtures.
///
/// Scenario-specific query, response, name, and record builders stay with their tests so
/// fixture intent remains visible and independent from the production parser.
enum DNSWireTestSupport {
    static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        precondition(
            offset >= 0 && data.count >= 2 && offset <= data.count - 2,
            "DNS UInt16 read requires two bytes starting at offset \(offset); buffer has \(data.count) bytes."
        )
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
}
