import Foundation
import LavaSecKit

/// Stateless byte-level DNS helpers used where the tunnel must preserve or validate an existing wire message.
public enum DNSWireMessage {
    package static func transactionID(in data: Data) -> UInt16? {
        let data = zeroBased(data)
        guard data.count >= 2 else {
            return nil
        }

        return (UInt16(data[0]) << 8) | UInt16(data[1])
    }

    package static func clearingTransactionID(in data: Data) -> Data {
        var copy = zeroBased(data)
        guard copy.count >= 2 else {
            return copy
        }

        copy[0] = 0
        copy[1] = 0
        return copy
    }

    /// Copies the query's transaction ID into a response, returning the response unchanged when either header is short.
    public static func replacingTransactionID(in response: Data, from query: Data) -> Data {
        var copy = zeroBased(response)
        let query = zeroBased(query)
        guard copy.count >= 2, query.count >= 2 else {
            return copy
        }

        copy[0] = query[0]
        copy[1] = query[1]
        return copy
    }

    package static func matchesTransactionID(in response: Data, query: Data) -> Bool {
        guard let responseTransactionID = transactionID(in: response),
              let queryTransactionID = transactionID(in: query)
        else {
            return false
        }

        return responseTransactionID == queryTransactionID
    }

    package static func firstResponseMatchingTransactionID(in responses: [Data], query: Data) -> Data? {
        responses.first { matchesTransactionID(in: $0, query: query) }
    }

    package static func isValidResponse(
        _ response: Data,
        matching query: Data,
        requiresMatchingTransactionID: Bool = true
    ) -> Bool {
        let response = zeroBased(response)
        let query = zeroBased(query)
        if requiresMatchingTransactionID, !matchesTransactionID(in: response, query: query) {
            return false
        }

        guard let queryMessage = DNSQuestionSectionMessage(data: query),
              let responseMessage = DNSQuestionSectionMessage(data: response)
        else {
            return false
        }

        return !queryMessage.isResponse
            && responseMessage.isResponse
            && queryMessage.opcode == responseMessage.opcode
            && queryMessage.questionCount == responseMessage.questionCount
            && queryMessage.questionBytes == responseMessage.questionBytes
    }

    package static func cappingAnswerTTLs(in response: Data, to maximumTTL: UInt32) -> Data {
        cappingCacheableTTLs(in: response, to: maximumTTL) ?? response
    }

    /// Traverses header-declared resource records, caps non-OPT TTLs in seconds, and returns `nil` if traversal is incomplete.
    public static func cappingCacheableTTLs(in response: Data, to maximumTTL: UInt32) -> Data? {
        let response = zeroBased(response)
        guard response.count >= 12 else {
            return nil
        }

        let questionCount = Int(readUInt16(response, at: 4))
        let answerCount = Int(readUInt16(response, at: 6))
        let authorityCount = Int(readUInt16(response, at: 8))
        let additionalCount = Int(readUInt16(response, at: 10))
        let resourceRecordCount = answerCount + authorityCount + additionalCount
        guard resourceRecordCount > 0 else {
            return response
        }

        var cursor = 12
        for _ in 0..<questionCount {
            guard skipName(in: response, cursor: &cursor), cursor + 4 <= response.count else {
                return nil
            }
            cursor += 4
        }

        var capped = response
        var didCapTTL = false
        for _ in 0..<resourceRecordCount {
            guard skipName(in: response, cursor: &cursor), cursor + 10 <= response.count else {
                return nil
            }

            let recordType = readUInt16(response, at: cursor)
            let ttlOffset = cursor + 4
            let ttl = readUInt32(response, at: ttlOffset)
            let dataLength = Int(readUInt16(response, at: cursor + 8))
            cursor += 10

            guard cursor + dataLength <= response.count else {
                return nil
            }

            if recordType != 41, ttl > maximumTTL {
                writeUInt32(maximumTTL, to: &capped, at: ttlOffset)
                didCapTTL = true
            }

            cursor += dataLength
        }

        return didCapTTL ? capped : response
    }

    /// Returns true only when all declared question and resource-record bytes parse and consume the entire message.
    public static func hasWellFormedResourceRecords(_ response: Data) -> Bool {
        let response = zeroBased(response)
        guard response.count >= 12 else {
            return false
        }

        let questionCount = Int(readUInt16(response, at: 4))
        let answerCount = Int(readUInt16(response, at: 6))
        let authorityCount = Int(readUInt16(response, at: 8))
        let additionalCount = Int(readUInt16(response, at: 10))
        let resourceRecordCount = answerCount + authorityCount + additionalCount

        var cursor = 12
        for _ in 0..<questionCount {
            guard skipName(in: response, cursor: &cursor), cursor + 4 <= response.count else {
                return false
            }
            cursor += 4
        }

        for _ in 0..<resourceRecordCount {
            guard skipName(in: response, cursor: &cursor), cursor + 10 <= response.count else {
                return false
            }

            let dataLength = Int(readUInt16(response, at: cursor + 8))
            cursor += 10

            guard cursor + dataLength <= response.count else {
                return false
            }

            cursor += dataLength
        }

        return cursor == response.count
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

    // Every parser below indexes by absolute integer offset, which is only valid
    // on a 0-indexed Data. Callers today pass copies (0-indexed), but a sliced
    // Data (non-zero startIndex) would silently misread or trap. Normalize once at
    // each public entry: a no-op (no copy) when already 0-based, a copy otherwise.
    private static func zeroBased(_ data: Data) -> Data {
        data.startIndex == 0 ? data : Data(data)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private struct DNSQuestionSectionMessage {
        let isResponse: Bool
        let opcode: UInt16
        let questionCount: UInt16
        let questionBytes: Data

        init?(data: Data) {
            guard data.count >= 12 else {
                return nil
            }

            let flags = Self.readUInt16(data, at: 2)
            let questionCount = Self.readUInt16(data, at: 4)
            guard questionCount > 0,
                  let questionRange = Self.questionSectionRange(in: data, questionCount: questionCount)
            else {
                return nil
            }

            self.isResponse = flags & 0x8000 != 0
            self.opcode = flags & 0x7800
            self.questionCount = questionCount
            self.questionBytes = data.subdata(in: questionRange)
        }

        private static func questionSectionRange(in data: Data, questionCount: UInt16) -> Range<Int>? {
            var cursor = 12

            for _ in 0..<Int(questionCount) {
                while true {
                    guard cursor < data.count else {
                        return nil
                    }

                    let length = data[cursor]
                    cursor += 1

                    if length == 0 {
                        break
                    }

                    guard length <= 63, cursor + Int(length) <= data.count else {
                        return nil
                    }

                    cursor += Int(length)
                }

                guard cursor + 4 <= data.count else {
                    return nil
                }

                cursor += 4
            }

            return 12..<cursor
        }

        private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
            (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        }
    }
}
