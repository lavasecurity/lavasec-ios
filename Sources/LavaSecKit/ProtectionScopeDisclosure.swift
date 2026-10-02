import Foundation

/// The user-facing sentences that say what Lava can and cannot see, and where an allowed
/// DNS lookup actually goes.
///
/// ## Why this is a policy type and not view copy
///
/// Every one of these sentences is a CLAIM ABOUT THE DATA PATH, and the ways they can go wrong
/// are product-level, not layout-level: saying allowed lookups stay on the device, or implying
/// DNS filtering can block one page on a host the user allowed, would each be an over-claim that
/// no amount of correct SwiftUI would catch. Centralising them here gives the claim one home and
/// one test suite, so onboarding, Settings help, and the public site cannot drift into three
/// different promises — the drift this is meant to prevent
/// (`lavasec-infra` `plans/2026-05-25-resolver-and-protection-scope-disclosure-plan.md`).
///
/// ## THIS TYPE MAKES NO ROUTING CLAIMS OF ITS OWN
///
/// The first draft took resolver DISPLAY NAMES and wrote categorical sentences around them. That
/// shape cannot be made truthful, and three review rounds found three different ways it lied
/// (Codex, PR #641): a Device-DNS primary also reaches the encrypted fallback and, while chained,
/// the upstream's resolver; a NAMED primary with `fallbackToDeviceDNS` on — the default — falls
/// back to the *network's* resolver rather than staying under the named provider's policy; and a
/// fallback the user picked on a plain transport is not "encrypted" at all.
///
/// The fix is structural rather than editorial. `recipientDisclosures` renders the recipients it
/// is TOLD about, in the vocabulary of the tier scaffold (`docs/architecture/dns-tiers.md`), and
/// decides nothing about routing itself:
///
/// - **T0** — `isChainedUpstreamCarryingDNS`, the chained upstream's own `DNS =`. It leads the
///   list, because while chained it is asked FIRST and the rungs below receive only what it
///   declines to serve.
/// - **T1 and T2** — `physicalRungs`, ONE value, `nil` when the physical rung cannot run at all,
///   and carrying what each tier ACTUALLY reaches: the EFFECTIVE T1 rather than the user's
///   selection, and the ADMITTED T2 rather than the configuration-resolved tier. See
///   ``PhysicalRungs`` for why they are not two parameters and what each label is naming.
///
/// The per-tier sentence builders are deliberately NOT public. A caller that could render one of
/// them alone could disclose one recipient and silently omit two, which is what made the first
/// draft dangerous rather than merely incomplete.
///
/// ## Disclose RECIPIENTS, never TRIGGER CONDITIONS
///
/// The copy says who can receive an allowed lookup. It does not say when, and that is a rule
/// rather than an omission. Five review rounds on this file were all the same mistake — a
/// precise-sounding clause about *when* a tier receives traffic, narrower than the ladder that
/// actually decides it. The last one: "if that resolver stops answering" excluded SERVFAIL and
/// REFUSED, which `ResolverOrchestrator` also treats as a fallback trigger once the resolver is
/// health-confirmed wedged, so a resolver that answered still handed the lookup on.
///
/// A user needs to know which parties can see their lookups. The failover algorithm is not that,
/// it changes as the ladder is tuned, and every sentence describing it is one implementation
/// change from being false. `testNoFallbackSentenceStatesATriggerCondition` holds the line.
///
/// The same rule forbids asserting DELIVERY. EVERY recipient sentence says a party CAN receive an
/// allowed lookup; none says lookups DO go there, because for many of them none ever does: a cache
/// hit is written from `dnsResponseCache` and returns before any upstream dispatch, and a query
/// the `inFlightQueryCoalescer` folds into one already in flight sends nothing of its own
/// (`PacketTunnelProvider`). "Allowed DNS lookups go to X" was false on every one of those
/// (Codex review, PR #641). The fallback sentences already read this way; the T0 and T1 sentences
/// did not, which is the whole reason the rule needed stating over ALL of them rather than one
/// tier. `testNoRecipientSentenceAssertsALookupActuallyLeavesTheDevice` covers every sentence the
/// type can emit.
///
/// ## A RECIPIENT THAT CANNOT BE REACHED IS NOT A RECIPIENT
///
/// The mirror of the over-claim, and the one the later rounds found twice: naming a party that
/// receives ZERO lookups is as false as omitting one that receives them. Both cases are
/// structural rather than editorial, and both are handled where the shape is decided — see
/// ``PhysicalRungs`` and the `.deviceDNS` arm of `tierTwoDisclosure`.
///
/// ## Pinned language
///
/// Copy is resolved through `LavaCoreStrings` (`Bundle.module`), so the tunnel, widget, and app
/// all read the same localized text — these strings are shown before the user grants the VPN
/// profile, which is the one moment the disclosure has to be right.
///
/// Every accessor takes an optional `languageCode` for the same reason the notification posters
/// and the Live Activity do: ambient `Bundle.module` lookup resolves in the PROCESS's preferred
/// language, which is not the app's pinned UI language for an out-of-process render, and
/// Foundation will refuse a non-preferred `.lproj` outright. `nil` keeps the ambient behaviour
/// that is correct in the app process; a caller rendering somewhere else passes
/// `LavaNotificationLanguage.pinnedCode(...)`, exactly as `SwitchFilterIntent` does.
public enum ProtectionScopeDisclosure {
    /// Who receives an allowed lookup at a given tier.
    ///
    /// `named` carries the whole preset rather than a display name so the copy can read the
    /// transport off it: "encrypted fallback" is a claim, and a preset the user picked on
    /// `.plainDNS` would make it a false one.
    public enum Recipient: Equatable, Sendable {
        /// The DNS servers this device captured from a network — NOT necessarily the network it
        /// is on now.
        ///
        /// `DeviceDNSFallbackPolicy.refreshedResolverAddresses` defaults `preserveOnEmptyCapture`
        /// to true and returns the PREVIOUS addresses when iOS hands back an empty or masked
        /// capture, and the plan builder keeps using them. A preserved address that is still
        /// reachable — a public resolver the prior Wi-Fi handed over — then receives lookups
        /// while the current network never supplied it, so "your current Wi-Fi, cellular, or
        /// system settings provide" was false during exactly the handoff the runtime supports
        /// on purpose (Codex review, PR #641). The copy says captured, not current.
        /// pinned: ProtectionScopeDisclosureTests.testTheNetworkSentencesClaimNoCurrentNetwork
        case networkProvided
        /// A named resolver that is ACTUALLY BEING ASKED, on the transport it is asked over.
        ///
        /// Not necessarily the one the user picked: see ``PhysicalRungs/effectiveTierOne``.
        case named(DNSResolverPreset)
    }

