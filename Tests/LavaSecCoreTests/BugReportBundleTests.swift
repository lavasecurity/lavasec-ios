import XCTest
@testable import LavaSecCore
@testable import LavaSecAppServices
@testable import LavaSecKit

final class BugReportBundleTests: XCTestCase {
    func testIssueTypesUseFeedbackTopicSet() {
        XCTAssertEqual(BugReportIssueType.allCases.map(\.title), [
            "I can't visit a website",
            "VPN or filter doesn't work",
            "A Lava feature doesn't work",
            "Translation is not quite right",
            "I have a suggestion",
            "Something else"
        ])
    }

    func testIssueTypesMapToTriageKinds() {
        XCTAssertEqual(BugReportIssueType.websiteAccess.kind, .bug)
        XCTAssertEqual(BugReportIssueType.vpnOrFilterIssue.kind, .bug)
        XCTAssertEqual(BugReportIssueType.featureIssue.kind, .bug)
        XCTAssertEqual(BugReportIssueType.translationIssue.kind, .bug)
        XCTAssertEqual(BugReportIssueType.suggestion.kind, .suggestion)
        XCTAssertEqual(BugReportIssueType.other.kind, .other)
    }

    func testIssueKindRawValuesMatchTriageWireVocabulary() {
        XCTAssertEqual(
            [BugReportIssueKind.bug, .suggestion, .other].map(\.rawValue),
            ["bug", "suggestion", "other"]
        )
    }

    func testRequestBodyIncludesTriageKind() throws {
        let bundle = makeBundle(
            context: BugReportContext(issueType: .suggestion, details: "Please add a widget")
        )
        let body = bundle.makeRequestBody()
        XCTAssertEqual(body["kind"] as? String, "suggestion")
    }

    func testNormalizationStripsInvisibleAndControlCharacters() {
        let context = BugReportContext(
            issueType: .other,
            affectedSite: "exa\u{200B}mple.com",
            details: "Line one\nLine two\u{202E}reversed\u{0007}",
            contactEmail: "user\u{FEFF}@example.com"
        )

        // Zero-width space, bidi override, and bell control are removed; newline + text survive.
        XCTAssertEqual(context.normalizedAffectedSite, "example.com")
        XCTAssertEqual(context.normalizedDetails, "Line one\nLine tworeversed")
        XCTAssertEqual(context.normalizedContactEmail, "user@example.com")
    }

    func testSanitizeKeepsStandaloneEmojiButFlattensJoinedSequences() {
        // Standalone emoji, skin-tone modifiers, and flags are untouched (no invisible scalars).
        XCTAssertEqual(BugReportContext.sanitize("🚀"), "🚀")
        XCTAssertEqual(BugReportContext.sanitize("👍🏽"), "👍🏽")
        XCTAssertEqual(BugReportContext.sanitize("🇺🇸"), "🇺🇸")
        // ZWJ-joined sequences are flattened to their visible base scalars (joiner removed).
        XCTAssertEqual(BugReportContext.sanitize("👩\u{200D}👩\u{200D}👧"), "👩👩👧")
    }

    func testSanitizeStripsWordJoinerAndOtherInvisibleFormatScalars() {
        // Word joiner (U+2060) and other invisible format scalars must be stripped, not just
        // the specific zero-width set — otherwise blank-looking content submits hidden text.
        XCTAssertEqual(BugReportContext.sanitize("a\u{2060}b"), "ab")
        XCTAssertEqual(BugReportContext.sanitize("\u{2061}\u{2066}\u{206F}"), "")
        // ARABIC LETTER MARK (U+061C) is a bidi control and must be stripped too.
        XCTAssertEqual(BugReportContext.sanitize("a\u{061C}b"), "ab")
        XCTAssertEqual(BugReportContext.sanitize("\u{061C}"), "")
        // A zero-width joiner that is standalone, at an edge, or between ordinary characters
        // (incl. ASCII keycap bases, for which Unicode isEmoji is true) is invisible filler →
        // dropped, so it can't hide content and an all-invisible field normalizes to empty.
        XCTAssertEqual(BugReportContext.sanitize("\u{200D}"), "")
        XCTAssertEqual(BugReportContext.sanitize("a\u{200D}"), "a")
        XCTAssertEqual(BugReportContext.sanitize("a\u{200D}b"), "ab")
        XCTAssertEqual(BugReportContext.sanitize("1\u{200D}2"), "12")
        XCTAssertEqual(BugReportContext.sanitize("#\u{200D}*"), "#*")
        // Standalone variation selectors and soft hyphens are invisible → stripped.
        XCTAssertEqual(BugReportContext.sanitize("\u{FE0F}"), "")
        XCTAssertEqual(BugReportContext.sanitize("a\u{00AD}b"), "ab")
        // Tag characters (U+E0020–E007F) can ride along inside any emoji grapheme cluster, so
        // they are stripped unconditionally too — no invisible scalar survives.
        XCTAssertEqual(BugReportContext.sanitize("😀\u{E0061}\u{E0062}"), "😀")
        // Invisible scalars are removed even adjacent to emoji (joiner / selector flattened).
        XCTAssertEqual(BugReportContext.sanitize("👩\u{200D}👧"), "👩👧")
        XCTAssertEqual(BugReportContext.sanitize("❤\u{FE0F}"), "❤")
    }

    func testDetailsNormalizationEnforcesSharedInputLimit() {
        let longDetails = String(repeating: "a", count: BugReportInputLimits.details + 50)
        let context = BugReportContext(issueType: .other, details: longDetails)
        XCTAssertEqual(context.normalizedDetails.count, BugReportInputLimits.details)
    }

    func testSingleLineFieldsCollapseEmbeddedLineBreaks() {
        let context = BugReportContext(
            issueType: .websiteAccess,
            affectedSite: "example.com\nDetails: spoofed",
            details: "Line one\nLine two",
            contactEmail: "user\n@example.com"
        )

        // Single-line site + email collapse the newline to a space; multi-line details keep it.
        XCTAssertEqual(context.normalizedAffectedSite, "example.com Details: spoofed")
        XCTAssertEqual(context.normalizedContactEmail, "user @example.com")
        XCTAssertEqual(context.normalizedDetails, "Line one\nLine two")
        XCTAssertFalse(context.normalizedAffectedSite.contains("\n"))
        XCTAssertFalse(context.normalizedContactEmail?.contains("\n") ?? false)
        // The site value stays on a single line in the composed report text — it can't inject a
        // standalone "Details:" line; the only "Details:" line is the real one.
        XCTAssertTrue(context.userDescription.contains("Affected site/domain: example.com Details: spoofed"))
    }

    func testSingleLineFieldsCollapseUnicodeLineSeparators() {
        // U+2028 LINE SEPARATOR / U+2029 PARAGRAPH SEPARATOR are line breaks too, so single-line
        // fields must collapse them just like \n — otherwise they reopen the line-injection path.
        let context = BugReportContext(
            issueType: .websiteAccess,
            affectedSite: "example.com\u{2028}Details: spoofed",
            contactEmail: "user\u{2029}@example.com"
        )
        XCTAssertEqual(context.normalizedAffectedSite, "example.com Details: spoofed")
        XCTAssertEqual(context.normalizedContactEmail, "user @example.com")

        // Multi-line details normalize every line-break variant (CRLF, lone CR, U+2028) to "\n".
        XCTAssertEqual(BugReportContext.sanitize("a\u{2028}b"), "a\nb")
        XCTAssertEqual(BugReportContext.sanitize("a\r\nb"), "a\nb")
        XCTAssertEqual(BugReportContext.sanitize("a\rb"), "a\nb")
    }

    func testRequestBodyOmitsOptionalDiagnosticsByDefault() throws {
        let bundle = makeBundle()
        let body = bundle.makeRequestBody()

        XCTAssertEqual(body["include_optional_diagnostics"] as? Bool, false)
        XCTAssertEqual(body["include_recent_dns_events"] as? Bool, false)
        XCTAssertNotNil(body["report_id"])
        XCTAssertNotNil(body["user_description"])
        XCTAssertNil(body["recent_dns_events"])
        XCTAssertNil(body["app"])
        XCTAssertNil(body["device"])
        XCTAssertNil(body["vpn"])
        XCTAssertNil(body["filters"])
        XCTAssertNil(body["diagnostics"])
        XCTAssertNil(body["debug_log"])
    }

