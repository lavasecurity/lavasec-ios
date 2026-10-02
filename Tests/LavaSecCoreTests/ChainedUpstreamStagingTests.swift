import XCTest

@testable import LavaSecKit

/// The S9 staging boundary: which builds may stage at all, and what a `.conf` has to say.
final class ChainedUpstreamStagingTests: XCTestCase {
    /// Team-prefixed exactly as `ChainedUpstreamKeychainAccessGroup.resolved` yields them.
    private static let qaGroup = "ABCDE12345.com.lavasec.dev.qa.chained-upstream"
    private static let productionGroup = "ABCDE12345.com.lavasec.app.chained-upstream"
    /// A syntactically valid client key that is not the peer's.
    private static let privateKey = Data(repeating: 7, count: 32).base64EncodedString()
    private static let peerKey = Data([
        0xe6, 0xdb, 0x37, 0x1d, 0x9a, 0x2a, 0x1e, 0x2c, 0x4d, 0x5b, 0x6f, 0x71, 0x83, 0x94,
        0xa5, 0xb6, 0xc7, 0xd8, 0xe9, 0xfa, 0x0b, 0x1c, 0x2d, 0x3e, 0x4f, 0x50, 0x61, 0x72,
        0x83, 0x94, 0xa5, 0x36,
    ]).base64EncodedString()

    private func conf(
        privateKey: String? = nil,
        peerKey: String? = nil,
        address: String = "10.64.0.2/32",
        extraInterface: String = "",
        extraPeer: String = ""
    ) -> String {
        """
        [Interface]
        PrivateKey = \(privateKey ?? Self.privateKey)
        Address = \(address)
        DNS = 10.64.0.1
        \(extraInterface)

        [Peer]
        PublicKey = \(peerKey ?? Self.peerKey)
        Endpoint = 193.138.7.5:51820
        AllowedIPs = 0.0.0.0/0, ::/0
        \(extraPeer)
        """
    }

    // MARK: - The build refusal

    func testAProductionIdentityCannotBeStagedInto() throws {
        // The C8-adjacent obligation, as a type: a QA writer must not persist state a Release
        // build reads. The gates do not line up on their own — the staging UI compiles under
        // `DEBUG || LAVA_QA_TOOLS` while the store identity is chosen by `LAVA_QA_TOOLS`
        // alone, so a local Debug build offers the button AND addresses the production slot.
        // Refusing the identity is what makes that combination unwritable.
        XCTAssertThrowsError(
            try ChainedUpstreamStagingRequest(conf: conf(), identity: .production, accessGroup: Self.productionGroup)
        ) { error in
            XCTAssertEqual(
                error as? ChainedUpstreamStagingRefusal, .buildMayNotStage(.production),
                "a production-identity build staged a chained upstream")
        }
    }

    func testTheBuildRefusalPrecedesEveryOtherVerdict() throws {
        // Ordering, and it is not cosmetic: a production build pasting a broken file must
        // hear that it may not stage at all, rather than spending a QA session fixing a file
        // it was never allowed to use. Also keeps the refusal independent of parse coverage —
        // a future parser change cannot accidentally let a production build through by
        // failing earlier.
        let garbage = "not a conf at all"
        XCTAssertThrowsError(
            try ChainedUpstreamStagingRequest(conf: garbage, identity: .production, accessGroup: Self.productionGroup)
        ) { error in
            XCTAssertEqual(
                error as? ChainedUpstreamStagingRefusal, .buildMayNotStage(.production))
        }
    }

    func testAFlagWithoutTheQAConfigurationIsRefused() throws {
        // THE OTHER HALF OF THE BUILD'S IDENTITY. The file half follows
        // `#if LAVA_QA_TOOLS`; the key half follows the per-configuration
        // `LAVA_KEYCHAIN_SHARING_GROUP`. Injecting the define through OTHER_SWIFT_FLAGS is
        // this repo's documented way to reach package targets, and a developer who puts it
        // in `Config/Lava.local.xcconfig` flags Debug and Release too — producing a build
        // that is `.qa` by the identity and PRODUCTION by the group. An identity-only guard
        // waves that through and commits a live private key into the group the shipping
        // build is entitled to, where it outlives app deletion, with no visible failure
        // because the configuration lands under a filename production never opens.
        XCTAssertThrowsError(
            try ChainedUpstreamStagingRequest(
                conf: conf(), identity: .qa, accessGroup: Self.productionGroup)
        ) { error in
            XCTAssertEqual(
                error as? ChainedUpstreamStagingRefusal,
                .buildIdentityIsInconsistent(identity: .qa, group: Self.productionGroup),
                "a QA-flagged build committed into the production access group")
        }
        // And an unrecognised group is refused rather than assumed benign: a group this
        // mapping does not know is a build shape nobody reasoned about.
        XCTAssertThrowsError(
            try ChainedUpstreamStagingRequest(
                conf: conf(), identity: .qa, accessGroup: "ABCDE12345.com.example.other")
        )
    }