    /// The rungs beneath T0, as ONE value, because T2 CANNOT OUTLIVE T1'S PLAN.
    ///
    /// `DNSResolverRuntimePlan.make` builds T2 as the `encryptedFallback` field of the T1 plan, so
    /// when there is no T1 plan there is no T2 either — and there is no T1 plan whenever
    /// `AppConfiguration.chainedTierOneResolverConfiguration` answers nil for a declined rung, or
    /// `ChainedResolverEgress.permitsTierOneFallbackOnPhysicalInterface` rejects a full-tunnel
    /// upstream.
    ///
    /// Taking `tierOne: Recipient?` and `tierTwo: ResolverTierTwo` as two parameters let a caller
    /// state the pairing the runtime cannot produce, and a caller naturally would: the canonical
    /// `ResolverTierTwo.resolve` has no chained-policy input at all, so in exactly those
    /// configurations it still answers `.deviceDNS` or `.resolver` while T1 is nil. The disclosure
    /// then advertised a fallback that could not receive a single lookup (Codex review, PR #641).
    /// Nesting them makes that state unrepresentable rather than merely wrong.
    /// pinned: ProtectionScopeDisclosureTests.testAForbiddenPhysicalRungDisclosesNoFallbackEither
    public struct PhysicalRungs: Equatable, Sendable {
        /// The recipient T1 ACTUALLY ASKS — never simply the resolver the user selected, and
        /// `nil` when the rung runs but has nobody to ask.
        ///
        /// THE PLAN EXISTING AND THE RUNG HAVING A RECIPIENT ARE DIFFERENT FACTS, which the first
        /// version of this type conflated by making the recipient mandatory. A Device-DNS
        /// selection with the encrypted fallback armed and NO captured device resolver builds an
        /// effective `.deviceDNS` plan whose address list is empty, while
        /// `ResolverTierTwo.resolve` returns `.resolver(encryptedFallbackResolver)` from a branch
        /// that never consults `hasDeviceDNSAddresses` — so T1 asks nobody and T2 receives every
        /// lookup. With a mandatory recipient there was no truthful call: naming one invented a
        /// recipient, and passing `physicalRungs: nil` hid the fallback that was really receiving
        /// (Codex review, PR #641).
        /// pinned: ProtectionScopeDisclosureTests.testAnEmptyDeviceCaptureDisclosesTheFallbackAlone
        ///
        /// `DNSResolverRuntimePlan.make` computes `usesDeviceDNSFallbackMode` and, when it is on,
        /// sets `effectiveTransport = .deviceDNS` and `effectivePlainAddresses` to the captured
        /// device resolvers. A named selection is REPLACED wholesale for the duration: the
        /// provider the user picked receives nothing, and the network's resolver receives
        /// everything. `ResolverTierTwo.resolve` reads the same `effectiveTransport` and answers
        /// `.none`, so the device rung is not disclosed twice.
        ///
        /// Passing `.named(...)` there — which an earlier version of this doc invited — named an
        /// inactive provider while omitting the one actually receiving the lookups, both halves of
        /// the class at once (Codex review, PR #641). So this is the effective recipient, exactly
        /// as `admittedTierTwo` below is the admitted fallback.
        ///
        /// The two labels use different words on purpose. `effective` is what
        /// `DNSResolverRuntimePlan` calls the substitution at T1; `admitted` is what the chained
        /// gates call the narrowing at T2. Forcing one word onto both would name neither
        /// derivation, and it is the derivation a caller has to go and read.
        /// pinned: ProtectionScopeDisclosureTests.testDeviceDNSFallbackModeDisclosesTheNetworkNotTheSelection
        public let effectiveTierOne: Recipient?

