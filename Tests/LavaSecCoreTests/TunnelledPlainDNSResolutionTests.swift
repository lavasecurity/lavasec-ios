import XCTest

@testable import LavaSecDNS

/// The tunnelled `.plainDNS` loop (S6): the EDNS0 cap at the socket seam, the
/// TC-fails-closed/TC-is-liveness split, and the unanswered classification.
///
/// The socket seam IS the tunnel-egress seam for these assertions:
/// `ChainedTunnelDNSCaptureTests` proves the bytes handed to the pinned socket reach the
/// peer byte-for-byte on real WireGuard sessions, so capturing the query at the injected
/// `resolveUDP` closure is capture at tunnel egress — the two harnesses compose because
/// neither can drive the other's half (that file's own header records why).
final class TunnelledPlainDNSResolutionTests: XCTestCase {
    private static let primary = "10.64.0.1"
    private static let secondary = "10.64.0.2"

    // NO `fallback:` PARAMETER. The route carried a T1 subset until PR #590 moved the rung
    // to the physical interface; the parameter and the ~21 tests over it went with the machinery
    // (the plan's S3). What survives here is T0's own behaviour, which is all this loop does.
    private func route(
        _ addresses: [String] = [primary, secondary]
    ) -> ResolverOrchestrator.TunnelledPlainDNSRoute {
        guard
            let route = ResolverOrchestrator.TunnelledPlainDNSRoute(
                resolverAddresses: addresses, originatingLifecycle: 7, originatingLatchEpoch: 3)
        else {
            fatalError("test route must not be empty")
        }
        return route
    }

    private func plainQuery(domain: String = "example.com") -> Data {
        DNSResolverSmokeProbe.query(transactionID: 0x1234, domain: domain)
    }

    private func optRecord(class klass: UInt16) -> Data {
        var record = Data([0x00, 0x00, 0x29])
        record.append(contentsOf: [UInt8(klass >> 8), UInt8(klass & 0xFF)])
        record.append(contentsOf: [0, 0, 0, 0, 0x00, 0x00])
        return record
    }

    private func query(advertising klass: UInt16, domain: String = "example.com") -> Data {
        var query = plainQuery(domain: domain)
        var bytes = [UInt8](query)
        bytes[11] = 1  // ARCOUNT
        query = Data(bytes)
        query.append(optRecord(class: klass))
        return query
    }

    /// A valid-looking SERVED response for `query`: header echoed with QR set, carrying ONE
    /// A record for the queried name.
    ///
    /// The answer record is not decoration. Header-echo-with-QR is NOERROR with no answers and
    /// no authority — the unbacked-NODATA shape the loop now fails over past — so a fixture
    /// without it would stop meaning "this resolver served the name" the moment a route has a
    /// T1 configured (PR #588). It is inserted BEFORE any OPT the query carries, so the
    /// sections stay in wire order and `DNSEDNS0.fullRCode` still finds the OPT.
    private func response(for query: Data, truncated: Bool = false) -> Data {
        var bytes = [UInt8](query)
        bytes[2] |= 0x80
        if truncated {
            bytes[2] |= 0x02
        }
        bytes[6] = 0x00
        bytes[7] = 0x01  // ANCOUNT = 1
        var message = Data(bytes)
        message.insert(contentsOf: Self.answerRecord, at: questionEnd(in: message))
        return message
    }

    /// One IN A record for the question name (compression pointer to offset 12), TTL 60.
    private static let answerRecord = Data([
        0xC0, 0x0C,              // NAME → the question's name at offset 12
        0x00, 0x01,              // TYPE = A
        0x00, 0x01,              // CLASS = IN
        0x00, 0x00, 0x00, 0x3C,  // TTL = 60
        0x00, 0x04,              // RDLENGTH
        93, 184, 216, 34,
    ])

    /// A NOERROR reply for `query` answering with exactly `addresses`, one IN A record each
    /// (compression pointer to the question name, TTL 60).
    private func response(for query: Data, addresses: [[UInt8]]) -> Data {
        var bytes = [UInt8](query)
        bytes[2] |= 0x80
        bytes[6] = UInt8(addresses.count >> 8)
        bytes[7] = UInt8(addresses.count & 0xFF)
        var message = Data(bytes)
        var records = Data()
        for address in addresses {
            records.append(contentsOf: [
                0xC0, 0x0C,
                0x00, 0x01,
                0x00, 0x01,
                0x00, 0x00, 0x00, 0x3C,
                0x00, 0x04,
            ])
            records.append(contentsOf: address)
        }
        message.insert(contentsOf: records, at: questionEnd(in: message))
        return message
    }

    /// A NOERROR reply for an AAAA `query` answering with exactly `addresses`, one IN AAAA record
    /// each (compression pointer to the question name, TTL 60), 16-byte payload.
    private func responseAAAA(for query: Data, addresses: [[UInt8]]) -> Data {
        var bytes = [UInt8](query)
        bytes[2] |= 0x80
        bytes[6] = UInt8(addresses.count >> 8)
        bytes[7] = UInt8(addresses.count & 0xFF)
        var message = Data(bytes)
        var records = Data()
        for address in addresses {
            records.append(contentsOf: [
                0xC0, 0x0C,
                0x00, 0x1C,              // TYPE = AAAA (28)
                0x00, 0x01,              // CLASS = IN
                0x00, 0x00, 0x00, 0x3C,  // TTL = 60
                0x00, 0x10,              // RDLENGTH = 16
            ])
            records.append(contentsOf: address)
        }
        message.insert(contentsOf: records, at: questionEnd(in: message))
        return message
    }

    /// A NOERROR reply for `query` with NO answer records, optionally with an authority record
    /// backing the negative — the RFC 2308 §2.2 split the T1 failover keys on.
    private func emptyAnswer(for query: Data, backedByAuthority: Bool) -> Data {
        var bytes = [UInt8](query)
        bytes[2] |= 0x80
        bytes[8] = 0x00
        bytes[9] = backedByAuthority ? 0x01 : 0x00  // NSCOUNT
        var message = Data(bytes)
        guard backedByAuthority else {
            return message
        }
        message.insert(contentsOf: Self.soaRecord, at: questionEnd(in: message))
        return message
    }

