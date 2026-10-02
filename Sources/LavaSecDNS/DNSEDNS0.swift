import Foundation

/// EDNS0 (RFC 6891) advertisement for queries forwarded through the chained tunnel (S6).
///
/// The tunnelled plain-DNS transport advertises a UDP payload size so the upstream answers
/// with TC instead of relying on IP fragmentation for large responses: fragments are widely
/// filtered or dropped in real networks and nothing in the chained path repairs that loss,
/// so an over-large response degrades to a silent timeout — strictly worse than the
/// explicit TC the advertisement converts it into (phase-3 plan, resolved decision 3).
///
/// THE ADVERTISEMENT ONLY EVER LOWERS. An earlier version reasoned that the size is ours
/// rather than the client's — the upstream answers to the transport's own socket, and the
/// client's stub never sees that datagram — and therefore raised a client's 512 to the cap.
/// That is one frame too shallow: the answer is RELAYED to the stub afterwards, as a UDP
/// datagram written into the utun, so a stub that advertised 512 and sized its receive
/// buffer to match can be handed 1232 bytes it never agreed to accept. Where it previously
/// got a clean TC (and, in DNS-only mode, a TCP retry), it would get a truncated read or a
/// silent drop — a worse failure than the one this mitigation exists to soften (Codex,
/// PR #511).
///
/// So the rule is: never advertise more than the client itself asked for, and never more
/// than the cap. A client OPT is lowered to the cap when it is larger (the fragmentation
/// case this exists for, and the common one — iOS stubs advertise 1232 or 4096) and left
/// alone when it is smaller. A query with NO OPT keeps none: absence means the classic
/// 512-byte limit, and introducing an advertisement would promise the upstream a size the
/// client never offered.
///
/// The DO bit and options ride along untouched — they are the client's query semantics, not
/// ours to invent or discard.
public enum DNSEDNS0 {
    /// The advertised UDP payload size for tunnel-carried queries: the DNS-flag-day 1232,
    /// which fits under every representable chained MTU — the configuration boundary
    /// refuses sub-1280, and 1280 − 20 (IPv4) − 8 (UDP) = 1252 ≥ 1232 — so no MTU-derived
    /// sizing is needed, and none is done.
    public static let tunnelAdvertisedPayloadBytes: UInt16 = 1232

