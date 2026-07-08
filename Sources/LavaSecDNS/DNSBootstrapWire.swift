// Bootstrap-path DNS wire helpers: answer-address extraction + response
// synthesis, extracted verbatim from PacketTunnelProvider.swift (Phase E1).
import Foundation
import LavaSecKit

/// Extracts bootstrap A/AAAA addresses from a DNS response — how encrypted-resolver
/// hostnames (DoH/DoT/DoQ) get resolved over plain bootstrap DNS.
///
/// Trust gate: the response must validate against the issuing query (transaction
/// ID + question, `DNSWireMessage.isValidResponse`) before ANY answer is read, and
/// each answer must match the requested record type, be class IN, and carry an
/// exactly-sized address payload. Structurally malformed answers stop extraction
/// (never trusting bytes past the damage); non-matching answers are skipped;
/// duplicate addresses are dropped.
public enum DNSBootstrapAddressExtractor {
    /// Returns the unique, well-formed `recordType` addresses found in `response`'s
    /// answer section, in answer order. Returns `[]` when the response is missing,
    /// shorter than a DNS header, or fails validation against `query`; returns the
    /// addresses collected so far when an answer is structurally malformed.
    public static func addresses(from response: Data?, matching query: Data, recordType: DNSRecordType) -> [String] {
        guard let response,
              response.count >= 12,
              DNSWireMessage.isValidResponse(response, matching: query)
        else {
            return []
        }

        let questionCount = Int(readUInt16(response, at: 4))
        let answerCount = Int(readUInt16(response, at: 6))
        var cursor = 12

        for _ in 0..<questionCount {
            guard skipName(in: response, cursor: &cursor), cursor + 4 <= response.count else {
                return []
            }
            cursor += 4
        }

        var addresses: [String] = []
        var seenAddresses = Set<String>()
        for _ in 0..<answerCount {
            guard skipName(in: response, cursor: &cursor), cursor + 10 <= response.count else {
                return addresses
            }

            let answerType = readUInt16(response, at: cursor)
            let answerClass = readUInt16(response, at: cursor + 2)
            let dataLength = Int(readUInt16(response, at: cursor + 8))
            cursor += 10

            guard cursor + dataLength <= response.count else {
                return addresses
            }

            defer {
                cursor += dataLength
            }

            guard answerType == recordType.rawValue,
                  answerClass == 1,
                  let address = addressString(from: response[cursor..<(cursor + dataLength)], recordType: recordType),
                  seenAddresses.insert(address).inserted
            else {
                continue
            }

            addresses.append(address)
        }

        return addresses
    }

    private static func addressString(from bytes: Data.SubSequence, recordType: DNSRecordType) -> String? {
        let family: Int32
        let expectedByteCount: Int
        let bufferLength: Int32

        switch recordType {
        case .a:
            family = AF_INET
            expectedByteCount = 4
            bufferLength = INET_ADDRSTRLEN
        case .aaaa:
            family = AF_INET6
            expectedByteCount = 16
            bufferLength = INET6_ADDRSTRLEN
        case .txt, .srv, .svcb, .https, .unknown:
            return nil
        }

        guard bytes.count == expectedByteCount else {
            return nil
        }

        var rawBytes = Array(bytes)
        var buffer = [CChar](repeating: 0, count: Int(bufferLength))
        let converted = rawBytes.withUnsafeMutableBytes { pointer in
            inet_ntop(family, pointer.baseAddress, &buffer, socklen_t(bufferLength))
        }
        guard converted != nil else {
            return nil
        }

        let terminatedLength = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<terminatedLength].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func skipName(in data: Data, cursor: inout Int) -> Bool {
        var localCursor = cursor
        while localCursor < data.count {
            let length = data[localCursor]
            localCursor += 1

            if length == 0 {
                cursor = localCursor
                return true
            }

            if length & 0xC0 == 0xC0 {
                guard localCursor < data.count else {
                    return false
                }
                let pointer = (Int(length & 0x3F) << 8) | Int(data[localCursor])
                localCursor += 1
                guard isValidCompressedNameTarget(pointer, in: data) else {
                    return false
                }
                cursor = localCursor
                return true
            }

            guard length & 0xC0 == 0, localCursor + Int(length) <= data.count else {
                return false
            }

            localCursor += Int(length)
        }

        return false
    }