    func testTheGroupMappingNamesExactlyTheTwoKnownIdentities() {
        XCTAssertEqual(
            ChainedUpstreamStoreIdentity.identity(forKeychainGroup: Self.qaGroup), .qa)
        XCTAssertEqual(
            ChainedUpstreamStoreIdentity.identity(forKeychainGroup: Self.productionGroup),
            .production)
        // Unprefixed (an unsigned build's shape) and foreign groups belong to neither.
        XCTAssertNil(
            ChainedUpstreamStoreIdentity.identity(
                forKeychainGroup: "com.lavasec.app.chained-upstreamX"))
        XCTAssertNil(ChainedUpstreamStoreIdentity.identity(forKeychainGroup: ""))
    }

    func testTheRefusalNeverLogsTheAccessGroup() {
        // The group carries the team prefix. The identity alone already says what went
        // wrong, so the log value says only that.
        let refusal = ChainedUpstreamStagingRefusal.buildIdentityIsInconsistent(
            identity: .qa, group: Self.productionGroup)
        XCTAssertFalse(refusal.logValue.contains("ABCDE12345"))
        XCTAssertFalse(refusal.logValue.contains("com.lavasec"))
    }

    func testTheQAIdentityIsAdmitted() throws {
        let request = try ChainedUpstreamStagingRequest(conf: conf(), identity: .qa, accessGroup: Self.qaGroup)
        XCTAssertEqual(request.identity, .qa)
        XCTAssertEqual(request.rotation.configuration.endpointHost, "193.138.7.5")
        XCTAssertEqual(request.rotation.configuration.endpointPort, 51820)
        XCTAssertEqual(request.rotation.configuration.clientAddress, "10.64.0.2")
        XCTAssertEqual(request.rotation.configuration.dnsAddresses, ["10.64.0.1"])
        XCTAssertEqual(request.rotation.configuration.allowedIPs, ["0.0.0.0/0", "::/0"])
    }

    // MARK: - The parse

    func testCRLFLinesParse() throws {
        // A file pasted from a Windows-authored provider portal. Splitting on "\n" leaves a
        // trailing \r on every value, and base64 decoding then fails for a reason invisible on
        // a device screen (the #442 spike parser's own bug).
        let crlf = conf().replacingOccurrences(of: "\n", with: "\r\n")
        let request = try ChainedUpstreamStagingRequest(conf: crlf, identity: .qa, accessGroup: Self.qaGroup)
        XCTAssertEqual(request.rotation.configuration.endpointHost, "193.138.7.5")
    }

    func testCommentsAndInertUnknownKeysDoNotChangeTheResult() throws {
        // `FwMark` is genuinely inert here: it sets a Linux packet mark this platform has
        // no equivalent of, and nothing downstream reads it. `Table` used to stand in this
        // test as the harmless example and was exactly the wrong choice — see
        // `testBehaviourChangingDirectivesAreRefused`.
        let annotated = try ChainedUpstreamStagingRequest(
            conf: conf(
                extraInterface: "# a comment\nFwMark = 0x1234",
                extraPeer: "PersistentKeepalive = 25 # trailing"),
            identity: .qa, accessGroup: Self.qaGroup)
        XCTAssertEqual(annotated.rotation.configuration.persistentKeepaliveSeconds, 25)
        XCTAssertEqual(annotated.rotation.configuration.endpointPort, 51820)
    }

