import Foundation

public enum DNSResolverSmokeProbe {
    public static let defaultDomain = "example.com"

    public static func query(
        transactionID: UInt16 = 0x4C56,
        domain: String = defaultDomain,
        recordType: UInt16 = DNSRecordType.a.rawValue
    ) -> Data {
        var data = Data()
        appendUInt16(transactionID, to: &data)
        appendUInt16(0x0100, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)

        for label in domain.split(separator: ".") {
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: label.utf8)
        }

        data.append(0)
        appendUInt16(recordType, to: &data)
        appendUInt16(1, to: &data)
        return data
    }

    public static func acceptsResolutionResponse(_ response: Data?, matching query: Data) -> Bool {
        guard let response,
              response.count >= 12,
              query.count >= 12,
              readUInt16(response, at: 0) == readUInt16(query, at: 0)
        else {
            return false
        }

        let responseFlags = readUInt16(response, at: 2)
        let isResponse = responseFlags & 0x8000 != 0
        let responseCode = responseFlags & 0x000F
        let answerCount = readUInt16(response, at: 6)
        guard isResponse, responseCode == 0, answerCount > 0 else {
            return false
        }

        guard let queryQuestionRange = questionSectionRange(in: query),
              let responseQuestionRange = questionSectionRange(in: response)
        else {
            return false
        }

        return query[queryQuestionRange] == response[responseQuestionRange]
    }

    private static func questionSectionRange(in data: Data) -> Range<Int>? {
        guard data.count >= 12, readUInt16(data, at: 4) == 1 else {
            return nil
        }

        var cursor = 12
        while cursor < data.count {
            let length = Int(data[cursor])
            cursor += 1

            if length == 0 {
                guard cursor + 4 <= data.count else {
                    return nil
                }

                return 12..<(cursor + 4)
            }

            guard length & 0xC0 == 0,
                  length <= 63,
                  cursor + length <= data.count
            else {
                return nil
            }

            cursor += length
        }

        return nil
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