    /// `query` with its OPT advertisement lowered to at most `payloadBytes`, or `query`
    /// unchanged when there is nothing to lower or it cannot be done safely.
    ///
    /// Unchanged is the deliberate degraded answer, not an error: a query this function
    /// declines to touch is forwarded exactly as the pre-S6 path would have forwarded it,
    /// and an over-large answer for it still fails closed downstream on the TC/timeout
    /// path. The declined shapes:
    /// - a query with no OPT, or one already advertising `payloadBytes` or less — the
    ///   client's own limit governs and this function never raises it (see the type's note);
    /// - not a query, or a header/section walk that does not parse — rewriting bytes this
    ///   function does not understand risks producing a message the upstream reads
    ///   differently than the client wrote it;
    /// - more than one OPT — protocol-illegal input this function will not compound;
    /// - a non-OPT additional section with no OPT — nothing to lower, and this function
    ///   deliberately introduces no record of its own;
    /// - anything TSIG- or SIG(0)-authenticated, whose MAC covers the bytes this would
    ///   rewrite.
    public static func cappingAdvertisedPayload(
        in query: Data, to payloadBytes: UInt16
    ) -> Data {
        var bytes = [UInt8](query)
        guard bytes.count >= 12 else { return query }
        // QR must be 0: this operates on queries only.
        guard bytes[2] & 0x80 == 0 else { return query }
        let qdcount = Int(bytes[4]) << 8 | Int(bytes[5])
        let ancount = Int(bytes[6]) << 8 | Int(bytes[7])
        let nscount = Int(bytes[8]) << 8 | Int(bytes[9])
        let arcount = Int(bytes[10]) << 8 | Int(bytes[11])

        var cursor = 12
        for _ in 0..<qdcount {
            guard skipName(bytes, &cursor), advance(&cursor, by: 4, toAtMost: bytes.count)
            else { return query }
        }
        for _ in 0..<(ancount + nscount) {
            guard skipRecord(bytes, &cursor) else { return query }
        }

        // Additional section: find every OPT (TYPE 41), remembering where its CLASS
        // (the advertised payload size, RFC 6891 §6.1.2) sits.
        var optClassOffsets: [Int] = []
        for _ in 0..<arcount {
            let nameStart = cursor
            guard skipName(bytes, &cursor) else { return query }
            guard cursor + 10 <= bytes.count else { return query }
            let type = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            // TSIG (250) and SIG(0) (24) authenticate the message BYTES. Rewriting the OPT
            // CLASS under either one changes bytes the MAC covers without recomputing it,
            // so the upstream rejects a query it would otherwise have honoured — and the
            // pre-S6 path forwarded it intact. Nothing here can re-sign, so the only
            // correct move is to leave the message exactly as the client wrote it
            // (Codex, PR #511).
            // pinned: DNSEDNS0Tests.testAnAuthenticatedQueryIsLeftAlone
            if type == 250 || type == 24 { return query }
            if type == 41 {
                // A well-formed OPT name is root (one zero byte); anything else is not an
                // OPT this function trusts itself to rewrite.
                guard cursor == nameStart + 1, bytes[nameStart] == 0 else { return query }
                optClassOffsets.append(cursor + 2)
            }
            let rdlength = Int(bytes[cursor + 8]) << 8 | Int(bytes[cursor + 9])
            guard advance(&cursor, by: 10 + rdlength, toAtMost: bytes.count) else {
                return query
            }
        }
        // The walk must have consumed the message exactly — leftover bytes mean the
        // counts and the sections disagree, and rewriting a message like that forwards
        // a guess.
        guard cursor == bytes.count else { return query }

        guard optClassOffsets.count == 1 else { return query }
        let offset = optClassOffsets[0]
        // LOWER ONLY. A client advertising less than the cap keeps its own number: it is the
        // one that has to receive the relayed answer, and promising the upstream more than
        // the client offered is what hands a 512-byte stub a 1232-byte datagram.
        let advertised = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        guard advertised > payloadBytes else { return query }
        bytes[offset] = UInt8(payloadBytes >> 8)
        bytes[offset + 1] = UInt8(payloadBytes & 0xFF)
        return Data(bytes)
    }