    func testBehaviourChangingDirectivesAreRefused() throws {
        // The parser's stated invariant is that unknown keys are skipped only where they
        // cannot change what the tunnel does with the keys it DID read. `Table = off` is
        // the counter-example that made the invariant false: in wg-quick it disables
        // automatic route installation from `AllowedIPs`, while this tunnel derives and
        // installs the default routes from that same `AllowedIPs` regardless — so the
        // staged session does the OPPOSITE of the pasted file. The script hooks are the
        // same class: absent, and invisible until whatever they set up is missing.
        for directive in ["Table = off", "PreUp = /bin/true", "PostUp = /bin/true",
                          "PreDown = /bin/true", "PostDown = /bin/true",
                          // The resolvconf hooks, newer than the other four and easy to
                          // omit for exactly that reason (Kilo, PR #519).
                          "PreDNS = /bin/true", "PostDNS = /bin/true",
                          "SaveConfig = true",
                          // Not a hook, and not inert: the engine honours `listen_port` by
                          // opening that socket, while this transport is an NWConnection
                          // whose local port it does not choose.
                          "ListenPort = 51820"] {
            let key = directive.split(separator: " ")[0].lowercased()
            XCTAssertThrowsError(
                try ChainedUpstreamStagingRequest(
                    conf: conf(extraInterface: directive), identity: .qa,
                    accessGroup: Self.qaGroup),
                "\(directive) was silently dropped"
            ) { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamStagingRefusal, .unsupportedDirective(key))
            }
        }
        // And in the [Peer] section too — wg-quick accepts the hooks in either.
        XCTAssertThrowsError(
            try ChainedUpstreamStagingRequest(
                conf: conf(extraPeer: "PostUp = /bin/true"), identity: .qa,
                accessGroup: Self.qaGroup)
        ) { error in
            XCTAssertEqual(
                error as? ChainedUpstreamStagingRefusal, .unsupportedDirective("postup"))
        }
    }

    func testNoRefusalLogValueCarriesPunctuationALogFilterMustQuote() throws {
        // `logValue` is a stable log identifier, never user copy. The convention this asserts
        // is PUNCTUATION, not case: the existing cases deliberately echo the file's key as
        // written (`staging-malformed-Address`), so a lower-case rule would be inventing a
        // convention this enum does not follow. What it must not carry is a bracket or a
        // space — the wrong-section case was the only one that did, because its payload
        // holds `[Peer]` for the operator to read on a device screen (Kilo, PR #519).
        let refusals: [ChainedUpstreamStagingRefusal] = [
            .buildMayNotStage(.production),
            .unsupportedDirective("table"),
            .missingOrRepeatedKey("endpoint"),
            .directiveInWrongSection(directive: "dns", section: "[Peer]"),
            .directiveInWrongSection(directive: "persistentkeepalive", section: "[Interface]"),
            .malformedValue("Address"),
        ]
        let forbidden = CharacterSet(charactersIn: "[]{}() \t\"'")
        for refusal in refusals {
            XCTAssertNil(
                refusal.logValue.rangeOfCharacter(from: forbidden),
                "\(refusal.logValue) carries punctuation a log filter must quote")
        }
        XCTAssertEqual(
            ChainedUpstreamStagingRefusal
                .directiveInWrongSection(directive: "dns", section: "[Peer]").logValue,
            "staging-wrong-section-dns-peer")
    }

    func testEveryWireGuardDirectiveIsReadRefusedOrKnownInert() throws {
        // The parser promises that unknown keys are skipped only where they cannot change
        // what the tunnel does with the keys it DID read. That promise is only checkable if
        // the known set is covered, so this puts every directive `wg` and `wg-quick` define
        // into exactly one of three named categories — read, refused, or deliberately inert.
        //
        // The third category is the point. `Table` was once this file's example of a harmless
        // unknown key and turned out to be the sharpest counter-example; `FwMark` was then
        // reported as a missing refusal on the grounds that the engine applies it, which is
        // true on Linux and false here (`set_fwmark` is not compiled for iOS). Either way the
        // answer must be a DECISION recorded in a set, not a default that nobody revisited.
        // REFUSED first, and READ is what is left over. The section lists are about
        // PLACEMENT, not consumption: `presharedkey` sits in `peerOnlyDirectives` so a
        // wrong-section copy can be diagnosed. It is now READ — the parser parses it as an
        // optional `[Peer]` directive and carries it end-to-end — so it falls out of
        // `sectionScoped` into `read` here, no longer in `refused` (the staging→engine carry
        // exists). The Amnezia keys stay refused (the engine cannot obfuscate). This test once
        // recorded `presharedkey` as consumed while the parser refused it, which was the bug;
        // now the disposition and the parser agree (Codex, PR #519).
        let refused = Set(
            ChainedUpstreamConfParser.behaviourChangingDirectives
                + ChainedUpstreamConfParser.separatelyRefusedDirectives)
        let sectionScoped = Set(
            ChainedUpstreamConfParser.interfaceOnlyDirectives
                + ChainedUpstreamConfParser.peerOnlyDirectives)
        let read = sectionScoped.subtracting(refused)
        let inert = Set(ChainedUpstreamConfParser.knownInertDirectives)

        // The disposition SHIFT, asserted explicitly so a revert cannot pass this test by
        // moving `presharedkey` back into `refused` while the loop below still finds exactly
        // one category for it. PSK is read; the Amnezia keys are not.
        XCTAssertTrue(read.contains("presharedkey"), "PresharedKey must now be READ, not refused")
        XCTAssertFalse(
            refused.contains("presharedkey"), "PresharedKey must not be in the refused set")
        // AmneziaWG's obfuscation keys: a fork's, not `wg(8)`'s — Kilo reported them as
        // upstream, which they are not. They are refused anyway, because the vendored engine
        // is stock boringtun with no obfuscation support, so such a file stages green and
        // then fails as a handshake that never completes.
        let amneziaDirectives = [
            "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4",
        ]
        for key in amneziaDirectives {
            XCTAssertTrue(
                refused.contains(key),
                "\(key) is an AmneziaWG obfuscation key and must stay refused — the vendored "
                    + "engine cannot obfuscate")
        }
        let everyDirective = amneziaDirectives + [
            // wg-quick(8) [Interface]
            "address", "dns", "mtu", "table",
            "preup", "postup", "predown", "postdown", "predns", "postdns", "saveconfig",
            // wg(8) [Interface]
            "privatekey", "listenport", "fwmark",
            // wg(8) [Peer]
            "publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive",
        ]
        for directive in everyDirective {
            let categories = [read, refused, inert].filter { $0.contains(directive) }.count
            XCTAssertEqual(
                categories, 1,
                "\(directive) belongs to \(categories) categories — it must be read, refused, "
                    + "or explicitly inert, and exactly one of those")
        }

        // AND THE OTHER DIRECTION. The loop above only proves the known set is covered; it
        // says nothing about an entry that is in a set but is not a directive, so a typo
        // (`persistantkeepalive`) would sit in `peerOnlyDirectives` doing nothing while this
        // test stayed green (Kilo, PR #519). Everything declared must be a directive this
        // parser has a reason to name.
        let declared = read.union(refused).union(inert)
        let known = Set(everyDirective).union(amneziaDirectives)
        XCTAssertTrue(
            declared.isSubset(of: known),
            "declared but not a known directive: \(declared.subtracting(known).sorted())")
    }

    func testAWellFormedAddressPrefixIsNormalisedAwayWhileAMalformedSuffixIsRefused() throws {
        // `TunnelRoutePlan.make` installs the inner address as a bare /32 for the chained
        // branch REGARDLESS of the file's prefix, and with 0.0.0.0/0 claimed the interface
        // subnet routes nothing — so a `/24` is behaviourally SUBSUMED by that /32, not a
        // contradiction the tunnel cannot honour. Staging therefore accepts any well-formed
        // `/0`…`/32` prefix and NORMALISES it away, yielding the same bare `clientAddress`
        // as a bare address or `/32`. This is the largest population of real configs — `/24`
        // (and `/16`, `/8`, …) is what PiVPN, wg-easy, wireguard-ui, pfSense/OPNsense, and
        // the official WireGuard quickstart write. MECE WG-config audit gap #1; the earlier
        // version of this test asserted the OPPOSITE (that a prefix is refused) — inverted
        // here now that the plan's hardcoded /32 is understood to subsume it (Codex, #519).
        for prefix in ["/24", "/16", "/8", "/0", "/31", "/32", ""] {
            let request = try ChainedUpstreamStagingRequest(
                conf: conf(address: "10.64.0.2\(prefix)"), identity: .qa,
                accessGroup: Self.qaGroup)
            XCTAssertEqual(
                request.rotation.configuration.clientAddress, "10.64.0.2",
                "Address 10.64.0.2\(prefix) must stage and normalise to the bare host")
        }
        // A MALFORMED suffix is still refused, not repaired: non-numeric (`/garbage`), out of
        // the 0…32 range (`/33`, `/320`), an IPv6 length applied to v4 (`/128`), a negative
        // (`/-1`), a leading-zero spelling (`/032` — the same single-spelling rule the octets
        // get), a trailing slash with nothing after it (`/`), and interior whitespace in the
        // suffix (`/ 32`). The prefix relaxation is a WIDTH relaxation, not a "read anything
        // after the slash" one — this is still the boundary that decides the tunnel matches
        // the file.
        for prefix in ["/garbage", "/33", "/-1", "/128", "/320", "/032", "/", "/ 32"] {
            XCTAssertThrowsError(
                try ChainedUpstreamStagingRequest(
                    conf: conf(address: "10.64.0.2\(prefix)"), identity: .qa,
                    accessGroup: Self.qaGroup),
                "Address\(prefix) was accepted"
            ) { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamStagingRefusal, .malformedValue("Address"))
            }
        }
        // AND THE HOST SIDE, which the first version of the check left trimmed while making
        // the suffix exact — one expression, strict on one side and lenient on the other, so
        // `10.64.0.2 /32` passed with the trim quietly repairing the host (Codex, PR #519).
        // Relaxing the suffix does NOT loosen this: interior whitespace in the host is still
        // refused. NOT " 10.64.0.2": the key/value split already trims the whole value, and
        // trimming there is right — a conf may be written `Address =  10.64.0.2/32` and mean
        // it. What this boundary must refuse is whitespace it would otherwise REPAIR inside
        // the token.
        for host in ["10.64.0.2 ", "10.64. 0.2", "10.64.0.2\t"] {
            XCTAssertThrowsError(
                try ChainedUpstreamStagingRequest(
                    conf: conf(address: "\(host)/32"), identity: .qa,
                    accessGroup: Self.qaGroup),
                "Address \(host)/32 was accepted"
            ) { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamStagingRefusal, .malformedValue("Address"))
            }
        }
    }

    func testASupportedDirectiveInTheWrongSectionIsRefused() throws {
        // Every lookup in the parser is section-scoped, so a supported key in the wrong
        // section is read by NOBODY. For the optional ones that is silent: the file says
        // keepalive 25, no resolvers, or a smaller MTU, and the staged tunnel does the
        // default instead — the same "session contradicts the file" class as `Table = off`,
        // only quieter because nothing refuses it (Codex, PR #519). `PersistentKeepalive`
        // under `[Interface]` is the realistic typo, since wg-quick users write it next to
        // the other tuning knobs.
        for directive in ["DNS = 10.64.0.1", "MTU = 1380", "PrivateKey = \(Self.privateKey)",
                          "Address = 10.64.0.2/32"] {
            let key = directive.split(separator: " ")[0].lowercased()
            XCTAssertThrowsError(
                try ChainedUpstreamStagingRequest(
                    conf: conf(extraPeer: directive), identity: .qa, accessGroup: Self.qaGroup),
                "\(directive) was accepted under [Peer]"
            ) { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamStagingRefusal,
                    .directiveInWrongSection(directive: key, section: "[Peer]"))
            }
        }
        for directive in ["PersistentKeepalive = 25", "PublicKey = \(Self.peerKey)",
                          "Endpoint = 193.138.7.5:51820", "AllowedIPs = 0.0.0.0/0",
                          "PresharedKey = \(Self.peerKey)"] {
            let key = directive.split(separator: " ")[0].lowercased()
            XCTAssertThrowsError(
                try ChainedUpstreamStagingRequest(
                    conf: conf(extraInterface: directive), identity: .qa,
                    accessGroup: Self.qaGroup),
                "\(directive) was accepted under [Interface]"
            ) { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamStagingRefusal,
                    .directiveInWrongSection(directive: key, section: "[Interface]"))
            }
        }
        // ...and the CORRECT placements still parse, or the refusal would be a regression
        // dressed as a fix.
        XCTAssertNoThrow(
            try ChainedUpstreamStagingRequest(
                conf: conf(extraPeer: "PersistentKeepalive = 25"), identity: .qa,
                accessGroup: Self.qaGroup))
        XCTAssertNoThrow(
            try ChainedUpstreamStagingRequest(
                conf: conf(extraInterface: "MTU = 1380"), identity: .qa,
                accessGroup: Self.qaGroup))
    }

    func testAKeyOutsideAnySectionIsIgnored() throws {
        // A preamble line before `[Interface]` belongs to no section and must not seed one.
        let request = try ChainedUpstreamStagingRequest(
            conf: "Endpoint = 10.0.0.1:1\n" + conf(), identity: .qa, accessGroup: Self.qaGroup)
        XCTAssertEqual(request.rotation.configuration.endpointHost, "193.138.7.5")
    }

    func testARepeatedKeyIsRefusedRatherThanLastWins() throws {
        // Two Endpoints mean the file says two things; picking one silently stages an
        // upstream the user did not choose.
        XCTAssertThrowsError(
            try ChainedUpstreamStagingRequest(
                conf: conf(extraPeer: "Endpoint = 10.0.0.9:51820"), identity: .qa, accessGroup: Self.qaGroup)
        ) { error in
            XCTAssertEqual(
                error as? ChainedUpstreamStagingRefusal, .missingOrRepeatedKey("Endpoint"))
        }
    }

    func testEveryRequiredKeyIsNamedWhenItIsMissing() throws {
        let required = ["PrivateKey", "Address", "PublicKey", "Endpoint", "AllowedIPs"]
        for key in required {
            let lines = conf().split(whereSeparator: { $0.isNewline })
                .filter { !$0.hasPrefix("\(key) ") }
                .joined(separator: "\n")
            XCTAssertThrowsError(
                try ChainedUpstreamStagingRequest(conf: lines, identity: .qa, accessGroup: Self.qaGroup),
                "\(key) was not required"
            ) { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamStagingRefusal, .missingOrRepeatedKey(key),
                    "the refusal did not name \(key)")
            }
        }
    }

    func testARepeatedSectionHeaderIsRefusedRatherThanMerged() throws {
        // `section` is only a dictionary selector, so a second `[Peer]` appends into the
        // first one's bucket: its REQUIRED keys read as repeated (caught), but its optional
        // ones — PersistentKeepalive, or DNS under a second `[Interface]` — silently join a
        // section the file presents as separate. A multi-peer conf is a shape this feature
        // does not carry, and folding half of one in is the same "stages an upstream they
        // did not choose" failure the repeated-key rule refuses.
        for section in ["[Peer]", "[Interface]"] {
            XCTAssertThrowsError(
                try ChainedUpstreamStagingRequest(
                    conf: conf() + "\n\n\(section)\nPersistentKeepalive = 99\n",
                    identity: .qa, accessGroup: Self.qaGroup),
                "a repeated \(section) was merged"
            ) { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamStagingRefusal,
                    .unsupportedDirective(section.lowercased()))
            }
        }
    }

    func testARepeatedOrEmptyDNSLineIsRefusedNotSwallowed() throws {
        // ABSENT is the only tolerated shape. A `try?` here swallowed the repeated-key and
        // empty-value refusals too, so `DNS =` twice — or with nothing after it — became an
        // empty resolver list that readiness later refuses as `noUsableTunnelDNS`, with
        // nothing to say the file had said otherwise.
        for line in ["DNS = 10.64.0.9", "DNS ="] {
            XCTAssertThrowsError(
                try ChainedUpstreamStagingRequest(
                    conf: conf(extraInterface: line), identity: .qa, accessGroup: Self.qaGroup),
                "\(line) was swallowed"
            ) { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamStagingRefusal, .missingOrRepeatedKey("DNS"))
            }
        }
        // And the refusal must survive the SPLIT, not just the read: `DNS = ,` passes the
        // non-empty check and then collapses to nothing, which is the same silent
        // empty-resolver shape one step later.
        let onlySeparators = conf().replacingOccurrences(of: "DNS = 10.64.0.1", with: "DNS = , ,")
        XCTAssertThrowsError(
            try ChainedUpstreamStagingRequest(
                conf: onlySeparators, identity: .qa, accessGroup: Self.qaGroup)
        ) { error in
            XCTAssertEqual(
                error as? ChainedUpstreamStagingRefusal, .malformedValue("DNS"))
        }
        // Absent stays ordinary: the configuration's own doc calls a missing DNS line an
        // ordinary shape, and readiness — not the parser — is what refuses to latch it.
        let withoutDNS = conf().split(whereSeparator: { $0.isNewline })
            .filter { !$0.hasPrefix("DNS ") }.joined(separator: "\n")
        let request = try ChainedUpstreamStagingRequest(
            conf: withoutDNS, identity: .qa, accessGroup: Self.qaGroup)
        XCTAssertEqual(request.rotation.configuration.dnsAddresses, [])
    }

    func testAPreSharedKeyBearingConfStagesAndCarriesTheKey() throws {
        // REPLACES `testAPreSharedKeyIsRefusedRatherThanDropped`. The engine plumbing carries a
        // PSK and now a producer supplies one: many real providers (Mullvad, Tailscale,
        // self-hosted) ship a `PresharedKey` line, so it must PARSE and be carried, not refused.
        // `Self.privateKey` is a syntactically valid 32-byte base64 value, used here purely as a
        // well-formed PSK.
        let psk = Data(repeating: 0x2B, count: 32)
        let request = try ChainedUpstreamStagingRequest(
            conf: conf(extraPeer: "PresharedKey = \(psk.base64EncodedString())"),
            identity: .qa, accessGroup: Self.qaGroup)
        XCTAssertEqual(
            request.rotation.presharedKey, psk,
            "a well-formed PresharedKey must be parsed and carried on the rotation")
        XCTAssertEqual(request.rotation.presharedKey?.count, 32)
    }

    func testAMalformedPreSharedKeyIsRefused() throws {
        // Present-but-malformed is refused, exactly like a malformed DNS or Address value:
        // wrong decoded length, and not-base64, both name `PresharedKey`. A file saying
        // something the engine cannot use must fail at staging, not surface as a handshake that
        // never completes.
        let wrongLength = Data(repeating: 0x2B, count: 16).base64EncodedString()  // 16 bytes
        for value in [wrongLength, "not-base-64-!!!"] {
            XCTAssertThrowsError(
                try ChainedUpstreamStagingRequest(
                    conf: conf(extraPeer: "PresharedKey = \(value)"),
                    identity: .qa, accessGroup: Self.qaGroup),
                "PresharedKey = \(value) was accepted"
            ) { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamStagingRefusal, .malformedValue("PresharedKey"))
            }
        }
    }

    func testAConfWithoutAPreSharedKeyYieldsANilPreSharedKey() throws {
        // Absent is the ordinary shape — WireGuard's own "no PSK" — so a conf with no
        // `PresharedKey` line stages with a nil PSK rather than a refusal or a zero key.
        let request = try ChainedUpstreamStagingRequest(
            conf: conf(), identity: .qa, accessGroup: Self.qaGroup)
        XCTAssertNil(request.rotation.presharedKey)
    }

    func testTheAmneziaObfuscationKeysAreStillRefused() throws {
        // The engine is stock boringtun with no obfuscation support, so an AmneziaWG `.conf`
        // describes a handshake this tunnel cannot perform — refused rather than staged green
        // and then failing. Unlike PresharedKey, there is no engine capability to carry these
        // to. `[Interface]` placement, where Amnezia writes them.
        for key in ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4"] {
            XCTAssertThrowsError(
                try ChainedUpstreamStagingRequest(
                    conf: conf(extraInterface: "\(key) = 4"),
                    identity: .qa, accessGroup: Self.qaGroup),
                "\(key) was accepted"
            ) { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamStagingRefusal, .unsupportedDirective(key))
            }
        }
    }

    func testADualStackAddressStagesOnItsIPv4Entry() throws {
        // REPLACES `testAMultiAddressInterfaceLineIsRefused`. That test pinned a refusal
        // whose stated reason — the v6 half would "vanish" and the file would not say what
        // the tunnel does — does not hold against the tunnel it describes: chained mode
        // never uses a configured IPv6 address. `TunnelRoutePlan` assigns the fixed ULA
        // `chainedTunnelIPv6Address` and claims `::/0` in order to DROP it, so v6 behaviour
        // is identical whether the file carries a v6 address or not.
        //
        // What the refusal actually did was reject every real provider config: found on
        // device during S9, all 539 Mullvad configurations refused with
        // `staging-malformed-Address` because Mullvad writes
        // `Address = 10.68.193.169/32,fc00:bbbb:bbbb:bb01::5:c1a8/128`.
        let request = try ChainedUpstreamStagingRequest(
            conf: conf().replacingOccurrences(
                of: "Address = 10.64.0.2/32",
                with: "Address = 10.64.0.2/32,fc00:bbbb:bbbb:bb01::5:c1a8/128"),
            identity: .qa, accessGroup: Self.qaGroup)
        XCTAssertEqual(
            request.rotation.configuration.clientAddress, "10.64.0.2",
            "The IPv4 entry is the inner source the peer's AllowedIPs must permit.")
    }

    func testADualStackAddressWrittenWithSpacesAfterCommasStages() throws {
        // wg-quick tools write these lists both ways. Entries are trimmed for the same
        // reason `AllowedIPs` and `DNS` are — a comma-separated list is conventionally
        // written with spaces after the commas.
        let request = try ChainedUpstreamStagingRequest(
            conf: conf().replacingOccurrences(
                of: "Address = 10.64.0.2/32",
                with: "Address = 10.64.0.2/32, fc00:bbbb::5/128"),
            identity: .qa, accessGroup: Self.qaGroup)
        XCTAssertEqual(request.rotation.configuration.clientAddress, "10.64.0.2")
    }

    func testAnAddressCarryingNoIPv4EntryIsRefused() throws {
        // The IPv4 address is not optional: it is the inner source address, and a v6-only
        // file describes a tunnel this build cannot carry.
        XCTAssertThrowsError(
            try ChainedUpstreamStagingRequest(
                conf: conf().replacingOccurrences(
                    of: "Address = 10.64.0.2/32",
                    with: "Address = fc00:bbbb::5/128"),
                identity: .qa, accessGroup: Self.qaGroup)
        ) { error in
            XCTAssertEqual(
                error as? ChainedUpstreamStagingRefusal, .malformedValue("Address"))
        }
    }

    func testAnAddressCarryingTwoIPv4EntriesIsRefused() throws {
        // Ambiguous rather than dual-stack: nothing decides which address is the inner
        // source, and picking one silently is exactly the failure the original comma
        // refusal was written to prevent — that concern is real HERE, and preserved.
        XCTAssertThrowsError(
            try ChainedUpstreamStagingRequest(
                conf: conf().replacingOccurrences(
                    of: "Address = 10.64.0.2/32",
                    with: "Address = 10.64.0.2/32, 10.64.0.3/32"),
                identity: .qa, accessGroup: Self.qaGroup)
        ) { error in
            XCTAssertEqual(
                error as? ChainedUpstreamStagingRefusal, .malformedValue("Address"))
        }
    }

    func testAHostnameEndpointStagesAndCannotLatch() throws {
        // RECORDED, not refused. Staging validates the FILE; whether it can LATCH is the
        // tunnel's readiness verdict, and those gates live in LavaSecChainedUpstream, which
        // the app process must not link (it would pull the engine into the app binary) —
        // duplicating them here is the two-validators drift this codebase refuses. So a
        // hostname endpoint stages, and the operator learns from `data-path-latched`
        // (`upstream-not-ready-endpointNotYetResolvable`) that S1 has no hostname executor.
        // The status copy says "Stored", never "will latch", for exactly this reason.
        let request = try ChainedUpstreamStagingRequest(
            conf: conf().replacingOccurrences(
                of: "Endpoint = 193.138.7.5:51820",
                with: "Endpoint = vpn.example.com:51820"),
            identity: .qa, accessGroup: Self.qaGroup)
        XCTAssertEqual(request.rotation.configuration.endpointHost, "vpn.example.com")
    }

    func testAPresentButUnreadableNumberIsRefusedNotDefaulted() throws {
        // An `MTU = 12800` typo silently defaulting to 1280 is a session that behaves unlike
        // the file the operator is reading from.
        for line in ["MTU = twelve-eighty", "MTU = 99999"] {
            XCTAssertThrowsError(
                try ChainedUpstreamStagingRequest(conf: conf(extraInterface: line), identity: .qa, accessGroup: Self.qaGroup)
            ) { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamStagingRefusal, .malformedValue("MTU"))
            }
        }
    }

    func testTheBracketedIPv6EndpointSplitsHereAndIsRefusedThere() throws {
        // Two facts in one case, because separating them would hide the second.
        //
        // The SPLIT is this parser's job and it is done right: `[2001:db8::1]:51820` has its
        // last colon inside the address, so a naive rsplit yields a garbage host — the
        // brackets are what make the port unambiguous, and they are consumed here.
        //
        // The REFUSAL is the configuration boundary's, and it is deliberate: that validator
        // rejects any colon in `endpointHost` because a colon means either a pasted
        // "host:port" or a bare IPv6 literal, and it requires the caller to have said which.
        // So a chained upstream cannot currently carry an IPv6 endpoint AT ALL — an existing
        // product limit, not one staging introduces, and not one a QA writer may quietly
        // relax by routing around the validator. Recorded here so the next reader learns it
        // from a test rather than from a device that refuses their config.
        XCTAssertThrowsError(
            try ChainedUpstreamStagingRequest(
                conf: conf().replacingOccurrences(
                    of: "Endpoint = 193.138.7.5:51820",
                    with: "Endpoint = [2001:db8::1]:51820"),
                identity: .qa, accessGroup: Self.qaGroup)
        ) { error in
            XCTAssertEqual(
                error as? ChainedUpstreamStagingRefusal,
                .configurationRefused(.malformedEndpointHost),
                "the v6 host reached the validator in some other shape than the bare literal")
        }
    }

    func testAMalformedEndpointIsRefused() throws {
        for endpoint in ["193.138.7.5", "193.138.7.5:0", "193.138.7.5:notaport"] {
            XCTAssertThrowsError(
                try ChainedUpstreamStagingRequest(
                    conf: conf().replacingOccurrences(
                        of: "Endpoint = 193.138.7.5:51820", with: "Endpoint = \(endpoint)"),
                    identity: .qa, accessGroup: Self.qaGroup)
            ) { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamStagingRefusal, .malformedValue("Endpoint"),
                    "\(endpoint) was accepted")
            }
        }
    }

    // MARK: - The validating boundaries own their own verdicts

    func testTheConfigurationValidatorsVerdictTravels() throws {
        // A split IPv4 set that ALSO carries a v6 prefix (`10.0.0.0/8, ::/0`): split's IPv6 is
        // the plan's own blackhole, so the profile's v6 entry could never be honored — refused
        // by the configuration boundary (infra #198 §3.4 open-Q #3), and the parser reports THAT rather than
        // inventing its own message — one validator, one verdict. (A bare `10.0.0.0/8` is now
        // ACCEPTED as a split tunnel — Slice 3 — so it no longer exercises a refusal here.)
        XCTAssertThrowsError(
            try ChainedUpstreamStagingRequest(
                conf: conf().replacingOccurrences(
                    of: "AllowedIPs = 0.0.0.0/0, ::/0", with: "AllowedIPs = 10.0.0.0/8, ::/0"),
                identity: .qa, accessGroup: Self.qaGroup)
        ) { error in
            XCTAssertEqual(
                error as? ChainedUpstreamStagingRefusal,
                .configurationRefused(.splitTunnelCarriesIPv6AllowedIPs))
        }
    }

    func testTheRotationBoundarysVerdictTravels() throws {
        // An all-zero private key is well-formed base64 of the right length and unusable;
        // the rotation boundary is what knows that.
        XCTAssertThrowsError(
            try ChainedUpstreamStagingRequest(
                conf: conf(privateKey: Data(repeating: 0, count: 32).base64EncodedString()),
                identity: .qa, accessGroup: Self.qaGroup)
        ) { error in
            XCTAssertEqual(
                error as? ChainedUpstreamStagingRefusal, .rotationRefused(.unusablePrivateKey))
        }
    }

    func testAMalformedPrivateKeyIsNamed() throws {
        XCTAssertThrowsError(
            try ChainedUpstreamStagingRequest(conf: conf(privateKey: "not base64!"), identity: .qa, accessGroup: Self.qaGroup)
        ) { error in
            XCTAssertEqual(
                error as? ChainedUpstreamStagingRefusal, .malformedValue("PrivateKey"))
        }
    }
}