    private static func isValidCompressedNameTarget(_ offset: Int, in data: Data) -> Bool {
        guard offset >= 0, offset < data.count else {
            return false
        }

        var cursor = offset
        var visitedOffsets: Set<Int> = []
        while cursor < data.count {
            guard visitedOffsets.insert(cursor).inserted else {
                return false
            }

            let length = data[cursor]
            cursor += 1

            if length == 0 {
                return true
            }

            if length & 0xC0 == 0xC0 {
                guard cursor < data.count else {
                    return false
                }
                let pointer = (Int(length & 0x3F) << 8) | Int(data[cursor])
                guard pointer >= 0, pointer < data.count else {
                    return false
                }
                cursor = pointer
                continue
            }

            guard length & 0xC0 == 0, cursor + Int(length) <= data.count else {
                return false
            }

            cursor += Int(length)
        }

        return false
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
}

/// Synthesizes answers for queries that target an encrypted resolver's OWN
/// hostname, from the preset's pinned bootstrap server lists — so looking the
/// resolver up never has to recurse through the (possibly not-yet-reachable)
/// resolver itself. The TTL is deliberately short (default 60 s) so real
/// resolution takes over as soon as the encrypted path is up.
public enum DNSBootstrapResponseFactory {
    /// Answers `query`/`question` for a DoH endpoint's hostname with its pinned
    /// bootstrap addresses: A questions get the IPv4 list, AAAA the IPv6 list,
    /// any other type a zero-answer response; unparseable bootstrap address
    /// strings are silently skipped. Transaction ID and question are echoed and
    /// RD is copied from the query, so `question` MUST be
    /// `DNSMessage.parseQuestion` output for this same `query`.
    public static func response(
        for query: Data,
        question: DNSQuestion,
        endpoint: DNSOverHTTPSEndpoint,
        ttl: UInt32 = 60
    ) -> Data? {
        response(
            for: query,
            question: question,
            ipv4Servers: endpoint.bootstrapIPv4Servers,
            ipv6Servers: endpoint.bootstrapIPv6Servers,
            ttl: ttl
        )
    }

    /// DoQ-endpoint overload of `response(for:question:endpoint:ttl:)` — same
    /// contract, reading the QUIC endpoint's pinned bootstrap lists.
    public static func response(
        for query: Data,
        question: DNSQuestion,
        endpoint: DNSOverQUICEndpoint,
        ttl: UInt32 = 60
    ) -> Data? {
        response(
            for: query,
            question: question,
            ipv4Servers: endpoint.bootstrapIPv4Servers,
            ipv6Servers: endpoint.bootstrapIPv6Servers,
            ttl: ttl
        )
    }

    /// DoT-endpoint overload of `response(for:question:endpoint:ttl:)` — same
    /// contract, reading the TLS endpoint's pinned bootstrap lists.
    public static func response(
        for query: Data,
        question: DNSQuestion,
        endpoint: DNSOverTLSEndpoint,
        ttl: UInt32 = 60
    ) -> Data? {
        response(
            for: query,
            question: question,
            ipv4Servers: endpoint.bootstrapIPv4Servers,
            ipv6Servers: endpoint.bootstrapIPv6Servers,
            ttl: ttl
        )
    }

    private static func response(
        for query: Data,
        question: DNSQuestion,
        ipv4Servers: [String],
        ipv6Servers: [String],
        ttl: UInt32
    ) -> Data? {
        let answerAddresses: [Data]
        switch question.recordType {
        case .a:
            answerAddresses = ipv4Servers.compactMap {
                addressData($0, family: AF_INET, byteCount: 4)
            }
        case .aaaa:
            answerAddresses = ipv6Servers.compactMap {
                addressData($0, family: AF_INET6, byteCount: 16)
            }
        case .txt, .srv, .svcb, .https, .unknown:
            answerAddresses = []
        }

        let queryFlags = readUInt16(query, at: 2)
        let recursionDesired = queryFlags & 0x0100
        let questionBytes = query[question.questionRange]

        var response = Data()
        appendUInt16(question.transactionID, to: &response)
        appendUInt16(0x8000 | recursionDesired | 0x0080, to: &response)
        appendUInt16(1, to: &response)
        appendUInt16(UInt16(answerAddresses.count), to: &response)
        appendUInt16(0, to: &response)
        appendUInt16(0, to: &response)
        response.append(questionBytes)

        for answerAddress in answerAddresses {
            response.append(contentsOf: [0xC0, 0x0C])
            appendUInt16(question.rawRecordType, to: &response)
            appendUInt16(1, to: &response)
            appendUInt32(ttl, to: &response)
            appendUInt16(UInt16(answerAddress.count), to: &response)
            response.append(answerAddress)
        }

        return response
    }

    private static func addressData(_ address: String, family: Int32, byteCount: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let result = bytes.withUnsafeMutableBytes { rawBytes in
            inet_pton(family, address, rawBytes.baseAddress)
        }

        guard result == 1 else {
            return nil
        }

        return Data(bytes)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