        /// The fallback the ADMITTED plan can actually reach — never the configuration-resolved
        /// tier.
        ///
        /// THE ARGUMENT LABEL SAYS `admittedTierTwo` BECAUSE THE TWO DIFFER, and the difference is
        /// not rare. `ResolverTierTwo.resolve` answers from the configuration; the tunnel then
        /// runs `DNSResolverRuntimePlan.restrictingDeviceDNSFallbackAddresses(to:)` over the
        /// chained admission set, which drops a captured device resolver that is IPv6 (swallowed
        /// by the chained `::/0` blackhole) or equal to the upstream's own `DNS =`. Its rule is
        /// `shouldFallbackToDeviceDNS && !kept.isEmpty` — THE FLAG FALLS WITH THE LIST — so a
        /// chained split tunnel with an encrypted T1 can keep T1 runnable while T2 is admitted
        /// away entirely. Rendering the pre-admission `.deviceDNS` there names a recipient that
        /// receives nothing (Codex review, PR #641).
        ///
        /// This type cannot detect that: admission depends on the tunnel's runtime capture, and
        /// re-deriving it here would be the second implementation of the routing rules this type
        /// exists to avoid. So the label carries the precondition to every call site instead —
        /// `admittedTierTwo:` cannot be written absent-mindedly — and the caller in Task 2 reads
        /// the admitted plan it already holds rather than re-resolving the tier.
        /// pinned: ProtectionScopeDisclosureTests.testAnAdmittedAwayFallbackDisclosesNoRecipient
        public let admittedTierTwo: ResolverTierTwo

        public init(effectiveTierOne: Recipient?, admittedTierTwo: ResolverTierTwo) {
            self.effectiveTierOne = effectiveTierOne
            self.admittedTierTwo = admittedTierTwo
        }
    }