    func testRequestBodyExcludesRecentDomainEventsWhenDiagnosticsAreIncluded() throws {
        var diagnostics = DiagnosticsStore(startedAt: Date(timeIntervalSinceReferenceDate: 100))
        diagnostics.record(
            domain: "private-bank.example",
            decision: FilterDecision(action: .block, reason: .blocklist),
            keepDomainHistory: true
        )
        diagnostics.record(domain: "weather.example", decision: .defaultAllow, keepDomainHistory: true)

        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .websiteAccess,
                affectedSite: "checkout.example",
                details: "Checkout would not load after protection turned on.",
                includeDiagnostics: true
            ),
            diagnostics: diagnostics
        )
        let body = bundle.makeRequestBody()
        let json = try jsonString(body)

        XCTAssertEqual(body["include_optional_diagnostics"] as? Bool, true)
        XCTAssertEqual(body["include_recent_dns_events"] as? Bool, false)
        XCTAssertNil(body["recent_dns_events"])
        XCTAssertFalse(json.contains("private-bank.example"))
        XCTAssertFalse(json.contains("weather.example"))

        let diagnosticsBody = try XCTUnwrap(body["diagnostics"] as? [String: Any])
        XCTAssertEqual(diagnosticsBody["blocked_count"] as? Int, 1)
        XCTAssertEqual(diagnosticsBody["allowed_count"] as? Int, 1)
        XCTAssertEqual(diagnosticsBody["has_domain_history"] as? Bool, true)
    }

    func testRequestBodySurfacesPrivacySafeFocusSwitchDiagnostic() throws {
        // LAV-100 Phase 4: a closed-app Focus failure must be debuggable from the (Release) bug report —
        // the last switch attempt's outcome + target filter id + time, no domains/rules.
        let at = Date(timeIntervalSinceReferenceDate: 765_000)
        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .websiteAccess, affectedSite: "checkout.example",
                details: "Focus didn't switch my filter.", includeDiagnostics: true
            ),
            lastFocusSwitch: FocusSwitchDiagnosticRecord(outcome: "deferred", targetFilterID: "filter-extra", at: at, reason: "deferred-no-warm-artifact")
        )
        let body = bundle.makeRequestBody()
        let incident = try XCTUnwrap(body["incident"] as? [String: Any])
        let focus = try XCTUnwrap(incident["focus_last_switch"] as? [String: Any])
        XCTAssertEqual(focus["outcome"] as? String, "deferred")
        XCTAssertEqual(focus["target_filter_id"] as? String, "filter-extra")
        XCTAssertEqual(focus["at"] as? String, SharedDateFormatting.iso8601.string(from: at))
        XCTAssertEqual(focus["reason"] as? String, "deferred-no-warm-artifact",
                       "The bug report must surface the specific defer/outcome reason for closed-app debugging.")
    }

    func testRequestBodyOmitsFocusSwitchDiagnosticWhenAbsent() throws {
        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .websiteAccess, affectedSite: "checkout.example",
                details: "No focus switch yet.", includeDiagnostics: true
            )
        )
        let incident = try XCTUnwrap(bundle.makeRequestBody()["incident"] as? [String: Any])
        XCTAssertNil(incident["focus_last_switch"], "No record ⇒ no focus_last_switch key.")
    }

    func testBugReportDoesNotIncludeNetworkActivityLogByDefault() throws {
        let bundle = makeBundle()
        let body = bundle.makeRequestBody()
        let json = try jsonString(body)

        XCTAssertNil(body["network_activity_log"])
        XCTAssertFalse(json.contains("network_activity_log"))
        XCTAssertFalse(json.contains("eventLine"))
        XCTAssertFalse(json.contains("lavaStateLine"))
    }

    func testRequestBodyDoesNotIncludeCustomBlocklistURLs() throws {
        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .vpnOrFilterIssue,
                details: "A custom blocklist stopped working.",
                includeDiagnostics: true
            ),
            filters: BugReportFilterSummary(
                catalogVersion: "20260526T000000Z",
                enabledListIDs: ["blocklistproject-basic", "custom-sensitive"],
                snapshotVersion: "snapshot-456",
                compiledRuleCount: 20,
                blocklistRuleCount: 18,
                customBlocklistCount: 1,
                enabledCustomBlocklistCount: 1
            )
        )

        let body = bundle.makeRequestBody()
        let json = try jsonString(body)
        let filters = try XCTUnwrap(body["filters"] as? [String: Any])

        XCTAssertEqual(filters["custom_blocklist_count"] as? Int, 1)
        XCTAssertEqual(filters["enabled_custom_blocklist_count"] as? Int, 1)
        XCTAssertFalse(json.contains("sensitive.example.com"))
        XCTAssertFalse(json.contains("private-list.txt"))
        XCTAssertFalse(json.contains("https://"))
    }

    func testRequestBodyIncludesAffectedSiteFilterDecisionForUserProvidedSite() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "linkedin.com", matchesSubdomains: true)
        let snapshot = FilterSnapshot(blockRules: blockRules)
        let context = BugReportContext(
            issueType: .websiteAccess,
            affectedSite: "https://www.linkedin.com/feed/",
            details: "LinkedIn would not load.",
            includeDiagnostics: true
        )
        let decision = try XCTUnwrap(BugReportAffectedSiteFilterDecision.make(
            rawAffectedSite: context.normalizedAffectedSite,
            snapshot: snapshot
        ))
        let bundle = makeBundle(context: context, affectedSiteDecision: decision)

        let body = bundle.makeRequestBody()
        let filters = try XCTUnwrap(body["filters"] as? [String: Any])

        XCTAssertEqual(filters["affected_site_domain"] as? String, "www.linkedin.com")
        XCTAssertEqual(filters["affected_site_filter_action"] as? String, "block")
        XCTAssertEqual(filters["affected_site_filter_reason"] as? String, "blocklist")
    }

    func testDebugLogParserDropsPotentiallyIdentifyingDetails() throws {
        let jsonLines = """
        {"component":"app","event":"enable-begin","timestamp":"2026-05-18T01:02:03Z","vpnStatus":"connected","arguments":"--token secret","providerConfiguration":"private config","resolver":"Google Public DNS"}
        {"component":"tunnel","event":"network-path-changed","timestamp":"2026-05-18T01:03:03Z","kind":"wifi","status":"satisfied","options":"launch options"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].component, "app")
        XCTAssertEqual(entries[0].event, "enable-begin")
        XCTAssertEqual(entries[0].details["vpnStatus"], "connected")
        XCTAssertEqual(entries[0].details["resolver"], "Google Public DNS")
        XCTAssertNil(entries[0].details["arguments"])
        XCTAssertNil(entries[0].details["providerConfiguration"])
        XCTAssertEqual(entries[1].details["kind"], "wifi")
        XCTAssertNil(entries[1].details["options"])
    }

    /// A dropped detail key must SAY SO in the report.
    ///
    /// This is the structural half of the fix in PR #615, and the half that does not depend on
    /// anyone maintaining a list. `TunnelDetailKeyExportSourceTests` catches an unexported key
    /// before it ships, but it reads Swift as text and a text reader can always be evaded by a
    /// shape it does not parse. This cannot: whatever the emitter looked like, an entry that lost
    /// keys to the allowlist says how many it lost.
    ///
    /// What that buys is the diagnosis, not the data. Three times now a missing reading has been
    /// read as a missing FEATURE — most recently on 2026-08-28, when a current extension binary
    /// was diagnosed as stale and a device was reinstalled over it. `_withheld: 1` on
    /// `data-path-latched` ends that class of investigation in one line: the binary emitted
    /// something the exporter dropped, so the binary is current and the allowlist is behind.
    func testDebugLogParserCountsTheDetailKeysItWithheld() throws {
        let jsonLines = """
        {"component":"tunnel","event":"data-path-latched","timestamp":"2026-08-28T01:02:03Z","dataPath":"chained","brandNewKey":"7","anotherNewKey":"8"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].details["dataPath"], "chained")
        XCTAssertNil(entries[0].details["brandNewKey"], "the filter must still drop it")
        XCTAssertEqual(
            entries[0].details[BugReportDebugLogEntry.withheldKeysField], "2",
            "the report must say that two readings were dropped, which is what distinguishes a "
                + "current build with a stale allowlist from a build that never emitted them")
    }

    /// The chained-connect gate's outcome line must arrive with ALL FIVE of its readings.
    ///
    /// This is the regression test for a real, dated failure. On 2026-08-30 the chained connect
    /// failed three times in a row on device, and every exported gate line looked exactly like
    /// this, verbatim from the archive:
    ///
    ///     {"component":"app","event":"chained-establish-gate",
    ///      "details":{"_withheld":"3","elapsedMs":"0","phase":"begin"}}
    ///
    /// `phase` and `elapsedMs` survived only because tunnel events happen to use the same two key
    /// names. The three readings PR #598 added expressly to tell a stuck gate from one that never
    /// started — and both from an extension not answering the IPC — were the three that were
    /// dropped, so the investigation had to reconstruct the gate's state from tunnel-side
    /// counters. Written against the real `parseJSONLines`, so it fails if the allowlist narrows
    /// again by any route.
    func testTheConnectGateOutcomeLineSurvivesRedactionIntact() throws {
        let jsonLines = """
        {"component":"app","event":"chained-establish-gate","timestamp":"2026-08-30T07:01:38Z","phase":"failed","elapsedMs":"15582","polls":"15","unknownReplies":"0","receivedDelta":"0"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].details["phase"], "failed")
        XCTAssertEqual(entries[0].details["elapsedMs"], "15582")
        XCTAssertEqual(entries[0].details["polls"], "15", "a stuck gate is told apart by its poll count")
        XCTAssertEqual(
            entries[0].details["unknownReplies"], "0",
            "unknownReplies tracking polls is the signature of an extension not answering the IPC")
        XCTAssertEqual(
            entries[0].details["receivedDelta"], "0",
            "the forwarded-byte delta is the gate's whole decision input — without it the outcome "
                + "line says a connect failed but not what it saw")
        XCTAssertNil(
            entries[0].details[BugReportDebugLogEntry.withheldKeysField],
            "the gate line must arrive whole; `_withheld: 3` on this event is the exact defect "
                + "that made the 2026-08-30 device failures unreadable")
    }

    func testDeviceDNSConfirmationTransitionsSurviveExportWithoutPrivateQueryOrIdentity() throws {
        let jsonLines = """
        {"component":"tunnel","event":"dns-tier-confirmation","timestamp":"2026-10-02T01:02:03Z","tier":"tierTwo","decision":"checking","reason":"timeout","sequence":"7","transport":"device-dns","domain":"private.example","identity":"private-configuration"}
        {"component":"tunnel","event":"dns-tier-confirmation","timestamp":"2026-10-02T01:02:06Z","tier":"tierTwo","decision":"completed","reason":"timeout","sequence":"7","outcome":"failure","transport":"device-dns","durationMs":"3000"}
        """
        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)
        XCTAssertEqual(entries.count, 2)
        for entry in entries {
            XCTAssertEqual(entry.event, "dns-tier-confirmation")
            XCTAssertEqual(entry.details["tier"], "tierTwo")
            XCTAssertEqual(entry.details["reason"], "timeout")
            XCTAssertEqual(entry.details["sequence"], "7")
            XCTAssertEqual(entry.details["transport"], "device-dns")
            XCTAssertNil(entry.details["domain"])
            XCTAssertNil(entry.details["identity"])
        }
        XCTAssertEqual(entries[0].details["decision"], "checking")
        XCTAssertEqual(entries[0].details[BugReportDebugLogEntry.withheldKeysField], "2")
        XCTAssertEqual(entries[1].details["decision"], "completed")
        XCTAssertEqual(entries[1].details["outcome"], "failure")
        XCTAssertEqual(entries[1].details["durationMs"], "3000")
        XCTAssertNil(entries[1].details[BugReportDebugLogEntry.withheldKeysField])
    }

    /// The envelope fields are not details and must not be reported as withheld.
    func testDebugLogParserDoesNotCountStructuralFieldsAsWithheld() throws {
        let jsonLines = """
        {"component":"tunnel","event":"network-path-changed","timestamp":"2026-08-28T01:02:03Z","kind":"wifi"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(
            entries[0].details[BugReportDebugLogEntry.withheldKeysField],
            "component/event/timestamp are the envelope — counting them would put a withheld "
                + "line on every entry in every report")
    }

    /// Neither names nor values — otherwise this becomes the leak the allowlist exists to prevent.
    func testWithheldFieldCarriesNoDomainOrKey() throws {
        let jsonLines = """
        {"component":"tunnel","event":"chained-aaaa-nodata","timestamp":"2026-08-28T01:02:03Z","domain":"private.example.com"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        let withheld = entries[0].details[BugReportDebugLogEntry.withheldKeysField]
        XCTAssertEqual(withheld, "1")
        XCTAssertFalse(
            withheld?.contains("private.example.com") ?? true,
            "the withheld field is a count — never the key, and never what the user resolved")
    }

    /// The withheld field is a COUNT, and carries no key name at all.
    ///
    /// Naming the dropped keys reads as obviously more useful and cannot be made safe: a key name
    /// is only schema while every emitter writes it as a literal, and `details[userValue] = …`
    /// would put user data in the key position. No character filter fixes that — `AliceSmith` is
    /// a perfectly ordinary identifier (Codex, PR #615).
    func testWithheldFieldCarriesACountAndNeverAKeyName() throws {
        let jsonLines = """
        {"component":"tunnel","event":"chained-probe","timestamp":"2026-08-28T01:02:03Z","private.example.com":"1","secretToken":"2","dataPath":"chained"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        let withheld = try XCTUnwrap(
            entries.first?.details[BugReportDebugLogEntry.withheldKeysField])
        XCTAssertEqual(withheld, "2")
        XCTAssertFalse(withheld.contains("private.example.com"))
        XCTAssertFalse(withheld.contains("secretToken"), "an ordinary identifier can still be a name")
        XCTAssertEqual(
            entries.first?.details["dataPath"], "chained", "the allowlisted key still exports")
    }

    func testDebugLogParserKeepsSnapshotArtifactMissDetails() throws {
        let jsonLines = """
        {"component":"tunnel","event":"loadSnapshot-store-miss","timestamp":"2026-05-18T01:02:03Z","route":"resolved","compactReason":"reuse:inputs:selectedSourceHashes+catalogVersion","preparedReason":"manifest-missing","generation":"42","ruleCount":"356662","syncCap":"1000000","storeCount":"2","eligibleStoreCount":"1","maxRuleCount":"356662","expected":"full-private-fingerprint","privateDomain":"checkout.example"}
        {"component":"tunnel","event":"bootstrap-fast-resume-miss","timestamp":"2026-05-18T01:02:04Z","reason":"strict-miss","storeCount":"2","eligibleStoreCount":"1","syncCap":"1000000","maxRuleCount":"356662","privateDomain":"checkout.example"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].event, "loadSnapshot-store-miss")
        XCTAssertEqual(entries[0].details["route"], "resolved")
        XCTAssertEqual(entries[0].details["compactReason"], "reuse:inputs:selectedSourceHashes+catalogVersion")
        XCTAssertEqual(entries[0].details["preparedReason"], "manifest-missing")
        XCTAssertEqual(entries[0].details["generation"], "42")
        XCTAssertEqual(entries[0].details["ruleCount"], "356662")
        XCTAssertEqual(entries[0].details["syncCap"], "1000000")
        XCTAssertEqual(entries[0].details["storeCount"], "2")
        XCTAssertEqual(entries[0].details["eligibleStoreCount"], "1")
        XCTAssertEqual(entries[0].details["maxRuleCount"], "356662")
        XCTAssertNil(entries[0].details["expected"])
        XCTAssertNil(entries[0].details["privateDomain"])
        XCTAssertEqual(entries[1].details["reason"], "strict-miss")
        XCTAssertEqual(entries[1].details["storeCount"], "2")
        XCTAssertEqual(entries[1].details["eligibleStoreCount"], "1")
        XCTAssertNil(entries[1].details["privateDomain"])
    }

    // An 8 MB rotation can land between an incident and the report: the loaders read the
    // rotated generation + the current file, and the concatenating parser must survive a
    // rotation that cut mid-line (no trailing newline on the rotated chunk) without fusing
    // the boundary lines, while the entry cap still keeps the NEWEST entries.
    func testDebugLogParserConcatenatesGenerationsAcrossRotationBoundary() throws {
        let rotated = Data("""
        {"component":"tunnel","event":"self-reconnect","timestamp":"2026-05-18T01:02:03Z"}
        {"component":"tunnel","event":"self-reconnect-credited","timestamp":"2026-05-18T01:04:03Z"}
        """.utf8) // no trailing newline: rotation cut mid-write
        let current = Data("""
        {"component":"tunnel","event":"network-path-changed","timestamp":"2026-05-18T01:05:03Z","kind":"wifi"}
        """.utf8)

        let entries = BugReportDebugLogEntry.parseJSONLines(concatenating: [rotated, current], limit: 10)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].event, "self-reconnect")
        XCTAssertEqual(entries[1].event, "self-reconnect-credited")
        XCTAssertEqual(entries[2].event, "network-path-changed")

        // The cap keeps the newest entries, so the rotated (older) generation must come first.
        let capped = BugReportDebugLogEntry.parseJSONLines(concatenating: [rotated, current], limit: 2)
        XCTAssertEqual(capped.map(\.event), ["self-reconnect-credited", "network-path-changed"])

        // Empty generations (no rotated file yet) are skipped without a phantom boundary line.
        let currentOnly = BugReportDebugLogEntry.parseJSONLines(concatenating: [Data(), current], limit: 10)
        XCTAssertEqual(currentOnly.count, 1)
    }

    func testDebugLogParserKeepsSafeQAConnectivityDetails() throws {
        let jsonLines = """
        {"component":"tunnel","event":"qa-connectivity-assessment","timestamp":"2026-05-18T01:04:03Z","severity":"needsReconnect","primaryAction":"reconnect","lastFailureReason":"timeout","lastResolverTransport":"plainDNS","upstreamSuccessCount":"9","upstreamFailureCount":"3","upstreamTimeoutCount":"3","dnsSmokeProbeFailureCount":"1","deviceDNSFallbackActivationCount":"0","resolverRuntimeResetCount":"2","lastUpstreamFailureAt":"2026-05-18T01:04:00Z","privateDomain":"checkout.example"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].details["severity"], "needsReconnect")
        XCTAssertEqual(entries[0].details["primaryAction"], "reconnect")
        XCTAssertEqual(entries[0].details["lastFailureReason"], "timeout")
        XCTAssertEqual(entries[0].details["lastResolverTransport"], "plainDNS")
        XCTAssertEqual(entries[0].details["upstreamFailureCount"], "3")
        XCTAssertEqual(entries[0].details["lastUpstreamFailureAt"], "2026-05-18T01:04:00Z")
        XCTAssertNil(entries[0].details["privateDomain"])
    }

    func testDebugLogParserKeepsCoalescedFallbackCount() throws {
        // The log-coalescing throttles "dns-encrypted-fallback" markers and carries
        // "carriedSinceLastLog" — how many events the emitted marker stands in for.
        // That count must survive into Feedback/local exports (a bare integer, no
        // queried domain); otherwise coalescing silently discards the "how often".
        let jsonLines = """
        {"component":"tunnel","event":"dns-encrypted-fallback","timestamp":"2026-05-18T01:06:00Z","transport":"doh","resolver":"Mullvad DoH","carriedSinceLastLog":"7","privateDomain":"checkout.example"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].event, "dns-encrypted-fallback")
        XCTAssertEqual(entries[0].details["carriedSinceLastLog"], "7")
        XCTAssertEqual(entries[0].details["transport"], "doh")
        XCTAssertNil(entries[0].details["privateDomain"])
    }

    func testDebugLogParserKeepsNetworkRecoveryDiagnosticDetails() throws {
        // Mirrors what the tunnel now emits on release for the handoff/DNS-recovery
        // story — counts, reasons, and kinds only, never resolver addresses or
        // queried domains — so a Feedback log can show it without leaking anything.
        let jsonLines = """
        {"component":"tunnel","event":"device-dns-captured","timestamp":"2026-05-18T01:05:00Z","reason":"network-path-changed","count":"0","activeCount":"2"}
        {"component":"tunnel","event":"dns-smoke-probe-device-fallback","timestamp":"2026-05-18T01:05:01Z","reason":"network-settled","evidenceCount":"2","fallbackModeActive":"true"}
        {"component":"tunnel","event":"self-reconnect","timestamp":"2026-05-18T01:05:02Z","reason":"dns-wedged","attemptsInWindow":"1"}
        {"component":"tunnel","event":"dns-doq-connection-error","timestamp":"2026-05-18T01:05:03Z","endpoint":"dns.example:8853","phase":"failed","error":"POSIXErrorCode(rawValue: 54): Connection reset by peer","privateDomain":"checkout.example"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].event, "device-dns-captured")
        XCTAssertEqual(entries[0].details["count"], "0")
        XCTAssertEqual(entries[0].details["activeCount"], "2")
        XCTAssertEqual(entries[1].details["evidenceCount"], "2")
        XCTAssertEqual(entries[1].details["fallbackModeActive"], "true")
        XCTAssertEqual(entries[2].event, "self-reconnect")
        XCTAssertEqual(entries[2].details["attemptsInWindow"], "1")
        XCTAssertEqual(entries[2].details["reason"], "dns-wedged")
        // DoQ connection failures are promoted to Release; the NWError reason and
        // phase must survive redaction (they distinguish failure modes during a
        // handoff) while a queried domain on the same entry is still stripped.
        XCTAssertEqual(entries[3].event, "dns-doq-connection-error")
        XCTAssertEqual(entries[3].details["phase"], "failed")
        XCTAssertEqual(entries[3].details["error"], "POSIXErrorCode(rawValue: 54): Connection reset by peer")
        XCTAssertEqual(entries[3].details["endpoint"], "dns.example:8853")
        XCTAssertNil(entries[3].details["privateDomain"])
    }

    func testDebugLogParserKeepsSelfReconnectGapCloseDetails() throws {
        // COH-2 (Codex #219): a self-reconnect-gap-closed entry carries gapMs AND, when the wall
        // clock stepped backward past the recorded start, clockAnomaly=true (the end was FLOORED,
        // not measured). Both must survive redaction so support can tell a floored gap from a real
        // one; neither is a domain.
        let jsonLines = """
        {"component":"tunnel","event":"self-reconnect-gap-closed","timestamp":"2026-05-18T01:06:00Z","gapMs":"1000","clockAnomaly":"true","privateDomain":"checkout.example"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].event, "self-reconnect-gap-closed")
        XCTAssertEqual(entries[0].details["gapMs"], "1000")
        XCTAssertEqual(entries[0].details["clockAnomaly"], "true")
        XCTAssertNil(entries[0].details["privateDomain"], "a domain on the same entry must still be stripped")
    }

    func testDebugLogParserKeepsProbeSkipEvidenceAge() throws {
        // COH-3 (Codex mirror of the worker allowlist): a dns-smoke-probe-skipped entry carries
        // evidenceAgeMs — how old the corroborating evidence was when the routine probe was
        // skipped. It must survive redaction so a field report can confirm the skip fired inside
        // the <=300 s honesty-budget window (#196); it is a millisecond count, never a domain.
        let jsonLines = """
        {"component":"tunnel","event":"dns-smoke-probe-skipped","timestamp":"2026-05-18T01:07:00Z","reason":"periodic-health-check","evidenceAgeMs":"1234","privateDomain":"checkout.example"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].event, "dns-smoke-probe-skipped")
        XCTAssertEqual(entries[0].details["evidenceAgeMs"], "1234")
        XCTAssertEqual(entries[0].details["reason"], "periodic-health-check")
        XCTAssertNil(entries[0].details["privateDomain"], "a domain on the same entry must still be stripped")
    }

    func testDebugLogParserKeepsWedgeRecoveryDiagnosticDetails() throws {
        // The "said reconnect needed but never recovered" story: why a wedge was
        // not restarted (decision + gating booleans) and the in-place recovery
        // re-probe. Policy state only — no resolver address or queried domain.
        let jsonLines = """
        {"component":"tunnel","event":"self-reconnect-suppressed","timestamp":"2026-05-18T01:06:00Z","decision":"throttled","protectionEnabled":"true","onDemandConfirmed":"false","attemptsInWindow":"2","reason":"backed-off","privateDomain":"checkout.example"}
        {"component":"tunnel","event":"resolver-wedge-recovery","timestamp":"2026-05-18T01:06:30Z","reason":"backed-off","severity":"needs-reconnect","consecutiveUpstreamFailureCount":"5"}
        {"component":"tunnel","event":"dns-recovered","timestamp":"2026-05-18T01:06:35Z","reason":"backed-off","transport":"device-dns","durationMs":"5120","privateDomain":"checkout.example"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].event, "self-reconnect-suppressed")
        XCTAssertEqual(entries[0].details["decision"], "throttled")
        XCTAssertEqual(entries[0].details["protectionEnabled"], "true")
        XCTAssertEqual(entries[0].details["onDemandConfirmed"], "false")
        XCTAssertEqual(entries[0].details["attemptsInWindow"], "2")
        XCTAssertEqual(entries[0].details["reason"], "backed-off")
        XCTAssertNil(entries[0].details["privateDomain"])
        XCTAssertEqual(entries[1].event, "resolver-wedge-recovery")
        XCTAssertEqual(entries[1].details["severity"], "needs-reconnect")
        XCTAssertEqual(entries[1].details["consecutiveUpstreamFailureCount"], "5")
        // The recovery counterpart: mechanism + how long the wedge lasted, with a
        // co-located queried domain still stripped.
        XCTAssertEqual(entries[2].event, "dns-recovered")
        XCTAssertEqual(entries[2].details["transport"], "device-dns")
        XCTAssertEqual(entries[2].details["durationMs"], "5120")
        XCTAssertNil(entries[2].details["privateDomain"])
    }

    func testDebugLogParserKeepsLatencySpanDetails() throws {
        let jsonLines = """
        {"component":"tunnel","event":"latency-span-end","timestamp":"2026-06-12T10:00:00Z","operationID":"op-turn-on-0001","operationKind":"turnOn","spanID":"span-network-settings","parentSpanID":"span-start-tunnel","spanName":"tunnel.setNetworkSettings","spanEvent":"end","durationMs":"842","sequence":"7","status":"ok","errorKind":"none","privateDomain":"checkout.example"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].details["operationID"], "op-turn-on-0001")
        XCTAssertEqual(entries[0].details["operationKind"], "turnOn")
        XCTAssertEqual(entries[0].details["spanID"], "span-network-settings")
        XCTAssertEqual(entries[0].details["parentSpanID"], "span-start-tunnel")
        XCTAssertEqual(entries[0].details["spanName"], "tunnel.setNetworkSettings")
        XCTAssertEqual(entries[0].details["spanEvent"], "end")
        XCTAssertEqual(entries[0].details["durationMs"], "842")
        XCTAssertEqual(entries[0].details["sequence"], "7")
        XCTAssertEqual(entries[0].details["status"], "ok")
        XCTAssertEqual(entries[0].details["errorKind"], "none")
        XCTAssertNil(entries[0].details["privateDomain"])
    }

    func testPreviewSectionsExplainEachIncludedBundlePart() {
        let bundle = makeBundle(
            debugLogEntries: [
                BugReportDebugLogEntry(
                    component: "tunnel",
                    event: "startTunnel-ready",
                    timestamp: "2026-05-18T01:02:03Z",
                    details: [:]
                )
            ]
        )

        let sections = bundle.previewSections
        let titles = sections.map(\.title)

        XCTAssertEqual(
            titles,
            [
                "What happened",
                "App & Device",
                "VPN Status",
                "Tunnel Lifecycle Log",
                "Network & Resolver Health",
                "Incident Summary",
                "Filter Snapshot",
                "Local Activity Summary"
            ]
        )
        XCTAssertTrue(sections.allSatisfy { !$0.purpose.isEmpty })
        XCTAssertTrue(sections.allSatisfy { !$0.items.isEmpty })
    }

    func testBugReportIncludesCurrentDeviceDNSFallbackContext() throws {
        let activatedAt = Date(timeIntervalSinceReferenceDate: 800_720_030)
        let probeAt = Date(timeIntervalSinceReferenceDate: 800_720_020)
        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .vpnOrFilterIssue,
                details: "Device DNS fallback is active.",
                includeDiagnostics: true
            ),
            health: TunnelHealthSnapshot(
                startedAt: Date(timeIntervalSinceReferenceDate: 10),
                updatedAt: Date(timeIntervalSinceReferenceDate: 20),
                networkKind: .wifi,
                lastResolverAddress: "192.168.1.1",
                lastFailureReason: nil,
                upstreamSuccessCount: 9,
                upstreamFailureCount: 1,
                lastResolverTransport: .deviceDNS,
                deviceDNSUnavailableCount: 2,
                lastDNSSmokeProbeAt: probeAt,
                lastDNSSmokeProbeSucceeded: false,
                dnsSmokeProbeFailureCount: 1,
                deviceDNSFallbackModeActive: true,
                lastDeviceDNSFallbackActivatedAt: activatedAt,
                deviceDNSFallbackActivationCount: 1
            )
        )

        let body = bundle.makeRequestBody()
        let vpn = try XCTUnwrap(body["vpn"] as? [String: Any])
        let section: BugReportPreviewSection = try XCTUnwrap(
            bundle.previewSections.first { $0.id == "network_resolver" }
        )
        let itemIDs = Set(section.items.map(\.id))

        XCTAssertEqual(vpn["device_dns_fallback_mode_active"] as? Bool, true)
        XCTAssertEqual(vpn["last_resolver_transport"] as? String, "device-dns")
        XCTAssertEqual(vpn["last_dns_smoke_probe_succeeded"] as? Bool, false)
        XCTAssertEqual(vpn["device_dns_unavailable_count"] as? Int, 2)
        XCTAssertNotNil(vpn["last_device_dns_fallback_activated_at"])
        XCTAssertNotNil(vpn["last_dns_smoke_probe_at"])
        XCTAssertTrue(itemIDs.contains("device_dns_fallback_active"))
        XCTAssertTrue(itemIDs.contains("last_resolver_transport"))
        XCTAssertTrue(itemIDs.contains("device_dns_unavailable"))
    }

    func testBugReportCarriesLockedBootFilteringEvidence() throws {
        // The reboot QA gate's direct locked-window evidence must reach the SUBMITTED
        // payload on a Release RC (Feedback is the only artifact there), and a clean
        // locked-window pass produces no incident envelope — so the lockedBoot* fields
        // ride the always-carried vpnBody (incident plan Phase 4 follow-up, #381).
        let windowEndedAt = Date(timeIntervalSinceReferenceDate: 800_720_100)
        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .vpnOrFilterIssue,
                details: "Reboot QA gate evidence capture.",
                includeDiagnostics: true
            ),
            health: TunnelHealthSnapshot(
                startedAt: Date(timeIntervalSinceReferenceDate: 10),
                updatedAt: Date(timeIntervalSinceReferenceDate: 20),
                lockedBootBlockedQueryCount: 3,
                lockedBootAllowedQueryCount: 7,
                lockedBootFailClosedQueryCount: 1,
                lockedBootWindowEndedAt: windowEndedAt
            )
        )

        let vpn = try XCTUnwrap(bundle.makeRequestBody()["vpn"] as? [String: Any])
        XCTAssertEqual(vpn["locked_boot_blocked_query_count"] as? Int, 3)
        XCTAssertEqual(vpn["locked_boot_allowed_query_count"] as? Int, 7)
        XCTAssertEqual(vpn["locked_boot_fail_closed_query_count"] as? Int, 1)
        XCTAssertNotNil(vpn["locked_boot_window_ended_at"])
        XCTAssertNotEqual(vpn["locked_boot_window_ended_at"] as? String, "none")

        // A session that never started locked exports zero counters and "none" — the
        // absence signal the gate reads as "this boot had no locked window".
        let neverLocked = makeBundle(
            context: BugReportContext(
                issueType: .vpnOrFilterIssue,
                details: "Normal boot.",
                includeDiagnostics: true
            ),
            health: TunnelHealthSnapshot(
                startedAt: Date(timeIntervalSinceReferenceDate: 10),
                updatedAt: Date(timeIntervalSinceReferenceDate: 20)
            )
        )
        let neverLockedVPN = try XCTUnwrap(neverLocked.makeRequestBody()["vpn"] as? [String: Any])
        XCTAssertEqual(neverLockedVPN["locked_boot_blocked_query_count"] as? Int, 0)
        XCTAssertEqual(neverLockedVPN["locked_boot_window_ended_at"] as? String, "none")
    }

    func testSubmissionPolicyKeepsPreparedSnapshotWhenContextMatches() {
        let context = BugReportContext(
            issueType: .vpnOrFilterIssue,
            affectedSite: "",
            details: "Lava stopped resolving while the phone still had internet.",
            contactEmail: nil,
            includeDiagnostics: true
        )
        let preparedDraft = makeBundle(
            reportID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-9aaa-aaaaaaaaaaaa")!,
            context: context,
            vpnStatus: "connected"
        )
        var didBuildFreshBundle = false

        let bundle = BugReportSubmissionBundlePolicy.bundleToSubmit(
            draft: preparedDraft,
            currentContext: context
        ) {
            didBuildFreshBundle = true
            return makeBundle(
                reportID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb")!,
                context: context,
                vpnStatus: "disconnected"
            )
        }

        XCTAssertFalse(didBuildFreshBundle)
        XCTAssertEqual(bundle.reportID, preparedDraft.reportID)
        XCTAssertEqual(bundle.vpn.status, "connected")
    }

    func testSubmissionPolicyRebuildsSnapshotWhenContextChanged() {
        let preparedContext = BugReportContext(
            issueType: .vpnOrFilterIssue,
            details: "Old details",
            includeDiagnostics: true
        )
        let currentContext = BugReportContext(
            issueType: .vpnOrFilterIssue,
            details: "Updated details",
            includeDiagnostics: true
        )
        let preparedDraft = makeBundle(
            reportID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-9aaa-aaaaaaaaaaaa")!,
            context: preparedContext,
            vpnStatus: "connected"
        )
        let freshBundle = makeBundle(
            reportID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb")!,
            context: currentContext,
            vpnStatus: "disconnected"
        )

        let bundle = BugReportSubmissionBundlePolicy.bundleToSubmit(
            draft: preparedDraft,
            currentContext: currentContext
        ) {
            freshBundle
        }

        XCTAssertEqual(bundle.reportID, freshBundle.reportID)
        XCTAssertEqual(bundle.context, currentContext)
        XCTAssertEqual(bundle.vpn.status, "disconnected")
    }

    // MARK: - LAV-94 A: live-activity reconcile must not flood the report window

    func testDebugLogParserExcludesLiveActivityReconcileFromReportWindow() {
        // 14 reconciles + 2 incident events; the small window (limit 5) must keep the incident
        // events, not be flooded out by the high-frequency reconcile churn (LAV-94 A).
        var lines = [
            #"{"component":"tunnel","event":"self-reconnect","reason":"receive-failed","timestamp":"2026-06-22T00:00:00Z"}"#
        ]
        for index in 0..<14 {
            lines.append(
                #"{"component":"live-activity-controller","event":"reconcile","timestamp":"2026-06-22T00:00:\#(String(format: "%02d", index))Z"}"#
            )
        }
        lines.append(
            #"{"component":"tunnel","event":"resolver-wedge-recovery","reason":"covered-primary-recapture","timestamp":"2026-06-22T00:00:20Z"}"#
        )

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(lines.joined(separator: "\n").utf8), limit: 5)

        XCTAssertFalse(
            entries.contains { $0.component == "live-activity-controller" && $0.event == "reconcile" },
            "Reconcile churn must be excluded from the report window."
        )
        XCTAssertTrue(entries.contains { $0.event == "self-reconnect" })
        XCTAssertTrue(entries.contains { $0.event == "resolver-wedge-recovery" })
    }

    func testDebugLogParserExcludesLatencySpanChurnFromReportWindow() {
        // The QA/Debug-only resolver latency spans fire ~2 per DNS wire attempt; on a recovering
        // link they flood the window and evict the incident events (on-device QA replay 2026-06-22:
        // ~30 of 40 entries were latency-span pairs). The small window must keep the self-reconnect.
        var lines = [
            #"{"component":"tunnel","event":"self-reconnect","reason":"receive-failed","timestamp":"2026-06-22T00:00:00Z"}"#
        ]
        for index in 0..<14 {
            lines.append(
                #"{"component":"tunnel","event":"latency-span-begin","timestamp":"2026-06-22T00:00:\#(String(format: "%02d", index))Z"}"#
            )
            lines.append(
                #"{"component":"tunnel","event":"latency-span-end","details":{"durationMs":"8"},"timestamp":"2026-06-22T00:00:\#(String(format: "%02d", index))Z"}"#
            )
        }
        lines.append(
            #"{"component":"tunnel","event":"startTunnel-begin","timestamp":"2026-06-22T00:00:30Z"}"#
        )

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(lines.joined(separator: "\n").utf8), limit: 5)

        XCTAssertFalse(
            entries.contains { $0.event == "latency-span-begin" || $0.event == "latency-span-end" },
            "Per-query latency-span churn must be excluded from the report window."
        )
        XCTAssertTrue(entries.contains { $0.event == "self-reconnect" })
        XCTAssertTrue(entries.contains { $0.event == "startTunnel-begin" })
    }

    func testDebugLogParserExcludesChainedTransportFlapChurnButKeepsItsCauseLines() {
        // Socket flap is the condition a "sites won't load" report is filed DURING, so the
        // brief-stall transport lines flood exactly the window that has to explain the report —
        // and their readings (`state`, `previousMs`, `isViable`, `channel`) are not in
        // `allowedDetailKeys`, so each surviving entry spends a slot and carries no number.
        //
        // The cause lines are NOT churn and the distinction is the whole point of the
        // classification: an identity change is why a rebind happened, and a receive loop that
        // ended is a socket that will never deliver again. Both are rare and both must survive
        // a flap that outnumbers them 20:1.
        var lines = [
            #"{"component":"tunnel","event":"chained-path-identity-changed","timestamp":"2026-08-24T00:00:00Z"}"#,
            #"{"component":"tunnel","event":"chained-transport-receive-ended","details":{"error":"posix-54"},"timestamp":"2026-08-24T00:00:01Z"}"#
        ]
        for index in 0..<14 {
            let stamp = String(format: "%02d", index)
            lines.append(
                #"{"component":"tunnel","event":"chained-transport-state","details":{"state":"waiting:posix-50","channel":"4"},"timestamp":"2026-08-24T00:00:\#(stamp)Z"}"#
            )
            lines.append(
                #"{"component":"tunnel","event":"chained-transport-viability","details":{"isViable":"false"},"timestamp":"2026-08-24T00:00:\#(stamp)Z"}"#
            )
            lines.append(
                #"{"component":"tunnel","event":"chained-path-observation","details":{"eligible":"en0/wifi"},"timestamp":"2026-08-24T00:00:\#(stamp)Z"}"#
            )
        }
        lines.append(
            #"{"component":"tunnel","event":"self-reconnect","reason":"receive-failed","timestamp":"2026-08-24T00:00:30Z"}"#
        )

        // Limit 40, the production default. The old limit of 5 could only be satisfied by
        // dropping the family outright — no window that small survives a 14-deep flap plus its
        // cause lines — so it was testing the drop, not the guarantee (Codex P2, PR #581).
        let entries = BugReportDebugLogEntry.parseJSONLines(
            Data(lines.joined(separator: "\n").utf8), limit: 40)

        // The transport family is no longer dropped — PR #580 allowlisted its readings, so each
        // line now carries a stall's state ordering — but it IS capped, so a 14-deep flap cannot
        // evict the cause lines below (Codex P2, PR #581).
        XCTAssertFalse(
            entries.contains { $0.event == "chained-path-observation" },
            "the unbounded per-callback observation line is still churn — it has no rate bound "
                + "to cap against")
        XCTAssertTrue(
            entries.contains { $0.event == "chained-path-identity-changed" },
            "the rebind's cause line was evicted by the flap it explains")
        XCTAssertTrue(
            entries.contains { $0.event == "chained-transport-receive-ended" },
            "a dead receive loop is once-per-socket evidence, never churn")
        XCTAssertTrue(entries.contains { $0.event == "self-reconnect" })
    }

    func testTransportTransitionsAreCappedRatherThanDropped() {
        // BOTH FAILURES ARE REAL, which is why this is a cap and not a boolean. Dropping the
        // family discarded the only per-stall state ordering in a submitted report — the 60 s
        // liveness counters keep aggregates only. Keeping all of it lets a sustained flap fill
        // the window and evict the cause lines. The newest few survive; the rest do not.
        var lines = [
            #"{"component":"tunnel","event":"chained-path-identity-changed","timestamp":"2026-08-24T00:00:00Z"}"#
        ]
        for index in 0..<20 {
            let stamp = String(format: "%02d", index)
            lines.append(
                #"{"component":"tunnel","event":"chained-transport-state","state":"waiting:posix-50","channel":"\#(index)","previousMs":"1200","timestamp":"2026-08-24T00:00:\#(stamp)Z"}"#
            )
        }
        let entries = BugReportDebugLogEntry.parseJSONLines(
            Data(lines.joined(separator: "\n").utf8), limit: 40)

        let transitions = entries.filter { $0.event == "chained-transport-state" }
        XCTAssertEqual(
            transitions.count, BugReportDebugLogEntry.transportTransitionReportCap,
            "the family must be capped, not dropped and not unbounded")
        // The NEWEST are the ones kept — a stall is diagnosed from what happened last.
        XCTAssertEqual(transitions.last?.details["channel"], "19")
        XCTAssertEqual(transitions.first?.details["channel"], "14")
        // And the readings survive, which is the whole reason they are worth keeping.
        XCTAssertEqual(transitions.last?.details["previousMs"], "1200")
        XCTAssertTrue(
            entries.contains { $0.event == "chained-path-identity-changed" },
            "the cause line must survive a flap that outnumbers it 20:1")
    }

    // MARK: - LAV-94 B: redacted incident summary

    func testRequestBodyIncludesIncidentSummaryWhenDiagnosticsAreIncluded() throws {
        // Anchor to "now" so the self-reconnect timeline falls inside the attempt window the
        // summary prunes to (the bundle's `incident` uses the current clock).
        let networkChangedAt = Date().addingTimeInterval(-180)
        let reconnectAt = networkChangedAt.addingTimeInterval(120)
        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .vpnOrFilterIssue,
                details: "Lava keeps reconnecting on its own.",
                includeDiagnostics: true
            ),
            health: TunnelHealthSnapshot(
                lastFailureReason: "receive-failed",
                consecutiveUpstreamFailureCount: 2,
                lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(110),
                lastDNSSmokeProbeSucceeded: false,
                consecutiveDNSSmokeProbeFailureCount: 5,
                consecutiveRejectedSmokeResponseCount: 0,
                lastNetworkChangeAt: networkChangedAt,
                networkChangeCount: 3,
                resolverRuntimeResetCount: 1,
                lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(60)
            ),
            selfReconnectTimes: [reconnectAt, networkChangedAt.addingTimeInterval(30)]
        )

        let body = bundle.makeRequestBody()
        XCTAssertEqual(body["has_incident_summary"] as? Bool, true)
        let incident = try XCTUnwrap(body["incident"] as? [String: Any])
        XCTAssertEqual(incident["self_reconnect_count"] as? Int, 2)
        XCTAssertEqual(incident["consecutive_dns_smoke_probe_failure_count"] as? Int, 5)
        XCTAssertEqual(incident["consecutive_rejected_smoke_response_count"] as? Int, 0)
        XCTAssertEqual(incident["last_failure_reason"] as? String, "receive-failed")
        XCTAssertNotNil(incident["last_self_reconnect_at"])
        XCTAssertNotNil(incident["last_encrypted_fallback_success_at"])
        let times = try XCTUnwrap(incident["self_reconnect_times"] as? [String])
        XCTAssertEqual(times.count, 2)
        // Timeline is sorted ascending, so the last entry is the most recent self-reconnect.
        XCTAssertEqual(incident["last_self_reconnect_at"] as? String, times.last)
    }

    func testIncidentSummaryAbsentWithoutDiagnostics() {
        let bundle = makeBundle(
            context: BugReportContext(issueType: .vpnOrFilterIssue, includeDiagnostics: false),
            selfReconnectTimes: [Date(timeIntervalSinceReferenceDate: 800_720_000)]
        )

        let body = bundle.makeRequestBody()
        XCTAssertEqual(body["has_incident_summary"] as? Bool, false)
        XCTAssertNil(body["incident"], "No incident envelope is sent unless diagnostics are attached.")
    }

    // A fail-closed window can be the ONLY evidence in a report: queries are suppressed and
    // self-reconnect escalation is deliberately suppressed while the snapshot is unavailable,
    // so no other incident counter moves. The flag must stay honest for that class, and the
    // trace must never look like blocking (it is not in filtering counts — #164).
    func testIncidentSummaryCarriesFailClosedTrace() throws {
        let failClosedAt = Date(timeIntervalSinceReferenceDate: 800_800_000)
        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .vpnOrFilterIssue,
                details: "Everything stopped loading for a minute.",
                includeDiagnostics: true
            ),
            health: TunnelHealthSnapshot(
                failClosedServedQueryCount: 42,
                lastFailClosedAt: failClosedAt,
                lastFailClosedReason: "snapshot-unavailable"
            )
        )

        let body = bundle.makeRequestBody()
        XCTAssertEqual(body["has_incident_summary"] as? Bool, true)
        let incident = try XCTUnwrap(body["incident"] as? [String: Any])
        XCTAssertEqual(incident["fail_closed_served_query_count"] as? Int, 42)
        XCTAssertNotNil(incident["last_fail_closed_at"])
        XCTAssertEqual(incident["last_fail_closed_reason"] as? String, "snapshot-unavailable")
        XCTAssertEqual(incident["self_reconnect_count"] as? Int, 0)
    }

    func testIncidentSummaryHasNoContentOnAHealthyTunnel() {
        let incident = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: []
        )
        XCTAssertFalse(incident.hasContent, "A clean snapshot with no failures or reconnects has nothing to report.")
    }

    // The gap record is the DURABLE self-reconnect evidence (LAV-92/93): the credit deletes
    // the recovered attempt and the report prunes to the 600 s window, so a report filed 30
    // minutes after "it reconnected on its own" otherwise arrives evidence-free. A RECENT gap
    // must flip has_incident_summary; the never-expiring record alone must NOT (the
    // misleading-true class the always-persisted Focus record has).
    func testIncidentSummaryRecentGapCountsAsContentButStaleGapDoesNot() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_900_000)
        let recentGap = SelfReconnectGapRecord(
            startedAt: now.addingTimeInterval(-30 * 60),
            endedAt: now.addingTimeInterval(-30 * 60 + 4.2),
            cumulativeCount: 3
        )
        let recent = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: [], // credited/pruned away — the gap is the only evidence
            selfReconnectGap: recentGap,
            now: now
        )
        XCTAssertTrue(recent.hasContent, "A 30-minute-old gap is real incident evidence.")
        let body = recent.dictionary
        XCTAssertEqual(body["self_reconnect_gap_count"] as? Int, 3)
        XCTAssertNotNil(body["last_self_reconnect_gap_started_at"])
        XCTAssertNotNil(body["last_self_reconnect_gap_ended_at"])
        XCTAssertEqual(body["last_self_reconnect_gap_ms"] as? Int, 4_200)

        let stale = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: [],
            selfReconnectGap: SelfReconnectGapRecord(
                startedAt: now.addingTimeInterval(-3 * 24 * 60 * 60),
                endedAt: now.addingTimeInterval(-3 * 24 * 60 * 60 + 4),
                cumulativeCount: 3
            ),
            now: now
        )
        XCTAssertFalse(stale.hasContent, "A long-CLOSED record must not flip the flag forever.")
        XCTAssertNotNil(
            stale.dictionary["self_reconnect_gap_count"],
            "The stale record still ships its fields — staleness is data, not a reason to hide it."
        )

        // Recency keys on the gap's END, not its start: a 3-day outage that ended an hour
        // ago is fresh evidence.
        let longOutageJustEnded = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: [],
            selfReconnectGap: SelfReconnectGapRecord(
                startedAt: now.addingTimeInterval(-3 * 24 * 60 * 60),
                endedAt: now.addingTimeInterval(-60 * 60),
                cumulativeCount: 2
            ),
            now: now
        )
        XCTAssertTrue(longOutageJustEnded.hasContent)

        // A still-open gap (relaunch pending) has no end/duration yet — and is ONGOING
        // evidence no matter how long ago it started (Connect-On-Demand never relaunched).
        let openGap = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: [],
            selfReconnectGap: SelfReconnectGapRecord(
                startedAt: now.addingTimeInterval(-3 * 24 * 60 * 60),
                endedAt: nil,
                cumulativeCount: 1
            ),
            now: now
        )
        XCTAssertNil(openGap.dictionary["last_self_reconnect_gap_ended_at"])
        XCTAssertNil(openGap.dictionary["last_self_reconnect_gap_ms"])
        XCTAssertTrue(openGap.hasContent, "An open gap is ongoing evidence, however old its start.")
    }

    func testIncidentSummaryFocusSwitchAloneCountsAsContentOnlyWhileRecent() throws {
        // A closed-app Focus switch can be the ONLY evidence in a report (e.g. it failed/deferred with no DNS
        // failures or self-reconnects). It must flag has_incident_summary so backend/support triage keyed off
        // that flag doesn't skip the very Focus diagnostic this surfaces (Codex round 7) — but the record
        // never expires, so its bare existence must not flip the flag FOREVER (OBS-1's misleading-true
        // failure): recency-gated at 24 h, like the gap and the incident ledger.
        let now = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let record = FocusSwitchDiagnosticRecord(
            outcome: "deferred",
            targetFilterID: "filter-extra",
            at: now.addingTimeInterval(-60 * 60)
        )
        let recent = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: [],
            lastFocusSwitch: record,
            now: now
        )
        XCTAssertTrue(recent.hasContent, "A recent Focus-switch diagnostic alone must count as incident content.")

        let stale = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: [],
            lastFocusSwitch: record,
            now: now.addingTimeInterval(3 * 24 * 60 * 60)
        )
        XCTAssertFalse(
            stale.hasContent,
            "An install-lifetime Focus record must not claim a live incident forever."
        )
        // The record itself still SHIPS either way — recency only gates the flag.
        let staleBody = stale.dictionary
        XCTAssertNotNil(staleBody["focus_last_switch"], "A stale Focus record is still context for triage.")
    }

    func testIncidentSummaryLedgerTimelineShipsAndGatesContentOnRecency() throws {
        // OBS R2: the ledger is the record that SURVIVES the policy stores' by-design
        // forgetting — a report filed 30 minutes after a thrash carries the timeline.
        let now = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let committed = IncidentLedgerRecord(
            at: now.addingTimeInterval(-31 * 60),
            kind: .selfReconnectCommitted,
            reason: "upstream-failed"
        )
        let credited = IncidentLedgerRecord(
            at: now.addingTimeInterval(-28 * 60),
            kind: .selfReconnectCredited,
            durationMs: 180_000
        )
        let summary = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: [],  // credited/pruned away — the ledger is the only evidence
            recentIncidents: [committed, credited],
            now: now
        )

        XCTAssertTrue(summary.hasContent, "a 30-minute-stale thrash must still claim an incident")
        let body = summary.dictionary
        let entries = try XCTUnwrap(body["recent_incidents"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["kind"] as? String, "self_reconnect_committed")
        XCTAssertEqual(entries[0]["reason"] as? String, "upstream-failed")
        XCTAssertEqual(entries[1]["kind"] as? String, "self_reconnect_credited")
        XCTAssertEqual(entries[1]["duration_ms"] as? Int, 180_000)
        XCTAssertNotNil(entries[0]["at"] as? String)

        // Week-old records still SHIP (triage context) but no longer claim a live incident.
        let stale = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: [],
            recentIncidents: [committed, credited],
            now: now.addingTimeInterval(3 * 24 * 60 * 60)
        )
        XCTAssertFalse(stale.hasContent)
        XCTAssertNotNil(stale.dictionary["recent_incidents"])
    }

    func testIncidentSummaryCarriesNoResolvedDomains() throws {
        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .vpnOrFilterIssue,
                affectedSite: "secret-site.example",
                includeDiagnostics: true
            ),
            health: TunnelHealthSnapshot(
                lastFailureReason: "receive-failed",
                consecutiveDNSSmokeProbeFailureCount: 3
            ),
            selfReconnectTimes: [Date(timeIntervalSinceReferenceDate: 800_720_000)]
        )

        let incident = try XCTUnwrap(bundle.makeRequestBody()["incident"] as? [String: Any])
        // The incident envelope is timestamps / counts / policy reasons only — never a queried
        // domain or browsing history (the data-minimization line, LAV-94 B).
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: incident), as: UTF8.self)
        XCTAssertFalse(serialized.contains("secret-site"))
        XCTAssertFalse(serialized.lowercased().contains("example"))
    }

    func testIncidentSummaryTimelineIsBounded() {
        let base = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let manyTimes = (0..<50).map { base.addingTimeInterval(Double($0)) }
        // `now` anchored to the last attempt so all 50 fall inside the prune window and the
        // bound (not the window) is what trims the timeline.
        let incident = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(lastFailureReason: "receive-failed"),
            selfReconnectTimes: manyTimes,
            now: manyTimes.last!
        )
        XCTAssertEqual(incident.selfReconnectTimes.count, BugReportIncidentSummary.maxSelfReconnectTimes)
        // The cap keeps the MOST RECENT attempts.
        XCTAssertEqual(incident.lastSelfReconnectAt, manyTimes.last)
    }

    func testIncidentSummaryPrunesSelfReconnectsOutsideTheAttemptWindow() {
        let now = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let recent = now.addingTimeInterval(-120)            // inside the 600s attempt window
        let stale = now.addingTimeInterval(-1_800)           // 30 min old — outside the window
        let incident = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(lastFailureReason: "receive-failed"),
            selfReconnectTimes: [stale, recent],
            now: now
        )
        XCTAssertEqual(
            incident.selfReconnectTimes,
            [recent],
            "Only self-reconnects inside the attempt window are surfaced — the persisted store can hold older ones the tunnel hasn't pruned yet."
        )
        XCTAssertEqual(incident.selfReconnectCount, 1)
    }

    func testIncidentSummaryStaleOnlySelfReconnectDoesNotFlagAnIncident() {
        let now = Date(timeIntervalSinceReferenceDate: 800_720_000)
        // A clean tunnel whose ONLY "evidence" is a self-reconnect older than the window must
        // not report an incident — otherwise a report filed long after a one-off reconnect would
        // dishonestly set has_incident_summary (the Codex finding on #105).
        let incident = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: [now.addingTimeInterval(-3_600)],
            now: now
        )
        XCTAssertTrue(incident.selfReconnectTimes.isEmpty)
        XCTAssertFalse(incident.hasContent)
    }

    /// 🔴 THE BUNDLE FORWARDS THE FAILURE INTO THE SUMMARY IT SERIALIZES.
    ///
    /// The bundle stored `lastFocusFailure` while `incident` built `BugReportIncidentSummary`
    /// without it, so the field defaulted to nil and the record never left the device — the
    /// diagnostic inert with every other test green (Codex, PR #625). Asserted through
    /// `bundle.incident`, because a test that constructs the summary DIRECTLY proves rendering
    /// and not forwarding, and that is exactly the gap that let this through once already.
    func testTheBundleForwardsTheFocusFailureIntoTheIncidentSummary() throws {
        let failure = FocusSwitchDiagnosticRecord(
            outcome: "foreground-reconcile-failed",
            targetFilterID: "filter-comprehensive",
            at: Date(),
            reason: "shared-state-unavailable")
        let bundle = makeBundle(lastFocusFailure: failure)

        XCTAssertEqual(
            bundle.incident.lastFocusFailure, failure,
            "the bundle dropped the failure on its way into the summary the report serializes")
        let rendered = try XCTUnwrap(
            bundle.incident.dictionary["focus_last_failure"] as? [String: Any])
        XCTAssertEqual(rendered["reason"] as? String, "shared-state-unavailable")
    }

    func testContextEditingRetainsCapturedEnvironmentAndReportIdentity() throws {
        let original = makeBundle()
        let context = BugReportContext(issueType: .suggestion, details: "Updated reviewed text", includeDiagnostics: true)
        let edited = original.updatingContext(context, affectedSiteDecision: nil)
        XCTAssertEqual(edited.reportID, original.reportID)
        XCTAssertEqual(edited.context, context)
        XCTAssertEqual(edited.filters, original.filters)
        XCTAssertEqual(edited.vpn, original.vpn)
        XCTAssertEqual(edited.app, original.app)
        XCTAssertEqual(edited.device, original.device)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(edited.diagnostics), try encoder.encode(original.diagnostics))
        XCTAssertEqual(edited.makeRequestBody()["user_description"] as? String, context.userDescription)
    }

    private func makeBundle(
        reportID: UUID = UUID(uuidString: "12345678-1234-4234-9234-123456789abc")!,
        context: BugReportContext = BugReportContext(
            issueType: .websiteAccess,
            affectedSite: "checkout.example",
            details: "Checkout would not load after protection turned on.",
            contactEmail: nil
        ),
        vpnStatus: String = "connected",
        affectedSiteDecision: BugReportAffectedSiteFilterDecision? = nil,
        filters: BugReportFilterSummary? = nil,
        diagnostics: DiagnosticsStore = DiagnosticsStore(startedAt: Date(timeIntervalSinceReferenceDate: 100)),
        debugLogEntries: [BugReportDebugLogEntry] = [],
        health: TunnelHealthSnapshot? = nil,
        selfReconnectTimes: [Date] = [],
        lastFocusSwitch: FocusSwitchDiagnosticRecord? = nil,
        lastFocusFailure: FocusSwitchDiagnosticRecord? = nil
    ) -> BugReportBundle {
        BugReportBundle(
            reportID: reportID,
            context: context,
            app: BugReportAppSnapshot(version: "1.2.3", build: "45"),
            device: BugReportDeviceSnapshot(
                iosVersion: "iOS 18.5",
                deviceFamily: "Phone",
                locale: "en_US"
            ),
            vpn: BugReportVPNSnapshot(
                status: vpnStatus,
                resolverPreset: "Google Public DNS",
                health: health ?? TunnelHealthSnapshot(
                    startedAt: Date(timeIntervalSinceReferenceDate: 10),
                    updatedAt: Date(timeIntervalSinceReferenceDate: 20),
                    networkKind: .wifi,
                    lastResolverAddress: "8.8.8.8",
                    lastFailureReason: "timeout",
                    cacheHitCount: 7,
                    cacheMissCount: 3,
                    coalescedQueryCount: 2,
                    upstreamSuccessCount: 9,
                    upstreamFailureCount: 1,
                    lastResolverTransport: .plainDNS,
                    upstreamTimeoutCount: 1,
                    tcpFallbackAttemptCount: 1,
                    tcpFallbackSuccessCount: 1,
                    networkChangeCount: 2,
                    resolverRuntimeResetCount: 1
                )
            ),
            filters: filters ?? BugReportFilterSummary(
                catalogVersion: "20260518T000000Z",
                enabledListIDs: ["blocklistproject-basic"],
                snapshotVersion: "snapshot-123",
                compiledRuleCount: 1200,
                blocklistRuleCount: 1180,
                affectedSiteDecision: affectedSiteDecision
            ),
            diagnostics: diagnostics,
            localHistoryEnabled: false,
            debugLogEntries: debugLogEntries,
            selfReconnectTimes: selfReconnectTimes,
            lastFocusSwitch: lastFocusSwitch,
            lastFocusFailure: lastFocusFailure
        )
    }

    /// A resolver this session ROAMED AWAY FROM is still folded, because the counter maps still
    /// name it.
    ///
    /// The device-DNS rung's addresses are the tunnel's live capture, so a roam republishes the
    /// new set over the old one — but `resolverAttemptCounts` and its siblings are session-wide
    /// and keyed by whichever address was tried, so the retired resolver stays in them. The fold
    /// is built from the CURRENT lists, so without `chainedFallbackRetiredAddresses` the old
    /// address walked into the report as a verbatim dictionary key: a LAN or ISP resolver naming
    /// the user's network, which is the whole disclosure this redaction exists to stop
    /// (Codex P1, PR #592).
    ///
    /// This is the same INDIRECT road PR #575 closed for the current set, re-opened one roam
    /// later — which is why the test is shaped like its neighbour rather than folded into it.
    func testTheReportCarriesNoRoamedAwayFallbackAddresses() throws {
        let roamedAway = "192.168.7.1"
        let current = "10.0.0.1"
        var health = TunnelHealthSnapshot(startedAt: Date(), updatedAt: Date())
        health.chainedFallbackEvaluated = true
        // The CURRENT capture names only the new resolver — this is what a roam leaves behind.
        health.chainedFallbackLatchedAddresses = [current]
        health.chainedFallbackEffectiveAddresses = [current]
        health.chainedFallbackRetiredAddresses = [roamedAway]
        // ...while the session-wide maps still carry the one it asked before the roam.
        health.resolverAttemptCounts = [roamedAway: 5, current: 2]
        health.resolverSuccessCounts = [roamedAway: 3]
        health.resolverFailureCounts = [roamedAway: 2, current: 1]
        health.lastResolverAddress = roamedAway

        let snapshot = BugReportVPNSnapshot(
            status: "connected", resolverPreset: "Device DNS", health: health)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

        XCTAssertFalse(
            encoded.contains(roamedAway),
            "a resolver the session roamed away from still keys the counter maps, so it must "
                + "still fold")
        XCTAssertFalse(encoded.contains(current), "and the current one is redacted as it always was")
        XCTAssertEqual(
            snapshot.health.chainedFallbackRetiredAddresses, [],
            "the retired list's job is to be READ by the fold, never shipped — it is a list of "
                + "the very addresses being hidden")
        // The COUNTS survive under the placeholder: which tier was tried how often is the
        // diagnostic, and it carries no network detail once the key is folded.
        XCTAssertEqual(
            snapshot.health.resolverAttemptCounts[TunnelHealthSnapshot.redactedFallbackAddress], 7,
            "both resolvers' attempts fold onto the one T1 placeholder")
    }

    func testTheReportCarriesNoChainedFallbackAddresses() throws {
        // The chained fallback's custom-resolver field accepts any IPv4, so a QA user can point it
        // at their own network. The panel may show it — the user's own device, the user's own
        // setting — but a report they SEND US may not, which is the contract already written
        // beside `chainedFallbackEvaluated`; these fields broke it three fields later
        // (Codex, PR #575).
        let priv = "10.11.12.13"
        var health = TunnelHealthSnapshot(startedAt: Date(), updatedAt: Date())
        health.chainedFallbackEvaluated = true
        health.chainedFallbackLatchedAddresses = [priv, "1.1.1.1"]
        health.chainedFallbackEffectiveAddresses = [priv]
        health.chainedFallbackOutcomes = [
            ChainedFallbackAddressOutcome(address: priv, disposition: .admitted),
            ChainedFallbackAddressOutcome(address: "1.1.1.1", disposition: .alreadyPrimary),
        ]
        health.chainedFallbackRescueCount = 4
        health.chainedFallbackLatchedConfigurationFingerprint = "deadbeef"
        // THE IDENTITY IS THE NEWEST ROAD OUT. It carries the preset ID, the transport and every
        // endpoint — and for a Custom entry those endpoints are the user's own resolver, which is
        // exactly what the address lists above are cleared for (the plan's S4).
        health.chainedFallbackLatchedIdentity = "custom|plain-dns|\(priv)"
        health.chainedFallbackAttemptKeys = [priv, "1.1.1.1"]
        // THE INDIRECT ROAD (Codex, PR #575). Resolver-health evidence keys these by whichever
        // address served or was tried, and a T1 rung lands in them like any other — so the
        // first version of this redaction cleared the fallback fields while the same private
        // address walked out through here.
        health.lastResolverAddress = priv
        health.resolverAttemptCounts = [priv: 3, "10.64.0.1": 9]
        health.resolverSuccessCounts = [priv: 2]
        health.resolverFailureCounts = [priv: 1, "10.64.0.1": 4]

        // Through the REPORT type, not the helper: the redaction has to belong to the boundary,
        // so that adding a second construction site cannot quietly bypass it.
        let snapshot = BugReportVPNSnapshot(
            status: "connected", resolverPreset: "Cloudflare", health: health)
        let encoded = String(
            decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(
            encoded.contains(priv), "a hand-entered private resolver must not reach a bug report")
        XCTAssertFalse(encoded.contains("1.1.1.1"), "no fallback address may reach a bug report")
        XCTAssertEqual(
            snapshot.health.chainedFallbackLatchedIdentity, "",
            "the latched identity embeds a custom resolver's own address; it must be cleared")
        XCTAssertEqual(
            snapshot.health.chainedFallbackAttemptKeys, [],
            "an encrypted attempt key is the endpoint's full cacheIdentifier — URL and all")

        // The DIAGNOSTICS must survive, or the redaction has cost us the reason the field exists:
        // which gate refused which entry, the counters, and the opaque configuration fingerprint.
        XCTAssertEqual(
            snapshot.health.chainedFallbackOutcomes.map(\.disposition),
            [.admitted, .alreadyPrimary],
            "the dispositions are the diagnostic and carry no network detail")
        XCTAssertEqual(snapshot.health.chainedFallbackRescueCount, 4)
        XCTAssertEqual(
            snapshot.health.chainedFallbackLatchedConfigurationFingerprint, "deadbeef",
            "an opaque fingerprint reveals nothing and must be kept")
        XCTAssertTrue(
            snapshot.health.chainedFallbackEvaluated,
            "redaction must not erase whether a session evaluated the selection")

        // The indirect projections, and what must SURVIVE them. Folding onto a placeholder keeps
        // the totals — T1 was tried three times and served twice — which is the diagnostic;
        // dropping the entries would make a working fallback and an untried one look identical.
        XCTAssertEqual(
            snapshot.health.lastResolverAddress, TunnelHealthSnapshot.redactedFallbackAddress,
            "that a T1 resolver served last is worth keeping; which one is not")
        XCTAssertEqual(
            snapshot.health.resolverAttemptCounts,
            [TunnelHealthSnapshot.redactedFallbackAddress: 3, "10.64.0.1": 9],
            "fallback keys fold onto the placeholder; a T0 key is untouched")
        XCTAssertEqual(
            snapshot.health.resolverSuccessCounts,
            [TunnelHealthSnapshot.redactedFallbackAddress: 2])
        XCTAssertEqual(
            snapshot.health.resolverFailureCounts,
            [TunnelHealthSnapshot.redactedFallbackAddress: 1, "10.64.0.1": 4])
    }

    func testANonFallbackResolverIsLeftAloneByTheRedaction() {
        // The redaction must not become a blanket scrub: with no fallback in play the snapshot is
        // a diagnostic and every address in it is one the user chose on the DNS page.
        var health = TunnelHealthSnapshot(startedAt: Date(), updatedAt: Date())
        health.lastResolverAddress = "1.1.1.1"
        health.resolverAttemptCounts = ["1.1.1.1": 5]
        let snapshot = BugReportVPNSnapshot(
            status: "connected", resolverPreset: "Cloudflare", health: health)
        XCTAssertEqual(snapshot.health.lastResolverAddress, "1.1.1.1")
        XCTAssertEqual(snapshot.health.resolverAttemptCounts, ["1.1.1.1": 5])
    }

    func testADeduplicatedPrimaryIsNotCountedAsAlternativeDNSTraffic() {
        // Cloudflare selected while the conf already carries `DNS = 1.1.1.1`: that address is
        // latched and marked `.alreadyPrimary`, but deliberately absent from the effective set —
        // it is T0. Folding it in with the T1 totals made the report say Alternative DNS
        // had served queries it never handled, and summed primary counts with real fallback ones
        // (Codex, PR #575). Still redacted, because a user can hand-enter their own `DNS =`
        // address here and it names their network either way.
        var health = TunnelHealthSnapshot(startedAt: Date(), updatedAt: Date())
        health.chainedFallbackLatchedAddresses = ["1.1.1.1", "1.0.0.1"]
        health.chainedFallbackEffectiveAddresses = ["1.0.0.1"]
        health.chainedFallbackOutcomes = [
            ChainedFallbackAddressOutcome(address: "1.1.1.1", disposition: .alreadyPrimary),
            ChainedFallbackAddressOutcome(address: "1.0.0.1", disposition: .admitted),
        ]
        health.lastResolverAddress = "1.1.1.1"
        health.resolverAttemptCounts = ["1.1.1.1": 40, "1.0.0.1": 2]

        let snapshot = BugReportVPNSnapshot(
            status: "connected", resolverPreset: "Cloudflare", health: health)
        XCTAssertEqual(
            snapshot.health.resolverAttemptCounts,
            [
                TunnelHealthSnapshot.redactedDeduplicatedPrimaryAddress: 40,
                TunnelHealthSnapshot.redactedFallbackAddress: 2,
            ],
            "40 primary attempts must not be reported as alternative-DNS traffic")
        XCTAssertEqual(
            snapshot.health.lastResolverAddress,
            TunnelHealthSnapshot.redactedDeduplicatedPrimaryAddress,
            "the deduped address served as T0, and the report must say which tier")
        // Redacted all the same — the two placeholders differ in MEANING, not in whether they hide.
        let encoded = String(decoding: try! JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("1.1.1.1"))
        XCTAssertFalse(encoded.contains("1.0.0.1"))
    }

    func testARefusedFallbackGetsItsOwnIdentityRatherThanTheTierOneBucket() {
        // A refused address is never in the resolver route, so it should never key these maps at
        // all. The mapping is total anyway: folding one into the T1 bucket would invent
        // alternative-DNS traffic out of an address the tunnel declined to use.
        var health = TunnelHealthSnapshot(startedAt: Date(), updatedAt: Date())
        health.chainedFallbackLatchedAddresses = ["224.0.0.1"]
        health.chainedFallbackOutcomes = [
            ChainedFallbackAddressOutcome(address: "224.0.0.1", disposition: .unusable)
        ]
        health.resolverAttemptCounts = ["224.0.0.1": 1]
        let snapshot = BugReportVPNSnapshot(
            status: "connected", resolverPreset: "Cloudflare", health: health)
        XCTAssertEqual(
            snapshot.health.resolverAttemptCounts,
            [TunnelHealthSnapshot.redactedRefusedFallbackAddress: 1])
    }

    func testTwoFallbackAddressesFoldWithoutLosingEitherCount() {
        // A built-in provider contributes TWO servers, so folding must SUM them rather than let
        // one overwrite the other — otherwise the report understates how hard T1 was working.
        var health = TunnelHealthSnapshot(startedAt: Date(), updatedAt: Date())
        health.chainedFallbackLatchedAddresses = ["1.1.1.1", "1.0.0.1"]
        health.resolverAttemptCounts = ["1.1.1.1": 4, "1.0.0.1": 6, "10.64.0.1": 1]
        let snapshot = BugReportVPNSnapshot(
            status: "connected", resolverPreset: "Cloudflare", health: health)
        XCTAssertEqual(
            snapshot.health.resolverAttemptCounts,
            [TunnelHealthSnapshot.redactedFallbackAddress: 10, "10.64.0.1": 1],
            "both servers' attempts must survive as one total")
    }

    func testTheExportKeepsChainedTunnelDiagnosticsAndStillDropsIdentifiers() throws {
        // THE FIELD FAILURE (PR #580). The allowlist did not keep pace with the chained work, so
        // `nrg-counters` and `chained-session-liveness` — the two richest lines in the system —
        // exported as `"details": {}`, along with the `dataPath`/`refusal` pair that says why
        // chaining did not engage. A log sent from the road, off-tether, could not be diagnosed
        // because the export had removed everything worth reading.
        let line = """
            {"event":"data-path-latched","timestamp":"2026-08-25T00:39:01Z","component":"tunnel",            "dataPath":"dns-only","refusal":"chained-surrendered","outageCount":"4",            "chainedDNSSilentTimeout":"17","chainedDNSResolution":"66","footprintMB":"41",            "sawEgressDemandHost":"probe.example.com","identity":"10.64.0.1"}
            """
        let entries = BugReportDebugLogEntry.parseJSONLines(Data(line.utf8))
        let details = try XCTUnwrap(entries.first?.details)

        // The fault is legible: which data path latched, why, and how bad DNS was.
        XCTAssertEqual(details["dataPath"], "dns-only")
        XCTAssertEqual(details["refusal"], "chained-surrendered")
        XCTAssertEqual(details["outageCount"], "4")
        XCTAssertEqual(details["chainedDNSSilentTimeout"], "17")
        XCTAssertEqual(details["chainedDNSResolution"], "66")
        XCTAssertEqual(details["footprintMB"], "41")

        // And the guarantee the allowlist exists for is unchanged: a hostname and an
        // identity-shaped value are still dropped, so widening it did not widen what leaks.
        XCTAssertNil(details["sawEgressDemandHost"], "a hostname must never reach a shared bundle")
        XCTAssertNil(details["identity"], "identity-shaped values stay out by default")
    }

    /// The reply-SHAPE counters export (PR #588). This is the whole reason they exist: the
    /// unbacked count against `chainedDNSResolution` is what says "the VPN's resolver completes
    /// every lookup without resolving anything", and it is only useful in a bundle the founder
    /// sends from the road. Counts of resolutions — no name, no rcode of any one query.
    func testTheExportKeepsTheEmptyAnswerShapeCounters() throws {
        let line = """
            {"event":"nrg-counters","timestamp":"2026-08-26T04:44:01Z","component":"nrg",            "chainedDNSResolution":"93","chainedDNSEmptyAnswer":"93",            "chainedDNSUnbackedEmptyAnswer":"91","chainedDNSUnbackedEmptyAnswerPerMin":"48.7",            "chainedDNSEmptyAnswerPerMin":"49.8","sawEgressDemandHost":"probe.example.com"}
            """
        let entries = BugReportDebugLogEntry.parseJSONLines(Data(line.utf8))
        let details = try XCTUnwrap(entries.first?.details)

        XCTAssertEqual(details["chainedDNSEmptyAnswer"], "93")
        XCTAssertEqual(details["chainedDNSUnbackedEmptyAnswer"], "91")
        XCTAssertEqual(details["chainedDNSEmptyAnswerPerMin"], "49.8")
        XCTAssertEqual(details["chainedDNSUnbackedEmptyAnswerPerMin"], "48.7")
        XCTAssertNil(details["sawEgressDemandHost"], "a hostname must never reach a shared bundle")
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Observation order (PR #582)

    func testSameBootDelayedAppendIsOrderedByCapturedObservation() {
        // Production mutation caught: ordering by file position leaves the delayed order-20
        // append after the order-30 incident and makes stale transport evidence look newest.
        let boot = "0123456789abcdef0123456789abcdef"
        let jsonLines = """
        {"component":"tunnel","event":"first","timestamp":"2026-08-25T12:00:00Z","observationOrder":"v1:\(boot):10"}
        {"component":"tunnel","event":"incident","timestamp":"2026-08-25T12:00:00Z","observationOrder":"v1:\(boot):30"}
        {"component":"tunnel","event":"delayed","timestamp":"2026-08-25T12:00:00Z","observationOrder":"v1:\(boot):20"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["first", "delayed", "incident"])
        XCTAssertEqual(entries.last?.event, "incident")
    }

    func testSmallWallClockJumpCannotOverrideCapturedObservationOrder() {
        // Production mutation caught: retaining the five-second wall-clock heuristic sorts this
        // same-boot run by display timestamps instead of its monotonic observation sequence.
        let boot = "0123456789abcdef0123456789abcdef"
        let jsonLines = """
        {"component":"tunnel","event":"first","timestamp":"2026-08-25T12:00:04Z","observationOrder":"v1:\(boot):10"}
        {"component":"tunnel","event":"newest","timestamp":"2026-08-25T12:00:03Z","observationOrder":"v1:\(boot):30"}
        {"component":"tunnel","event":"middle-delayed","timestamp":"2026-08-25T12:00:05Z","observationOrder":"v1:\(boot):20"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["first", "middle-delayed", "newest"])
    }

    func testLargeWallClockJumpCannotSplitOneBootRun() {
        // Production mutation caught: classifying a large timestamp regression as a new epoch
        // preserves the wrong physical order even though one boot's monotonic key is comparable.
        let boot = "0123456789abcdef0123456789abcdef"
        let jsonLines = """
        {"component":"tunnel","event":"first","timestamp":"2026-08-25T13:00:00Z","observationOrder":"v1:\(boot):10"}
        {"component":"tunnel","event":"newest","timestamp":"2026-08-25T12:00:00Z","observationOrder":"v1:\(boot):30"}
        {"component":"tunnel","event":"middle-delayed","timestamp":"2026-08-25T14:00:00Z","observationOrder":"v1:\(boot):20"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["first", "middle-delayed", "newest"])
    }

    func testBootChangeIsAPhysicalOrderBarrier() {
        // Production mutation caught: comparing monotonic values across boot IDs moves boot B's
        // small counters ahead of boot A even though the clock domains are incomparable.
        let bootA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let bootB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let jsonLines = """
        {"component":"tunnel","event":"a-later","timestamp":"2026-08-25T12:00:04Z","observationOrder":"v1:\(bootA):20"}
        {"component":"tunnel","event":"a-earlier","timestamp":"2026-08-25T12:00:03Z","observationOrder":"v1:\(bootA):10"}
        {"component":"tunnel","event":"b-later","timestamp":"2026-08-25T12:00:02Z","observationOrder":"v1:\(bootB):20"}
        {"component":"tunnel","event":"b-earlier","timestamp":"2026-08-25T12:00:01Z","observationOrder":"v1:\(bootB):10"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["a-earlier", "a-later", "b-earlier", "b-later"])
    }

    func testBootTimeFallbackDomainChangeIsAPhysicalOrderBarrier() {
        // Production mutation caught: globally sorting fallback tokens treats a conservative
        // manual-wall-time split as permission to compare unrelated monotonic coordinates.
        let beforeStep = "62747631000000006a78be4b000dfdbe"
        let afterStep = "62747631000000006a78be4c000dfdbe"
        let jsonLines = """
        {"component":"tunnel","event":"before-later","timestamp":"2026-08-25T12:00:04Z","observationOrder":"v1:\(beforeStep):20"}
        {"component":"tunnel","event":"before-earlier","timestamp":"2026-08-25T12:00:03Z","observationOrder":"v1:\(beforeStep):10"}
        {"component":"tunnel","event":"after","timestamp":"2026-08-25T12:00:02Z","observationOrder":"v1:\(afterStep):1"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["before-earlier", "before-later", "after"])
    }

    func testABARunsDoNotMergeAcrossTheInterveningBoot() {
        // Production mutation caught: grouping by boot ID globally merges the two A runs and
        // moves the final A entry across the intervening reboot evidence.
        let bootA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let bootB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let jsonLines = """
        {"component":"tunnel","event":"a-before","timestamp":"2026-08-25T12:00:03Z","observationOrder":"v1:\(bootA):20"}
        {"component":"tunnel","event":"b","timestamp":"2026-08-25T12:00:02Z","observationOrder":"v1:\(bootB):10"}
        {"component":"tunnel","event":"a-after","timestamp":"2026-08-25T12:00:01Z","observationOrder":"v1:\(bootA):10"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["a-before", "b", "a-after"])
    }

    func testOneBootRunSortsAcrossTheRotationBoundary() {
        // Production mutation caught: treating the chunk boundary itself as a barrier leaves a
        // delayed rotated-file append ahead of the earlier current-file observation.
        let boot = "0123456789abcdef0123456789abcdef"
        let rotated = Data("""
        {"component":"tunnel","event":"later-in-rotated","timestamp":"2026-08-25T12:00:00Z","observationOrder":"v1:\(boot):20"}
        """.utf8)
        let current = Data("""
        {"component":"tunnel","event":"earlier-in-current","timestamp":"2026-08-25T12:00:00Z","observationOrder":"v1:\(boot):10"}
        """.utf8)

        let entries = BugReportDebugLogEntry.parseJSONLines(
            concatenating: [rotated, current], limit: 10)

        XCTAssertEqual(entries.map(\.event), ["earlier-in-current", "later-in-rotated"])
    }

    func testLegacyEntryWithoutOrderIsAPhysicalOrderBarrier() {
        // Production mutation caught: dropping unkeyed legacy entries before ordering lets the
        // two keyed sides collapse into one run and cross a line from a shipped older build.
        let boot = "0123456789abcdef0123456789abcdef"
        let jsonLines = """
        {"component":"tunnel","event":"keyed-before","timestamp":"2026-08-25T12:00:03Z","observationOrder":"v1:\(boot):20"}
        {"component":"tunnel","event":"legacy","timestamp":"2026-08-25T12:00:02Z"}
        {"component":"tunnel","event":"keyed-after","timestamp":"2026-08-25T12:00:01Z","observationOrder":"v1:\(boot):10"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["keyed-before", "legacy", "keyed-after"])
    }

    func testMalformedOrderIsAPhysicalOrderBarrier() {
        // Production mutation caught: treating a malformed token as absent only after sorting
        // lets valid keyed entries cross metadata that cannot establish a clock domain.
        let boot = "0123456789abcdef0123456789abcdef"
        let jsonLines = """
        {"component":"tunnel","event":"keyed-before","timestamp":"2026-08-25T12:00:03Z","observationOrder":"v1:\(boot):20"}
        {"component":"tunnel","event":"bad-token","timestamp":"2026-08-25T12:00:02Z","observationOrder":"v1:\(boot):01"}
        {"component":"tunnel","event":"keyed-after","timestamp":"2026-08-25T12:00:01Z","observationOrder":"v1:\(boot):10"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["keyed-before", "bad-token", "keyed-after"])
    }

    func testMalformedJSONIsAPhysicalOrderBarrier() {
        // Production mutation caught: compact-mapping malformed lines before ordering makes
        // valid keyed entries on opposite sides look contiguous and reorders across lost bytes.
        let boot = "0123456789abcdef0123456789abcdef"
        let jsonLines = """
        {"component":"tunnel","event":"keyed-before","timestamp":"2026-08-25T12:00:03Z","observationOrder":"v1:\(boot):20"}
        {this line was torn by rotation
        {"component":"tunnel","event":"keyed-after","timestamp":"2026-08-25T12:00:01Z","observationOrder":"v1:\(boot):10"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["keyed-before", "keyed-after"])
    }

    func testBlankJSONLineIsAPhysicalOrderBarrier() {
        // Production mutation caught: restoring String.split's default empty-subsequence omission
        // erases this blank malformed line and sorts the two same-boot sides as one run.
        let boot = "0123456789abcdef0123456789abcdef"
        let jsonLines = """
        {"component":"tunnel","event":"keyed-before","timestamp":"2026-08-25T12:00:03Z","observationOrder":"v1:\(boot):20"}

        {"component":"tunnel","event":"keyed-after","timestamp":"2026-08-25T12:00:01Z","observationOrder":"v1:\(boot):10"}
        """ + "\n" // An ordinary terminal JSONL delimiter must not surface a phantom entry.

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["keyed-before", "keyed-after"])
    }

    func testInvalidUTF8JSONLineIsAPhysicalOrderBarrier() {
        // Production mutation caught: loss-tolerant whole-buffer decoding repairs 0xff into U+FFFD,
        // turning this damaged keyed line into a public entry and joining both valid sides.
        let boot = "0123456789abcdef0123456789abcdef"
        var bytes = Array(
            ("{\"component\":\"tunnel\",\"event\":\"keyed-before\","
                + "\"timestamp\":\"2026-08-25T12:00:03Z\","
                + "\"observationOrder\":\"v1:\(boot):20\"}\n"
                + "{\"component\":\"tunnel\",\"event\":\"invalid-").utf8
        )
        bytes.append(0xff)
        bytes.append(contentsOf:
            ("\",\"timestamp\":\"2026-08-25T12:00:02Z\","
                + "\"observationOrder\":\"v1:\(boot):15\"}\n"
                + "{\"component\":\"tunnel\",\"event\":\"keyed-after\","
                + "\"timestamp\":\"2026-08-25T12:00:01Z\","
                + "\"observationOrder\":\"v1:\(boot):10\"}").utf8
        )

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(bytes), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["keyed-before", "keyed-after"])
    }

    func testCRLFDelimitersPreserveOneSameBootRun() {
        // Production mutation caught: splitting raw bytes on CR and LF independently inserts an
        // empty barrier between every CRLF record and prevents this valid same-boot reorder.
        let boot = "0123456789abcdef0123456789abcdef"
        let jsonLines =
            "{\"component\":\"tunnel\",\"event\":\"later\","
            + "\"timestamp\":\"2026-08-25T12:00:02Z\","
            + "\"observationOrder\":\"v1:\(boot):20\"}\r\n"
            + "{\"component\":\"tunnel\",\"event\":\"earlier\","
            + "\"timestamp\":\"2026-08-25T12:00:01Z\","
            + "\"observationOrder\":\"v1:\(boot):10\"}\r\n"

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["earlier", "later"])
    }

    func testEqualMonotonicValuesKeepPhysicalOrder() {
        // Production mutation caught: omitting the physical-index tie-break delegates equal keys
        // to Swift's unstable sort and can permute otherwise indistinguishable observations.
        let boot = "0123456789abcdef0123456789abcdef"
        let jsonLines = """
        {"component":"tunnel","event":"first","timestamp":"2026-08-25T12:00:03Z","observationOrder":"v1:\(boot):42"}
        {"component":"tunnel","event":"second","timestamp":"2026-08-25T12:00:02Z","observationOrder":"v1:\(boot):42"}
        {"component":"tunnel","event":"third","timestamp":"2026-08-25T12:00:01Z","observationOrder":"v1:\(boot):42"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["first", "second", "third"])
    }

    func testOrderingRunsBeforeChurnFiltering() {
        // Production mutation caught: filtering the unkeyed churn barrier first merges the keyed
        // sides and moves `after` ahead of `before`, even though their order is incomparable.
        let boot = "0123456789abcdef0123456789abcdef"
        let jsonLines = """
        {"component":"tunnel","event":"before","timestamp":"2026-08-25T12:00:03Z","observationOrder":"v1:\(boot):20"}
        {"component":"live-activity-controller","event":"reconcile","timestamp":"2026-08-25T12:00:02Z"}
        {"component":"tunnel","event":"after","timestamp":"2026-08-25T12:00:01Z","observationOrder":"v1:\(boot):10"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.map(\.event), ["before", "after"])
    }

    func testOrderingRunsBeforeTheTransportTransitionCap() {
        // Production mutation caught: capping physical file order first keeps monotonic 1...6 and
        // drops 7; sorting first keeps the six genuinely newest transitions, 2...7.
        let boot = "0123456789abcdef0123456789abcdef"
        let lines = stride(from: 7, through: 1, by: -1).map { value in
            "{\"component\":\"tunnel\",\"event\":\"chained-transport-state\","
                + "\"timestamp\":\"2026-08-25T12:00:00Z\",\"channel\":\"\(value)\","
                + "\"observationOrder\":\"v1:\(boot):\(value)\"}"
        }

        let entries = BugReportDebugLogEntry.parseJSONLines(
            Data(lines.joined(separator: "\n").utf8), limit: 40)

        XCTAssertEqual(entries.count, BugReportDebugLogEntry.transportTransitionReportCap)
        XCTAssertEqual(entries.map { $0.details["channel"] }, ["2", "3", "4", "5", "6", "7"])
    }

    func testFinalSuffixRetainsIncidentAfterMoreThanFortyDelayedWrites() {
        // Production mutation caught: applying suffix(40) before ordering excludes the incident
        // that was physically followed by 41 delayed writes but observed after every one of them.
        let boot = "0123456789abcdef0123456789abcdef"
        var lines = [
            "{\"component\":\"tunnel\",\"event\":\"incident\","
                + "\"timestamp\":\"2026-08-25T12:00:00Z\","
                + "\"observationOrder\":\"v1:\(boot):100\"}"
        ]
        lines += (1...41).map { value in
            "{\"component\":\"tunnel\",\"event\":\"delayed-\(value)\","
                + "\"timestamp\":\"2026-08-25T13:00:00Z\","
                + "\"observationOrder\":\"v1:\(boot):\(value)\"}"
        }

        let entries = BugReportDebugLogEntry.parseJSONLines(
            Data(lines.joined(separator: "\n").utf8), limit: 40)

        XCTAssertEqual(entries.count, 40)
        XCTAssertEqual(entries.first?.event, "delayed-3")
        XCTAssertEqual(entries.last?.event, "incident")
    }

    func testObservationOrderNeverLeavesTheRawOrderingPass() throws {
        // Production mutation caught: forwarding the structural token into details exposes it in
        // entry dictionaries, request bodies, local-export JSONL, and future `_withheld` counts.
        let boot = "62747631000000006a78be4b000dfdbe"
        let entries = BugReportDebugLogEntry.parseJSONLines(Data("""
        {"component":"tunnel","event":"incident","timestamp":"2026-08-25T12:00:00Z","kind":"wifi","observationOrder":"v1:\(boot):10"}
        """.utf8), limit: 10)
        let entry = try XCTUnwrap(entries.first)
        let entryJSON = try jsonString(entry.dictionary)
        let bodyJSON = try jsonString(makeBundle(
            context: BugReportContext(
                issueType: .vpnOrFilterIssue,
                details: "Connection stalled.",
                includeDiagnostics: true
            ),
            debugLogEntries: entries
        ).makeRequestBody())

        XCTAssertNil(entry.details["observationOrder"])
        XCTAssertNil(entry.details["_withheld"])
        XCTAssertFalse(entryJSON.contains("observationOrder"))
        XCTAssertFalse(bodyJSON.contains("observationOrder"))
    }

    func testTheDeviceLogStillWritesMillisecondDisplayTimestamps() {
        // Production mutation caught: returning the display formatter to whole seconds loses the
        // sub-second precision used by people reading raw logs, even though it no longer orders.
        let stamped = SharedDateFormatting.iso8601WithMilliseconds.string(
            from: Date(timeIntervalSince1970: 1_787_659_201.234))

        XCTAssertTrue(stamped.contains(".234"), "the stamp must carry milliseconds: \(stamped)")
    }

    /// A CUSTOM ENCRYPTED endpoint is redacted, and its counters are still folded.
    ///
    /// The two halves are one bug. `ResolverOrchestrator.resolveEndpoints` records an encrypted
    /// attempt under the endpoint's `cacheIdentifier` — the complete `doh:<absolute URL>`, path and
    /// query included — while the T1 display projection publishes the bare host. The redaction
    /// folds resolver counters onto placeholders by matching those keys, so a host-only map matched
    /// nothing: the URL reached the report intact AND the T1 counters it keyed were attributed
    /// to nobody (Codex P1, PR #591).
    ///
    /// Invisible until this PR, because until then the rung could only ever be plain IPv4, where
    /// the attempt key IS the address.
    func testACustomEncryptedEndpointIsRedactedAndItsCountersFolded() throws {
        let privateURL = "doh:https://dns.internal.example/private-path?token=secret"
        var health = TunnelHealthSnapshot(startedAt: Date(), updatedAt: Date())
        health.chainedFallbackEvaluated = true
        // What the PANEL shows: the host alone.
        health.chainedFallbackLatchedAddresses = ["dns.internal.example"]
        health.chainedFallbackEffectiveAddresses = ["dns.internal.example"]
        health.chainedFallbackOutcomes = [
            ChainedFallbackAddressOutcome(
                address: "dns.internal.example", disposition: .admitted)
        ]
        // What the COUNTERS are keyed by: the whole identifier.
        health.chainedFallbackAttemptKeys = [privateURL]
        health.resolverAttemptCounts = [privateURL: 5, "10.64.0.1": 2]
        health.resolverSuccessCounts = [privateURL: 4]
        health.lastResolverAddress = privateURL

        let snapshot = BugReportVPNSnapshot(
            status: "connected", resolverPreset: "Custom", health: health)
        let encoded = String(
            decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

        XCTAssertFalse(
            encoded.contains("dns.internal.example"),
            "a hand-entered DoH host names the user's network as surely as an IPv4 does")
        XCTAssertFalse(
            encoded.contains("private-path"),
            "the URL's PATH is the sharpest half and must not survive")
        XCTAssertFalse(encoded.contains("secret"), "nor its query")

        // ...and the DIAGNOSTIC survives the redaction, which is the half a bare `contains` check
        // would not have caught: five attempts and four successes, attributed to T1.
        XCTAssertEqual(
            snapshot.health.resolverAttemptCounts[TunnelHealthSnapshot.redactedFallbackAddress], 5)
        XCTAssertEqual(
            snapshot.health.resolverSuccessCounts[TunnelHealthSnapshot.redactedFallbackAddress], 4)
        XCTAssertEqual(
            snapshot.health.lastResolverAddress, TunnelHealthSnapshot.redactedFallbackAddress,
            "which tier served the last query is exactly what a triager wants, and it survives")
        XCTAssertEqual(
            snapshot.health.resolverAttemptCounts["10.64.0.1"], 2,
            "the conf's own resolver is untouched — this fold is about the T1 keys")
    }
}
