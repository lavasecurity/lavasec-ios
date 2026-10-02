import Foundation
import XCTest

@testable import LavaSecCore
@testable import LavaSecKit

/// The disclosure copy is a claim about the data path, so these assert the PRODUCT RULES from
/// `plans/2026-05-25-resolver-and-protection-scope-disclosure-plan.md` rather than exact wording.
///
/// The structural rule they exist to hold: this type renders the recipients it is TOLD about and
/// decides nothing about routing. Three review rounds killed the display-name shape that came
/// before (Codex, PR #641) — every categorical sentence written around a resolver NAME was false
/// for some reachable configuration.
///
/// Its mirror is asserted just as hard: naming a party that receives ZERO lookups is as false as
/// omitting one that receives them, and the later rounds found that twice — a T2 disclosed while
/// T1 could not run, and a Device-DNS T2 selection the runtime builds no plan for.
///
/// Content assertions pin `languageCode: "en"` deliberately. Ambient `Bundle.module` lookup
/// resolves in the process's preferred language and Foundation refuses a non-preferred `.lproj`
/// (the stuck-English failure `LavaCoreStringsTests` documents), so asserting English through the
/// ambient path would make these a function of the CI runner's locale rather than of the copy.
final class ProtectionScopeDisclosureTests: XCTestCase {
    private static let english = "en"

