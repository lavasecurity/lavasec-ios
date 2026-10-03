import Foundation

/// Removes the `ipv6hint` SvcParam from HTTPS (TYPE 65) and SVCB (TYPE 64) answers so a full-tunnel
/// chained client is never handed a v6 address for a path the data plane drops.
///
/// WHY THIS EXISTS (companion to `ChainedIPv6DNSPolicy`): a full-tunnel chained upstream drops every
/// outbound IPv6 packet (`ChainedOutboundPacketClassifier`, `INV-CHAIN-1`). `ChainedIPv6DNSPolicy`
/// already answers AAAA with NODATA so the client never attempts the dropped v6 path. But a service
/// binding record (HTTPS/SVCB) can seed the same doomed v6 attempt through its `ipv6hint` SvcParam
/// (RFC 9460 §7.3): the client reads the hint and races a v6 connection that is silently dropped,
/// stalling ~15-30 s until Happy-Eyeballs falls back to v4 — the exact symptom AAAA→NODATA fixed,
/// on a different record type.
///
/// The fix is SURGICAL, not NODATA. Unlike AAAA, an HTTPS/SVCB record also carries ALPN (h2/h3
/// discovery), `ipv4hint`, port, and ECH — all of which a v4-only site needs — so NODATA-ing the
/// whole record would break HTTP/3 upgrade and Encrypted Client Hello. Instead this strips ONLY the
/// `ipv6hint` SvcParam (SvcParamKey 6), leaving every other parameter intact. A record left with no
/// address hint resolves its TargetName's A record — the same graceful outcome as AAAA→NODATA.
///
/// COMPRESSION SAFETY (the load-bearing constraint). Removing an `ipv6hint` SvcParam SHRINKS the
/// record's RDATA and shifts every byte after it left. A DNS compression pointer stores an ABSOLUTE
/// offset and always points BACKWARD (RFC 1035 §4.1.4), so a pointer breaks iff it sits after a
/// deletion and targets an offset at or after that deletion. This transform is therefore applied
/// ONLY when it is provably offset-safe, and otherwise returns the response byte-for-byte unchanged
/// (`INV-DNS-1`: a response this cannot rewrite safely is forwarded exactly as the upstream sent it,
/// never corrupted). The proof rests on two checks done in one pass:
///   1. Every resource record is one of {A, AAAA, CNAME, SVCB, HTTPS, OPT}. Of these, only CNAME and
///      the SVCB/HTTPS TargetName carry a name in RDATA; A/AAAA/OPT carry none. So every compression
///      pointer in the message lives in an owner name or a CNAME's RDATA — both of which this walk
///      visits — and none can hide inside opaque RDATA this walk skips. Any other record type → bail.
///   2. Every compression-pointer target found is strictly before the earliest deleted byte. A
///      pointer whose target precedes every deletion still resolves to the same (unshifted) bytes.
/// A SVCB/HTTPS TargetName MUST be uncompressed (RFC 9460 §2.2); a pointer there → bail. The
/// conservative allowlist deliberately passes NS/SOA/MX/etc. through untouched — they are rare in a
/// positive HTTPS answer and not worth the type-specific RDATA name-parsing to rewrite safely.
///
/// DNSSEC: a response carrying RRSIGs bails to passthrough (RRSIG is not on the allowlist), so a
/// signature is never invalidated. When a hint IS stripped the DNSSEC Authenticated Data (AD) bit is
/// cleared — the answer is no longer what the resolver authenticated (RFC 6840 §5.8). A record whose
/// `mandatory` SvcParam names ipv6hint is left intact (removing the hint would break §8 consistency).
public enum DNSServiceBinding {
    private static let mandatoryKey: UInt16 = 0
    private static let ipv6HintKey: UInt16 = 6

    private static let typeA: UInt16 = 1
    private static let typeCNAME: UInt16 = 5
    private static let typeAAAA: UInt16 = 28
    private static let typeOPT: UInt16 = 41
    private static let typeSVCB: UInt16 = 64
    private static let typeHTTPS: UInt16 = 65

