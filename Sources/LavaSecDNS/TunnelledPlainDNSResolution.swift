import Foundation

/// The tunnelled `.plainDNS` resolution loop (S6): plain UDP DNS to the upstream's own
/// resolvers, carried through the chained session, with the EDNS0 cap applied and the
/// outcome classified for the outage supervisor's observation door.
///
/// A package type rather than provider code so every decision here has executable tests —
/// the wire I/O is injected, exactly as `ResolverOrchestrator.Executors` injects it one
/// layer up. The provider's executor supplies its interface-pinned `resolveUDP` (the
/// S8.7b socket carry: the kernel emits the datagram on the tunnel interface and it
/// surfaces at the provider's own `readPackets`; `ChainedResolverEgressPolicy.socketBinding`
/// is the seam), so nothing in this type can egress anywhere the socket layer would not.
/// This carry was validated with ordinary routing. The September 23 `includeAllNetworks`
/// comparison put provider DNS on physical Wi-Fi; this loop does not itself enforce containment.
/// See `lavasec-infra/records/ios-planning/2026-09-23-connectivity-assist-validation.md` before enabling strict routing.
///
/// What this loop deliberately does NOT have:
/// - **No TCP retry.** Resolved decision 3 (phase-3 plan): truncation is mitigated by the
///   EDNS0 advertisement and the residual fails CLOSED per `INV-DNS-1`; the tunnelled TCP
///   retry is a follow-up gated on S9 field evidence. The DNS-only ladder's
///   `shouldAttemptTCPFallback` already answers `false` for `.truncatedAnswer`; this type
///   simply contains no TCP path at all.
/// - **No fallback ladder.** Device DNS and the encrypted transports are physical-interface
///   behaviours, suspended while chained (`ChainedResolverEgressPolicy`); the failover here
///   is only across the route's own selected resolvers.
public enum TunnelledPlainDNSResolution {
    /// What this resolution tells the outage supervisor, in module-neutral vocabulary.
    ///
    /// `LavaSecChainedUpstream` cannot be imported here (the dependency runs the other
    /// way; the packet tunnel is that module's one approved consumer), so this is the
    /// same pattern as `EgressAllowance`: this module states the OUTCOME as a plain
    /// value and the provider maps it onto
    /// `ChainedOutageDriver.TunnelDNSObservation`. `nil` observation means silence —
    /// nothing here is evidence about the resolver.
    public enum Observation: Equatable, Sendable {
        /// A resolver produced a valid answer — a truncated one included. TC is the
        /// resolver replying, promptly and correctly, that the response does not fit
        /// UDP; reporting it as anything else lets one large-response domain spend the
        /// outage budget (resolved decision 3, and
        /// `ChainedResolverEgressPolicy.truncationIsResolverLiveness`). SERVFAIL,
        /// NXDOMAIN and REFUSED from the upstream are equally a resolver ANSWERING.
        case answered
        /// At least one query was actually sent and its receive budget elapsed with
        /// nothing valid back, and NO resolver in the route answered. Carries the
        /// normalized query name (nil when the query does not parse) so the provider
        /// can key the driver's distinct-names floor; the driver itself never sees a
        /// name.
        ///
        /// ONLY the sent-and-unanswered shape maps here. Local refusals — a send
        /// failure, an expired port claim, a refused binding, a mismatched-response
        /// storm — are not evidence about the resolver, and reporting them would arm
        /// the outage budget on conditions a session rebuild cannot fix.
        case unanswered(normalizedQueryName: String?)
    }