    /// EVERY recipient an allowed lookup can reach, in tier order, as sentences to render
    /// together. This is the only supported way to disclose recipients.
    ///
    /// - Parameters:
    ///   - physicalRungs: the effective T1 and the admitted T2 nested inside it, or `nil` when
    ///     no T1 plan is built at all. Both are what the plan reaches, not what the user selected,
    ///     and `effectiveTierOne` is itself `nil` when the rung runs with nobody to ask.
    ///   - isChainedUpstreamCarryingDNS: whether a chained upstream is carrying DNS (T0).
    public static func recipientDisclosures(
        physicalRungs: PhysicalRungs?,
        isChainedUpstreamCarryingDNS: Bool,
        languageCode: String? = nil
    ) -> [String] {
        // TIER ORDER IS ASK ORDER, and T0 is tier ZERO for a reason: while chained, the upstream's
        // own resolver is asked FIRST. A wire-attempted timeout, resolver error, or malformed
        // reply can open the T1 rung. Listing T1 and T2 and
        // then saying lookups go to the upstream "instead" was self-contradicting copy for a
        // chained split tunnel, where all three can receive a lookup (Codex review, PR #641).
        var sentences: [String] = []
        if isChainedUpstreamCarryingDNS {
            sentences.append(chainedRecipientDisclosure(languageCode: languageCode))
        }
        guard let physicalRungs else { return sentences }
        // A RUNG WITH NOBODY TO ASK ADDS NO SENTENCE, but its fallback still does: the T1 plan
        // exists, so T2 is built and reachable beneath it. Skipping the whole block here would
        // hide the tier that receives every lookup (Codex review, PR #641).
        if let tierOne = physicalRungs.effectiveTierOne {
            sentences.append(tierOneDisclosure(tierOne, languageCode: languageCode))
            sentences.append(
                contentsOf: recipientCaveats(for: tierOne, languageCode: languageCode))
        }
        if let tierTwoSentence = tierTwoDisclosure(
            physicalRungs.admittedTierTwo, languageCode: languageCode) {
            sentences.append(tierTwoSentence)
            if let preset = physicalRungs.admittedTierTwo.resolverPreset {
                sentences.append(
                    contentsOf: recipientCaveats(for: .named(preset), languageCode: languageCode))
            }
        }
        return sentences
    }

    /// What DNS-level filtering can and cannot see: domains, never paths or page content.
    ///
    /// Unconditional — it describes what DNS *is*, so no routing state can falsify it.
    public static func dnsScopeDisclosure(languageCode: String? = nil) -> String {
        LavaCoreStrings.localized("core.disclosure.dnsScope", languageCode: languageCode)
    }

    /// Why iOS shows a VPN profile, and the fact that browsing traffic does not reach Lava.
    ///
    /// Unconditional in the same way: every recipient above is someone other than Lava.
    ///
    /// BROWSING TRAFFIC, NOT ALL TRAFFIC, in every catalog. Lava's own control plane does reach
    /// Lava — `BlocklistCatalogSync` fetches the catalogue, and account and backup features call
    /// their services — so a translation that widens this to "your internet traffic" turns a true
    /// sentence into a false one (Codex review, PR #641, on the Korean and Chinese catalogs).
    public static func vpnDisclosure(languageCode: String? = nil) -> String {
        LavaCoreStrings.localized("core.disclosure.vpn", languageCode: languageCode)
    }

    // MARK: - Per-tier sentences (internal by design; see the type's routing-claims note)

    static func tierOneDisclosure(_ recipient: Recipient, languageCode: String?) -> String {
        switch recipient {
        case .networkProvided:
            return LavaCoreStrings.localized(
                "core.disclosure.resolverNetworkProvided", languageCode: languageCode)
        case .named(let preset) where preset.id == DNSResolverPreset.customID:
            // A CAVEAT CANNOT UNSAY A CATEGORICAL CLAIM. The general sentence ends "handled under
            // that provider's policy", and appending "Lava cannot say who operates them" after it
            // does not correct that — it CONTRADICTS it, and the user reads both (Codex review,
            // PR #641). I claimed the caveat corrected it when I added it; it never could.
            //
            // So Custom gets its own T1 sentence with no provider attribution at all, and the
            // caveat then adds only what it is actually able to add: who Lava cannot vouch for,
            // and how many addresses are in play. Substituting no display name either — "Custom
            // DNS" is a default label, not a party.
            return LavaCoreStrings.localized(
                "core.disclosure.resolverSelfEntered", languageCode: languageCode)
        case .named(let preset):
            return LavaCoreStrings.localizedFormat(
                "core.disclosure.resolver", languageCode: languageCode, preset.displayName)
        }
    }

