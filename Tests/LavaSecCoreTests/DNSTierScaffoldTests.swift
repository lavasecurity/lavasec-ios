import XCTest

import LavaSecDNS
import LavaSecKit

/// The DNS tier scaffold is canonical: T0 is the chained upstream's own `DNS =`, T1 is the
/// resolver the user selected, T2 is the fallback they selected
/// (`docs/architecture/dns-tiers.md`).
///
/// Before PR #637 the code numbered ATTEMPTS within a chained session and started at one, so the
/// same setting carried two numbers: `AppConfiguration` had to say the user's one selection
/// served "both modes" under two different numbers, and `ChainedResolverEgress` had to carry an
/// aside explaining that in DNS-only the chosen resolver was the OTHER number. A number that
/// changes with the mode is not a tier; it is an attempt index wearing a tier's name, and every
/// surface that read it had to re-derive which mode it was in first.
///
/// These tests keep the scaffold from drifting back: the document says what the tiers are, the
/// retired numbering cannot return to the source, and the one persisted key the rename touched
/// still decodes configurations written under its old spelling.
final class DNSTierScaffoldTests: XCTestCase {
    // WHAT IS SWEPT IS THE PROSE FORM, not the identifiers. The identifiers were renamed and the
    // compiler keeps them renamed — `tierTwoFallback` no longer exists to be written. Comments
    // are where a retired number survives a rename and then teaches the next reader the scheme
    // the rename removed, which is precisely the drift a source pin is for.
    //
    // Canonical written form is `T0`/`T1`/`T2`. The tokens below are ASSEMBLED rather than
    // written out, so this file can name what it forbids without the sweep having to exempt
    // itself — an exemption is the hole a drifting file would slip through.
    private static let retiredProseTokens = [
        "tier" + "-1", "tier" + "-2", "tier" + "-3",
        "tier " + "1", "tier " + "2", "tier " + "3",
        "tier " + "one", "tier " + "two", "tier " + "three",
    ]
    /// `INV-TIER-1` — the FILTER RULE BUDGET invariant, a different subject that shares the word
    /// — legitimately contains one of them, so the sweep strips that name before looking.
    private static let filterBudgetInvariant = "INV-" + "TIER" + "-1"

    private static let sweptDirectories = [
        "Sources", "LavaSecApp", "LavaSecTunnel", "LavaSecIntents", "LavaSecWidget", "Shared",
        "Tests",
    ]

    // MARK: - The document

    /// The scaffold is only canonical if it is written down. A rename with no document is a
    /// preference; a document is what the next change can be checked against.
    func testTheScaffoldDocumentDefinesTheThreeTiers() throws {
        let doc = try readSource(.dnsTierScaffold)

        XCTAssertTrue(doc.contains("**Canonical.**"), "the document must declare itself canonical")

        // Each tier is defined by WHERE IT COMES FROM, because that is what makes it a statement
        // about the user's intent rather than about a session's attempt order.
        XCTAssertTrue(
            doc.contains("`DNS =`"),
            "T0 must be defined as the chained upstream's own resolver")
        XCTAssertTrue(
            doc.contains("`resolverPresetID`"),
            "T1 must be defined as the resolver the user selected")
        XCTAssertTrue(
            doc.contains("`fallbackResolverPresetID`"),
            "T2 must be defined as the fallback the user selected")

        // The rule the whole scaffold exists to state.
        XCTAssertTrue(
            doc.contains("A tier keeps its number in every mode."),
            "the document must state that chaining inserts T0 above T1 rather than renumbering it")

        // And the correction that a reader of the field names alone would get wrong. An earlier
        // draft of this document drew T1 → T2 → device DNS as one chain; the code arms exactly one
        // rung beneath T1. A canonical document that misdraws the ladder is worse than none.
        XCTAssertTrue(
            doc.contains("T2 is one optional, explicitly selected rung"),
            "the document must say that one optional rung sits beneath T1")

        // And that the rung which arms is a CHOICE, not a degradation. An earlier draft described
        // the device rung as falling back to a resolver "the user did not choose", which is false:
        // "Fallback to Device DNS" is a labelled control the user sets. A document that reads a
        // deliberate setting as a failure invites changing behaviour the user asked for.
        XCTAssertTrue(
            doc.contains("Two alternatives may be stacked."),
            "the document must record the rung beneath T1 as the user's own setting")
    }

    // MARK: - The retired numbering