    /// The zone's SOA, as RFC 2308 §2.2 requires a real negative to carry. Both names are root
    /// and the numeric fields are zero: this fixture is about the record BEING there.
    private static let soaRecord: Data = {
        var record = Data([
            0xC0, 0x0C,              // NAME → the question's name at offset 12
            0x00, 0x06,              // TYPE = SOA
            0x00, 0x01,              // CLASS = IN
            0x00, 0x00, 0x00, 0x3C,  // TTL = 60
            0x00, 0x16,              // RDLENGTH = 22
            0x00, 0x00,              // MNAME, RNAME — both root
        ])
        record.append(Data(repeating: 0, count: 20))  // SERIAL/REFRESH/RETRY/EXPIRE/MINIMUM
        return record
    }()

    /// The offset just past the single uncompressed question — where a fixture inserts records so
    /// the answer/authority sections precede any OPT the query carried.
    private func questionEnd(in message: Data) -> Int {
        let bytes = [UInt8](message)
        var cursor = 12
        while cursor < bytes.count, bytes[cursor] != 0 {
            cursor += Int(bytes[cursor]) + 1
        }
        return cursor + 1 + 4  // root byte + QTYPE + QCLASS
    }

    /// A response for `query` carrying a specific RCODE in the low nibble of the flags byte.
    /// SERVFAIL=2, NXDOMAIN=3, REFUSED=5.
    private func response(for query: Data, rcode: UInt8) -> Data {
        var bytes = [UInt8](query)
        bytes[2] |= 0x80
        bytes[3] = (bytes[3] & 0xF0) | (rcode & 0x0F)
        return Data(bytes)
    }

    /// A NOERROR response whose header CLAIMS one answer but carries no resource-record bytes —
    /// header-valid, but `hasWellFormedResourceRecords` fails, so `completeForward` replaces it with
    /// SERVFAIL downstream. The client receives a failure, so it is not a served answer.
    private func malformedAnswer(for query: Data) -> Data {
        var bytes = [UInt8](query)
        bytes[2] |= 0x80        // QR = response
        bytes[6] = 0x00         // ANCOUNT high
        bytes[7] = 0x01         // ANCOUNT = 1, but no RR follows the question
        return Data(bytes)
    }

    private final class WireRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var scripted: [String: [DNSUpstreamResponse]] = [:]
        private(set) var sentQueries: [(address: String, query: Data)] = []

        func script(_ address: String, _ responses: [DNSUpstreamResponse]) {
            lock.lock()
            defer { lock.unlock() }
            scripted[address] = responses
        }

