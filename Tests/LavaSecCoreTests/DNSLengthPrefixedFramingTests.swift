import Foundation
import XCTest
@testable import LavaSecCore

/// Behavioral coverage for the length-prefixed DNS wire framing shared by the DoT and DoQ
/// transports (`DNSLengthPrefixedWireMessage`, RFC 7858 §3.3 / RFC 9250 §4.2 framing).
/// Until now the framing was pinned only as source text; these tests execute it. The
/// receive-side reassembly loops live as private methods on the NWConnection-bound
/// connection classes and stay device/socket-only until the transport-extraction work.
final class DNSLengthPrefixedFramingTests: XCTestCase {
    func testFramedQueryPrependsBigEndianLengthAndPreservesPayload() throws {
        let query = Data([0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let frame = try XCTUnwrap(DNSLengthPrefixedWireMessage.framedQuery(query))

        XCTAssertEqual(frame.count, query.count + 2, "the frame is exactly the payload plus a 2-byte prefix")
        XCTAssertEqual(frame[frame.startIndex], 0x00, "high byte of a 12-byte length")
        XCTAssertEqual(frame[frame.index(after: frame.startIndex)], 0x0C, "low byte of a 12-byte length")
        XCTAssertEqual(frame.dropFirst(2), query, "the payload is preserved byte-for-byte")
    }

    func testFramedQueryPrefixIsBigEndianAcrossByteBoundary() throws {
        // 0x0102 = 258 bytes: both prefix bytes are nonzero, so an endianness swap
        // (0x0201 = 513) cannot pass this assertion.
        let query = Data(repeating: 0x55, count: 0x0102)
        let frame = try XCTUnwrap(DNSLengthPrefixedWireMessage.framedQuery(query))

        XCTAssertEqual(frame[frame.startIndex], 0x01)
        XCTAssertEqual(frame[frame.index(after: frame.startIndex)], 0x02)

        // The DoT/DoQ receive paths decode the prefix as (hi << 8) | lo — the same
        // arithmetic must round-trip the encoded length.
        let decoded = (UInt16(frame[frame.startIndex]) << 8)
            | UInt16(frame[frame.index(after: frame.startIndex)])
        XCTAssertEqual(Int(decoded), query.count)
    }

    func testFramedQueryHandlesEmptyAndMaximumSizedPayloads() throws {
        // An empty payload frames to just the zero prefix (the length gate is the
        // receive side's job — `responseLength > 0` — not the framer's).
        let empty = try XCTUnwrap(DNSLengthPrefixedWireMessage.framedQuery(Data()))
        XCTAssertEqual(empty, Data([0x00, 0x00]))

        // 65,535 bytes is the largest representable frame and must be accepted...
        let maximum = Data(repeating: 0x00, count: Int(UInt16.max))
        let maximumFrame = try XCTUnwrap(DNSLengthPrefixedWireMessage.framedQuery(maximum))
        XCTAssertEqual(maximumFrame.count, Int(UInt16.max) + 2)
        XCTAssertEqual(maximumFrame[maximumFrame.startIndex], 0xFF)
        XCTAssertEqual(maximumFrame[maximumFrame.index(after: maximumFrame.startIndex)], 0xFF)

        // ...and one byte more is unrepresentable in a UInt16 prefix: nil, never a
        // truncated or wrapped length (a wrapped prefix would desynchronize the stream).
        XCTAssertNil(DNSLengthPrefixedWireMessage.framedQuery(Data(repeating: 0x00, count: Int(UInt16.max) + 1)))
    }

    func testFramedQuerySliceIndependence() throws {
        // Data slices carry non-zero startIndex; the framer must not assume index 0.
        let backing = Data([0xFF, 0xFF, 0xAB, 0xCD, 0x01, 0x02, 0x03])
        let slice = backing.dropFirst(2)
        let frame = try XCTUnwrap(DNSLengthPrefixedWireMessage.framedQuery(slice))

        XCTAssertEqual(frame[frame.startIndex], 0x00)
        XCTAssertEqual(frame[frame.index(after: frame.startIndex)], 0x05)
        XCTAssertEqual(frame.dropFirst(2), slice)
    }
}