    /// The resolution's result plus what — if anything — it observed about the resolver.
    public struct Verdict: Sendable {
        /// The result handed back to the orchestrator. A truncated or failed resolution
        /// carries `response: nil`, and the forwarding path synthesizes the fail-closed
        /// SERVFAIL from exactly that (`INV-DNS-1`); the TC answer's bytes are never in
        /// here, so they cannot be relayed to a stub whose TCP retry the tunnel does
        /// not serve.
        public let result: DNSResolutionResult
        /// Evidence for the outage supervisor, or `nil` when this resolution learned
        /// nothing about the resolver.
        public let observation: Observation?
        /// The query's normalized name, when this resolution ended with NO response.
        /// `nil` when it completed, and when the query does not parse.
        ///
        /// Separate from ``Observation/unanswered(normalizedQueryName:)`` because the
        /// observation answers a different question. It is a LIVENESS verdict: a TC answer
        /// paired with another resolver's silence classifies `.answered`, on purpose, because
        /// the outage supervisor must not spend its budget on one large-response domain. A
        /// consumer measuring SILENCE cannot read that verdict without inheriting the
        /// liveness rule — the TC-plus-timeout resolution would look like no timeout at all
        /// (Codex, PR #520). Callers deriving evidence take the result and the attempts, and
        /// this is the name to attribute them to.
        public let unresolvedQueryName: String?
        // THE TUNNELLED ROUTE HAS NO T1 TO REPORT ON, so the three T1 terms this
        // outcome carried — `servedByFallback`, `attemptedFallback`, `answeredByFallback` — are
        // gone with the route field they were computed from.
        //
        // They were membership tests against `route.fallbackResolverAddresses`, which PR #590
        // stopped populating: the rung egresses on the physical interface, so nothing the tunnel
        // carries is T1 any more and all three were permanently false. The evidence they
        // stood for is not lost — the rung records its own
        // (`ResolverOrchestrator.TierOneRungEvidence` → the provider's
        // `applyChainedFallbackEvidenceOnQueue`), which is where it belongs now that the two
        // tiers travel on two different interfaces (the plan's S3).
        /// SOME resolver on this route replied NOERROR with no answer records — a NODATA of
        /// either kind (``DNSResolverSmokeProbe/EmptyAnswer``). QA telemetry only
        /// (`chainedDNSEmptyAnswer`), set on EVERY exit and NOT gated on a T1 existing.
        ///
        /// Reported because the reply SHAPE was twice inferred from what other counters did not
        /// move rather than read off a capture: a primary answering every public name with an
        /// empty NOERROR leaves `chainedDNSSilentTimeout` at 0, `chainedDNSFallbackRescue` at 0
        /// and `tunnelDNSAnswered` climbing — indistinguishable, in the numbers alone, from a
        /// route that is simply working (field 2026-08-26, build 1787707228). A capture should
        /// state it.
        /// pinned: TunnelledPlainDNSResolutionTests.testAnEmptyAnswerIsReportedWithItsBacking
        public let sawEmptyAnswer: Bool
        /// Of those, ones with NOTHING backing the negative — no answer records AND no authority
        /// records (``DNSResolverSmokeProbe/EmptyAnswer/unbacked``), the shape a resolver
        /// produces about a zone it does not serve. A strict subset of ``sawEmptyAnswer``, which
        /// is why both are carried: ordinary NODATA is most of DNS (every AAAA for an IPv4-only
        /// host), so the two counted as one number say nothing.
        /// pinned: TunnelledPlainDNSResolutionTests.testAnEmptyAnswerIsReportedWithItsBacking
        public let sawUnbackedEmptyAnswer: Bool
        /// What T0 said about an **IPv4 address** query when it said nothing usable.
        ///
        /// ``sawEmptyAnswer`` cannot answer this: it is read from the header alone — answer count
        /// and authority count — and never looks at the QUESTION. So an AAAA NODATA for a v4-only
        /// host, which is most of DNS and entirely benign, is indistinguishable in it from an A
        /// NODATA for a public name, which leaves the client with no address at all. On a network
        /// with no IPv6 the second is a total failure to load, while every counter in the capture
        /// reads healthy — the exact shape this family of counters was added to make visible, and
        /// the exact way it stayed invisible anyway (field 2026-08-28, build 1787899086: 230 empty
        /// answers across 1266 resolutions read as benign because `unbacked` was 0).
        ///
        /// NXDOMAIN is carried in the same field rather than a second one because for an address
        /// query the two are the same event to the client — no address — and this file's own note
        /// on the unsolved MagicDNS shape says the resolver that answers nothing answers NXDOMAIN,
        /// not NODATA. Counting only the empty case would have missed it.
        /// pinned: TunnelledPlainDNSResolutionTests.testAnIPv4AddressNegativeIsReportedByShape
        public let ipv4AddressNegative: IPv4AddressNegative