    /// `nil` when there is no second tier to disclose, so the caller adds no sentence at all
    /// rather than one saying "there is no fallback" — the absence is not itself a recipient.
    static func tierTwoDisclosure(_ tier: ResolverTierTwo, languageCode: String?) -> String? {
        switch tier {
        case .none:
            return nil
        case .deviceDNS:
            return LavaCoreStrings.localized(
                "core.disclosure.fallbackNetworkProvided", languageCode: languageCode)
        case .resolver(let preset):
            // THE ENCRYPTION CLAIM IS DERIVED, never assumed: the fallback picker exposes each
            // preset's `availableTransports`, which includes `.plainDNS`, so a user can select a
            // fallback that is not encrypted (Codex review, PR #641). Switched exhaustively and
            // locally rather than through a shared `isEncrypted` helper, so adding a transport
            // forces a decision AT THE CLAIM rather than defaulting into one of these sentences.
            let key: String
            switch preset.transport {
            case .dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC:
                key = "core.disclosure.encryptedFallbackRecipient"
            case .plainDNS:
                key = "core.disclosure.plainFallbackRecipient"
            case .deviceDNS:
                // NO PLAN, SO NO RECIPIENT. A user whose FALLBACK selection is itself Device DNS
                // has chosen T2 — `ResolverTierTwo.resolve` answers `.resolver(.device)` — but
                // `DNSResolverRuntimePlan.make` guards `preset.transport != .deviceDNS` and leaves
                // the nested plan nil, so nothing is ever routed there. Naming it would invent a
                // recipient that receives zero lookups (Codex review, PR #641).
                return nil
            }
            return LavaCoreStrings.localizedFormat(
                key, languageCode: languageCode, preset.displayName)
        }
    }

    /// What a NAMED recipient's own properties add to the tier sentence, at whichever tier it
    /// sits. Empty for most presets, which is the common case.
    ///
    /// One call site per tier rather than two lists to keep in step: a caveat that is true of a
    /// filtering primary is true of a filtering fallback, and the drift when they are appended
    /// separately is a caveat that follows one slot instead of the resolver it belongs to.
    static func recipientCaveats(for recipient: Recipient, languageCode: String?) -> [String] {
        guard case .named(let preset) = recipient else { return [] }
        return selfEnteredDisclosure(preset, languageCode: languageCode)
            + upstreamFilteringDisclosure(preset, languageCode: languageCode)
    }

    /// ONE `.named` VALUE CAN BE SEVERAL RECIPIENTS, and only for Custom.
    ///
    /// `DNSResolverPreset.custom(primaryRawValue:secondaryRawValue:displayName:)` merges the
    /// services the user entered into ONE preset — concatenated `ipv4Servers`/`ipv6Servers` for a
    /// plain entry, `dohEndpoint` plus `secondaryDohEndpoint` for an encrypted one — under the
    /// PRIMARY's display name, which defaults to "Custom DNS". Nothing about the merged value
    /// says there were two, and they need not be the same operator, so the tier sentence named one
    /// party for what can be several (Codex review, PR #641).
    ///
    /// It also corrects the tier sentence's "under that provider's policy": true of a preset Lava
    /// ships and knows, meaningless for an address the user typed. Lava cannot say who operates it.
    ///
    /// THE COUNT IS READ OFF THE PRESET, not off its id, because the id survives a narrowing the
    /// addresses do not: `restrictingPlainAddresses(to:)` keeps only the chained-admitted subset,
    /// so a two-address Custom entry whose secondary is IPv6, unusable, or equal to T0 runs T1 on
    /// ONE address. Keying the plural sentence on `id == customID` promised a recipient that had
    /// been narrowed away (Codex review, PR #641) — the same admitted-versus-configured split as
    /// ``PhysicalRungs/effectiveTierOne``, which is why the fix is to read the value rather than
    /// to add a parameter: a caller already obliged to pass the effective recipient passes a
    /// preset carrying the admitted addresses, and the sentence follows.
    /// pinned: ProtectionScopeDisclosureTests.testACustomResolverNarrowedToOneAddressClaimsNoSecond
    static func selfEnteredDisclosure(
        _ preset: DNSResolverPreset,
        languageCode: String?
    ) -> [String] {
        guard preset.id == DNSResolverPreset.customID else { return [] }
        let key = selfEnteredEndpointCount(preset) > 1
            ? "core.disclosure.selfEnteredRecipients"
            : "core.disclosure.selfEnteredRecipient"
        return [LavaCoreStrings.localized(key, languageCode: languageCode)]
    }