    /// The attempt-order numbering does not come back in prose.
    ///
    /// A sweep rather than a per-file pin: the old scheme reached fourteen source files and a
    /// larger test surface, and a pin on the files it happened to occupy in September would say
    /// nothing about the fifteenth.
    func testTheRetiredAttemptOrderNumberingDoesNotReturn() throws {
        var offenders: [String] = []

        for relativePath in try Self.sweptSwiftFiles() {
            let contents = try String(
                contentsOf: packageRootURL.appendingPathComponent(relativePath), encoding: .utf8)
            // The filter-budget invariant is a different subject that shares the word.
            let dnsText = contents.replacingOccurrences(
                of: Self.filterBudgetInvariant, with: "")

            var hits: [String] = []
            for token in Self.retiredProseTokens
            where dnsText.range(of: token, options: .caseInsensitive) != nil {
                hits.append("\"\(token)\"")
            }
            if !hits.isEmpty {
                offenders.append("\(relativePath): \(hits.joined(separator: ", "))")
            }
        }

        XCTAssertEqual(
            offenders, [],
            """
            The retired attempt-order numbering is back in prose. Write tiers as T0/T1/T2, per \
            the canonical scaffold (docs/architecture/dns-tiers.md): T0 is the chained upstream's \
            own `DNS =`, T1 is the user's selected resolver, T2 is their selected fallback. Prose \
            meaning "whichever tier this session's plan was built from" says `planned`, never a \
            number — that one is genuinely mode-relative, which is why it must not carry a \
            tier's name.
            """)
    }