        /// Which routing classes this verdict's answered A records carried.
        ///
        /// A METHOD, not a stored term, and that is a build-configuration constraint rather
        /// than a style choice: every other term here is a header read, but this one walks the
        /// answer section, and it exists only to feed QA counters. `Package.swift` declares no
        /// `swiftSettings`, so `LAVA_QA_TOOLS` is undefined for the SPM targets and a
        /// `#if DEBUG || LAVA_QA_TOOLS` in this file would collapse to DEBUG-only — taking the
        /// diagnostic out of the QA builds the field captures come from. Computing on demand
        /// puts the decision at the caller instead, where the tunnel's own QA gate is real, and
        /// Release pays nothing.
        ///
        /// TELEMETRY ONLY, on the same terms as ``ipv4AddressNegative`` — nothing in the
        /// resolution path may route, fail over, or rewrite on it.
        ///
        /// It exists because the 2026-08-29 field report ruled the DNS *answer shape* out and
        /// left nowhere else to look: the resolver answered 39 lookups in the minute before the
        /// failure with zero empty A answers, zero A-NXDOMAINs and zero unanswered queries,
        /// while the pages for names it had just resolved did not load. The next fact a capture
        /// needs is not whether an address came back but WHICH KIND: the chained route carries
        /// `100.64.0.0/10` into the tunnel and sends the rest direct, so a public name answered
        /// with a CGNAT or private address is a connection routed somewhere the browser is not
        /// expecting — which presents as exactly that symptom.
        ///
        /// IT DOES NOT KNOW WHETHER THE NAME IS PUBLIC, so only the public class stands alone.
        /// The other three say the address was not routable for the browser, and every one of
        /// them has a correct reading that looks identical to the poisoning they were added to
        /// detect (Codex, PR #619): MagicDNS answers tailnet names from `100.64.0.0/10`; a split
        /// conf may route an RFC1918 range and put its resolver inside it; and a filtering
        /// upstream answers a name it blocks with `0.0.0.0`. The conf's search domains are what
        /// would separate an internal name from a public one and they never reach this module —
        /// `ChainedTunnelResolverSelection` keeps only usable resolver ADDRESSES from `DNS =`.
        ///
        /// So a non-zero minute in any of the three is a pointer to the names `domain-history`
        /// recorded in that minute, not a verdict — and only when it recorded any: these run
        /// unconditionally in a QA build, while the name log is gated on the user's Domain Logs
        /// setting and is cleared when they turn it off. With no names to pair against, read all
        /// three as UNRESOLVED — neither the benign explanation nor the poisoning.
        ///
        /// - Parameter query: the query this verdict answers, needed both to tell an A question
        ///   from any other and to validate the reply against the request it was issued for.
        /// - Returns: `.none` for a non-A query, a verdict that carries no response, or a reply
        ///   whose records do not parse — see the gate's note below.
        /// pinned: IPv4AnswerAddressClassesTests.testTheChainedRouteRangesAreClassifiedApart
        /// pinned: TunnelledPlainDNSResolutionTests.testTheAnswerAddressClassesAreReportedForTheAnsweredResponse
        public func ipv4AnswerAddressClasses(forQuery query: Data) -> IPv4AnswerAddressClasses {
            guard let addresses = resolvedAnswerAddresses(forQuery: query, recordType: .a) else {
                return .none
            }
            return IPv4AnswerAddressClasses(classifying: addresses)
        }

        /// Whether a resolved, well-formed reply to an AAAA query carried at least one IPv6
        /// address.
        ///
        /// THE IPv6 COUNTER THE IPv4 CLASSES LEFT OUT. Every other chained answer counter is
        /// IPv4-shaped, so a v6 answer bumped none of them — in the 2026-09-17/19 captures roughly
        /// half the resolutions landed in no address counter at all, which is part of why the
        /// v6-shaped escape went unseen (`plans/2026-09-17-path-independent-dns-capture-floor.md`,
        /// observability gap). Shares `resolvedAnswerAddresses` with the IPv4 method, so the two
        /// cannot drift in WHICH replies they trust — only in the record type they ask for.
        public func hasIPv6AnswerAddress(forQuery query: Data) -> Bool {
            guard let addresses = resolvedAnswerAddresses(forQuery: query, recordType: .aaaa) else {
                return false
            }
            return !addresses.isEmpty
        }