        func resolve(_ query: Data, _ endpoint: ResolverEndpoint) -> DNSUpstreamResponse {
            lock.lock()
            defer { lock.unlock() }
            sentQueries.append((endpoint.address, query))
            guard var queue = scripted[endpoint.address], !queue.isEmpty else {
                return DNSUpstreamResponse(response: nil, outcome: .timeout)
            }
            let next = queue.removeFirst()
            scripted[endpoint.address] = queue
            return next
        }
    }

    // MARK: - The cap at the egress seam

    func testEveryTunnelEgressCarriesTheCappedAdvertisement() {
        // Decision 3's first executable obligation: the advertised payload AT EGRESS equals
        // the cap — asserted on the bytes the socket seam receives, not on a builder flag,
        // so advertising larger fails. Both failover attempts must carry the SAME capped
        // bytes: the cap is a property of the tunnel path, not of one resolver.
        let recorder = WireRecorder()
        let query = query(advertising: 4096)

        _ = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(recorder.sentQueries.count, 2, "both resolvers attempted")
        let expected = DNSEDNS0.cappingAdvertisedPayload(
            in: query, to: DNSEDNS0.tunnelAdvertisedPayloadBytes)
        XCTAssertNotEqual(expected, query, "the fixture must actually need lowering")
        XCTAssertEqual(
            Data(expected.suffix(11)),
            optRecord(class: DNSEDNS0.tunnelAdvertisedPayloadBytes))
        for sent in recorder.sentQueries {
            XCTAssertEqual(sent.query, expected, "\(sent.address) egressed an uncapped query")
        }
    }

    func testAClientAdvertisingLessKeepsItsOwnLimitOnTheWire() {
        // The never-raise half (Codex, PR #511): a 512-byte stub's advertisement — and a
        // query with no OPT at all — egress exactly as written.
        for query in [query(advertising: 512), plainQuery()] {
            let recorder = WireRecorder()
            _ = TunnelledPlainDNSResolution.resolve(
                query: query, route: route([Self.primary]), resolveUDP: recorder.resolve)
            XCTAssertEqual(recorder.sentQueries.first?.query, query)
        }
    }

    // MARK: - Per-rung path epoch (task #56, Codex #565)

    func testEachFailoverRungStampsThePathEpochLiveAtItsSend() {
        // A surviving-carry roam BETWEEN rung 1 and rung 2 of the ladder must leave rung 2 stamped
        // with the NEW epoch, so the provider can still back off a resolver that times out on the new
        // path. `resolve` reads the epoch at the START of each rung — not once for the whole resolution
        // — which is why a single per-resolution epoch was insufficient (Codex P2).
        let recorder = WireRecorder()
        recorder.script(Self.primary, [DNSUpstreamResponse(response: nil, outcome: .timeout)])
        recorder.script(Self.secondary, [DNSUpstreamResponse(response: nil, outcome: .timeout)])

        var rung = 0
        let epochs = [5, 6]  // the roam advances the epoch between the two rungs
        let verdict = TunnelledPlainDNSResolution.resolve(
            query: plainQuery(),
            route: route([Self.primary, Self.secondary]),
            pathEpochAtAttempt: {
                defer { rung += 1 }
                return epochs[min(rung, epochs.count - 1)]
            },
            resolveUDP: recorder.resolve)

        XCTAssertEqual(verdict.result.attempts.map(\.address), [Self.primary, Self.secondary])
        XCTAssertEqual(
            verdict.result.attempts.map(\.pathEpoch), [5, 6],
            "each rung carries the epoch live at its own send, not one epoch for the whole resolution")
    }

    func testAttemptsCarryNoPathEpochForNonTunnelledCallers() {
        // The default provider is nil-epoch: a non-tunnelled / test caller's attempts are never
        // epoch-fenced (their runtime-generation gate already covers a reset).
        let recorder = WireRecorder()
        recorder.script(Self.primary, [DNSUpstreamResponse(response: nil, outcome: .timeout)])
        let verdict = TunnelledPlainDNSResolution.resolve(
            query: plainQuery(), route: route([Self.primary]), resolveUDP: recorder.resolve)
        XCTAssertEqual(verdict.result.attempts.map(\.pathEpoch), [nil])
    }

    // MARK: - Truncation: fails closed, reads as liveness

    func testATruncatedAnswerFailsClosedAndReadsAsLiveness() {
        // Decision 3's second and third obligations in one shape: the TC answer is never
        // relayed (nil response → the forwarding path synthesizes SERVFAIL), no TCP retry
        // exists, and the observation is `.answered` — the resolver replied, promptly and
        // correctly, that the answer does not fit UDP.
        let recorder = WireRecorder()
        let query = query(advertising: 4096)
        let truncated = response(for: query, truncated: true)
        recorder.script(Self.primary, [DNSUpstreamResponse(response: truncated, outcome: .success)])
        recorder.script(Self.secondary, [DNSUpstreamResponse(response: truncated, outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertNil(verdict.result.response, "the TC answer must never be relayed")
        XCTAssertEqual(verdict.result.udpTruncated, true)
        XCTAssertEqual(verdict.result.tcpFallbackAttempted, false)
        XCTAssertEqual(verdict.result.attempts.map(\.outcome), [.truncatedAnswer, .truncatedAnswer])
        XCTAssertEqual(verdict.result.attempts.map(\.usedTCP), [false, false])
        XCTAssertEqual(verdict.observation, .answered)
    }

    func testABrowserStyleTCRetryBurstOnlyEverReadsAsAnswered() {
        // Decision 3's arming obligation, producer half: however many times one
        // large-response domain is retried, every resolution classifies `.answered` — the
        // driver side (`testAnsweredObservationsArmNothing`) proves answered streams arm
        // nothing, so the two halves compose into "a TC burst spends no outage budget".
        let query = query(advertising: 4096)
        for _ in 0..<8 {
            let recorder = WireRecorder()
            recorder.script(
                Self.primary,
                [DNSUpstreamResponse(response: response(for: query, truncated: true), outcome: .success)])
            let verdict = TunnelledPlainDNSResolution.resolve(
                query: query, route: route([Self.primary]), resolveUDP: recorder.resolve)
            XCTAssertEqual(verdict.observation, .answered)
        }
    }

    func testATruncationDoesNotEndTheFailover() {
        // The advertisement is identical everywhere, but resolvers legitimately differ in
        // what they answer — a later resolver may fit where an earlier one truncated, and
        // that result is a resolution, not a truncation (the evidence layer's decisive-
        // attempt rule anticipates exactly this shape).
        let recorder = WireRecorder()
        let query = query(advertising: 4096)
        let served = response(for: query)
        recorder.script(
            Self.primary,
            [DNSUpstreamResponse(response: response(for: query, truncated: true), outcome: .success)])
        recorder.script(Self.secondary, [DNSUpstreamResponse(response: served, outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(verdict.result.response, served)
        XCTAssertEqual(verdict.result.successfulResolverAddress, Self.secondary)
        XCTAssertEqual(verdict.result.udpTruncated, true)
        XCTAssertEqual(verdict.observation, .answered)
    }

    func testTCThenSilenceIsStillLiveness() {
        // The liveness credit survives a LATER resolver's silence: the outage cause asks
        // "is tunnel DNS gone", and an answer from any selected resolver is "no".
        let recorder = WireRecorder()
        let query = query(advertising: 4096)
        recorder.script(
            Self.primary,
            [DNSUpstreamResponse(response: response(for: query, truncated: true), outcome: .success)])
        recorder.script(Self.secondary, [DNSUpstreamResponse(response: nil, outcome: .timeout)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertNil(verdict.result.response)
        XCTAssertEqual(verdict.observation, .answered)
    }

    // MARK: - Unanswered classification

    func testOnlySilenceReadsAsUnanswered() {
        // The driver door's contract: ONLY the sent-and-unanswered shape is evidence.
        // A timeout across every resolver carries the normalized name for the
        // distinct-names floor.
        let recorder = WireRecorder()
        let query = plainQuery(domain: "Example.COM")

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertNil(verdict.result.response)
        XCTAssertEqual(verdict.observation, .unanswered(normalizedQueryName: "example.com"))
    }

    func testLocalFailuresAreNotEvidenceAboutTheResolver() {
        // A send failure, an expired claim, a refused binding or a storm of off-source datagrams
        // says nothing about the resolver — reporting them would arm the outage budget on
        // conditions a session rebuild cannot fix.
        //
        // `.mismatchedResponse` USED to be in this list, and belonged here only while it
        // conflated two opposite things. Now that off-source junk is `.unexpectedSourceResponse`,
        // a mismatched response is source-matched by construction — the resolver replied, and
        // this attempt merely could not use the reply — so it is liveness, not a local failure.
        // See `testASourceMatchedMismatchIsTunnelDNSLiveness` (Codex, PR #577).
        let localOutcomes: [ResolverAttemptOutcome] = [
            .sendFailed, .socketUnavailable, .unexpectedSourceResponse, .receiveFailed,
        ]
        for outcome in localOutcomes {
            let recorder = WireRecorder()
            recorder.script(Self.primary, [DNSUpstreamResponse(response: nil, outcome: outcome)])
            recorder.script(Self.secondary, [DNSUpstreamResponse(response: nil, outcome: outcome)])
            let verdict = TunnelledPlainDNSResolution.resolve(
                query: plainQuery(), route: route(), resolveUDP: recorder.resolve)
            XCTAssertNil(verdict.result.response)
            XCTAssertNil(verdict.observation, "\(outcome) was reported as resolver evidence")
        }
    }

    func testATruncationPlusATimeoutStillCarriesTheUnresolvedName() {
        // THE SHAPE THAT SEPARATES THE TWO QUESTIONS. Truncation takes liveness precedence,
        // so the observation is `.answered` — correct for the outage supervisor, which must
        // not spend its budget on one large-response domain. But a resolver DID go quiet and
        // nothing resolved, so a consumer measuring silence needs the name anyway. Before
        // `unresolvedQueryName` existed, that consumer had only the observation and recorded
        // no timeout at all for this resolution (Codex, PR #520).
        let query = plainQuery()
        let recorder = WireRecorder()
        recorder.script(
            Self.primary,
            [DNSUpstreamResponse(response: response(for: query, truncated: true), outcome: .success)])
        recorder.script(Self.secondary, [DNSUpstreamResponse(response: nil, outcome: .timeout)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(verdict.observation, .answered, "TC is liveness, unchanged")
        XCTAssertNil(verdict.result.response)
        XCTAssertEqual(verdict.unresolvedQueryName, "example.com")
        XCTAssertTrue(verdict.result.attempts.contains { $0.outcome == .timeout })
    }

    func testACompletedResolutionCarriesNoUnresolvedName() {
        // A timeout RESCUED by a later resolver is not a silent domain, and the field says so
        // rather than leaving the caller to re-derive it from the response.
        let query = plainQuery()
        let recorder = WireRecorder()
        recorder.script(Self.primary, [DNSUpstreamResponse(response: nil, outcome: .timeout)])
        recorder.script(
            Self.secondary, [DNSUpstreamResponse(response: response(for: query), outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertNotNil(verdict.result.response)
        XCTAssertNil(verdict.unresolvedQueryName)
    }

    func testAMixedLocalFailureAndTimeoutIsStillUnanswered() {
        // One resolver's local refusal must not mask another's silence: a query WAS sent
        // and its budget elapsed, which is the evidence shape.
        let recorder = WireRecorder()
        recorder.script(
            Self.primary, [DNSUpstreamResponse(response: nil, outcome: .sendFailed)])
        recorder.script(Self.secondary, [DNSUpstreamResponse(response: nil, outcome: .timeout)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: plainQuery(), route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(verdict.observation, .unanswered(normalizedQueryName: "example.com"))
    }

    func testAnUpstreamFailureResponseIsStillAnAnswer() {
        // A resolver ANSWERING (SERVFAIL here) always credits liveness. With NO fallback resolver
        // in the route, a SERVFAIL relays as-is — the DNS-only path's behaviour — because there is
        // nothing to fail over to. (The failover-to-T1 case is
        // `testAServerFailureFailsOverToTheNextResolver`.)
        let recorder = WireRecorder()
        let query = plainQuery()
        let servfail = response(for: query, rcode: 2)
        recorder.script(Self.primary, [DNSUpstreamResponse(response: servfail, outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route([Self.primary]), resolveUDP: recorder.resolve)

        XCTAssertEqual(verdict.result.response, servfail)
        XCTAssertEqual(verdict.observation, .answered)
    }

    // MARK: - Server-failure failover to the next resolver in the conf's own `DNS =`

    /// A SERVFAIL from the first resolver FAILS OVER to the next one the conf lists. It answered
    /// (liveness), but another of the profile's own resolvers can still serve the name.
    func testAServerFailureFailsOverToTheNextResolver() {
        let recorder = WireRecorder()
        let query = plainQuery()
        let served = response(for: query)
        recorder.script(
            Self.primary, [DNSUpstreamResponse(response: response(for: query, rcode: 2), outcome: .success)])
        recorder.script(Self.secondary, [DNSUpstreamResponse(response: served, outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(verdict.result.response, served, "the SERVFAIL must fail over")
        XCTAssertEqual(verdict.result.successfulResolverAddress, Self.secondary)
        XCTAssertEqual(
            recorder.sentQueries.map(\.address), [Self.primary, Self.secondary],
            "both of the conf's resolvers must be queried — the first's SERVFAIL, then the second")
        XCTAssertEqual(verdict.observation, .answered)
    }

    /// REFUSED (rcode 5) fails over the same way — it too is a server-side "won't serve".
    func testARefusedResponseFailsOverToTheNextResolver() {
        let recorder = WireRecorder()
        let query = plainQuery()
        let served = response(for: query)
        recorder.script(
            Self.primary, [DNSUpstreamResponse(response: response(for: query, rcode: 5), outcome: .success)])
        recorder.script(Self.secondary, [DNSUpstreamResponse(response: served, outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(verdict.result.response, served)
        XCTAssertEqual(recorder.sentQueries.map(\.address), [Self.primary, Self.secondary])
    }

    /// NXDOMAIN is authoritative "does not exist": it returns as-is and does NOT fail over, so a
    /// negative is never double-queried and a legitimate "no such name" is never second-guessed.
    func testNXDOMAINIsAuthoritativeAndDoesNotFailOver() {
        let recorder = WireRecorder()
        let query = plainQuery()
        let nxdomain = response(for: query, rcode: 3)
        recorder.script(Self.primary, [DNSUpstreamResponse(response: nxdomain, outcome: .success)])
        recorder.script(
            Self.secondary, [DNSUpstreamResponse(response: response(for: query), outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(verdict.result.response, nxdomain, "NXDOMAIN returns as-is")
        XCTAssertEqual(
            recorder.sentQueries.map(\.address), [Self.primary],
            "the second resolver must NOT be queried for an authoritative negative")
        XCTAssertEqual(verdict.observation, .answered)
    }

    /// Every tier SERVFAILs: hand back a REAL failure answer (not a synthesized nil), still
    /// crediting liveness, after the whole route is tried.
    func testEveryResolverServerFailsReturnsTheFailureAnswer() {
        let recorder = WireRecorder()
        let query = plainQuery()
        recorder.script(
            Self.primary, [DNSUpstreamResponse(response: response(for: query, rcode: 2), outcome: .success)])
        recorder.script(
            Self.secondary, [DNSUpstreamResponse(response: response(for: query, rcode: 2), outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertTrue(
            DNSResolverSmokeProbe.indicatesResolverFailure(verdict.result.response),
            "a real server-failure answer is returned, not a synthesized nil")
        XCTAssertEqual(
            recorder.sentQueries.map(\.address), [Self.primary, Self.secondary],
            "the whole route is tried before returning the failure")
        XCTAssertEqual(verdict.observation, .answered)
    }

    // MARK: - NODATA is recorded, never acted on (RFC 2308 §2.2, PR #589)

    /// An unbacked empty NOERROR is RETURNED, not failed over past — even with a T1
    /// configured, which is the shape #588's failover fired on.
    ///
    /// That failover rested on RFC 2308 §2.2 requiring a legitimate negative to carry the zone's
    /// SOA. It does not: §2.2 reads "the authority section will contain an SOA record, OR there
    /// will be no NS records there", and enumerates a TYPE 3 NODATA whose authority section is
    /// empty. Type 3 is discouraged for authoritative servers, not invalid, so the shape is
    /// ambiguous at the wire and there is nothing here to discriminate on (Codex, PR #589).
    func testAnUnbackedEmptyAnswerIsReturnedNotFailedOverOn() {
        let recorder = WireRecorder()
        let query = plainQuery()
        let empty = emptyAnswer(for: query, backedByAuthority: false)
        recorder.script(Self.primary, [DNSUpstreamResponse(response: empty, outcome: .success)])
        recorder.script(
            Self.secondary, [DNSUpstreamResponse(response: response(for: query), outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(
            recorder.sentQueries.map(\.address), [Self.primary],
            "a type 3 NODATA is an answer — re-asking it double-queries ordinary negatives")
        XCTAssertEqual(verdict.result.response, empty)
        XCTAssertEqual(verdict.result.successfulResolverAddress, Self.primary)
        // ...and the SHAPE is still reported, which is the half of #588 that survives.
        XCTAssertTrue(verdict.sawEmptyAnswer)
        XCTAssertTrue(verdict.sawUnbackedEmptyAnswer)
    }

    /// THE FAILURE THE REVERT PREVENTS, in the traffic chained mode exists to carry.
    ///
    /// A split-DNS name that legitimately has no AAAA, answered type 3 NODATA by the upstream's
    /// own resolver, was re-asked of a public T1 that has never heard of it. The T1's
    /// NXDOMAIN is retained as an authoritative negative and OUTRANKS a soft failure at the exit,
    /// so the client received "does not exist" for a name that does.
    func testALegitimateNegativeIsNeverReplacedByAPublicResolversNXDOMAIN() {
        let recorder = WireRecorder()
        let query = plainQuery(domain: "host.tailnet.ts.net")
        let empty = emptyAnswer(for: query, backedByAuthority: false)
        recorder.script(Self.primary, [DNSUpstreamResponse(response: empty, outcome: .success)])
        recorder.script(
            Self.secondary,
            [DNSUpstreamResponse(response: response(for: query, rcode: 3), outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(
            verdict.result.response, empty,
            "the upstream's own negative must reach the client, not a stranger's NXDOMAIN")
        XCTAssertFalse(
            verdict.result.response.flatMap { DNSAnswerDisposition.disposition(ofResponse: $0) } == .nameDoesNotExist,
            "a name that exists must not be answered NXDOMAIN")
    }

    /// An ordinary backed NODATA is likewise returned from the first resolver, unqueried twice.
    func testABackedEmptyAnswerIsReturnedWithoutASecondQuery() {
        let recorder = WireRecorder()
        let query = plainQuery()
        let nodata = emptyAnswer(for: query, backedByAuthority: true)
        recorder.script(Self.primary, [DNSUpstreamResponse(response: nodata, outcome: .success)])
        recorder.script(
            Self.secondary, [DNSUpstreamResponse(response: response(for: query), outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(recorder.sentQueries.map(\.address), [Self.primary])
        XCTAssertEqual(verdict.result.response, nodata)
        XCTAssertTrue(verdict.sawEmptyAnswer)
        XCTAssertFalse(verdict.sawUnbackedEmptyAnswer, "an authority section backs it")
    }

    /// The reply SHAPE reaches every exit, including the ones that never return the empty answer
    /// itself — the telemetry is about what the route SAW, and the capture is read after the
    /// fact. Both terms travel together, and unbacked is a strict subset of empty.
    /// (`Verdict.sawEmptyAnswer` / `sawUnbackedEmptyAnswer` → `chainedDNSEmptyAnswer`.)
    func testAnEmptyAnswerIsReportedWithItsBacking() {
        let query = plainQuery()
        for backed in [true, false] {
            let recorder = WireRecorder()
            recorder.script(
                Self.primary,
                [DNSUpstreamResponse(
                    response: emptyAnswer(for: query, backedByAuthority: backed),
                    outcome: .success)])
            recorder.script(Self.secondary, [DNSUpstreamResponse(response: nil, outcome: .timeout)])

            let verdict = TunnelledPlainDNSResolution.resolve(
                query: query, route: route(),
                resolveUDP: recorder.resolve)

            XCTAssertTrue(verdict.sawEmptyAnswer, "backed=\(backed)")
            XCTAssertEqual(verdict.sawUnbackedEmptyAnswer, !backed, "backed=\(backed)")
        }
    }

    /// The address-query split, which the header-only terms above cannot make.
    ///
    /// This is the whole point of the field: `sawEmptyAnswer` is read from answer/authority
    /// counts and never looks at the QUESTION, so an AAAA NODATA for a v4-only host — most of
    /// DNS, entirely benign — and an A NODATA for a public name — the client gets no address at
    /// all — are one number in it. On a network with no IPv6 the second is a total failure to
    /// load while every counter reads healthy (field 2026-08-28, build 1787899086).
    func testAnIPv4AddressNegativeIsReportedByShape() {
        let cases: [(UInt16, TunnelledPlainDNSResolution.IPv4AddressNegative, String)] = [
            (DNSRecordType.a.rawValue, .emptyAnswer, "A NODATA is the shape that costs a page"),
            (DNSRecordType.aaaa.rawValue, .none, "AAAA NODATA is ordinary and must not count"),
        ]
        for (recordType, expected, message) in cases {
            let query = DNSResolverSmokeProbe.query(
                transactionID: 0x1234, domain: "example.com", recordType: recordType)
            let recorder = WireRecorder()
            recorder.script(
                Self.primary,
                [DNSUpstreamResponse(
                    response: emptyAnswer(for: query, backedByAuthority: true), outcome: .success)])

            let verdict = TunnelledPlainDNSResolution.resolve(
                query: query, route: route(), resolveUDP: recorder.resolve)

            XCTAssertEqual(verdict.ipv4AddressNegative, expected, message)
            XCTAssertTrue(verdict.sawEmptyAnswer, "the header-only term still reports both shapes")
        }
    }

    /// NXDOMAIN on an address query counts too, because to the client it is the same event —
    /// no address — and the unsolved MagicDNS shape this file documents answers public names
    /// NXDOMAIN rather than NODATA. Counting only the empty case would miss it entirely.
    func testAnNXDomainOnAnAddressQueryIsReportedAsANegative() {
        let query = plainQuery()
        let recorder = WireRecorder()
        recorder.script(
            Self.primary,
            [DNSUpstreamResponse(response: response(for: query, rcode: 3), outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(verdict.ipv4AddressNegative, .nameDoesNotExist)
        XCTAssertFalse(
            verdict.sawEmptyAnswer,
            "NXDOMAIN is not an empty NOERROR — the two terms describe different wire shapes")
    }

    /// The verdict must carry WHICH KIND of address came back, not just that one did.
    ///
    /// This is the fact left after the negative family came back all-zero in the field: the
    /// chained route carries `100.64.0.0/10` into the tunnel and sends the rest direct, so a
    /// public name answered inside that range resolves fine and then loads nothing. The
    /// classification itself is covered in `IPv4AnswerAddressClassesTests`; this pins that the
    /// resolution actually reads the ANSWER bytes and reports them.
    func testTheAnswerAddressClassesAreReportedForTheAnsweredResponse() {
        let query = plainQuery()
        let recorder = WireRecorder()
        recorder.script(
            Self.primary,
            [DNSUpstreamResponse(
                response: response(for: query, addresses: [[93, 184, 216, 34], [100, 64, 0, 5]]),
                outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertTrue(verdict.ipv4AnswerAddressClasses(forQuery: query).containsPublicRoutable)
        XCTAssertTrue(
            verdict.ipv4AnswerAddressClasses(forQuery: query).containsCarrierGradeNAT,
            "the tunnel-routed range is the one this diagnostic exists to surface")
        XCTAssertFalse(verdict.ipv4AnswerAddressClasses(forQuery: query).containsPrivateUse)
        XCTAssertEqual(
            verdict.ipv4AddressNegative, .none,
            "an answered set is not a negative — the two families must not both fire")
    }

    /// A reply the CLIENT never gets must not be recorded as a healthy public answer.
    ///
    /// The extractor hands back what it collected before structural damage, so a good A record
    /// followed by a malformed later record still yields an address — while `completeForward`
    /// rejects that same reply on `hasWellFormedResourceRecords` and sends SERVFAIL. Counting it
    /// would put "public DNS answered fine" in a capture for a lookup that failed, which is the
    /// one way this diagnostic could actively mislead the next investigation (Codex P2, PR #619).
    func testAMalformedTailIsNotClassifiedAsAHealthyPublicAnswer() {
        let query = plainQuery()
        // One well-formed A record, then ANCOUNT claiming a second that is not there.
        var bytes = [UInt8](response(for: query, addresses: [[93, 184, 216, 34]]))
        bytes[6] = 0x00
        bytes[7] = 0x02
        let damaged = Data(bytes)

        XCTAssertFalse(
            DNSWireMessage.hasWellFormedResourceRecords(damaged),
            "precondition: this is the shape completeForward turns into SERVFAIL")
        XCTAssertEqual(
            DNSBootstrapAddressExtractor.addresses(
                from: damaged, matching: query, recordType: .a),
            ["93.184.216.34"],
            "precondition: the extractor alone still yields the address — the gate is what stops it")

        let recorder = WireRecorder()
        recorder.script(
            Self.primary, [DNSUpstreamResponse(response: damaged, outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertTrue(
            verdict.ipv4AnswerAddressClasses(forQuery: query).isEmpty,
            "a reply the client never receives contributes no address class")
    }

    /// A reply that FAILED contributes no address class, even when it carries address records.
    ///
    /// An NXDOMAIN answering a CNAME chain carries records, and a broken resolver can attach
    /// them to a SERVFAIL. Classifying those would put a healthy public answer in the capture
    /// for a lookup the client saw fail — and would have this counter contradict
    /// `ipv4AddressNegative`, which reports the error for the same reply (Kilo, PR #619).
    func testAFailingReplyIsNotClassifiedEvenWhenItCarriesAddresses() {
        let query = plainQuery()
        // A well-formed answer section, then the header rcode flipped to NXDOMAIN.
        var bytes = [UInt8](response(for: query, addresses: [[93, 184, 216, 34]]))
        bytes[3] = (bytes[3] & 0xF0) | 3
        let negative = Data(bytes)

        let recorder = WireRecorder()
        recorder.script(Self.primary, [DNSUpstreamResponse(response: negative, outcome: .success)])
        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertTrue(
            verdict.ipv4AnswerAddressClasses(forQuery: query).isEmpty,
            "a failing reply contributes no class, however many addresses it carries")
        XCTAssertEqual(
            verdict.ipv4AddressNegative, .nameDoesNotExist,
            "and the negative family still reports it — the two must agree about one reply")
    }

    /// An ordinary public answer reports exactly one class, so a capture full of healthy
    /// lookups reads as "public" rather than as noise across all four counters.
    func testAnOrdinaryPublicAnswerReportsOnlyThePublicClass() {
        let query = plainQuery()
        let recorder = WireRecorder()
        recorder.script(
            Self.primary,
            [DNSUpstreamResponse(response: response(for: query), outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertTrue(verdict.ipv4AnswerAddressClasses(forQuery: query).containsPublicRoutable)
        XCTAssertFalse(verdict.ipv4AnswerAddressClasses(forQuery: query).containsCarrierGradeNAT)
        XCTAssertFalse(verdict.ipv4AnswerAddressClasses(forQuery: query).containsPrivateUse)
        XCTAssertFalse(verdict.ipv4AnswerAddressClasses(forQuery: query).containsSpecialUse)
    }

    /// Nothing to classify reports EMPTY, and the two families stay disjoint: an A NODATA is a
    /// negative with no classes, never a class with no negative.
    func testAnAnswerWithNoAddressesReportsNoClasses() {
        let query = plainQuery()
        let recorder = WireRecorder()
        recorder.script(
            Self.primary,
            [DNSUpstreamResponse(
                response: emptyAnswer(for: query, backedByAuthority: true), outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertTrue(verdict.ipv4AnswerAddressClasses(forQuery: query).isEmpty)
        XCTAssertEqual(verdict.ipv4AddressNegative, .emptyAnswer)
    }

    /// AAAA answers are not classified at all — the counters describe IPv4 routing, and an
    /// AAAA reply carries no A records for the extractor to read.
    func testAnIPv6QueryReportsNoIPv4AddressClasses() {
        let query = DNSResolverSmokeProbe.query(
            transactionID: 0x1234, domain: "example.com",
            recordType: DNSRecordType.aaaa.rawValue)
        let recorder = WireRecorder()
        recorder.script(
            Self.primary,
            [DNSUpstreamResponse(response: response(for: query), outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertTrue(verdict.ipv4AnswerAddressClasses(forQuery: query).isEmpty)
    }

    /// The IPv6 answer counter's verdict: true only for a RESOLVED AAAA reply that carried an
    /// address, so the one diagnostic that can see v6 traffic is not fooled by the other shapes.
    func testAnIPv6AnswerIsReportedOnlyForAResolvedAAAAQuery() {
        let aaaaQuery = DNSResolverSmokeProbe.query(
            transactionID: 0x1234, domain: "example.com", recordType: DNSRecordType.aaaa.rawValue)
        let v6: [UInt8] = [0x26, 0x06, 0x47, 0x00, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11]
        let recorder = WireRecorder()
        recorder.script(
            Self.primary,
            [DNSUpstreamResponse(
                response: responseAAAA(for: aaaaQuery, addresses: [v6]), outcome: .success)])
        let verdict = TunnelledPlainDNSResolution.resolve(
            query: aaaaQuery, route: route(), resolveUDP: recorder.resolve)
        XCTAssertTrue(verdict.hasIPv6AnswerAddress(forQuery: aaaaQuery))

        // An A query is not an AAAA question, so the v6 verdict stays false however the reply
        // is shaped — the two families must not both fire on one resolution.
        let aQuery = plainQuery()
        let aRecorder = WireRecorder()
        aRecorder.script(
            Self.primary,
            [DNSUpstreamResponse(response: response(for: aQuery), outcome: .success)])
        let aVerdict = TunnelledPlainDNSResolution.resolve(
            query: aQuery, route: route(), resolveUDP: aRecorder.resolve)
        XCTAssertFalse(aVerdict.hasIPv6AnswerAddress(forQuery: aQuery))

        // A NOERROR/NO-answer AAAA reply carries no address and reports false, matching the IPv4
        // classes' "nothing to classify".
        let negativeRecorder = WireRecorder()
        negativeRecorder.script(
            Self.primary,
            [DNSUpstreamResponse(
                response: emptyAnswer(for: aaaaQuery, backedByAuthority: true),
                outcome: .success)])
        let negativeVerdict = TunnelledPlainDNSResolution.resolve(
            query: aaaaQuery, route: route(), resolveUDP: negativeRecorder.resolve)
        XCTAssertFalse(negativeVerdict.hasIPv6AnswerAddress(forQuery: aaaaQuery))
    }

    /// An EDNS extended RCODE whose low nibble is 3 is NOT NXDOMAIN, and must not be counted as
    /// one.
    ///
    /// A header-nibble classifier would misread BADMODE (19) as NXDOMAIN (3), so
    /// it. Landing that in `chainedDNSNXDomainIPv4Address` would tell the next investigation "your
    /// resolver says the name does not exist" about a reply that says nothing of the kind — the
    /// same misreading this whole field exists to stop (Codex, PR #616).
    func testAnExtendedRCodeIsNotCountedAsNXDomain() {
        let query = plainQuery()
        let recorder = WireRecorder()
        // Header nibble 3 with an OPT carrying extended RCODE bits — full RCODE 19, not 3.
        var bytes = [UInt8](response(for: query, rcode: 3))
        bytes[11] = 1  // ARCOUNT
        var withOPT = Data(bytes)
        withOPT.append(contentsOf: [0x00, 0x00, 0x29, 0x10, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00])
        recorder.script(
            Self.primary, [DNSUpstreamResponse(response: withOPT, outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(
            verdict.ipv4AddressNegative, .none,
            "full RCODE 19 shares its low nibble with NXDOMAIN and is not one")
    }

    /// A served answer reports nothing, so the counter cannot read as "this resolver answers
    /// nothing" on a route that resolved every name.
    func testAServedAddressAnswerReportsNoNegative() {
        let query = plainQuery()
        let recorder = WireRecorder()
        recorder.script(
            Self.primary, [DNSUpstreamResponse(response: response(for: query), outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(verdict.ipv4AddressNegative, .none)
    }

    /// A route that never sees one reports neither term — the counters must not read as "the
    /// resolver answers nothing" on a route that served every name.
    func testAServedAnswerReportsNoEmptyAnswer() {
        let recorder = WireRecorder()
        let query = plainQuery()
        recorder.script(
            Self.primary, [DNSUpstreamResponse(response: response(for: query), outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertNotNil(verdict.result.response)
        XCTAssertFalse(verdict.sawEmptyAnswer)
        XCTAssertFalse(verdict.sawUnbackedEmptyAnswer)
    }

    // MARK: - servedByFallback (the chainedDNSFallbackRescue numerator, Codex/Kilo PR #575)

    func testASourceMatchedMismatchIsTunnelDNSLiveness() {
        // The observation the OUTAGE DRIVER sees, not just the fallback panel (Codex, PR #577).
        // A resolution ending only in `.mismatchedResponse` produced NO observation, so the
        // accumulated unanswered tally was never cleared — and a later timeout for a different
        // name could declare a tunnel-DNS outage and trigger recovery on a path that had just
        // demonstrably carried a reply. The file's own rule is "an answer from any selected
        // resolver" answers "no" to "is tunnel DNS gone"; a source-matched datagram is one.
        let recorder = WireRecorder()
        let query = plainQuery()
        for address in [Self.primary, Self.secondary] {
            recorder.script(
                address, [DNSUpstreamResponse(response: nil, outcome: .mismatchedResponse)])
        }
        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(
            verdict.observation, .answered,
            "a reply from a selected resolver is liveness, whatever this attempt made of it")
    }

    func testOffSourceJunkIsNeverTunnelDNSLiveness() {
        // The other half, and the reason the split exists: a datagram from somewhere else is not
        // the resolver answering, so it must not credit liveness. Crediting it would silence a
        // genuine outage whenever unrelated traffic reached the socket.
        let recorder = WireRecorder()
        let query = plainQuery()
        for address in [Self.primary, Self.secondary] {
            recorder.script(
                address, [DNSUpstreamResponse(response: nil, outcome: .unexpectedSourceResponse)])
        }
        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertNil(
            verdict.observation,
            "unsolicited traffic must not read as the tunnel's DNS being alive")
    }

    func testOnlyOutcomesThatProveADatagramWentOutReachTheWire() {
        // THE PARTITION, driven off `allCases` rather than restated. The comment here has always
        // promised that "a NEW outcome cannot quietly default into 'a datagram went out'" — but
        // two hand-written lists cannot deliver that, and did not: `.resolverPortUnavailable` was
        // added to the predicate and to neither list, so the case this very property exists to
        // catch is the one it missed (Kilo, PR #623). Enumerating means an unclassified outcome
        // fails here instead of being silently absent.
        let sentOutcomes: Set<ResolverAttemptOutcome> = [
            .success, .truncatedAnswer, .timeout, .receiveFailed,
            .mismatchedResponse, .unexpectedSourceResponse, .httpStatusFailure,
        ]
        for outcome in ResolverAttemptOutcome.allCases {
            XCTAssertEqual(
                outcome.reachedTheWire, sentOutcomes.contains(outcome),
                "\(outcome.rawValue) is classified against the partition, not by default — "
                    + "everything not listed as sent must prove nothing left the device")
        }
        // Every deliberate refusal is a local decision, so none of them may read as a send —
        // the two categories must agree wherever they overlap.
        for outcome in [
            ResolverAttemptOutcome.refusedByEgressPolicy, .refusedAfterLifecycleEnded,
            .refusedAfterLatchReplaced, .tunnelInterfaceUnavailable, .physicalInterfaceUnavailable,
        ] where outcome.isDeliberateRefusal {
            XCTAssertFalse(
                outcome.reachedTheWire, "a deliberate refusal cannot also be a wire attempt")
        }

        // THE LADDER-ENDING CATEGORY, asserted as a category for the reason it exists: there are
        // four ladder-break tests across the plain and device ladders, and an equality test at each
        // of them is four places a third terminal refusal has to find. Exactly what happened when
        // `.refusedAfterLatchReplaced` was added (PR #610).
        for terminal in [
            ResolverAttemptOutcome.refusedAfterLifecycleEnded, .refusedAfterLatchReplaced,
        ] {
            XCTAssertTrue(
                terminal.endsTheResolutionLadder,
                "\(terminal.rawValue) means the work belongs to nothing — walking on repeats it")
            XCTAssertFalse(
                terminal.reachedTheWire,
                "and it must never read as a send, or the panel counts a query never made")
        }
        // A REFUSAL IS NOT AUTOMATICALLY TERMINAL. `.refusedByEgressPolicy` and
        // `.tunnelInterfaceUnavailable` are per-attempt verdicts: the next address may be routable
        // or the interface may come up, so the ladder must keep walking.
        for perAttempt in [
            ResolverAttemptOutcome.refusedByEgressPolicy, .tunnelInterfaceUnavailable,
            .physicalInterfaceUnavailable, .timeout, .backedOff, .success,
        ] {
            XCTAssertFalse(
                perAttempt.endsTheResolutionLadder,
                "\(perAttempt.rawValue) fails one rung, not the whole ladder")
        }
    }

    func testATimeoutThenAnAnswerIsAnswered() {
        let recorder = WireRecorder()
        let query = plainQuery()
        let served = response(for: query)
        recorder.script(Self.primary, [DNSUpstreamResponse(response: nil, outcome: .timeout)])
        recorder.script(Self.secondary, [DNSUpstreamResponse(response: served, outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(), resolveUDP: recorder.resolve)

        XCTAssertEqual(verdict.result.response, served)
        XCTAssertEqual(verdict.result.successfulResolverAddress, Self.secondary)
        XCTAssertEqual(verdict.result.attempts.map(\.outcome), [.timeout, .success])
        XCTAssertEqual(verdict.observation, .answered)
    }

    func testAnUnparseableQueryTimesOutWithNoName() {
        // No name means no key for the distinct-names floor; the provider drops the
        // report, which is the fail-SAFE direction — nothing arms.
        let recorder = WireRecorder()
        let unparseable = Data(repeating: 0x00, count: 12)

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: unparseable, route: route([Self.primary]), resolveUDP: recorder.resolve)

        XCTAssertEqual(verdict.observation, .unanswered(normalizedQueryName: nil))
    }

    func testAnInvalidAddressIsRecordedAndSkipped() {
        // The selection refuses non-literals upstream, so this is a belt-and-braces
        // divergence path: the loop records it and fails over rather than aborting.
        let recorder = WireRecorder()
        let query = plainQuery()
        let served = response(for: query)
        recorder.script(Self.secondary, [DNSUpstreamResponse(response: served, outcome: .success)])

        let verdict = TunnelledPlainDNSResolution.resolve(
            query: query, route: route(["not-an-address", Self.secondary]),
            resolveUDP: recorder.resolve)

        XCTAssertEqual(verdict.result.response, served)
        XCTAssertEqual(verdict.result.attempts.map(\.outcome), [.invalidAddress, .success])
        XCTAssertEqual(recorder.sentQueries.map(\.address), [Self.secondary])
    }
}
