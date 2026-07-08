// DNS wire-format inspection + SERVFAIL synthesis, extracted verbatim from
// PacketTunnelProvider.swift (Phase E1); first executable coverage in
// DNSMessageTraitsTests.
import Foundation

/// Read-only inspectors over raw DNS wire messages.
public enum DNSMessageTraits {
    /// True when the response header carries the TC (truncation) bit — the
    /// signal that a UDP answer was cut short and the query should be retried
    /// over TCP. Buffers shorter than the 4 header bytes report `false`.
    public static func isTruncated(_ response: Data) -> Bool {
        guard response.count >= 4 else {
            return false
        }

        let flags = (UInt16(response[2]) << 8) | UInt16(response[3])
        return flags & 0x0200 != 0
    }
}

/// Synthesizes SERVFAIL responses — the fail-closed answer the tunnel serves
/// when a query cannot be resolved through the filter, instead of ever
/// forwarding raw queries around it (INV-DNS-1; the bounded bootstrap wait's
/// non-committed exits also answer SERVFAIL, INV-DNS-2).
public enum DNSResponseFactory {
    /// Builds a SERVFAIL (RCODE 2) response for `query`: transaction ID echoed,
    /// QR + RA set, RD copied from the query, and the question section echoed
    /// verbatim. Queries whose question cannot be parsed fall back to a
    /// header-only SERVFAIL (question count 0); returns `nil` only when the
    /// query is shorter than a 12-byte DNS header.
    public static func serverFailure(for query: Data) -> Data? {
        guard let question = try? DNSMessage.parseQuestion(from: query) else {
            return invalidQueryServerFailure(for: query)
        }

        let queryFlags = readUInt16(query, at: 2)
        let recursionDesired = queryFlags & 0x0100
        let questionBytes = query[question.questionRange]

        var response = Data()
        appendUInt16(question.transactionID, to: &response)
        appendUInt16(0x8000 | recursionDesired | 0x0080 | 0x0002, to: &response)
        appendUInt16(1, to: &response)
        appendUInt16(0, to: &response)
        appendUInt16(0, to: &response)
        appendUInt16(0, to: &response)
        response.append(questionBytes)
        return response
    }

    private static func invalidQueryServerFailure(for query: Data) -> Data? {
        guard query.count >= 12 else {
            return nil
        }

        let queryFlags = readUInt16(query, at: 2)
        let recursionDesired = queryFlags & 0x0100

        var response = Data()
        appendUInt16(readUInt16(query, at: 0), to: &response)
        appendUInt16(0x8000 | recursionDesired | 0x0080 | 0x0002, to: &response)
        appendUInt16(0, to: &response)
        appendUInt16(0, to: &response)
        appendUInt16(0, to: &response)
        appendUInt16(0, to: &response)
        return response
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