        /// The answer-section addresses of a resolved, well-formed reply to `query`, or nil when
        /// the reply fails any of the trust gates below.
        ///
        /// ONE HELPER FOR BOTH FAMILIES: the gates answer "is this a reply the client actually
        /// received, and did it resolve?", which is independent of record type. A second copy is
        /// how the two would come to disagree about it.
        private func resolvedAnswerAddresses(
            forQuery query: Data, recordType: DNSRecordType
        ) -> [String]? {
            guard (try? DNSMessage.parseQuestion(from: query))?.recordType == recordType,
                let response = result.response
            else {
                return nil
            }

            // GATED ON THE WHOLE MESSAGE PARSING, not just on the extractor's own per-answer
            // checks. The extractor returns what it collected BEFORE structural damage, so a
            // reply with a good A record followed by a malformed later record yields an address
            // — while `completeForward` rejects that same reply and sends the client SERVFAIL.
            // Classifying it would put "public DNS answered fine" in a capture for a lookup the
            // client never received, which is the one way a diagnostic actively misleads the
            // next investigation (Codex P2, PR #619). Same bar the NXDOMAIN arm holds.
            // pinned: TunnelledPlainDNSResolutionTests.testAMalformedTailIsNotClassifiedAsAHealthyPublicAnswer
            guard DNSWireMessage.hasWellFormedResourceRecords(response) else {
                return nil
            }

            // AND THE REPLY MUST HAVE RESOLVED. A failing reply can still carry address records
            // — an NXDOMAIN answering a CNAME chain, or a broken resolver attaching records to a
            // SERVFAIL — and classifying those would report a healthy public answer for a lookup
            // the client saw fail, while `ipv4AddressNegative` reported the error on the same
            // resolution. Two counters describing one reply must not contradict each other
            // (Kilo, PR #619). Reads the FULL 12-bit code, like the NXDOMAIN arm.
            // pinned: TunnelledPlainDNSResolutionTests.testAFailingReplyIsNotClassifiedEvenWhenItCarriesAddresses
            guard DNSEDNS0.fullRCode(of: response) == 0 else {
                return nil
            }

            // Reuses the bootstrap extractor rather than walking the answer section again: that
            // walk already carries the trust gate this must not skip — the response is validated
            // against the issuing query, each answer must be class IN with an exactly-sized
            // payload, and a structurally damaged answer stops extraction — and a second
            // hand-rolled parser is the one part of this diagnostic that could go wrong in a way
            // the counters would never reveal.
            return DNSBootstrapAddressExtractor.addresses(
                from: response, matching: query, recordType: recordType)
        }
    }

    /// T0's answer to an IPv4 address query, when that answer carried no address.
    ///
    /// TELEMETRY ONLY. Nothing in the resolution path may act on it — the same rule
    /// ``Verdict/sawEmptyAnswer`` carries, and for the same reason recorded above the NODATA block
    /// below: the wire shape is ambiguous and failing over on it can replace a legitimate
    /// split-DNS negative with a stranger's NXDOMAIN (PR #589).
    public enum IPv4AddressNegative: Sendable, Equatable {
        /// Not an A query, or the answer carried address records.
        case none
        /// NOERROR with no answer records, for an A query.
        case emptyAnswer
        /// NXDOMAIN, for an A query.
        case nameDoesNotExist
    }

