import Foundation
import LavaSecKit

/// A reply whose reachable alias graph cannot be safely inspected.
public enum DNSResponseAliasError: Error, Equatable, Sendable {
    /// A reachable alias target or the containing wire message is malformed.
    case malformed
    /// Alias resolution revisits a name in the same lookup path.
    case cycle
    /// The reply exceeds the bounded inspection budget.
    case limitExceeded
}

/// Reachable answer targets used by the existing domain-filter decision owner.
public enum DNSResponseAliases {
    /// Maximum distinct lookup nodes after the original question, across all alternatives.
    public static let maximumTargets = 16
    // At most 128 answer alias descriptors are retained; opaque RDATA stays in the response.
    private static let maximumAliasRecords = 128

    private struct Record {
        let owner: String
        let type: UInt16
        let range: Range<Int>
    }

    private struct Lookup: Hashable {
        let domain: String
        // ServiceMode targets need address resolution, not another SVCB lookup (RFC 9460 §3).
        let serviceType: UInt16?
    }

    /// Follows answer-section CNAMEs and the queried SVCB/HTTPS type only. Authority,
    /// additional records and unrelated owners do not contribute policy targets. Root
    /// SVCB targets retain RFC 9460 §2.5 semantics; cycles and unchecked suffixes are refused.
    public static func targets(in response: Data, for question: DNSQuestion) throws -> [String] {
        let response = response.startIndex == 0 ? response : Data(response)
        guard response.count <= 65_535 else { throw DNSResponseAliasError.limitExceeded }
        guard DNSWireMessage.hasWellFormedResourceRecords(response),
              response[2] & 0x80 != 0 else { throw DNSResponseAliasError.malformed }
        let serviceType = [UInt16(64), 65].contains(question.rawRecordType) ? question.rawRecordType : nil
        var cursor = 12
        for _ in 0..<read16(response, 4) {
            guard DNSWireMessage.skipName(in: response, cursor: &cursor), cursor + 4 <= response.count else {
                throw DNSResponseAliasError.malformed
            }
            cursor += 4
        }
        var records: [Record] = []
        for _ in 0..<read16(response, 6) {
            guard let owner = DNSWireMessage.readName(in: response, at: cursor), owner.end + 10 <= response.count else {
                throw DNSResponseAliasError.malformed
            }
            cursor = owner.end
            let type = read16(response, cursor)
            let recordClass = read16(response, cursor + 2)
            let start = cursor + 10
            let end = start + Int(read16(response, cursor + 8))
            guard end <= response.count else { throw DNSResponseAliasError.malformed }
            if recordClass == 1, type == 5 || type == serviceType,
               let spelling = owner.name, let normalized = try? DomainName.normalize(spelling) {
                guard records.count < maximumAliasRecords else { throw DNSResponseAliasError.limitExceeded }
                records.append(Record(owner: normalized, type: type, range: start..<end))
            }
            cursor = end
        }

        var visited: Set<Lookup> = []
        var path: Set<Lookup> = []
        var targets: [String] = []
        var targetNames: Set<String> = []
        let root = Lookup(domain: question.normalizedDomain, serviceType: serviceType)
        func visit(_ lookup: Lookup) throws {
            guard !path.contains(lookup) else { throw DNSResponseAliasError.cycle }
            guard !visited.contains(lookup) else { return }
            guard visited.count <= maximumTargets else { throw DNSResponseAliasError.limitExceeded }
            visited.insert(lookup)
            path.insert(lookup)
            defer { path.remove(lookup) }
            let owned = records.filter { $0.owner == lookup.domain }
            let cnames = owned.filter { $0.type == 5 }
            // A CNAME replaces the lookup name; service records at that owner cannot override it.
            let applicable = cnames.isEmpty ? owned.filter { $0.type == lookup.serviceType } : cnames
            var cnameTarget: String?
            for record in applicable {
                let isCNAME = record.type == 5
                let nameStart = record.range.lowerBound + (isCNAME ? 0 : 2)
                guard let decoded = DNSWireMessage.readName(in: response, at: nameStart,
                    limit: record.range.upperBound, allowsCompression: isCNAME),
                    let spelling = decoded.name,
                    !isCNAME || decoded.end == record.range.upperBound else {
                    throw DNSResponseAliasError.malformed
                }
                let priority = isCNAME ? 0 : read16(response, record.range.lowerBound)
                // AliasMode root means unavailable; ServiceMode root means this already-checked owner.
                if !isCNAME, spelling.isEmpty { continue }
                guard let target = try? DomainName.normalize(spelling) else { throw DNSResponseAliasError.malformed }
                if isCNAME {
                    if let cnameTarget, cnameTarget != target { throw DNSResponseAliasError.malformed }
                    cnameTarget = target
                }
                if targetNames.insert(target).inserted { targets.append(target) }
                try visit(Lookup(domain: target, serviceType: isCNAME || priority == 0 ? lookup.serviceType : nil))
            }
        }
        try visit(root)
        return targets
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
}
