import Foundation
import XCTest
@testable import LavaSecCore
@testable import LavaSecKit
@testable import LavaSecDNS

/// Behavioral coverage for the length-prefixed DNS wire framing shared by the DoT and DoQ
/// transports (`DNSLengthPrefixedWireMessage`, RFC 7858 §3.3 / RFC 9250 §4.2 framing) —
/// both the send-side framer and the receive-side reassembly step. The reassembly
/// decisions (partial frames, truncation, receive errors, the length-prefix gate) are
/// pure `receiveStep`/`responseBodyLength` calls here; only the NWConnection
/// receive/dispatch glue remains device/socket-only on the connection classes.
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

    // MARK: - Receive-side length prefix

    func testResponseBodyLengthDecodesBigEndianPrefix() throws {
        XCTAssertEqual(DNSLengthPrefixedWireMessage.responseBodyLength(fromPrefix: Data([0x01, 0x02])), 0x0102)
        XCTAssertEqual(DNSLengthPrefixedWireMessage.responseBodyLength(fromPrefix: Data([0x00, 0x0C])), 12)
        // The max boundary must decode to a POSITIVE length, not merely compare equal to
        // UInt16.max — the caller uses it as the allocation count for the body read, so a
        // sign-bit / off-by-one bug that yields <= 0 must fail here. responseBodyLength
        // returns Int?, so bind it with XCTUnwrap. (OCR review on the 1.2.4 sync)
        let maxLength = try XCTUnwrap(DNSLengthPrefixedWireMessage.responseBodyLength(fromPrefix: Data([0xFF, 0xFF])))
        XCTAssertEqual(maxLength, Int(UInt16.max))
        XCTAssertGreaterThan(maxLength, 0)
    }

    func testResponseBodyLengthRejectsMissingShortAndZeroPrefixes() {
        XCTAssertNil(DNSLengthPrefixedWireMessage.responseBodyLength(fromPrefix: nil))
        XCTAssertNil(DNSLengthPrefixedWireMessage.responseBodyLength(fromPrefix: Data()))
        XCTAssertNil(DNSLengthPrefixedWireMessage.responseBodyLength(fromPrefix: Data([0x0C])))
        // A zero-length "response" has no DNS header; accepting it would hand an
        // empty message to response validation.
        XCTAssertNil(DNSLengthPrefixedWireMessage.responseBodyLength(fromPrefix: Data([0x00, 0x00])))
    }

    func testResponseBodyLengthIsSliceSafe() {
        let backing = Data([0xAA, 0xBB, 0x01, 0x02])
        XCTAssertEqual(DNSLengthPrefixedWireMessage.responseBodyLength(fromPrefix: backing.dropFirst(2)), 0x0102)
    }

    // MARK: - Receive-side reassembly step

    func testReceiveStepFailsOnReceiveErrorRegardlessOfPayload() {
        // A receive error is terminal no matter what rode along with it — a
        // non-empty chunk, an empty chunk, or no chunk at all — and in both the
        // strict (DoT) and tolerant (DoQ) empty-chunk modes.
        // Single labeled-cases array iterated once so a failure names the exact
        // failsOnEmptyChunk/incoming combination rather than reporting the shared
        // XCTAssertEqual line for every case. (OCR review on the 1.2.4 sync)
        let cases: [(failsOnEmptyChunk: Bool, incoming: Data?, label: String)] = [
            (true, Data([0x02]), "strict / non-empty chunk"),
            (true, Data(), "strict / empty chunk"),
            (true, nil, "strict / nil chunk"),
            (false, Data([0x02]), "tolerant / non-empty chunk"),
            (false, Data(), "tolerant / empty chunk"),
            (false, nil, "tolerant / nil chunk"),
        ]
        for testCase in cases {
            // A receive error is terminal even when a stream FIN rides along (isComplete: true):
            // production short-circuits on hadReceiveError before consulting isComplete, so the
            // "regardless" guarantee must hold in both (OCR review on the 1.2.4 sync).
            for isComplete in [false, true] {
                let step = DNSLengthPrefixedWireMessage.receiveStep(
                    accumulated: Data([0x01]),
                    incoming: testCase.incoming,
                    hadReceiveError: true,
                    isComplete: isComplete,
                    targetByteCount: 4,
                    failsOnEmptyChunk: testCase.failsOnEmptyChunk
                )
                XCTAssertEqual(step, .failed, "\(testCase.label) / isComplete: \(isComplete)")
            }
        }
    }

    func testReceiveStepAccumulatesPartialChunksUntilTargetByteCount() {
        // Byte-at-a-time delivery must chain continueReceiving steps and complete
        // exactly at the target — the DoT/DoQ loops re-issue a receive per step.
        // Accumulation is identical in strict (DoT) and tolerant (DoQ) modes: the
        // empty-chunk policy only bites when a chunk is actually empty.
        for failsOnEmptyChunk in [true, false] {
            var accumulated = Data()
            let frame = Data([0xAB, 0xCD, 0xEF, 0x99])

            for (offset, byte) in frame.dropLast().enumerated() {
                let step = DNSLengthPrefixedWireMessage.receiveStep(
                    accumulated: accumulated,
                    incoming: Data([byte]),
                    hadReceiveError: false,
                    isComplete: false,
                    targetByteCount: frame.count,
                    failsOnEmptyChunk: failsOnEmptyChunk
                )
                guard case .continueReceiving(let next) = step else {
                    return XCTFail("byte \(offset) should continue receiving, got \(step) (failsOnEmptyChunk: \(failsOnEmptyChunk))")
                }
                XCTAssertEqual(next.count, offset + 1, "failsOnEmptyChunk: \(failsOnEmptyChunk)")
                accumulated = next
            }

            let finalStep = DNSLengthPrefixedWireMessage.receiveStep(
                accumulated: accumulated,
                incoming: Data([frame.last!]),
                hadReceiveError: false,
                isComplete: false,
                targetByteCount: frame.count,
                failsOnEmptyChunk: failsOnEmptyChunk
            )
            XCTAssertEqual(finalStep, .frameComplete(frame), "failsOnEmptyChunk: \(failsOnEmptyChunk)")
        }
    }

    func testReceiveStepReturnsFrameCompleteOnOversizedFinalChunk() {
        // The completion gate is `nextData.count >= targetByteCount` (not `==`): a final
        // chunk that overshoots the target still completes, and .frameComplete carries the
        // FULL accumulated buffer — overshoot included, never truncated to targetByteCount.
        // Exercises the `>=` branch the byte-at-a-time accumulation test can't reach, in
        // both the strict (DoT) and tolerant (DoQ) modes. (OCR review on the 1.2.4 sync)
        for failsOnEmptyChunk in [true, false] {
            let step = DNSLengthPrefixedWireMessage.receiveStep(
                accumulated: Data([0x01, 0x02]),
                incoming: Data([0x03, 0x04, 0x05, 0x06]),
                hadReceiveError: false,
                isComplete: false,
                targetByteCount: 4,
                failsOnEmptyChunk: failsOnEmptyChunk
            )
            XCTAssertEqual(
                step,
                .frameComplete(Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])),
                "failsOnEmptyChunk: \(failsOnEmptyChunk)"
            )
        }
    }

    func testReceiveStepCompletesWhenFinalChunkArrivesWithStreamCompletion() {
        // A stream FIN delivered WITH the last bytes is a complete frame, not a
        // truncation — completion is checked before isComplete, so it holds in BOTH the
        // strict (DoT) and tolerant (DoQ) empty-chunk modes; a mode-specific FIN special-case
        // would be caught here. (OCR review on the 1.2.4 sync)
        for failsOnEmptyChunk in [true, false] {
            let step = DNSLengthPrefixedWireMessage.receiveStep(
                accumulated: Data([0x01, 0x02]),
                incoming: Data([0x03, 0x04]),
                hadReceiveError: false,
                isComplete: true,
                targetByteCount: 4,
                failsOnEmptyChunk: failsOnEmptyChunk
            )
            XCTAssertEqual(step, .frameComplete(Data([0x01, 0x02, 0x03, 0x04])), "failsOnEmptyChunk: \(failsOnEmptyChunk)")
        }
    }

    func testReceiveStepFailsWhenStreamCompletesShortOfTarget() {
        // Truncation is terminal in BOTH modes: replaying a receive on a finished
        // stream spins until the query timeout (the pre-extraction DoQ loop did
        // exactly that), so a short FIN must fail fast.
        for failsOnEmptyChunk in [true, false] {
            let step = DNSLengthPrefixedWireMessage.receiveStep(
                accumulated: Data([0x01]),
                incoming: Data([0x02]),
                hadReceiveError: false,
                isComplete: true,
                targetByteCount: 4,
                failsOnEmptyChunk: failsOnEmptyChunk
            )
            XCTAssertEqual(step, .failed, "failsOnEmptyChunk: \(failsOnEmptyChunk)")
        }
    }

    func testReceiveStepEmptyChunkFailsStrictModeAndContinuesTolerantMode() {
        // DoT (strict): an empty/nil chunk without an error is a dead read — fail.
        for incoming in [Data(), nil] {
            let strict = DNSLengthPrefixedWireMessage.receiveStep(
                accumulated: Data([0x01]),
                incoming: incoming,
                hadReceiveError: false,
                isComplete: false,
                targetByteCount: 4,
                failsOnEmptyChunk: true
            )
            XCTAssertEqual(strict, .failed)

            // DoQ (tolerant): QUIC delivery can surface empty callbacks; keep
            // receiving with the accumulation unchanged.
            let tolerant = DNSLengthPrefixedWireMessage.receiveStep(
                accumulated: Data([0x01]),
                incoming: incoming,
                hadReceiveError: false,
                isComplete: false,
                targetByteCount: 4,
                failsOnEmptyChunk: false
            )
            XCTAssertEqual(tolerant, .continueReceiving(accumulated: Data([0x01])))
        }
    }
}