    /// The full 12-bit RCODE of a RESPONSE: the header's low nibble, plus the high 8 bits an OPT
    /// record carries in the most significant byte of its TTL (RFC 6891 §6.1.3).
    ///
    /// WHY THE HEADER NIBBLE IS NOT THE RCODE. An extended error presents a ZERO nibble and keeps
    /// its real value in the OPT, so a reader that stops at the header sees NOERROR. BADVERS (16)
    /// is the reachable one: `0000 0001 0000`, an extension byte of 1 over a nibble of 0. That is
    /// how a fallback resolver's error came to displace a retained authoritative NXDOMAIN and be
    /// relayed to the client as though the name had resolved (Codex, PR #586).
    ///
    /// A response with NO OPT is not a failure: EDNS is optional and such a message's RCODE is
    /// exactly the header nibble. `nil` is reserved for a message this cannot walk — a truncated
    /// section, counts that disagree with the bytes, a non-root OPT name, or more than one OPT,
    /// which is protocol-illegal and would make "which one carries the RCODE" a guess about a
    /// message that is already wrong. Callers treat `nil` as "not a resolved answer", so an
    /// unparseable reply fails toward keeping whatever better answer the caller already holds.
    ///
    /// Reuses this type's own section walk rather than growing a second one: OPT layout knowledge
    /// lives here, and a parallel copy is how the two drift.
    /// pinned: DNSEDNS0Tests.testTheFullRCodeCombinesTheHeaderNibbleWithTheOPTExtension
    /// pinned: DNSEDNS0Tests.testAResponseWithNoOPTCarriesItsHeaderRCode
    package static func fullRCode(of response: Data) -> UInt16? {
        let bytes = [UInt8](response)
        guard bytes.count >= 12 else { return nil }
        // QR must be 1: an extended RCODE is a property of a response.
        guard bytes[2] & 0x80 != 0 else { return nil }
        let headerRCode = UInt16(bytes[3] & 0x0F)
        let qdcount = Int(bytes[4]) << 8 | Int(bytes[5])
        let ancount = Int(bytes[6]) << 8 | Int(bytes[7])
        let nscount = Int(bytes[8]) << 8 | Int(bytes[9])
        let arcount = Int(bytes[10]) << 8 | Int(bytes[11])

        var cursor = 12
        for _ in 0..<qdcount {
            guard skipName(bytes, &cursor), advance(&cursor, by: 4, toAtMost: bytes.count)
            else { return nil }
        }
        for _ in 0..<(ancount + nscount) {
            guard skipRecord(bytes, &cursor) else { return nil }
        }

        var extension8: UInt16?
        for _ in 0..<arcount {
            let nameStart = cursor
            guard skipName(bytes, &cursor) else { return nil }
            guard cursor + 10 <= bytes.count else { return nil }
            let type = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            if type == 41 {
                // A well-formed OPT name is root (one zero byte); anything else is not an OPT
                // this function trusts itself to read.
                guard cursor == nameStart + 1, bytes[nameStart] == 0 else { return nil }
                guard extension8 == nil else { return nil }
                // TTL sits after NAME, TYPE (2) and CLASS (2); its FIRST byte is the extension.
                extension8 = UInt16(bytes[cursor + 4])
            }
            let rdlength = Int(bytes[cursor + 8]) << 8 | Int(bytes[cursor + 9])
            guard advance(&cursor, by: 10 + rdlength, toAtMost: bytes.count) else { return nil }
        }
        // Consumed EXACTLY, the same bar `cappingAdvertisedPayload` holds: leftover bytes mean the
        // counts and the sections disagree, and reading an RCODE out of a message like that
        // reports a guess.
        guard cursor == bytes.count else { return nil }
        return ((extension8 ?? 0) << 4) | headerRCode
    }

    /// Advances `cursor` past a wire-format name: labels until the root byte, or a
    /// compression pointer, which is two bytes and ends the name (RFC 1035 §4.1.4).
    private static func skipName(_ bytes: [UInt8], _ cursor: inout Int) -> Bool {
        while true {
            guard cursor < bytes.count else { return false }
            let length = bytes[cursor]
            if length == 0 {
                cursor += 1
                return true
            }
            if length & 0xC0 == 0xC0 {
                return advance(&cursor, by: 2, toAtMost: bytes.count)
            }
            guard length & 0xC0 == 0 else { return false }
            guard advance(&cursor, by: Int(length) + 1, toAtMost: bytes.count) else {
                return false
            }
        }
    }

    /// Advances `cursor` past a resource record (name + fixed header + RDATA).
    private static func skipRecord(_ bytes: [UInt8], _ cursor: inout Int) -> Bool {
        guard skipName(bytes, &cursor) else { return false }
        guard cursor + 10 <= bytes.count else { return false }
        let rdlength = Int(bytes[cursor + 8]) << 8 | Int(bytes[cursor + 9])
        return advance(&cursor, by: 10 + rdlength, toAtMost: bytes.count)
    }

    /// `cursor += by`, refusing to move past `count`. `cursor == count` is legal — it is
    /// "consumed exactly", which the caller's final check requires.
    private static func advance(_ cursor: inout Int, by: Int, toAtMost count: Int) -> Bool {
        guard cursor + by <= count else { return false }
        cursor += by
        return true
    }
}