    /// `response` with the `ipv6hint` SvcParam removed from every HTTPS/SVCB answer, or `response`
    /// unchanged when there is nothing to strip or the rewrite is not provably compression-safe.
    public static func strippingIPv6Hints(from response: Data) -> Data {
        let bytes = [UInt8](response)
        guard bytes.count >= 12 else { return response }
        // QR must be 1: this only rewrites responses.
        guard bytes[2] & 0x80 != 0 else { return response }

        let questionCount = Int(readUInt16(bytes, at: 4))
        let recordCount = Int(readUInt16(bytes, at: 6))
            + Int(readUInt16(bytes, at: 8))
            + Int(readUInt16(bytes, at: 10))
        guard recordCount > 0 else { return response }

        var cursor = 12
        var pointerTargets: [Int] = []

        for _ in 0..<questionCount {
            guard let name = readName(bytes, at: cursor) else { return response }
            if let target = name.pointerTarget { pointerTargets.append(target) }
            cursor = name.end
            guard cursor + 4 <= bytes.count else { return response }
            cursor += 4
        }

        // (rdlengthFieldOffset, originalRDataLength, ipv6HintRanges) for each record that must be
        // rewritten. Records with nothing to strip are copied verbatim and never recorded here.
        var rewrites: [(rdlengthFieldOffset: Int, rdataLength: Int, ranges: [Range<Int>])] = []

        for _ in 0..<recordCount {
            guard let owner = readName(bytes, at: cursor) else { return response }
            if let target = owner.pointerTarget { pointerTargets.append(target) }
            cursor = owner.end
            guard cursor + 10 <= bytes.count else { return response }

            let type = readUInt16(bytes, at: cursor)
            let rdlength = Int(readUInt16(bytes, at: cursor + 8))
            let rdlengthFieldOffset = cursor + 8
            let rdataStart = cursor + 10
            guard rdataStart + rdlength <= bytes.count else { return response }

            switch type {
            case typeA, typeAAAA, typeOPT:
                break // RDATA carries no names.
            case typeCNAME:
                // RDATA is exactly one <domain-name>, which MAY be compressed — capture its target.
                guard let name = readName(bytes, at: rdataStart),
                      name.end == rdataStart + rdlength
                else { return response }
                if let target = name.pointerTarget { pointerTargets.append(target) }
            case typeSVCB, typeHTTPS:
                guard let ranges = ipv6HintRanges(
                    in: bytes, rdataStart: rdataStart, rdataLength: rdlength
                ) else { return response }
                if !ranges.isEmpty {
                    rewrites.append((rdlengthFieldOffset, rdlength, ranges))
                }
            default:
                // A name-bearing type this walk cannot vouch for — leave the whole message alone.
                return response
            }

            cursor = rdataStart + rdlength
        }

        // The counts and the sections must agree exactly; leftover bytes mean a rewrite would guess.
        guard cursor == bytes.count else { return response }

        let deletions = rewrites.flatMap(\.ranges).sorted { $0.lowerBound < $1.lowerBound }
        guard let earliestDeletion = deletions.first?.lowerBound else { return response }

        // Compression safety: no pointer may target the shifted region.
        guard pointerTargets.allSatisfy({ $0 < earliestDeletion }) else { return response }

        var out = bytes
        for rewrite in rewrites {
            let removed = rewrite.ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
            let newLength = rewrite.rdataLength - removed
            out[rewrite.rdlengthFieldOffset] = UInt8((newLength >> 8) & 0xFF)
            out[rewrite.rdlengthFieldOffset + 1] = UInt8(newLength & 0xFF)
        }
        // We just modified the answer, so it is no longer what the upstream resolver authenticated.
        // Clear the DNSSEC Authenticated Data bit (flags low byte, bit 5) so a security-aware stub is
        // not told the rewritten record is DNSSEC-authenticated (RFC 6840 §5.8). A response that
        // carried actual RRSIGs never reaches here — an RRSIG record is not on the allowlist, so it
        // bails to passthrough above — but AD can be set with no RRSIG present (the common DO=0 case).
        out[3] &= 0xDF

        var result = [UInt8]()
        result.reserveCapacity(out.count)
        var copyFrom = 0
        for range in deletions {
            if range.lowerBound > copyFrom {
                result.append(contentsOf: out[copyFrom..<range.lowerBound])
            }
            copyFrom = range.upperBound
        }
        if copyFrom < out.count {
            result.append(contentsOf: out[copyFrom..<out.count])
        }
        return Data(result)
    }

