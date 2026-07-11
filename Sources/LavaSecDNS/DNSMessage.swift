import Foundation
import LavaSecKit

/// DNS resource-record types exchanged with the packet-tunnel client, encoded by their UInt16 wire code.
public enum DNSRecordType: UInt16, Codable, Sendable {
    /// IPv4 host-address records (TYPE 1).
    case a = 1
    /// Arbitrary text records (TYPE 16).
    case txt = 16
    /// IPv6 host-address records (TYPE 28).
    case aaaa = 28
    /// Service-location records (TYPE 33).
    case srv = 33
    /// General service-binding records (TYPE 64).
    case svcb = 64
    /// HTTPS service-binding records (TYPE 65).
    case https = 65
    /// Sentinel used when a wire TYPE code is unsupported; construction normalizes its public raw value to zero.
    case unknown = 0

    /// Maps unsupported UInt16 wire codes to `.unknown`; unsupported input codes are intentionally not preserved as `rawValue`.
    public init(rawValue: UInt16) {
        switch rawValue {
        case 1:
            self = .a
        case 16:
            self = .txt
        case 28:
            self = .aaaa
        case 33:
            self = .srv
        case 64:
            self = .svcb
        case 65:
            self = .https
        default:
            self = .unknown
        }
    }
}

/// The validated single-question portion of a DNS query returned across the tunnel-module boundary.
public struct DNSQuestion: Equatable, Sendable {
    package let transactionID: UInt16
    /// The domain spelling decoded from the DNS question before normalization.
    public let domain: String
    /// The canonical domain used for filtering and policy comparisons.
    public let normalizedDomain: String
    package let recordType: DNSRecordType
    internal let rawRecordType: UInt16
    internal let questionRange: Range<Int>

    internal init(
        transactionID: UInt16,
        domain: String,
        normalizedDomain: String? = nil,
        recordType: DNSRecordType,
        rawRecordType: UInt16,
        questionRange: Range<Int>
    ) {
        self.transactionID = transactionID
        self.domain = domain
        self.normalizedDomain = normalizedDomain ?? ((try? DomainName.normalize(domain)) ?? domain)
        self.recordType = recordType
        self.rawRecordType = rawRecordType
        self.questionRange = questionRange
    }
}

internal enum DNSMessageError: Error, Equatable, Sendable {
    case packetTooShort
    case notAQuery
    case noQuestion
    case unsupportedQuestionCount
    case malformedQuestion
    case compressedQuestionName
    case invalidDomain
}

/// Parses client DNS queries and synthesizes wire-format responses for locally blocked domains.
public enum DNSMessage {
    /// Validates and parses exactly one uncompressed question, throwing when the packet or domain is malformed.
    public static func parseQuestion(from data: Data) throws -> DNSQuestion {
        guard data.count >= 12 else {
            throw DNSMessageError.packetTooShort
        }

        let transactionID = readUInt16(data, at: 0)
        let flags = readUInt16(data, at: 2)
        guard flags & 0x8000 == 0 else {
            throw DNSMessageError.notAQuery
        }

        let questionCount = readUInt16(data, at: 4)
        guard questionCount > 0 else {
            throw DNSMessageError.noQuestion
        }
        guard questionCount == 1 else {
            throw DNSMessageError.unsupportedQuestionCount
        }

        var cursor = 12
        var labels: [String] = []

        while true {
            guard cursor < data.count else {
                throw DNSMessageError.malformedQuestion
            }

            let length = Int(data[cursor])
            cursor += 1

            if length == 0 {
                break
            }

            if length & 0xC0 == 0xC0 {
                throw DNSMessageError.compressedQuestionName
            }

            guard length <= 63, cursor + length <= data.count else {
                throw DNSMessageError.malformedQuestion
            }

            let labelData = data[cursor..<(cursor + length)]
            guard let label = String(data: labelData, encoding: .utf8) else {
                throw DNSMessageError.malformedQuestion
            }

            labels.append(label)
            cursor += length
        }

        guard cursor + 4 <= data.count else {
            throw DNSMessageError.malformedQuestion
        }

        let rawType = readUInt16(data, at: cursor)
        let domain = labels.joined(separator: ".")
        guard let normalizedDomain = try? DomainName.normalize(domain) else {
            throw DNSMessageError.invalidDomain
        }

        return DNSQuestion(
            transactionID: transactionID,
            domain: domain,
            normalizedDomain: normalizedDomain,
            recordType: DNSRecordType(rawValue: rawType),
            rawRecordType: rawType,
            questionRange: 12..<(cursor + 4)
        )
    }

    /// Builds a blocked response from a raw query; `ttl` is written in seconds and malformed queries throw.
    public static func blockedResponse(for query: Data, ttl: UInt32 = 60) throws -> Data {
        let question = try parseQuestion(from: query)
        return try blockedResponse(for: query, question: question, ttl: ttl)
    }

    /// Builds a blocked response using a previously validated question, avoiding a second parse on the packet path.
    public static func blockedResponse(for query: Data, question: DNSQuestion, ttl: UInt32 = 60) throws -> Data {
        guard query.count >= 12,
              question.questionRange.lowerBound >= query.startIndex,
              question.questionRange.upperBound <= query.endIndex
        else {
            throw DNSMessageError.malformedQuestion
        }

        let questionBytes = query[question.questionRange]
        var response = Data()
        // Header (12) + echoed question + one compressed answer (2-byte name ptr +
        // 10 fixed RR bytes + up to a 16-byte AAAA address). Reserving up front
        // avoids the intermediate Data reallocations under heavy blocked-query load.
        response.reserveCapacity(12 + questionBytes.count + 28)

        appendUInt16(question.transactionID, to: &response)
        appendUInt16(responseFlags(forQuery: query), to: &response)
        appendUInt16(1, to: &response)

        let answerAddress: Data?
        switch question.recordType {
        case .a:
            answerAddress = Data([0, 0, 0, 0])
        case .aaaa:
            answerAddress = Data(repeating: 0, count: 16)
        case .txt, .srv, .svcb, .https, .unknown:
            answerAddress = nil
        }

        appendUInt16(answerAddress == nil ? 0 : 1, to: &response)
        appendUInt16(0, to: &response)
        appendUInt16(0, to: &response)
        response.append(questionBytes)

        if let answerAddress {
            response.append(contentsOf: [0xC0, 0x0C])
            appendUInt16(question.rawRecordType, to: &response)
            appendUInt16(1, to: &response)
            appendUInt32(ttl, to: &response)
            appendUInt16(UInt16(answerAddress.count), to: &response)
            response.append(answerAddress)
        }

        return response
    }

    private static func responseFlags(forQuery data: Data) -> UInt16 {
        let queryFlags = readUInt16(data, at: 2)
        let recursionDesired = queryFlags & 0x0100
        return 0x8000 | recursionDesired | 0x0080
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