    /// LOCALE-INDEPENDENT REGISTRATION GUARD: `LavaCoreStrings` falls back to the key itself when
    /// a key is missing, so an unregistered key renders as `core.disclosure.vpn` on screen instead
    /// of failing. This is also the only test exercising the AMBIENT accessors the app calls.
    func testEveryDisclosureResolvesToRealCopyRatherThanItsKey() {
        var rendered = [
            ProtectionScopeDisclosure.dnsScopeDisclosure(),
            ProtectionScopeDisclosure.vpnDisclosure()
        ]
        rendered += ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .networkProvided, admittedTierTwo: .deviceDNS),
            isChainedUpstreamCarryingDNS: true)
        rendered += ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .named(.cloudflareDoH), admittedTierTwo: .resolver(.quad9UnfilteredDoH)),
            isChainedUpstreamCarryingDNS: false)
        rendered += ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .named(.quad9Secure), admittedTierTwo: .resolver(.quad9Unfiltered)),
            isChainedUpstreamCarryingDNS: false)
        rendered += ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(
                effectiveTierOne: .named(Self.twoServiceCustomResolver),
                admittedTierTwo: .resolver(Self.twoServiceCustomResolver)),
            isChainedUpstreamCarryingDNS: false)
        rendered += ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(
                effectiveTierOne: .named(Self.oneAddressCustomResolver), admittedTierTwo: .none),
            isChainedUpstreamCarryingDNS: false)
        rendered += ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: nil, isChainedUpstreamCarryingDNS: false)

        for text in rendered {
            XCTAssertFalse(
                text.hasPrefix("core.disclosure."),
                "\(text) is not registered — it rendered as its own key")
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(
                text.contains("%@"), "unsubstituted placeholder reached user-facing copy: \(text)")
        }
    }

    // MARK: - The type discloses what it is told, and only that

    /// T1 ABSENT MUST DISCLOSE NO T1, and this is the case chaining creates: a full-tunnel
    /// upstream is rejected by `ChainedResolverEgress.permitsTierOneFallbackOnPhysicalInterface`,
    /// and a declined rung makes `AppConfiguration.chainedTierOneResolverConfiguration` nil. The
    /// draft this replaces always emitted the network recipient, so those configurations
    /// advertised a resolver that could not receive a single lookup (Codex, PR #641).
    func testAForbiddenPhysicalRungDisclosesNoTierOneRecipient() {
        let chainedFullTunnel = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: nil, isChainedUpstreamCarryingDNS: true,
            languageCode: Self.english)

        XCTAssertEqual(chainedFullTunnel.count, 1, "only the upstream can receive a lookup here")
        XCTAssertTrue(chainedFullTunnel[0].localizedCaseInsensitiveContains("chained"))
    }

    /// A NAMED primary falls back to the NETWORK's resolver, not to the named provider — the
    /// `fallbackToDeviceDNS` default in `AppConfiguration`, resolved by `ResolverTierTwo`. The
    /// draft's named-resolver sentence said lookups are handled under that provider's policy and
    /// stopped there, which is the mirror of the Device-DNS over-claim (Codex, PR #641).
    func testANamedPrimaryDisclosesTheNetworkFallbackItActuallyUses() {
        let sentences = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .named(.cloudflareDoH), admittedTierTwo: .deviceDNS),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(sentences.count, 2)
        XCTAssertTrue(sentences[0].contains("Cloudflare"), "T1 names the provider the user picked")
        XCTAssertTrue(
            sentences[1].localizedCaseInsensitiveContains("network"),
            "T2 must say the network's resolver receives what the named one does not answer")
    }

    /// THE ENCRYPTION CLAIM IS DERIVED FROM THE TRANSPORT. A fallback picked on a plain transport
    /// is selectable, so calling every fallback "encrypted" is a false claim (Codex, PR #641).
    func testTheFallbackEncryptionClaimFollowsTheSelectedTransport() {
        let encrypted = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .networkProvided, admittedTierTwo: .resolver(.quad9UnfilteredDoH)),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)
        let plain = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .networkProvided, admittedTierTwo: .resolver(.quad9Unfiltered)),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertNotEqual(encrypted[1], plain[1], "the two transports cannot share one sentence")
        XCTAssertTrue(encrypted[1].localizedCaseInsensitiveContains("encrypted"))
        XCTAssertTrue(
            plain[1].localizedCaseInsensitiveContains("not encrypted"),
            "a plain fallback must say so rather than borrow the encrypted wording")
        XCTAssertTrue(plain[1].contains(DNSResolverPreset.quad9Unfiltered.displayName))
    }

    /// `.none` adds no sentence: the absence of a fallback is not itself a recipient.
    func testNoFallbackTierDisclosesNoFallbackSentence() {
        let sentences = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .networkProvided, admittedTierTwo: .none),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(
            sentences,
            [ProtectionScopeDisclosure.tierOneDisclosure(.networkProvided, languageCode: Self.english)])
    }

    /// The fresh-install shape end to end: Device DNS primary, encrypted fallback armed by
    /// `lavaRecommendedDefaults`, chaining carrying DNS. All three recipients, in tier order.
    func testTheFreshInstallShapeDisclosesAllThreeTiersInAskOrder() {
        let sentences = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .networkProvided, admittedTierTwo: .resolver(.quad9UnfilteredDoH)),
            isChainedUpstreamCarryingDNS: true, languageCode: Self.english)

        XCTAssertEqual(sentences.count, 3)
        // T0 LEADS, because while chained it is asked first and the rungs below receive only what
        // it declines to serve. Listing it last and saying lookups go there "instead" contradicted
        // the two sentences above it (Codex review, PR #641).
        XCTAssertTrue(sentences[0].localizedCaseInsensitiveContains("chained"), "T0 is asked first")
        XCTAssertTrue(
            sentences[0].localizedCaseInsensitiveContains("first"),
            "and the copy has to SAY it is first, or a reader takes it as the only recipient")
        XCTAssertTrue(sentences[1].contains("Wi-Fi"), "then T1, the network's own resolver")
        XCTAssertTrue(sentences[2].contains(DNSResolverPreset.quad9UnfilteredDoH.displayName), "then T2")
    }

    /// The chained sentence must never read as exclusive while other rungs are listed. A chained
    /// SPLIT tunnel that permits the physical rung reaches all three, so "instead" was false for
    /// a valid configuration (Codex review, PR #641).
    func testTheChainedSentenceDoesNotClaimToBeTheOnlyRecipient() {
        let chainedSplitTunnel = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .networkProvided, admittedTierTwo: .deviceDNS),
            isChainedUpstreamCarryingDNS: true, languageCode: Self.english)

        XCTAssertEqual(chainedSplitTunnel.count, 3)
        for exclusive in ["instead", "only"] {
            XCTAssertFalse(
                chainedSplitTunnel[0].localizedCaseInsensitiveContains(exclusive),
                "the T0 sentence claims exclusivity (\"\(exclusive)\") while two more recipients "
                    + "are disclosed beneath it")
        }
    }

    // MARK: - The unconditional sentences

    /// DNS sees domains. Copy may never imply it sees or can act on a URL.
    func testScopeDisclosureRefusesTheURLOverClaim() {
        let disclosure = ProtectionScopeDisclosure.dnsScopeDisclosure(languageCode: Self.english)

        XCTAssertTrue(disclosure.contains("domain names"))
        XCTAssertTrue(disclosure.contains("not full URLs"))
        XCTAssertTrue(disclosure.contains("page paths"))
        XCTAssertTrue(
            disclosure.localizedCaseInsensitiveContains("cannot block a single page"),
            "the plan forbids implying DNS filtering can block one path on a trusted host, so the "
                + "copy has to say the opposite out loud rather than merely omit it")
    }

    /// iOS calls it a VPN; that must not be left to read as "traffic goes to Lava".
    func testVPNDisclosureExplainsTheProfileWithoutImplyingTrafficReachesLava() {
        let disclosure = ProtectionScopeDisclosure.vpnDisclosure(languageCode: Self.english)

        XCTAssertTrue(disclosure.contains("VPN"))
        XCTAssertTrue(disclosure.localizedCaseInsensitiveContains("not sent to Lava servers"))
    }

    /// The pinned path reaches the translated catalogs, so the `languageCode` parameter cannot be
    /// silently inert — that would render English for every non-English user.
    func testPinnedLanguageReachesTheTranslatedCatalogs() {
        for locale in ["de", "ja", "zh-Hant"] {
            XCTAssertNotEqual(
                ProtectionScopeDisclosure.dnsScopeDisclosure(languageCode: locale),
                ProtectionScopeDisclosure.dnsScopeDisclosure(languageCode: Self.english),
                "\(locale) resolved to the English copy — the pin is not reaching its .lproj")
        }
        let german = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .named(.quad9SecureDoH), admittedTierTwo: .none),
            isChainedUpstreamCarryingDNS: false, languageCode: "de")
        XCTAssertTrue(german[0].contains(DNSResolverPreset.quad9SecureDoH.displayName))
        XCTAssertFalse(german[0].contains("%@"))
    }

    /// THE RULE THAT ENDS THE CLASS: disclose recipients, never trigger conditions.
    ///
    /// Five review rounds on this file were all the same mistake — a precise-sounding clause about
    /// WHEN a tier receives traffic, narrower than the ladder that decides it. The last: "if that
    /// resolver stops answering" excluded SERVFAIL and REFUSED, which `ResolverOrchestrator` also
    /// treats as a fallback trigger once the resolver is health-confirmed wedged (Codex, PR #641).
    ///
    /// A user needs to know which parties can see their lookups; the failover algorithm is not
    /// that, and every sentence describing it is one implementation change from false.
    func testNoFallbackSentenceStatesATriggerCondition() {
        let fallbackSentences = [
            ProtectionScopeDisclosure.tierTwoDisclosure(.deviceDNS, languageCode: Self.english),
            ProtectionScopeDisclosure.tierTwoDisclosure(
                .resolver(.quad9UnfilteredDoH), languageCode: Self.english),
            ProtectionScopeDisclosure.tierTwoDisclosure(
                .resolver(.quad9Unfiltered), languageCode: Self.english)
        ].compactMap { $0 }

        XCTAssertEqual(fallbackSentences.count, 3)
        for sentence in fallbackSentences {
            for triggerClaim in ["stops answering", "does not answer", "fails to answer", "when it"] {
                XCTAssertFalse(
                    sentence.localizedCaseInsensitiveContains(triggerClaim),
                    "\"\(triggerClaim)\" states WHEN the tier receives a lookup, which the ladder "
                        + "decides and this copy cannot track: \(sentence)")
            }
            XCTAssertTrue(
                sentence.localizedCaseInsensitiveContains("can also receive"),
                "a fallback sentence discloses that the tier CAN receive lookups: \(sentence)")
        }
    }

    /// A RECIPIENT *CAN* RECEIVE; NOTHING SAYS A LOOKUP ACTUALLY LEAVES THE DEVICE.
    ///
    /// Most allowed lookups reach no resolver at all. `PacketTunnelProvider` writes a cache hit
    /// from `dnsResponseCache` and returns before dispatching upstream, and a query the
    /// `inFlightQueryCoalescer` folds into one already in flight sends nothing of its own. So
    /// "Allowed DNS lookups go to X" was false on the ordinary path, not an edge case
    /// (Codex, PR #641).
    ///
    /// This is the same rule as `testNoFallbackSentenceStatesATriggerCondition` applied to the
    /// tiers that rule did not cover: the fallback sentences already said "can also receive"
    /// while T0 and T1 still asserted delivery.
    ///
    /// The shapes below render all TEN recipient keys between them, so a new sentence cannot be
    /// written in the old voice. `dnsScope` and `vpn` are the catalog's other two and are
    /// unconditional, with their own tests.
    func testNoRecipientSentenceAssertsALookupActuallyLeavesTheDevice() {
        var everySentence = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .networkProvided, admittedTierTwo: .resolver(.quad9UnfilteredDoH)),
            isChainedUpstreamCarryingDNS: true, languageCode: Self.english)
        everySentence += ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .named(.quad9Secure), admittedTierTwo: .deviceDNS),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)
        everySentence += ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .named(.cloudflareDoH), admittedTierTwo: .resolver(.quad9Unfiltered)),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)
        everySentence += ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(
                effectiveTierOne: .named(Self.twoServiceCustomResolver),
                admittedTierTwo: .resolver(Self.twoServiceCustomResolver)),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)
        // The count-1 Custom shape is here for the SINGULAR self-entered key, which none of the
        // shapes above can render: they all carry two addresses. Without it the sweep covered nine
        // of the ten recipient keys while claiming all of them (Kilo, PR #641).
        everySentence += ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(
                effectiveTierOne: .named(Self.oneAddressCustomResolver), admittedTierTwo: .none),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(
            everySentence.count, 14,
            "fourteen sentences rendering all ten recipient keys — the catalog's other two, "
                + "dnsScope and vpn, are unconditional and asserted separately")
        for sentence in everySentence {
            for delivery in ["are sent to", "go to", "goes to", "receives allowed", "will receive"] {
                XCTAssertFalse(
                    sentence.localizedCaseInsensitiveContains(delivery),
                    "\"\(delivery)\" asserts a lookup leaves the device, which a cache hit or a "
                        + "coalesced query never does: \(sentence)")
            }
        }
        // "cannot say who operates" is the one allowed non-capability sentence: it is a claim
        // about LAVA's knowledge of a self-entered address, not about where a lookup goes, so the
        // delivery rule above is what governs it rather than this one.
        XCTAssertTrue(
            everySentence.allSatisfy { $0.localizedCaseInsensitiveContains("can receive")
                || $0.localizedCaseInsensitiveContains("can also receive")
                || $0.localizedCaseInsensitiveContains("can block")
                || $0.localizedCaseInsensitiveContains("cannot say who operates") },
            "every recipient sentence states a CAPABILITY of that party")
    }

    /// "BLOCK DECISIONS HAPPEN ON THIS iPHONE" IS ONLY TRUE OF LAVA'S DECISIONS.
    ///
    /// `quad9Secure` and `hagezi` — in plain, DoH and DoT variants — carry
    /// `hasUpstreamFiltering: true`, so a domain Lava ALLOWS can still be blocked by the resolver
    /// it is sent to. The categorical opening contradicted every one of those supported
    /// selections (Codex review, PR #641).
    func testAFilteringResolverIsDisclosedAsAbleToBlockWhatLavaAllowed() {
        let filtering = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .named(.quad9Secure), admittedTierTwo: .none),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(filtering.count, 2, "the filtering fact is its own sentence")
        XCTAssertTrue(
            filtering[0].localizedCaseInsensitiveContains("Lava's block decisions"),
            "the claim must be scoped to Lava rather than stated of all blocking")
        XCTAssertTrue(filtering[1].contains(DNSResolverPreset.quad9Secure.displayName))
        XCTAssertTrue(
            filtering[1].localizedCaseInsensitiveContains("block a domain Lava allowed"),
            "allowing is not final when the recipient filters, and a user cannot infer that")
    }

    /// ...and a resolver that does NOT filter adds nothing, so the copy never invents a caveat.
    func testANonFilteringResolverAddsNoUpstreamFilteringSentence() {
        let neutral = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .named(.cloudflareDoH), admittedTierTwo: .none),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(neutral.count, 1)
        XCTAssertFalse(DNSResolverPreset.cloudflareDoH.hasUpstreamFiltering)
    }

    /// T2 CANNOT OUTLIVE T1, so a forbidden rung discloses no fallback either.
    ///
    /// `DNSResolverRuntimePlan.make` builds T2 as the `encryptedFallback` field of the T1 plan, so
    /// no T1 plan means no T2. The two-parameter shape this replaces let a caller state that
    /// impossible pairing, and the canonical `ResolverTierTwo.resolve` produces it: it has no
    /// chained-policy input, so it still answers `.deviceDNS` or `.resolver` in exactly the
    /// configurations where the rung is forbidden (Codex, PR #641).
    ///
    /// This is a compile-time guarantee now — `PhysicalRungs` carries both or neither — and this
    /// test is what says the guarantee is the one we meant.
    func testAForbiddenPhysicalRungDisclosesNoFallbackEither() {
        let armedT2 = ResolverTierTwo.resolve(
            primaryTransport: .deviceDNS,
            effectiveTransport: .deviceDNS,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            encryptedFallbackResolver: .quad9UnfilteredDoH,
            allowsQueryFallback: true,
            hasDeviceDNSAddresses: true)
        XCTAssertEqual(
            armedT2, .resolver(.quad9UnfilteredDoH),
            "the resolver layer really does arm a T2 that the forbidden rung cannot run")

        let forbiddenRung = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: nil, isChainedUpstreamCarryingDNS: true, languageCode: Self.english)

        XCTAssertEqual(forbiddenRung.count, 1, "T0 alone; neither rung beneath it can run")
        XCTAssertFalse(
            forbiddenRung[0].contains(DNSResolverPreset.quad9UnfilteredDoH.displayName),
            "the armed-but-unreachable T2 must not be disclosed as a recipient")
    }

    /// A Custom entry built from TWO services, which is what makes one `.named` value two
    /// recipients. Force-unwrapped deliberately: if `custom(primaryRawValue:secondaryRawValue:)`
    /// stops merging these, the fixture is wrong and the tests below assert nothing.
    private static let twoServiceCustomResolver = DNSResolverPreset.custom(
        primaryRawValue: "1.1.1.1", secondaryRawValue: "8.8.8.8")!

    /// The same entry after chained admission narrowed it to one address — what
    /// `restrictingPlainAddresses(to:)` leaves the rung running on.
    private static let oneAddressCustomResolver = DNSResolverPreset.custom(
        primaryRawValue: "1.1.1.1")!

    /// T0 IS A SET LAVA DID NOT CHOOSE, so the copy attributes no operator to it.
    ///
    /// `ChainedTunnelResolverSelection.selection(from:)` admits EVERY usable `DNS =` entry in the
    /// imported configuration and `TunnelledPlainDNSResolution` walks `route.resolverAddresses` in
    /// failover order, so several addresses can each receive lookups — and they need not belong to
    /// the VPN operator, the selection code's own worked example being `DNS = 1.1.1.1`. "That
    /// VPN's own DNS resolver" attributed a third party's resolver to whoever wrote the conf
    /// (Codex, PR #641).
    func testTheChainedSentenceAttributesNoOperatorToTheUpstream() {
        let chained = ProtectionScopeDisclosure.chainedRecipientDisclosure(
            languageCode: Self.english)

        XCTAssertFalse(
            chained.localizedCaseInsensitiveContains("VPN's own"),
            "an imported conf can point at a third party's resolver: \(chained)")
        XCTAssertTrue(
            chained.localizedCaseInsensitiveContains("cannot say who operates"),
            "the same unknown-operator caveat a self-entered resolver carries")
        XCTAssertTrue(
            chained.localizedCaseInsensitiveContains("servers"),
            "plural, because every usable DNS = entry is admitted, not just the first")
        XCTAssertTrue(
            chained.localizedCaseInsensitiveContains("first"),
            "T0 is still asked before the rungs beneath it")
    }

    /// ONE `.named` VALUE, TWO OPERATORS. Custom merges the primary and secondary the user
    /// entered into a single preset carrying the PRIMARY's display name — "Custom DNS" by default
    /// — so the tier sentence named one party for what can be two, and claimed their lookups are
    /// "handled under that provider's policy" about an address Lava has never heard of
    /// (Codex, PR #641).
    func testACustomResolverDisclosesEveryAddressItCanHold() {
        let merged = Self.twoServiceCustomResolver
        XCTAssertEqual(
            merged.ipv4Servers.count, 2,
            "the merge really does put two operators behind one preset")
        XCTAssertTrue(merged.ipv4Servers.contains("1.1.1.1"))
        XCTAssertTrue(merged.ipv4Servers.contains("8.8.8.8"))
        XCTAssertEqual(merged.displayName, "Custom DNS", "under one name that mentions neither")

        let sentences = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .named(merged), admittedTierTwo: .none),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(sentences.count, 2, "the second-address fact is its own sentence")
        XCTAssertFalse(
            sentences[0].localizedCaseInsensitiveContains("provider's policy"),
            "a caveat cannot unsay a categorical claim, so the T1 sentence must not make it")
        XCTAssertFalse(
            sentences[0].contains(merged.displayName),
            "\"Custom DNS\" is a default label, not a party the copy can name")
        XCTAssertTrue(
            sentences[1].localizedCaseInsensitiveContains("every address you entered"),
            "a user cannot infer the second service they entered is also a recipient")
        XCTAssertTrue(
            sentences[1].localizedCaseInsensitiveContains("cannot say who operates"),
            "and the provider-policy claim is meaningless for an address the user typed")
    }

    /// A RUNG THAT RUNS WITH NOBODY TO ASK STILL HAS A FALLBACK, and it must be disclosed.
    ///
    /// Device DNS selected, encrypted fallback armed, nothing captured: `make` builds an effective
    /// `.deviceDNS` plan whose address list is EMPTY, while `ResolverTierTwo.resolve` returns the
    /// encrypted resolver from a branch that never consults `hasDeviceDNSAddresses`. T1 asks
    /// nobody; T2 receives every lookup.
    ///
    /// The mandatory recipient this replaces left no truthful call for that shape — naming a T1
    /// invented a recipient, and `physicalRungs: nil` hid the fallback (Codex, PR #641). `nil`
    /// there still means no T1 PLAN at all, which is a different fact and still suppresses both.
    func testAnEmptyDeviceCaptureDisclosesTheFallbackAlone() {
        let armedWithNothingCaptured = ResolverTierTwo.resolve(
            primaryTransport: .deviceDNS,
            effectiveTransport: .deviceDNS,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            encryptedFallbackResolver: .quad9UnfilteredDoH,
            allowsQueryFallback: true,
            hasDeviceDNSAddresses: false)
        XCTAssertEqual(
            armedWithNothingCaptured, .resolver(.quad9UnfilteredDoH),
            "the tier really is armed with no device address behind it")

        let sentences = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(
                effectiveTierOne: nil, admittedTierTwo: .resolver(.quad9UnfilteredDoH)),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(sentences.count, 1, "no T1 recipient, but T2 receives everything")
        XCTAssertTrue(sentences[0].contains(DNSResolverPreset.quad9UnfilteredDoH.displayName))
        XCTAssertFalse(
            sentences[0].contains("Wi-Fi"),
            "an empty device capture is not a network recipient")

        XCTAssertEqual(
            ProtectionScopeDisclosure.recipientDisclosures(
                physicalRungs: nil, isChainedUpstreamCarryingDNS: false,
                languageCode: Self.english),
            [],
            "no T1 PLAN is still a different fact, and suppresses the fallback with it")
    }

    /// THE DEVICE RESOLVERS ARE CAPTURED, NOT CURRENT, and the copy must not claim otherwise.
    ///
    /// `DeviceDNSFallbackPolicy.refreshedResolverAddresses` defaults `preserveOnEmptyCapture` to
    /// true and returns the PREVIOUS network's addresses on an empty or masked capture — the
    /// handoff behaviour the runtime supports deliberately. One of those can still be reachable,
    /// so "your current Wi-Fi ... provide" misattributed the recipient precisely there
    /// (Codex, PR #641).
    ///
    /// "Current" is the falsifiable word, so that is what this asserts against, at both tiers.
    func testTheNetworkSentencesClaimNoCurrentNetwork() {
        XCTAssertEqual(
            DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: ["9.9.9.9"], captured: []),
            ["9.9.9.9"],
            "the preserved-capture behaviour this copy has to survive is really the default")

        let tierOne = ProtectionScopeDisclosure.tierOneDisclosure(
            .networkProvided, languageCode: Self.english)
        let tierTwo = ProtectionScopeDisclosure.tierTwoDisclosure(
            .deviceDNS, languageCode: Self.english)

        for sentence in [tierOne, tierTwo].compactMap({ $0 }) {
            XCTAssertFalse(
                sentence.localizedCaseInsensitiveContains("current"),
                "a preserved resolver came from a network that is no longer current: \(sentence)")
        }
        XCTAssertTrue(tierOne.contains("Wi-Fi"), "it is still the device's own captured resolvers")
    }

    /// A SHIPPED PRESET KEEPS THE PROVIDER-POLICY SENTENCE, so the Custom branch is a real
    /// distinction rather than the copy quietly dropping a true claim everywhere.
    func testAShippedPresetStillNamesTheProviderAndItsPolicy() {
        let sentences = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(
                effectiveTierOne: .named(.cloudflareDoH), admittedTierTwo: .none),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(sentences.count, 1)
        XCTAssertTrue(sentences[0].contains(DNSResolverPreset.cloudflareDoH.displayName))
        XCTAssertTrue(
            sentences[0].localizedCaseInsensitiveContains("provider's policy"),
            "Lava ships this one and can speak to whose policy applies")
    }

    /// A DoT/DoQ STAMP IS ONE RECIPIENT EVEN THOUGH IT FILLS TWO STORAGE FIELDS.
    ///
    /// `DNSStampParser` writes the bootstrap IPs into `ipv4Servers` AND builds the single
    /// `dotEndpoint` beside them, so a count that sums every field saw two and produced the plural
    /// sentence for a user who entered one stamp (Codex, PR #641). Bootstrap addresses resolve the
    /// endpoint's hostname; they are not where an allowed lookup is sent.
    ///
    /// Built directly rather than parsed from an `sdns://` string so the test pins the SHAPE the
    /// parser produces — overlapping fields — rather than one stamp encoding.
    func testAStampWithBootstrapAddressesIsStillOneRecipient() {
        let stampShaped = DNSResolverPreset(
            id: DNSResolverPreset.customID,
            displayName: "Custom DNS",
            ipv4Servers: ["9.9.9.9"],
            ipv6Servers: [],
            notes: "Use your own resolver.",
            hasUpstreamFiltering: false,
            transport: .dnsOverTLS,
            dotEndpoint: DNSOverTLSEndpoint(
                hostname: "dns.example",
                bootstrapIPv4Servers: ["9.9.9.9"],
                bootstrapIPv6Servers: []))

        let sentences = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .named(stampShaped), admittedTierTwo: .none),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(sentences.count, 2)
        XCTAssertTrue(sentences[1].localizedCaseInsensitiveContains("cannot say who operates"))
        XCTAssertFalse(
            sentences[1].localizedCaseInsensitiveContains("every address"),
            "one stamp is one recipient, however many fields the parser fills")
    }

    /// A CUSTOM ENTRY NARROWED TO ONE ADDRESS PROMISES NO SECOND RECIPIENT.
    ///
    /// `restrictingPlainAddresses(to:)` keeps only the chained-admitted subset, so a two-address
    /// Custom entry whose secondary is IPv6, unusable, or equal to T0 runs T1 on one address while
    /// the preset id is unchanged. Keying the plural sentence on `id == customID` promised a
    /// recipient that had been narrowed away (Codex, PR #641) — the same admitted-versus-configured
    /// split as `effectiveTierOne`, so the count is read off the preset the caller passes.
    func testACustomResolverNarrowedToOneAddressClaimsNoSecond() {
        XCTAssertEqual(
            Self.oneAddressCustomResolver.id, DNSResolverPreset.customID,
            "the id is identical to the two-address entry — it cannot carry the distinction")
        XCTAssertEqual(
            Self.oneAddressCustomResolver.ipv4Servers.count
                + Self.oneAddressCustomResolver.ipv6Servers.count,
            1)

        let sentences = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(
                effectiveTierOne: .named(Self.oneAddressCustomResolver), admittedTierTwo: .none),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(sentences.count, 2, "the unknown-operator half is true either way")
        XCTAssertFalse(sentences[0].localizedCaseInsensitiveContains("provider's policy"))
        XCTAssertTrue(sentences[1].localizedCaseInsensitiveContains("cannot say who operates"))
        XCTAssertFalse(
            sentences[1].localizedCaseInsensitiveContains("every address"),
            "one admitted address is not several, and the copy must not promise a second")
    }

    /// The caveat follows the Custom resolver to T2, exactly as the filtering one does — a
    /// two-service Custom FALLBACK holds two recipients for the same reason a primary does.
    func testACustomFallbackCarriesTheSameSecondAddressCaveat() {
        let sentences = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(
                effectiveTierOne: .networkProvided,
                admittedTierTwo: .resolver(Self.twoServiceCustomResolver)),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(sentences.count, 3)
        XCTAssertTrue(
            sentences[1].localizedCaseInsensitiveContains("not encrypted"),
            "the transport claim still follows the preset — a plain Custom entry is not encrypted")
        XCTAssertTrue(sentences[2].localizedCaseInsensitiveContains("every address you entered"))
    }

    /// ...and a preset Lava ships adds no self-entered caveat, so the copy never invents one.
    func testAShippedPresetAddsNoSelfEnteredCaveat() {
        XCTAssertEqual(
            ProtectionScopeDisclosure.selfEnteredDisclosure(
                .cloudflareDoH, languageCode: Self.english),
            [])
        XCTAssertNotEqual(DNSResolverPreset.cloudflareDoH.id, DNSResolverPreset.customID)
    }

    /// DEVICE-DNS FALLBACK MODE REPLACES THE NAMED PRIMARY, so the disclosure must name the
    /// network rather than the provider the user picked.
    ///
    /// `DNSResolverRuntimePlan.make` computes `usesDeviceDNSFallbackMode` and then sets
    /// `effectiveTransport = .deviceDNS` with the captured device resolvers as the addresses — the
    /// selection is out of the path entirely — and `ResolverTierTwo.resolve`, reading that same
    /// effective transport, answers `.none` so the device rung is not disclosed twice.
    ///
    /// Passing the SELECTION here would be both failures at once: an inactive provider named, and
    /// the resolver actually receiving every lookup omitted (Codex, PR #641). Hence
    /// `effectiveTierOne:` rather than a parameter named for the user's choice.
    func testDeviceDNSFallbackModeDisclosesTheNetworkNotTheSelection() {
        let tierTwoUnderFallbackMode = ResolverTierTwo.resolve(
            primaryTransport: .dnsOverHTTPS,
            effectiveTransport: .deviceDNS,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: false,
            encryptedFallbackResolver: .quad9UnfilteredDoH,
            allowsQueryFallback: true,
            hasDeviceDNSAddresses: true)
        XCTAssertEqual(
            tierTwoUnderFallbackMode, .none,
            "the effective transport suppresses T2, so the device rung is disclosed once")

        let sentences = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .networkProvided, admittedTierTwo: .none),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(sentences.count, 1)
        XCTAssertTrue(sentences[0].contains("Wi-Fi"), "the network's resolver is the recipient")
        XCTAssertFalse(
            sentences[0].contains(DNSResolverPreset.cloudflareDoH.displayName),
            "the selection receives nothing while the mode is active and must not be named")
    }

    /// AN ADMITTED-AWAY FALLBACK IS NOT A RECIPIENT, and this is the third shape of that class.
    ///
    /// A chained split tunnel can keep an encrypted T1 runnable while T2 is removed underneath it:
    /// `DNSResolverRuntimePlan.restrictingDeviceDNSFallbackAddresses(to:)` drops a captured device
    /// resolver that is IPv6 or equal to the upstream's own `DNS =`, and its rule is
    /// `shouldFallbackToDeviceDNS && !kept.isEmpty` — the flag falls with the list. So the
    /// configuration-resolved tier says `.deviceDNS` while the admitted plan can send it nothing
    /// (Codex, PR #641).
    ///
    /// This type cannot detect admission and must not re-derive it, so the guard is the argument
    /// label: `admittedTierTwo:` is what every call site has to write. The assertion here is that
    /// passing the admitted `.none` produces no fallback sentence, which is what the Task 2 caller
    /// gets right by reading the plan it already holds.
    func testAnAdmittedAwayFallbackDisclosesNoRecipient() {
        let configurationResolved = ResolverTierTwo.resolve(
            primaryTransport: .dnsOverHTTPS,
            effectiveTransport: .dnsOverHTTPS,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: false,
            encryptedFallbackResolver: .quad9UnfilteredDoH,
            allowsQueryFallback: true,
            hasDeviceDNSAddresses: true)
        XCTAssertEqual(
            configurationResolved, .deviceDNS,
            "the configuration really does resolve a T2 that chained admission then removes")

        let admitted = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .named(.cloudflareDoH), admittedTierTwo: .none),
            isChainedUpstreamCarryingDNS: true, languageCode: Self.english)

        XCTAssertEqual(
            admitted.count, 2, "T0 and the encrypted T1; the device leg was admitted away")
        XCTAssertFalse(
            admitted.contains { $0.localizedCaseInsensitiveContains("can also receive") },
            "no fallback sentence, because no admitted address can receive a lookup")
    }

    /// A DEVICE-DNS *FALLBACK* SELECTION IS NOT A SECOND RECIPIENT.
    ///
    /// `ResolverTierTwo.resolve` answers `.resolver(.device)` for it — the user did choose T2 —
    /// but `DNSResolverRuntimePlan.make` guards `preset.transport != .deviceDNS` and leaves the
    /// nested plan nil, so nothing is ever routed there. Grouping it with the plain transports
    /// said "Device DNS can also receive allowed lookups" about a rung that receives none
    /// (Codex, PR #641).
    func testADeviceDNSFallbackSelectionDisclosesNoSecondRecipient() {
        let sentences = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .networkProvided, admittedTierTwo: .resolver(.device)),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(sentences.count, 1, "T1 only — the chosen T2 has no plan to receive on")
        XCTAssertNil(
            ProtectionScopeDisclosure.tierTwoDisclosure(
                .resolver(.device), languageCode: Self.english))
        XCTAssertEqual(
            DNSResolverPreset.device.transport, .deviceDNS,
            "the guard keys on the transport, so this is the preset that trips it")
    }

    /// The caveat follows a filtering resolver wherever it sits, including T2 — a fallback that
    /// filters can block what Lava allowed just as a primary can.
    func testAFilteringFallbackIsAlsoDisclosed() {
        let filteringFallback = ProtectionScopeDisclosure.recipientDisclosures(
            physicalRungs: .init(effectiveTierOne: .networkProvided, admittedTierTwo: .resolver(.hagezi)),
            isChainedUpstreamCarryingDNS: false, languageCode: Self.english)

        XCTAssertEqual(filteringFallback.count, 3)
        XCTAssertTrue(
            filteringFallback[2].contains(DNSResolverPreset.hagezi.displayName),
            "the caveat belongs to the filtering resolver, not to the primary slot")
    }
}