    /// How many resolvers a Custom preset actually sends allowed lookups to.
    ///
    /// SWITCHED ON THE EFFECTIVE TRANSPORT, because the storage fields OVERLAP. A DoT or DoQ DNS
    /// stamp writes its bootstrap IPs into `ipv4Servers`/`ipv6Servers` AND builds the single
    /// `dotEndpoint`/`doqEndpoint` beside them (`DNSStampParser`), so summing every field counted
    /// one logical resolver twice and produced the plural sentence for a user who entered one
    /// stamp (Codex review, PR #641).
    ///
    /// The first version summed deliberately, reasoning that a switch could silently miss a family
    /// a later transport adds. That reasoning was wrong twice over: the sum does not merely fail
    /// to understate, it OVERSTATES on the overlapping shapes — and an exhaustive switch over
    /// `DNSResolverTransport` fails to COMPILE when a case is added, which is the loudest possible
    /// version of the thing summing was meant to protect against.
    ///
    /// Bootstrap addresses are excluded on purpose: they resolve the endpoint's hostname, they are
    /// not where an allowed lookup is sent.
    /// pinned: ProtectionScopeDisclosureTests.testAStampWithBootstrapAddressesIsStillOneRecipient
    private static func selfEnteredEndpointCount(_ preset: DNSResolverPreset) -> Int {
        switch preset.transport {
        case .plainDNS, .deviceDNS:
            return preset.ipv4Servers.count + preset.ipv6Servers.count
        case .dnsOverHTTPS:
            return (preset.dohEndpoint == nil ? 0 : 1) + (preset.secondaryDohEndpoint == nil ? 0 : 1)
        case .dnsOverTLS:
            return (preset.dotEndpoint == nil ? 0 : 1) + (preset.secondaryDotEndpoint == nil ? 0 : 1)
        case .dnsOverQUIC:
            return (preset.doqEndpoint == nil ? 0 : 1) + (preset.secondaryDoqEndpoint == nil ? 0 : 1)
        }
    }

    /// A RECIPIENT THAT FILTERS IS NOT A NEUTRAL ONE, and the block-decision sentence is only
    /// true of LAVA's decisions. `quad9Secure` and `hagezi` — in plain, DoH and DoT variants —
    /// carry `hasUpstreamFiltering: true`, so a domain Lava allows can still be blocked by the
    /// resolver it is sent to. The copy says "Lava's block decisions happen on this iPhone", and
    /// this adds the other half rather than leaving a user to infer that allowing is final
    /// (Codex review, PR #641).
    ///
    /// Returns an array so the no-filtering case adds nothing at all, which is the common one.
    static func upstreamFilteringDisclosure(
        _ preset: DNSResolverPreset,
        languageCode: String?
    ) -> [String] {
        guard preset.hasUpstreamFiltering else { return [] }
        return [
            LavaCoreStrings.localizedFormat(
                "core.disclosure.upstreamFilteringRecipient", languageCode: languageCode,
                preset.displayName)
        ]
    }

    /// T0 IS A SET OF ADDRESSES LAVA DID NOT CHOOSE, and the copy says exactly that.
    ///
    /// The parameter is a Bool because whether the upstream carries DNS is the only routing fact
    /// this type is entitled to be told. The IDENTITIES behind it cannot be reduced that far:
    /// `ChainedTunnelResolverSelection.selection(from:)` admits EVERY usable `DNS =` entry in the
    /// imported configuration, and `TunnelledPlainDNSResolution` walks `route.resolverAddresses`
    /// in failover order, so several addresses can each receive lookups. They also need not belong
    /// to the VPN operator — the selection code's own comment uses `DNS = 1.1.1.1` as its worked
    /// example — so "that VPN's own DNS resolver" attributed a third party's resolver to whoever
    /// wrote the conf (Codex review, PR #641).
    ///
    /// Fixed in the copy rather than the signature: naming the servers as the ones the
    /// CONFIGURATION lists, plural, with the same unknown-operator caveat a self-entered resolver
    /// carries. That is true for one address or five and needs no new caller obligation — and this
    /// type has no business asserting who runs an address it read out of an imported file.
    /// pinned: ProtectionScopeDisclosureTests.testTheChainedSentenceAttributesNoOperatorToTheUpstream
    static func chainedRecipientDisclosure(languageCode: String?) -> String {
        LavaCoreStrings.localized("core.disclosure.chainedRecipient", languageCode: languageCode)
    }
}
