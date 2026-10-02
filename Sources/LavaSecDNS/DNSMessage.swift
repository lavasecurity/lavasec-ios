import Foundation
import LavaSecKit

/// Response shapes for a locally blocked name; nondefault modes are explicit compatibility comparisons.
public enum DNSBlockedAddressMode: String, Sendable {
    /// Existing behavior: unspecified IPv4 and IPv6 addresses.
    case unspecified
    /// Loopback IPv4 and IPv6 addresses, available for explicit compatibility comparisons.
    case loopback
    /// Name error for every question type, with an SOA for negative caching.
    case nxdomain
    /// Successful empty answer for every question type, with an SOA for negative caching.
    case nodata
    /// Reachable public addresses for the explicit QA sink-address comparison, not a production block response.
    case cloudflare

    /// Keeps real-address redirection limited to the owner's two explicit test names.
    /// Negative/loopback modes never contact a public sink and retain their existing scope.
    public func limitedToQAProbeDomain(_ domain: String) -> Self {
        guard self == .cloudflare else { return self }
        return ["www.oracle.com", "www.linkedin.com"].contains(domain) ? self : .unspecified
    }
}

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
        recordType: DNSRecordType,
        rawRecordType: UInt16,
        questionRange: Range<Int>
    ) throws {
        guard let normalizedDomain = try? DomainName.normalize(domain) else {
            throw DNSMessageError.invalidDomain
        }
        self.transactionID = transactionID
        self.domain = domain
        self.normalizedDomain = normalizedDomain
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
    /// A fixed diagnostic category for a failed question parse, with no query content or error text.
    /// Unknown error types stay unknown rather than forwarding a potentially sensitive description.
    public static func questionParseFailureCategory(_ error: any Error) -> String {
        guard let failure = error as? DNSMessageError else { return "unknown" }
        switch failure {
        case .packetTooShort: return "packet-too-short"
        case .notAQuery: return "not-a-query"
        case .noQuestion: return "no-question"
        case .unsupportedQuestionCount: return "unsupported-question-count"
        case .malformedQuestion: return "malformed-question"
        case .compressedQuestionName: return "compressed-question-name"
        case .invalidDomain: return "invalid-domain"
        }
    }

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
        return try DNSQuestion(
            transactionID: transactionID,
            domain: domain,
            recordType: DNSRecordType(rawValue: rawType),
            rawRecordType: rawType,
            questionRange: 12..<(cursor + 4)
        )
    }

    /// Builds a blocked response from a raw query; `ttl` is written in seconds and malformed queries throw.
    public static func blockedResponse(for query: Data, ttl: UInt32 = 60, addressMode: DNSBlockedAddressMode = .unspecified) throws -> Data {
        let question = try parseQuestion(from: query)
        return try blockedResponse(for: query, question: question, ttl: ttl, addressMode: addressMode)
    }

    /// Builds a blocked response using a previously validated question, avoiding a second parse on the packet path.
    public static func blockedResponse(for query: Data, question: DNSQuestion, ttl: UInt32 = 60, addressMode: DNSBlockedAddressMode = .unspecified) throws -> Data {
        guard query.count >= 12,
              question.questionRange.lowerBound >= query.startIndex,
              question.questionRange.upperBound <= query.endIndex
        else {
            throw DNSMessageError.malformedQuestion
        }

        if addressMode == .nxdomain || addressMode == .nodata {
            return negativeBlockedResponse(
                for: query, question: question, ttl: ttl, nameError: addressMode == .nxdomain)
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
            if addressMode == .cloudflare {
                answerAddress = Data([1, 1, 1, 1])
            } else {
                answerAddress = addressMode == .loopback ? Data([127, 0, 0, 1]) : Data([0, 0, 0, 0])
            }
        case .aaaa:
            if addressMode == .cloudflare {
                answerAddress = Data([0x26, 0x06, 0x47, 0x00, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11])
            } else {
                answerAddress = Data(repeating: 0, count: 15) + Data([addressMode == .loopback ? 1 : 0])
            }
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

    /// Synthesizes a local policy negative, not an authenticated upstream answer. RFC 2308
    /// type 2 negatives carry an SOA without NS records. The parent of the queried name is
    /// the synthetic policy zone; its SOA TTL and MINIMUM both bound negative caching to `ttl`.
    private static func negativeBlockedResponse(
        for query: Data, question: DNSQuestion, ttl: UInt32, nameError: Bool
    ) -> Data {
        var response = Data()
        appendUInt16(question.transactionID, to: &response)
        // Authoritative local policy, recursion available as usual, no DNSSEC AD assertion.
        appendUInt16(responseFlags(forQuery: query) | 0x0400 | (nameError ? 3 : 0), to: &response)
        appendUInt16(1, to: &response) // QDCOUNT
        appendUInt16(0, to: &response) // ANCOUNT
        appendUInt16(1, to: &response) // NSCOUNT: SOA only
        appendUInt16(0, to: &response) // ARCOUNT
        response.append(query[question.questionRange])

        let parentOffset = question.questionRange.lowerBound + 1 + Int(query[question.questionRange.lowerBound])
        appendUInt16(0xC000 | UInt16(parentOffset), to: &response)
        appendUInt16(6, to: &response) // SOA
        appendUInt16(1, to: &response) // IN
        appendUInt32(ttl, to: &response)
        var soa = Data()
        // Reserved names identify synthetic policy data without creating real DNS dependencies.
        for name in ["lava.invalid", "hostmaster.lava.invalid"] {
            for label in name.split(separator: ".") {
                soa.append(UInt8(label.utf8.count))
                soa.append(contentsOf: label.utf8)
            }
            soa.append(0)
        }
        for value: UInt32 in [1, 3600, 600, 86400, ttl] {
            appendUInt32(value, to: &soa)
        }
        appendUInt16(UInt16(soa.count), to: &response)
        response.append(soa)
        return response
    }

    /// Builds a NODATA answer — a NOERROR response that echoes the question with **zero** answer
    /// records — from a previously validated question.
    ///
    /// Used to suppress a record type the tunnel cannot carry. While chained, the data path drops
    /// every outbound IPv6 packet (`ChainedOutboundPacketClassifier`, `INV-CHAIN-1`), so an AAAA
    /// answer would hand the client a v6 address for a path that is silently dropped — the client
    /// tries v6 first and stalls until Happy-Eyeballs falls back to v4. A NODATA response instead
    /// tells the client the name exists but has no record of that type, so it uses the type the
    /// tunnel does carry (A) immediately. Distinct from ``blockedResponse``, which returns a null
    /// address (`0.0.0.0` / `::`) as a *positive* answer to a blocked domain; NODATA is the honest
    /// "no such record" answer for a name that is otherwise allowed. Filtering has already run at
    /// the call site, so declining a record here does not admit a blocked domain (`INV-DNS-1`).
    public static func emptyResponse(for query: Data, question: DNSQuestion) throws -> Data {
        guard query.count >= 12,
              question.questionRange.lowerBound >= query.startIndex,
              question.questionRange.upperBound <= query.endIndex
        else {
            throw DNSMessageError.malformedQuestion
        }

        let questionBytes = query[question.questionRange]
        var response = Data()
        response.reserveCapacity(12 + questionBytes.count)

        appendUInt16(question.transactionID, to: &response)
        appendUInt16(responseFlags(forQuery: query), to: &response)
        appendUInt16(1, to: &response) // QDCOUNT
        appendUInt16(0, to: &response) // ANCOUNT — NODATA: NOERROR with no answers
        appendUInt16(0, to: &response) // NSCOUNT
        appendUInt16(0, to: &response) // ARCOUNT
        response.append(questionBytes)
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