    private static func sweptSwiftFiles() throws -> [String] {
        var found: [String] = []
        for directory in sweptDirectories {
            let root = packageRootURL.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                found.append(
                    url.path.replacingOccurrences(of: packageRootURL.path + "/", with: ""))
            }
        }
        // A sweep that silently found nothing would pass forever.
        guard found.count > 100 else {
            throw SourceIntrospectionFailure(description: """
            The tier sweep found only \(found.count) Swift files under \
            \(sweptDirectories.joined(separator: ", ")) — the directory layout moved and the \
            sweep is no longer covering the source it was written to cover.
            """)
        }
        return found
    }

    // MARK: - What the tiers mean

    /// T1 IS THE SAME SETTING IN BOTH MODES. This is the claim the old numbering could not make,
    /// and it is a behavioural claim, not a naming one: the resolver the chained rung asks is the
    /// resolver Settings shows, byte for byte, whether or not chaining is on.
    func testTierOneIsTheUsersOwnSelectionInBothModes() {
        var configuration = AppConfiguration()
        configuration.resolverPresetID = DNSResolverPreset.cloudflareDoH.id

        let dnsOnly = configuration
        var chained = configuration
        chained.chainedUpstreamEnabled = true

        XCTAssertEqual(
            dnsOnly.resolverPreset.id, chained.resolverPreset.id,
            "turning chaining on must not renumber or re-point T1")
        XCTAssertEqual(
            chained.chainedTierOneResolverConfiguration?.resolverPreset.id,
            configuration.resolverPreset.id,
            "the chained T1 rung asks the resolver the user selected, not a substitute")
    }

    /// T2 IS ONE RUNG, AND WHAT FILLS IT FOLLOWS T1 — the document must not imply a third rung
    /// under every T1, and this test must not imply T2 is only one of the two fillings.
    ///
    /// Beneath T1 there is exactly ONE rung. `DNSResolverRuntimePlan.make` gates both candidate
    /// fillings on the same term, so they are mutually exclusive by construction rather than by
    /// convention, and BOTH are T2:
    ///
    /// - T1 encrypted or plain → T2 is device DNS, whatever DHCP handed the device (default ON)
    /// - T1 is Device DNS → T2 is the alternative resolver the user picked (default OFF)
    ///
    /// Asserted rather than described because the field names alone read as a three-rung ladder:
    /// `resolverPresetID` and `fallbackResolverPresetID` both DEFAULT to Quad9 DoH, which invites
    /// the conclusion that the alternative-resolver filling sits under T1 out of the box. It does
    /// not — under the default T1 that field is dormant, `Settings → DNS` shows no picker that
    /// could set it, and T2 is device DNS instead.
    ///
    /// 🔴 An earlier revision of this test called only the resolver filling T2 and said T2 was
    /// "unreachable" under an encrypted T1. The assertion passed — it reads the legacy
    /// implementation flag — while teaching the opposite of the vocabulary it exists to enforce
    /// (Codex, PR #637). A test whose message contradicts the canonical document is worse than no
    /// test, because it is the version a reader trusts.
    func testExactlyOneRungSitsBeneathTierOneAndItsFillingFollowsTheTransport() {
        // T1 encrypted: T2 is filled by device DNS, and the resolver filling cannot also arm.
        let encryptedTierOne = DNSResolverRuntimePlan.make(
            resolver: .quad9UnfilteredDoH,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            encryptedFallbackResolver: .quad9SecureDoH)
        XCTAssertTrue(
            encryptedTierOne.shouldFallbackToDeviceDNS,
            "under an encrypted T1, T2 is device DNS — the filling the settings toggle offers "
                + "there, and the one the user enabled")
        XCTAssertFalse(
            encryptedTierOne.shouldFallbackToEncrypted,
            "T2 is already filled, so the alternative-resolver filling must not also arm — even "
                + "with its opt-in on and a resolver selected. One rung, never two")
        XCTAssertEqual(
            encryptedTierOne.encryptedFallbackEndpoints, [],
            "and no alternative-resolver plan is built beside it")

        // T1 is Device DNS: T2 is filled by the user's alternative resolver, and the device
        // filling is the one that cannot arm — it would be the same resolver twice.
        let deviceTierOne = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            encryptedFallbackResolver: .quad9SecureDoH)
        XCTAssertTrue(
            deviceTierOne.shouldFallbackToEncrypted,
            "under a Device-DNS T1, T2 is the alternative resolver the user picked")
        XCTAssertFalse(
            deviceTierOne.shouldFallbackToDeviceDNS,
            "and the device filling cannot also arm — one rung, never two")

        // Declining the fallback empties T2 in either arrangement. That is a stated choice, and
        // the ladder then ends at T1 and refuses (`INV-DNS-1`).
        let declined = DNSResolverRuntimePlan.make(
            resolver: .quad9UnfilteredDoH,
            fallbackToDeviceDNS: false,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            encryptedFallbackResolver: .quad9SecureDoH)
        XCTAssertFalse(declined.shouldFallbackToDeviceDNS)
        XCTAssertFalse(
            declined.shouldFallbackToEncrypted,
            "declining T2 empties the rung; it does not swap in the other filling")
    }

    /// T2 is the user's OWN selection wherever it is reachable, and chaining does not move it —
    /// the same rule that holds for T1. The rung carries it because
    /// `chainedTierOneResolverConfiguration` hands the rung the user's whole configuration, which
    /// is what `INV-CHAIN-7` means by the full ladder on the rung's own interface.
    func testTheFallbackSelectionIsTheUsersOwnInBothModes() {
        var configuration = AppConfiguration()
        configuration.resolverPresetID = DNSResolverPreset.device.id
        configuration.usesEncryptedDeviceDNSFallback = true
        configuration.fallbackResolverPresetID = DNSResolverPreset.cloudflareDoH.id

        var chained = configuration
        chained.chainedUpstreamEnabled = true

        XCTAssertEqual(
            configuration.fallbackResolverPreset.id, chained.fallbackResolverPreset.id,
            "chaining does not move T2 either")
        XCTAssertEqual(
            chained.chainedTierOneResolverConfiguration?.fallbackResolverPreset.id,
            DNSResolverPreset.cloudflareDoH.id,
            "the rung is handed the user's own T2, not a substitute")
    }

    // MARK: - The rename's one persisted key

    /// THE NUMBERING WAS WRONG; THE STORED CONFIGURATION WAS NOT.
    ///
    /// `chainedTierOneFallbackEnabled` pins its encoded key to the retired spelling. Without that
    /// pin a renamed key decodes as ABSENT on every existing install, and the `?? true` default —
    /// which exists to reproduce the pre-toggle behaviour — would silently re-enable the rung for
    /// the one user who had turned it off. A rename may not change what a device already decided.
    func testTheRenamedToggleStillReadsAndWritesItsStoredKey() throws {
        // Assembled so the prose sweep above does not read a WIRE VALUE as retired naming.
        let storedKey = "chained" + "Tier" + "Two" + "FallbackEnabled"

        let declined = Data("{\"\(storedKey)\":false}".utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: declined)
        XCTAssertFalse(
            decoded.chainedTierOneFallbackEnabled,
            "a user who declined the rung under the old key must stay declined")
        XCTAssertNil(
            decoded.chainedTierOneResolverConfiguration,
            "and the gate must still read that decision")

        var enabled = AppConfiguration()
        enabled.chainedTierOneFallbackEnabled = false
        let written = try XCTUnwrap(
            String(data: try JSONEncoder().encode(enabled), encoding: .utf8))
        XCTAssertTrue(
            written.contains(storedKey),
            "the encoded key must stay the retired spelling, or an older build stops reading it")
        XCTAssertFalse(
            written.contains("chainedTierOneFallbackEnabled"),
            "writing the NEW spelling would be a one-way migration nothing performs")
    }
}