    /// The byte ranges of every `ipv6hint` SvcParam (key + length + value) inside one SVCB/HTTPS
    /// RDATA, or `nil` if the RDATA does not parse as a well-formed service binding record. An empty
    /// array means a valid record this must not strip: either it has no `ipv6hint`, or its
    /// `mandatory` SvcParam (key 0) lists ipv6hint — removing the hint would leave `mandatory`
    /// referencing an absent key, which RFC 9460 §8 says a client MUST reject (losing the ALPN/ECH
    /// this transform exists to keep), so that record is passed through untouched.
    private static func ipv6HintRanges(
        in bytes: [UInt8], rdataStart: Int, rdataLength: Int
    ) -> [Range<Int>]? {
        let rdataEnd = rdataStart + rdataLength
        // SvcPriority (2) + TargetName (>= 1 for the root label).
        guard rdataStart + 2 <= rdataEnd else { return nil }
        let priority = readUInt16(bytes, at: rdataStart)

        // TargetName MUST be uncompressed in a service binding record (RFC 9460 §2.2).
        guard let target = readName(bytes, at: rdataStart + 2),
              target.pointerTarget == nil,
              target.end <= rdataEnd
        else { return nil }
        var cursor = target.end

        // AliasMode (priority 0) carries no SvcParams; anything after the TargetName is malformed.
        if priority == 0 {
            return cursor == rdataEnd ? [] : nil
        }

        var ranges: [Range<Int>] = []
        var mandatoryListsIPv6Hint = false
        var previousKey = -1
        while cursor < rdataEnd {
            guard cursor + 4 <= rdataEnd else { return nil }
            let key = Int(readUInt16(bytes, at: cursor))
            let valueLength = Int(readUInt16(bytes, at: cursor + 2))
            let valueStart = cursor + 4
            guard valueStart + valueLength <= rdataEnd else { return nil }
            // SvcParams appear in strictly increasing key order (RFC 9460 §2.2).
            guard key > previousKey else { return nil }
            previousKey = key

            if key == Int(mandatoryKey) {
                // The mandatory value is a list of 2-byte SvcParamKeys; if it names ipv6hint, this
                // record must not be stripped (see the doc comment). A malformed (odd-length) list
                // is a bad record — bail the whole message.
                guard valueLength % 2 == 0 else { return nil }
                var scan = valueStart
                while scan < valueStart + valueLength {
                    if readUInt16(bytes, at: scan) == ipv6HintKey { mandatoryListsIPv6Hint = true }
                    scan += 2
                }
            } else if key == Int(ipv6HintKey) {
                ranges.append(cursor..<(valueStart + valueLength))
            }
            cursor = valueStart + valueLength
        }
        guard cursor == rdataEnd else { return nil }
        return mandatoryListsIPv6Hint ? [] : ranges
    }

    /// Walks a wire-format name from `offset`, returning where it ends and the target of its
    /// compression pointer if it ends in one (RFC 1035 §4.1.4). Does not follow the pointer — only
    /// the first-level target is needed for the offset-safety check. `nil` on a malformed name.
    private static func readName(_ bytes: [UInt8], at offset: Int) -> (end: Int, pointerTarget: Int?)? {
        var cursor = offset
        while cursor < bytes.count {
            let length = bytes[cursor]
            if length == 0 {
                return (cursor + 1, nil)
            }
            if length & 0xC0 == 0xC0 {
                guard cursor + 2 <= bytes.count else { return nil }
                let target = (Int(length & 0x3F) << 8) | Int(bytes[cursor + 1])
                return (cursor + 2, target)
            }
            guard length & 0xC0 == 0, length <= 63 else { return nil }
            let next = cursor + 1 + Int(length)
            guard next <= bytes.count else { return nil }
            cursor = next
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
}