    /// Resolves `query` against the route's resolvers in failover order over injected
    /// UDP I/O.
    ///
    /// The EDNS0 advertisement is capped ONCE, before the loop, and the same capped
    /// bytes go to every resolver — capping per attempt would let the shapes drift, and
    /// the cap is a property of the tunnel path, not of any one resolver. The rewrite
    /// touches only the OPT record's CLASS field, so the socket's anti-spoof validation
    /// (transaction ID + question bytes, `DNSWireMessage.isValidResponse`) matches the
    /// capped query exactly as it would the original.
    ///
    /// A truncated answer does not end the failover: the advertisement is identical for
    /// every resolver, but resolvers legitimately differ in what they answer (answer
    /// sets, minimization, ECS policy), so a later resolver may fit where an earlier
    /// one truncated — the DNS-only ladder's shape, minus its TCP rung. The cost is
    /// bounded by the selected set, which readiness keeps non-empty and selection keeps
    /// deduplicated.
    public static func resolve(
        query: Data,
        route: ResolverOrchestrator.TunnelledPlainDNSRoute,
        // Read the provider's live tunnelled backoff-path epoch at the START of EACH rung, so a rung
        // sent after a surviving-carry roam carries the new epoch even when an earlier rung in the same
        // failover ladder was sent before it. Stamped onto every attempt so the provider can fence stale
        // OLD-path rungs out of backoff per-attempt (task #56, Codex PR #565). Defaults to a nil-epoch
        // provider for non-tunnelled / test callers, which are never epoch-fenced.
        pathEpochAtAttempt: () -> Int? = { nil },
        resolveUDP: (Data, ResolverEndpoint) -> DNSUpstreamResponse
    ) -> Verdict {
        let cappedQuery = DNSEDNS0.cappingAdvertisedPayload(
            in: query, to: DNSEDNS0.tunnelAdvertisedPayloadBytes)

        var attempts: [ResolverAttempt] = []
        var sawTruncation = false
        var sawTimeout = false
        // A datagram FROM a selected resolver that this attempt could not use — wrong
        // transaction or question. Liveness by the same rule truncation is: the file's own
        // observation doc says "an answer from any selected resolver" answers "no" to "is tunnel
        // DNS gone". Off-source junk (`.unexpectedSourceResponse`) is deliberately NOT this
        // (Codex, PR #577).
        var sawSourceMatchedReply = false
        // The first error reply and the resolver that gave it. A server failure is a
        // resolver ANSWERING but not serving the name, so the loop tries the next resolver;
        // keeping the first means a route where nothing serves hands back that REAL answer (still
        // liveness), never a synthesized SERVFAIL and never a later resolver's.
        var softFailureResponse: Data?
        var softFailureAddress: String?
        // Reply-SHAPE telemetry, recorded and never acted on. It describes T0 only now, and
        // is the cheapest way to see an upstream resolver that answers without resolving (#588).
        var sawEmptyAnswer = false
        var sawUnbackedEmptyAnswer = false
        // Read ONCE from the original query, not per attempt: the question is identical for every
        // resolver in the ladder, and the EDNS0 cap above rewrites only the OPT record's CLASS.
        // A query whose question will not parse is not an address query for this purpose — the
        // same well-formedness bar the shape classifiers use.
        let asksForIPv4Address = (try? DNSMessage.parseQuestion(from: query))?.recordType == .a
        var ipv4AddressNegative = IPv4AddressNegative.none

        for address in route.resolverAddresses {
            let attemptEpoch = pathEpochAtAttempt()
            guard let endpoint = ResolverEndpoint(address: address) else {
                attempts.append(
                    ResolverAttempt(
                        address: address, outcome: .invalidAddress, transport: .plainDNS,
                        pathEpoch: attemptEpoch))
                continue
            }

            let udpResult = resolveUDP(cappedQuery, endpoint)

            guard let response = udpResult.response else {
                attempts.append(
                    ResolverAttempt(
                        address: address, outcome: udpResult.outcome, transport: .plainDNS,
                        pathEpoch: attemptEpoch))
                if udpResult.outcome == .timeout {
                    sawTimeout = true
                }
                if udpResult.outcome == .mismatchedResponse {
                    sawSourceMatchedReply = true
                }
                continue
            }

            if DNSMessageTraits.isTruncated(response) {
                attempts.append(
                    ResolverAttempt(
                        address: address, outcome: .truncatedAnswer, transport: .plainDNS,
                        pathEpoch: attemptEpoch))
                sawTruncation = true
                continue
            }

            if DNSResolverSmokeProbe.indicatesResolverFailure(response) {
                // A resolver error or malformed reply proves reachability, but cannot serve
                // the name. Try the next resolver while retaining the first real failure.
                // Structurally valid NOERROR/NODATA and NXDOMAIN remain authoritative: asking
                // another resolver could replace a legitimate split-DNS negative.
                // pinned: TunnelledPlainDNSResolutionTests.testAServerFailureFailsOverToTheNextResolver
                // pinned: TunnelledPlainDNSResolutionTests.testNXDOMAINIsAuthoritativeAndDoesNotFailOver
                attempts.append(
                    ResolverAttempt(
                        address: address, outcome: .success, transport: .plainDNS,
                        pathEpoch: attemptEpoch))
                if softFailureResponse == nil {
                    softFailureResponse = response
                    softFailureAddress = address
                }
                continue
            }

            // NXDOMAIN IS RETURNED BY THE LOOP ABOVE, and the deferral that used to sit here is
            // gone with the tunnelled T1 it was written for.
            //
            // #586 held an authoritative negative back so a LATER address in this same route —
            // the appended T1 — could be asked, on real field evidence (2026-08-25): a
            // Tailscale profile carrying `DNS = 100.100.100.100` serves MagicDNS names and
            // forwards nothing, so a primary authoritative for its own zone and ignorant of every
            // other answers every public name NXDOMAIN, which is identical at the wire to a
            // genuine negative. #589 reverted it because acting on that shape can replace a
            // legitimate negative with a stranger's.
            //
            // There is no later address to defer FOR: the route carries the conf's own `DNS =`
            // and nothing else since PR #590. The T1 rung that could second-guess a negative
            // runs in `ResolverOrchestrator`, on the physical interface, and deliberately does not
            // open on one — same reasoning, one layer up, where the decision now lives.
            //
            // THE FIELD SHAPE IS NOT SOLVED, and pretending otherwise here is how it gets
            // forgotten: a profile whose resolver NXDOMAINs every public name still resolves
            // nothing while chained. Discriminating it from a genuine negative needs something
            // the reply does not carry — the conf's own search domains are the candidate — and
            // that is a decision with its own slice, not a predicate to guess at in this loop.

            // NODATA — NOERROR with no answer records — is RECORDED and never acted on.
            //
            // THE FAILOVER THAT USED TO LIVE HERE WAS BUILT ON A MISREADING OF RFC 2308 §2.2
            // (Codex, PR #589). It fired on an "unbacked" empty NOERROR — no answers and no
            // authority records — on the claim that §2.2 REQUIRES a real negative to carry the
            // zone's SOA, so an empty authority section proved the resolver did not serve the
            // zone. §2.2 states no such requirement. Its definition is "the authority section
            // will contain an SOA record, OR there will be no NS records there", and it
            // enumerates a TYPE 3 NODATA whose authority section is empty. Type 3 is merely
            // discouraged for authoritative servers, not invalid, and real resolvers emit it.
            //
            // So the shape is ambiguous at the wire and cannot be failed over on. Acting on it
            // double-queried ordinary negatives and could REPLACE a legitimate one: a tailnet
            // name with no AAAA, answered Type 3 NODATA by the upstream's own resolver, would be
            // re-asked of a public T1 that has never heard of the name and answers NXDOMAIN —
            // and NXDOMAIN outranks a soft failure at the exit below, so the client would receive
            // "does not exist" for a name that does. Split-DNS names are exactly the traffic
            // chained mode exists to carry.
            //
            // The COUNTERS stay. They describe the wire shape, which is a fact, and a resolver
            // that completes every lookup without ever resolving one is still the cheapest thing
            // to read off a capture — it just is not something this loop may act on. Field
            // 2026-08-26 (build 1787723354): `chainedDNSUnbackedEmptyAnswer` was 0 across 97
            // resolutions on the profile the failover was written for, so it was cost without
            // benefit even there.
            // pinned: TunnelledPlainDNSResolutionTests.testAnUnbackedEmptyAnswerIsReturnedNotFailedOverOn
            if let emptyAnswer = DNSResolverSmokeProbe.emptyAnswer(in: response) {
                sawEmptyAnswer = true
                sawUnbackedEmptyAnswer =
                    sawUnbackedEmptyAnswer || emptyAnswer == .unbacked
                if asksForIPv4Address, ipv4AddressNegative == .none {
                    ipv4AddressNegative = .emptyAnswer
                }
            }
            // NXDOMAIN reaches here too — it is an authoritative answer, returned as-is by the
            // block below — and for an address query it costs the client exactly what a NODATA
            // does. FIRST one wins, like every other retained shape on this route.
            //
            // Full RCODE plus valid records distinguish an authoritative negative from an
            // extended error or malformed response. `emptyAnswer(in:)` applies the same bar.
            // pinned: TunnelledPlainDNSResolutionTests.testAnExtendedRCodeIsNotCountedAsNXDomain
            if asksForIPv4Address, ipv4AddressNegative == .none,
                DNSEDNS0.fullRCode(of: response) == 3,
                DNSWireMessage.hasWellFormedResourceRecords(response) {
                ipv4AddressNegative = .nameDoesNotExist
            }

            // FIRST answered set wins, matching every other retained shape on this route.
            // Reuses the bootstrap extractor rather than walking the answer section again:
            // that walk already carries the trust gate this must not skip — the response is
            // validated against the issuing query, each answer must be class IN with an
            // exactly-sized payload, and a structurally damaged answer stops extraction — and a
            // second hand-rolled parser is the one part of this diagnostic that could go wrong
            // in a way the counters would never reveal. Costs a few short strings per UPSTREAM
            // resolution, not per packet; the round trip that produced `response` took ~600 ms
            // in the field capture this was written for.
            // THIS ROUTE HANDS BACK WHAT THE RESOLVER SAID. Only error replies continue the
            // loop, above; everything that reaches here — a served answer, an authoritative
            // NXDOMAIN, a NODATA of either shape — is the resolver ANSWERING, so it is returned
            // as-is and the next resolver is never asked. The NODATA block above only RECORDS the
            // shape; it deliberately does not act on it.
            attempts.append(
                ResolverAttempt(
                    address: address, outcome: .success, transport: .plainDNS,
                    pathEpoch: attemptEpoch))
            return Verdict(
                result: DNSResolutionResult(
                    response: response,
                    successfulResolverAddress: address,
                    attempts: attempts,
                    transport: .plainDNS,
                    udpTruncated: sawTruncation,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false),
                observation: .answered,
                // This resolution COMPLETED, so there is no unresolved name to attribute —
                // an earlier resolver's timeout is not a silent domain when a later one
                // served the answer.
                unresolvedQueryName: nil,
                sawEmptyAnswer: sawEmptyAnswer,
                sawUnbackedEmptyAnswer: sawUnbackedEmptyAnswer,
                ipv4AddressNegative: ipv4AddressNegative)
        }

        // A resolver returned an error but none served the name. Hand back that real
        // answer — still liveness, a resolver replied — rather than a silence classification or a
        // synthesized SERVFAIL. It is the FIRST such reply, so a later resolver never overwrites
        // the first's verdict, and a later resolver's timeout does not erase it either, which is
        // why this precedes the silence/unanswered path below.
        //
        // NO SEPARATE NEGATIVE SLOT ANY MORE. A second retained response existed so an NXDOMAIN
        // the route had failed over PAST could outrank an earlier SERVFAIL (#586). Nothing fails
        // over past a negative on this route: an authoritative negative returns from the loop
        // above, and the T1 rung that could second-guess it deliberately does not open on one.
        let retainedResponse = softFailureResponse
        let retainedAddress = softFailureAddress
        if let retainedResponse {
            return Verdict(
                result: DNSResolutionResult(
                    response: retainedResponse,
                    successfulResolverAddress: retainedAddress,
                    attempts: attempts,
                    transport: .plainDNS,
                    udpTruncated: sawTruncation,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false),
                observation: .answered,
                unresolvedQueryName: nil,
                sawEmptyAnswer: sawEmptyAnswer,
                sawUnbackedEmptyAnswer: sawUnbackedEmptyAnswer,
                ipv4AddressNegative: ipv4AddressNegative)
        }

        // Parsed ONCE, here, where the resolution is known not to have completed — the only
        // shape any caller needs a name for.
        let unresolvedQueryName = (try? DNSMessage.parseQuestion(from: query))?.normalizedDomain

        let observation: Observation?
        if sawTruncation || sawSourceMatchedReply {
            // A resolver answered — the answer just cannot be completed over UDP, or arrived
            // for a different transaction. The liveness credit survives a LATER resolver's
            // silence: the question the outage cause asks is "is tunnel DNS gone", and an answer
            // from any selected resolver is "no".
            //
            // The source-matched arm was missing, so a resolution ending only in
            // `.mismatchedResponse` produced NO observation at all — the accumulated unanswered
            // tally was never cleared, and a later timeout for a different name could declare a
            // tunnel-DNS outage and trigger recovery on a path that had demonstrably just carried
            // a reply. The fallback predicate already counted that reply as evidence; the
            // resolution-level observation did not, which was the same judgement applied in one
            // place and not the other (Codex, PR #577).
            observation = .answered
        } else if sawTimeout {
            observation = .unanswered(normalizedQueryName: unresolvedQueryName)
        } else {
            observation = nil
        }

        return Verdict(
            result: DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: attempts,
                transport: .plainDNS,
                udpTruncated: sawTruncation,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false),
            observation: observation,
            unresolvedQueryName: unresolvedQueryName,
            sawEmptyAnswer: sawEmptyAnswer,
            sawUnbackedEmptyAnswer: sawUnbackedEmptyAnswer,
            ipv4AddressNegative: ipv4AddressNegative)
    }
}
