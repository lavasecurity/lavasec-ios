import XCTest
@testable import LavaSecDNS

/// `DNSServiceBinding.strippingIPv6Hints` must remove the `ipv6hint` SvcParam from HTTPS/SVCB answers
/// while keeping every other parameter — and must NEVER corrupt a response: anything it cannot rewrite
/// provably-safely is returned byte-for-byte unchanged (`INV-DNS-1`). See `DNSServiceBinding`.
final class DNSServiceBindingTests: XCTestCase {
    // MARK: wire builders

    private func u16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }

    private func encodedName(_ labels: [String]) -> [UInt8] {
        var out: [UInt8] = []
        for label in labels {
            out.append(UInt8(label.utf8.count))
            out.append(contentsOf: Array(label.utf8))
        }
        out.append(0)
        return out
    }

    private func pointer(to offset: Int) -> [UInt8] { [0xC0 | UInt8((offset >> 8) & 0x3F), UInt8(offset & 0xFF)] }

    private func svcParam(_ key: Int, _ value: [UInt8]) -> [UInt8] { u16(key) + u16(value.count) + value }

    private func serviceBindingRData(priority: Int, target: [UInt8], params: [[UInt8]]) -> [UInt8] {
        u16(priority) + target + params.flatMap { $0 }
    }

    private func resourceRecord(owner: [UInt8], type: Int, ttl: Int = 3600, rdata: [UInt8]) -> [UInt8] {
        owner + u16(type) + u16(1)
            + [UInt8((ttl >> 24) & 0xFF), UInt8((ttl >> 16) & 0xFF), UInt8((ttl >> 8) & 0xFF), UInt8(ttl & 0xFF)]
            + u16(rdata.count) + rdata
    }

    private func header(qd: Int, an: Int, ns: Int = 0, ar: Int) -> [UInt8] {
        u16(0x1234) + u16(0x8180) + u16(qd) + u16(an) + u16(ns) + u16(ar)
    }

    private func questionSection(_ name: [UInt8], type: Int) -> [UInt8] { name + u16(type) + u16(1) }

    // Common SvcParams (keys strictly increasing, per RFC 9460 §2.2).
    private var alpn: [UInt8] { svcParam(1, [0x02, 0x68, 0x32]) }        // ALPN "h2"
    private var ipv4hint: [UInt8] { svcParam(4, [1, 2, 3, 4]) }          // 1.2.3.4
    private var ipv6hint: [UInt8] { svcParam(6, Array(repeating: 0x20, count: 16)) }
    private var ech: [UInt8] { svcParam(5, [0xAB, 0xCD]) }               // opaque ECH config

    // MARK: strip

    func testStripsTheIPv6HintKeepingOtherSvcParams() {
        let question = questionSection(encodedName(["example", "com"]), type: 65)
        let withHint = Data(header(qd: 1, an: 1, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn, ipv4hint, ipv6hint])))
        let expected = Data(header(qd: 1, an: 1, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn, ipv4hint])))

        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: withHint), expected,
                       "the ipv6hint must be removed, ALPN + ipv4hint kept, rdlength corrected")
        XCTAssertTrue(DNSWireMessage.hasWellFormedResourceRecords(expected))
    }

    func testStripsSVCBType64AsWellAsHTTPS() {
        let question = questionSection(encodedName(["_dns", "example", "com"]), type: 64)
        let withHint = Data(header(qd: 1, an: 1, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 64,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [ipv4hint, ipv6hint])))
        let expected = Data(header(qd: 1, an: 1, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 64,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [ipv4hint])))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: withHint), expected)
    }

    func testStripsWhenIPv6HintIsTheOnlySvcParam() {
        let question = questionSection(encodedName(["example", "com"]), type: 65)
        let withHint = Data(header(qd: 1, an: 1, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [ipv6hint])))
        let expected = Data(header(qd: 1, an: 1, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [])))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: withHint), expected)
        XCTAssertTrue(DNSWireMessage.hasWellFormedResourceRecords(expected))
    }

    func testStripsAcrossMultipleServiceBindingRecords() {
        let question = questionSection(encodedName(["example", "com"]), type: 65)
        let withHint = Data(header(qd: 1, an: 2, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn, ipv6hint]))
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 2, target: [0], params: [ech, ipv6hint])))
        let expected = Data(header(qd: 1, an: 2, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn]))
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 2, target: [0], params: [ech])))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: withHint), expected)
        XCTAssertTrue(DNSWireMessage.hasWellFormedResourceRecords(expected))
    }

    func testStripsOnlyTheServiceBindingRecordLeavingOtherAnswers() {
        // An A record shares the answer section; it must be copied verbatim, HTTPS stripped.
        let question = questionSection(encodedName(["example", "com"]), type: 65)
        let aRecord = resourceRecord(owner: pointer(to: 12), type: 1, rdata: [93, 184, 216, 34])
        let withHint = Data(header(qd: 1, an: 2, ar: 0) + question + aRecord
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn, ipv6hint])))
        let expected = Data(header(qd: 1, an: 2, ar: 0) + question + aRecord
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn])))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: withHint), expected)
    }

    func testPreservesAnOPTRecordInTheAdditionalSection() {
        // A bare EDNS OPT (TYPE 41, root owner) rides in additional; it must survive the strip.
        let question = questionSection(encodedName(["example", "com"]), type: 65)
        let opt = resourceRecord(owner: [0], type: 41, ttl: 0, rdata: [])
        let withHint = Data(header(qd: 1, an: 1, ar: 1) + question
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn, ipv6hint]))
            + opt)
        let expected = Data(header(qd: 1, an: 1, ar: 1) + question
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn]))
            + opt)
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: withHint), expected)
        XCTAssertTrue(DNSWireMessage.hasWellFormedResourceRecords(expected))
    }

    func testStripsThroughACNAMEChain() {
        // The queried name CNAMEs to a canonical name that owns the HTTPS record — the common CDN
        // shape. CNAME is allowlisted (its RDATA name is walked), so the strip still applies.
        let question = questionSection(encodedName(["www", "example", "com"]), type: 65)
        let canonical = encodedName(["cdn", "example", "net"])
        let cname = resourceRecord(owner: pointer(to: 12), type: 5, rdata: canonical)
        let withHint = Data(header(qd: 1, an: 2, ar: 0) + question + cname
            + resourceRecord(owner: canonical, type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn, ipv6hint])))
        let expected = Data(header(qd: 1, an: 2, ar: 0) + question + cname
            + resourceRecord(owner: canonical, type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn])))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: withHint), expected)
        XCTAssertTrue(DNSWireMessage.hasWellFormedResourceRecords(expected))
    }

    // MARK: DNSSEC AD bit + mandatory SvcParam (Codex review)

    func testClearsTheDNSSECAuthenticatedDataBitWhenStripping() {
        // A validating resolver can set AD with no RRSIG present (the DO=0 case). Once we modify the
        // answer it is no longer authenticated, so AD must be cleared (RFC 6840 §5.8).
        var withAD = header(qd: 1, an: 1, ar: 0)
        withAD[3] |= 0x20 // set AD
        let body = questionSection(encodedName(["example", "com"]), type: 65)
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn, ipv6hint]))
        let response = Data(withAD + body)

        let stripped = DNSServiceBinding.strippingIPv6Hints(from: response)
        XCTAssertNotEqual(stripped, response, "the hint should have been stripped")
        XCTAssertEqual(stripped[3] & 0x20, 0, "AD must be cleared once the answer is modified")
        XCTAssertTrue(DNSWireMessage.hasWellFormedResourceRecords(stripped))
    }

    func testPreservesTheADBitWhenNothingIsStripped() {
        // Passthrough returns the response untouched — including whatever the resolver set for AD.
        var withAD = header(qd: 1, an: 1, ar: 0)
        withAD[3] |= 0x20
        let response = Data(withAD + questionSection(encodedName(["example", "com"]), type: 65)
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn])))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: response), response)
    }

    func testPassesThroughARecordWhoseMandatoryListsIPv6Hint() {
        // `mandatory` (key 0) naming ipv6hint means the client MUST understand ipv6hint; removing it
        // would leave `mandatory` referencing an absent key (RFC 9460 §8) → the client rejects the
        // whole record and loses ALPN/ECH. Leave such a record intact.
        let mandatory = svcParam(0, u16(6)) // lists SvcParamKey 6 (ipv6hint)
        let response = Data(header(qd: 1, an: 1, ar: 0) + questionSection(encodedName(["example", "com"]), type: 65)
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [mandatory, ipv6hint])))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: response), response)
    }

    func testStripsWhenMandatoryListsOnlyOtherKeys() {
        // `mandatory` naming a key OTHER than ipv6hint does not protect the hint — still stripped.
        let mandatory = svcParam(0, u16(1)) // lists ALPN (key 1), not ipv6hint
        let question = questionSection(encodedName(["example", "com"]), type: 65)
        let withHint = Data(header(qd: 1, an: 1, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [mandatory, alpn, ipv6hint])))
        let expected = Data(header(qd: 1, an: 1, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [mandatory, alpn])))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: withHint), expected)
    }

    // MARK: passthrough — nothing to strip

    func testLeavesAServiceBindingAnswerWithoutAnIPv6HintUnchanged() {
        let question = questionSection(encodedName(["example", "com"]), type: 65)
        let response = Data(header(qd: 1, an: 1, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn, ipv4hint, ech])))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: response), response)
    }

    func testLeavesAnAliasModeRecordUnchanged() {
        // AliasMode (priority 0) carries no SvcParams — nothing to strip.
        let question = questionSection(encodedName(["example", "com"]), type: 65)
        let response = Data(header(qd: 1, an: 1, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 0, target: encodedName(["svc", "example", "net"]), params: [])))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: response), response)
    }

    func testLeavesAMessageWithNoAnswerRecordsUnchanged() {
        let response = Data(header(qd: 1, an: 0, ar: 0) + questionSection(encodedName(["example", "com"]), type: 65))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: response), response)
    }

    // MARK: passthrough — cannot rewrite safely (must never corrupt)

    func testPassesThroughAForwardCompressionPointerRatherThanCorruptingIt() {
        // Craft a message where a later record's owner name points INTO the ipv6hint bytes. Removing
        // the hint would shift those bytes and break the pointer, so the strip MUST bail to the
        // original. This is the load-bearing safety gate.
        let question = questionSection(encodedName(["example", "com"]), type: 65)
        let answer = resourceRecord(owner: pointer(to: 12), type: 65,
                                    rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn, ipv4hint, ipv6hint]))
        let answerStart = 12 + question.count
        // ipv6hint begins after: owner(2) + fixed RR header(10) + priority(2) + root target(1) + alpn + ipv4hint.
        let ipv6HintOffset = answerStart + 2 + 10 + 2 + 1 + alpn.count + ipv4hint.count
        // An additional A record whose owner name points at the ipv6hint region (>= the deletion).
        let additional = resourceRecord(owner: pointer(to: ipv6HintOffset), type: 1, rdata: [5, 6, 7, 8])
        let response = Data(header(qd: 1, an: 1, ar: 1) + question + answer + additional)

        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: response), response,
                       "a pointer into the shifted region must force byte-for-byte passthrough")
    }

    func testPassesThroughANonAllowlistedRecordType() {
        // A TXT record (name-free but not on the allowlist) means the walk cannot vouch that no
        // compression pointer hides in opaque RDATA — bail conservatively.
        let question = questionSection(encodedName(["example", "com"]), type: 65)
        let txt = resourceRecord(owner: pointer(to: 12), type: 16, rdata: [3, 0x61, 0x62, 0x63])
        let response = Data(header(qd: 1, an: 2, ar: 0) + question + txt
            + resourceRecord(owner: pointer(to: 12), type: 65,
                             rdata: serviceBindingRData(priority: 1, target: [0], params: [alpn, ipv6hint])))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: response), response)
    }

    func testPassesThroughACompressedTargetName() {
        // A SVCB/HTTPS TargetName MUST be uncompressed (RFC 9460 §2.2); a pointer there is malformed.
        let question = questionSection(encodedName(["example", "com"]), type: 65)
        let rdata = u16(1) + pointer(to: 12) + ipv6hint // priority + (illegal) compressed target + hint
        let response = Data(header(qd: 1, an: 1, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 65, rdata: rdata))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: response), response)
    }

    func testPassesThroughMalformedSvcParams() {
        // An ipv6hint whose declared value length overruns the RDATA must not be rewritten.
        let question = questionSection(encodedName(["example", "com"]), type: 65)
        let badParam = u16(6) + u16(99) + [0x00, 0x00] // claims 99 bytes, supplies 2
        let rdata = u16(1) + [0] + badParam
        let response = Data(header(qd: 1, an: 1, ar: 0) + question
            + resourceRecord(owner: pointer(to: 12), type: 65, rdata: rdata))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: response), response)
    }

    func testPassesThroughNonResponsesAndShortMessages() {
        // A query (QR=0) is never a response to rewrite.
        let query = Data(u16(0x1234) + u16(0x0100) + u16(1) + u16(0) + u16(0) + u16(0)
            + questionSection(encodedName(["example", "com"]), type: 65))
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: query), query)

        let short = Data([0x00, 0x01, 0x02])
        XCTAssertEqual(DNSServiceBinding.strippingIPv6Hints(from: short), short)
    }
}
